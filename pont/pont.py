#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# pont.py — Pont TRX burst-level entre osmo-bts-trx et l'API RAM du Calypso.
#
# Voie A (validée) : L2 DE BOUT EN BOUT. Le pont ne transporte JAMAIS d'IQ ni de
# burst brut dans d_burst_d ; il code/décode le CANAL via libosmocoding (ctypes),
# puis réutilise le chemin SHUNT_LEGIT déjà en place :
#   - DL (BTS->UE) : burst TRXD -> libosmocoding decode -> L2 -> GSMTAP 4730/4731
#                    (le shunt in-QEMU écrit a_cd / feed_sb ; on ne touche pas QEMU).
#   - UL (UE->BTS) : L2 déposée par l'ARM dans /dev/shm/calypso_* -> libosmocoding
#                    encode -> bursts -> TRXD -> BTS.
#
# Process SÉPARÉ : ne patche NI QEMU NI osmocom-bb NI gapk.
#
# RÈGLE DE SENS (en rôle, pas "DL/UL" absolu) :
#   ce que la BTS ÉMET sur DATA (son TX)  -> reçu par le Calypso (on décode->GSMTAP).
#   ce que le Calypso ÉMET (sidebands)    -> renvoyé à la BTS comme son RX (on encode->TRXD).

import socket, struct, threading, time, os, ctypes, sys, collections, signal

# =========================== CONFIG (tête de fichier) ===========================
TRX_BIND      = os.environ.get("PONT_TRX_BIND",   "127.0.0.1")
TRX_REMOTE    = os.environ.get("PONT_TRX_REMOTE", "127.0.0.1")
TRX_BASE      = int(os.environ.get("PONT_TRX_BASE", "5700"))   # CLCK+0 CTRL+1 DATA+2
BSIC          = int(os.environ.get("PONT_BSIC", "7"))
ARFCN         = int(os.environ.get("PONT_ARFCN", "514"))

# POINT 3 — TIMING UL. Un burst UL hors fenêtre est JETÉ EN SILENCE par la BTS.
# Décalage d'avance UL en frames TDMA : on poste le burst quand l'horloge atteint
# (l1s_fn - UL_FN_ADVANCE). À AJUSTER empiriquement via le compteur hors-fenêtre.
UL_FN_ADVANCE = int(os.environ.get("PONT_UL_FN_ADVANCE", "3"))
WINDOW_TOL    = int(os.environ.get("PONT_WINDOW_TOL", "1"))
# RSSI annonce a la BTS pour nos bursts montants (uint8 = -dBm).
PONT_RSSI     = int(os.environ.get("PONT_RSSI", "60"))

GSMTAP_HOST   = "127.0.0.1"
PORT_GSMTAP   = int(os.environ.get("CALYPSO_SHUNT_GSMTAP_PORT", "4730") or "4730")  # SI/CCCH/SDCCH/SACCH
PORT_SCH      = int(os.environ.get("CALYPSO_SHUNT_SCH_PORT",    "4731") or "4731")  # SCH/BSIC
SB_SDCCH_UL   = "/dev/shm/calypso_sdcch_ul"     # 48o: seq u32 | l1s%51 u8 | l1s_fn u32 | l2[23]
SB_RACH       = "/dev/shm/calypso_rach"
DCCH_CFG      = "/dev/shm/calypso_dcch_cfg"
BSC_CFG       = os.environ.get("PONT_BSC_CFG", "/etc/osmocom/osmo-bsc.cfg")

GSM_HYPERFRAME = 26 * 51 * 2048         # 2 715 648
FRAME_DUR      = 60.0 / 13000.0         # 4.615 ms (POINT 4 : durée d'une trame TDMA)

# =========================== libosmocoding (ctypes) ============================
# Réutilise l'encodeur/décodeur de RÉFÉRENCE (GSM 05.03), le MÊME que qemu_wrap.c.
_cod = ctypes.CDLL("libosmocoding.so", use_errno=True)
ubit = ctypes.c_int8       # ubit_t : 0/1
sbit = ctypes.c_int8       # sbit_t : soft-bit signé (+/-127)
_cod.gsm0503_xcch_encode.argtypes      = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8)]
_cod.gsm0503_xcch_decode.argtypes      = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit),
                                          ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_rach_ext_encode.argtypes  = [ctypes.POINTER(ubit), ctypes.c_uint16, ctypes.c_uint8, ctypes.c_bool]
_cod.gsm0503_rach_ext_decode_ber.argtypes = [ctypes.POINTER(ctypes.c_uint16), ctypes.POINTER(sbit),
                                          ctypes.c_uint8, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_sch_encode.argtypes       = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8)]
# TCH/F plein debit : 8 bursts x 114 bits, entrelacement DIAGONAL (bloc tous les 4 bursts).
_cod.gsm0503_tch_fr_encode.argtypes    = [ctypes.POINTER(ubit), ctypes.POINTER(ctypes.c_uint8),
                                          ctypes.c_int, ctypes.c_int]
_cod.gsm0503_tch_fr_decode.argtypes    = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit),
                                          ctypes.c_int, ctypes.c_int,
                                          ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
_cod.gsm0503_sch_decode.argtypes       = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(sbit)]

# ============================ CHIFFREMENT A5 (host-side) ======================
# On court-circuite la crypto du DSP comme on court-circuite deja la demodulation.
# Le Kc est celui capte par osmocon (L1CTL_CRYPTO_REQ) dans /dev/shm/calypso_kc :
#   [0..3]seq u32 | [4]algo | [5]key_len=8 | [6..13]Kc | [14]cksn
# On applique le keystream osmo_a5() sur les 2x57 bits UTILES du burst normal
# (positions 3..59 et 88..144 — les 2 bits de vol, 60 et 87, ne sont PAS chiffres).
#   DL (recu de la BTS) : dechiffrer AVANT le decodage canal.
#   UL (emis vers la BTS) : chiffrer APRES l'encodage canal.
# C'est exactement ce que faisait ul_cipher_burst (qemu_wrap.c:1902), au meme
# etage logique — mais cote pont, puisque l'ipc-device est eteint en mode pont.
_gsm = ctypes.CDLL("libosmogsm.so", use_errno=True)
_gsm.osmo_a5.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32,
                         ctypes.POINTER(ubit), ctypes.POINTER(ubit)]
KC_PATH   = "/dev/shm/calypso_kc"
A5_FORCE  = int(os.environ.get("PONT_A5", "0"))      # 0 = suit l'algo du Kc ; 1..3 = force
A5_FN_ADJ = int(os.environ.get("PONT_A5_FN_ADJ", "0"))

_kc_fd = None
_kc_cache = (0, None)
_kc_next = 0.0
KC_TTL = 0.1        # 100 ms : bien plus court qu'une transaction, 0 syscall par burst

def kc_read():
    """(algo, Kc[8]) si un Kc valide est publie, sinon (0, None).

    ⚠️ COUT : appele a CHAQUE burst (DL et UL). L'ancienne version faisait
    open+pread+close par appel, soit ~4800 syscalls/s — assez pour voler du temps
    d'ordonnancement a trxcon/fake_trx (MS#2), qui sont temps-reel : leurs bursts
    montants partaient une trame en retard et fake_trx les jetait ("Stale TRXD").
    On garde donc UN fd et on ne relit qu'au plus toutes les KC_TTL secondes.
    pread reste obligatoire (un lecteur bufferise figerait la valeur, regle projet)."""
    global _kc_fd, _kc_cache, _kc_next
    now = time.monotonic()
    if now < _kc_next:
        return _kc_cache
    _kc_next = now + KC_TTL
    try:
        if _kc_fd is None:
            _kc_fd = os.open(KC_PATH, os.O_RDONLY)
        b = os.pread(_kc_fd, 32, 0)
    except OSError:
        try:
            if _kc_fd is not None:
                os.close(_kc_fd)
        except OSError:
            pass
        _kc_fd = None
        _kc_cache = (0, None)
        return _kc_cache
    if len(b) < 14:
        _kc_cache = (0, None); return _kc_cache
    algo = b[4]
    kc = b[6:14]
    if algo < 1 or algo > 3 or not any(kc):
        _kc_cache = (0, None); return _kc_cache
    _kc_cache = ((A5_FORCE if A5_FORCE else algo), kc)
    return _kc_cache

_a5_last = {"applied": False, "algo": 0, "kc4": ""}

def a5_apply(burst148, fn, uplink):
    """XOR du keystream A5 sur les 114 bits utiles. Renvoie le burst modifie."""
    algo, kc = kc_read()
    if not algo:
        _a5_last["applied"] = False
        return burst148                       # pas de Kc -> on ne touche a rien
    _a5_last["applied"] = True
    _a5_last["algo"] = algo
    _a5_last["kc4"] = kc[:4].hex()
    key = (ctypes.c_uint8 * 8)(*kc)
    dl = (ubit * 114)(); ul = (ubit * 114)()
    _gsm.osmo_a5(algo, key, ctypes.c_uint32((fn + A5_FN_ADJ) & 0xffffffff), dl, ul)
    ks = ul if uplink else dl
    # ⚠️ DEUX DOMAINES D'OCTETS DIFFERENTS — c'etait LE bug :
    #   UL (interne)  : 0x01 = bit 1, 0xFF = bit 0  (ce que construit normal_from_burst116)
    #   DL (TRXD brut): 0x01 = bit 1, 0x00 = bit 0  (octets recus tels quels de la BTS)
    # Inverser 0x01 -> 0xFF cote DL laissait le bit A 1 (plus loin, `-127 if v else 127`
    # traite 0xFF comme vrai) : la moitie du XOR etait un NO-OP.
    b = bytearray(burst148)
    if uplink:
        def _flip(x): return 0xFF if x == 0x01 else 0x01
    else:
        def _flip(x): return 0x00 if x else 0x01
    for i in range(57):                       # bloc 1 : positions 3..59
        if ks[i]:
            b[3 + i] = _flip(b[3 + i])
    for i in range(57):                       # bloc 2 : positions 88..144
        if ks[57 + i]:
            b[88 + i] = _flip(b[88 + i])
    if uplink: ST.n_a5_ul += 1
    else:      ST.n_a5_dl += 1
    return bytes(b)

# ---- Mapping burst normal <-> 116 bits codés (identique à qemu_wrap.c:856-868) ----
TSC7 = bytes([1,1,1,0,1,1,1,1,0,0,0,1,0,0,1,0,1,1,1,0,1,1,1,1,0,0])
# Un burst normal (148 bits actifs) : [3 tail][58 e][26 TSC][58 e][3 tail].
# Les 2x58 = 116 bits codés ; xcch travaille sur 4 bursts = 4x116.

def burst116_from_normal(b148):
    """DL : extrait les 116 bits codés (soft) d'un burst normal TRXD de 148 bits."""
    return b148[3:61] + b148[87:145]         # 58 + 58

def normal_from_burst116(cB):
    """UL : place 116 bits codés (ubit) dans un burst normal de 148 bits (+/-1 soft)."""
    ab = bytearray(148)
    p = 0
    for _ in range(3):          ab[p]=0xFF; p+=1                 # tail (-1)
    for i in range(58):         ab[p]=1 if cB[i] else 0xFF; p+=1 # data 1
    for i in range(26):         ab[p]=1 if TSC7[i] else 0xFF; p+=1
    for i in range(58):         ab[p]=1 if cB[58+i] else 0xFF; p+=1
    for _ in range(3):          ab[p]=0xFF; p+=1                 # tail
    return ab                    # 0x01 = +1, 0xFF = -1 (soft-bit signé)

def xcch_decode_4(bursts4_116):
    """DL : 4x116 soft-bits -> L2[23]. bursts4_116 = liste de 4 séquences de 116."""
    buf = (sbit * (4*116))()
    for k in range(4):
        for i in range(116):
            v = bursts4_116[k][i]
            # Convention osmocom (osmo_ubit2sbit) : ubit 1 -> sbit -127,
            # ubit 0 -> sbit +127. L'inverse fait echouer TOUS les CRC.
            buf[k*116+i] = -127 if v else 127
    l2 = (ctypes.c_uint8 * 23)()
    ne = ctypes.c_int(); nb = ctypes.c_int()
    rc = _cod.gsm0503_xcch_decode(l2, buf, ctypes.byref(ne), ctypes.byref(nb))
    return (bytes(l2), rc, ne.value) if rc == 0 else (None, rc, ne.value)

def xcch_encode_4(l2_23):
    """UL : L2[23] -> 4 bursts normaux (148 bits) prêts pour TRXD."""
    l2 = (ctypes.c_uint8 * 23)(*l2_23[:23])
    e  = (ubit * (4*116))()
    _cod.gsm0503_xcch_encode(e, l2)
    return [normal_from_burst116([e[k*116+i] for i in range(116)]) for k in range(4)]

# =========================== POINT 2 — slot mapping ============================
# NE PAS coder en dur : on LIT le channel-description depuis osmo-bsc.cfg.
# Fallback = table normative GSM 05.02 (TS0 = CCCH+SDCCH/4).
def load_ts_config(path):
    """Retourne {tn: phys_chan_config} lu du 1er 'trx' d'osmo-bsc.cfg."""
    ts = {}
    try:
        cur = None
        for line in open(path, encoding="utf-8", errors="ignore"):
            s = line.strip()
            if s.startswith("timeslot "):
                cur = int(s.split()[1])
            elif s.startswith("phys_chan_config") and cur is not None:
                ts[cur] = s.split(None, 1)[1].strip(); cur = None
    except OSError:
        pass
    if not ts:
        ts = {0: "CCCH+SDCCH4", 1: "SDCCH8", 2: "TCH/F", 3: "TCH/F"}
    return ts

TS_CONFIG = load_ts_config(BSC_CFG)

# Sous-voies SDCCH/4 combiné (TS0) : positions DL fn%51 et SACCH fn%102 (GSM 05.02).
SD4_DL_BASE   = [22, 26, 32, 36]        # 4 bursts consécutifs à base..base+3
SD4_SACCH_102 = [42, 46, 93, 97]        # SACCH fn%102 (POINT 1 : période 102, pas 51)
BCCH_FN51     = [2, 6, 12, 16]          # BCCH bloc (info système) fn%51

# =========================== compteurs / instrumentation ======================
class Stats:
    def __init__(s):
        s.n_dl_bursts=0; s.n_dl_decoded=0; s.n_dl_crc_fail=0
        s.n_ul_sent=0;   s.n_ul_out_of_window=0; s.n_rach=0
        s.n_tch_dl=0;    s.n_tch_ul=0;           s.n_tch_crc=0
        s.n_a5_dl=0;     s.n_a5_ul=0
        s.n_dcch_err=0
        s.n_facch_dl=0;  s.n_facch_ul=0;  s.n_tch_gap=0
        s.n_by_base={}   # base51 -> [decodes, crc_fail]
        s.n_act_clear=[0,0]  # sous-voie ACTIVE, en clair  : [decodes, total]
        s.n_act_ciph =[0,0]  # sous-voie ACTIVE, chiffree : [decodes, total]
        s.n_bsp_fed=0;   s.n_bsp_err=0   # relais des bursts DL vers le BSP
        s.n_tch_ul_court=0               # slots montants tronques (doit rester 0)
        s.n_tch_ul_drop=0                # trames voix jetees : file pleine
        s.n_tch_ul_vole=0                # voix cedee a une FACCH (normatif)
        s.n_tch_burst=0                  # bursts TCH montants reellement emis
    def log(s, msg): print("[pont] %s" % msg, flush=True)
ST = Stats()

# =========================== horloge FN (POINT 4) =============================
# FN = f(t - t0) sur time.monotonic() ABSOLU, jamais accumulation de sleep()
# (sinon drift cumulatif -> UL hors fenêtre après quelques minutes).
_T0 = None
def now_fn():
    return int((time.monotonic() - _T0) / FRAME_DUR) % GSM_HYPERFRAME

# =========================== sockets ==========================================
def mksock(bind_port):
    # PAS de SO_REUSEADDR : en UDP il autorise DEUX ponts a binder le meme port
    # sans erreur -> deux horloges concurrentes (t0 differents) -> la BTS voit
    # "GSM clock skew: old fn=X, new fn=Y" en boucle. Sans lui, un second pont
    # echoue BRUYAMMENT (EADDRINUSE), ce qui est le comportement voulu.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind((TRX_BIND, bind_port))
    except OSError as e:
        print("[pont] ECHEC bind %s:%d (%s) — un autre pont tourne deja ?"
              % (TRX_BIND, bind_port, e), flush=True)
        raise
    return s

# CLCK/CTRL/DATA côté BTS-facing (osmo-bts-trx s'y connecte).
sk_clck = mksock(TRX_BASE + 0)     # 5700 : IND CLOCK -> BTS
sk_ctrl = mksock(TRX_BASE + 1)     # 5701 : CMD/RSP
sk_data = mksock(TRX_BASE + 2)     # 5702 : bursts (bidir)
sk_gsmtap = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)  # -> shunt in-QEMU

# ------------------------- relais des bursts DL vers le BSP -------------------
# Le module BSP de QEMU (calypso_bsp.c) ECOUTE des bursts TRXD sur 6702 —
# `BSP_TRXD_PORT 6702  /* bridge forwards DL bursts here (5702 is bridge's own) */`.
# C'etait l'ancien bridge qui l'alimentait ; en mode pont plus personne ne le
# fait, donc le BSP est a sec.
#
# ⚠️ CE QUE CA DONNE, ET CE QUE CA NE DONNE PAS. Sous DSP_SHUNT le BSP draine
# l'UDP, publie l'I/Q (feed_iq) et APPREND son peer UL — puis il `return` AVANT
# de remplir la DARAM (calypso_bsp.c ~l.545 : « le vrai DSP ne consomme JAMAIS
# la DARAM », sinon la queue sature et la backpressure tue l'IPC/BTS). Donc ceci
# reanime l'I/Q partagee (enregistrement cfile, grgsm relay) et prepare le peer,
# mais ne fait PAS demoduler le DSP : ca reste gate derriere le revive c54x
# (CALYPSO_DSP_RUN_C54X=1), lui-meme bloque par le mur de vitesse de
# l'interpreteur. Ne pas lire une reprise du natif la-dedans.
#
# Format attendu (calypso_bsp.c, TRXDv0 DL) : tn(1) fn(4 BE) rssi(1) toa(2)
# bits(148) = 156 o ; le module fait `nbits = n - 8` et `bits = buf + 8`.
# La BTS, elle, nous envoie un en-tete de 6 o (ver|tn, fn BE, pwr) : on reprend
# ces 6 o tels quels (buf[5] devient `bsp.last_att`) et on insere les 2 o de ToA.
BSP_FEED      = os.environ.get("PONT_BSP_FEED", "1") == "1"
BSP_HOST      = os.environ.get("PONT_BSP_HOST", "127.0.0.1")
BSP_PORT      = int(os.environ.get("PONT_BSP_PORT", "6702"))
sk_bsp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

_bts_addr = {"clck": None, "data": None}   # appris à la 1re trame reçue

# =========================== GSMTAP (DL -> shunt) =============================
GSMTAP_BCCH=0x01; GSMTAP_CCCH=0x04; GSMTAP_SDCCH4=0x07; GSMTAP_SACCH=0x07|0x80
# Types RR relayes (identiques a si_bridge.py:20-25) : sans ce tri, le shunt
# recoit du bourrage et le mobile ne voit jamais de sysinfo.
SI_TYPES   = {0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e}          # SI1 SI2 SI3 SI4 SI2bis SI2ter
CCCH_TYPES = {0x3f, 0x39, 0x3a, 0x21, 0x22, 0x24}          # IMM-ASSIGN(+EXT/REJ), PAG-REQ 1/2/3
def gsmtap(fn, chan, l2):
    # En-tête GSMTAP v2 (16 o) : version=2, hdr_len=4 (mots 32b), type=UM(0x01),
    # timeslot, arfcn(H), signal(b), snr(B), frame_number(I), sub_type=chan,
    # antenna, sub_slot, res. Format attendu par le shunt (feed_si).
    h = struct.pack(">BBBBHbBIBBBB", 2, 4, 0x01, 0, ARFCN, 0, 0, fn, chan, 0, 0, 0)
    return h + bytes(l2)

def feed_dl_l2(fn, chan, l2, port):
    sk_gsmtap.sendto(gsmtap(fn, chan, l2), (GSMTAP_HOST, port))

# ============================== VOIX TCH/F ====================================
# Contrats RELEVES dans le code (jamais supposes) :
#   /dev/shm/calypso_tch_cfg : 16 o — seq u32@0 | tn@4 | tsc@5 | arfcn u16@6 (LE)
#                              publie a l'ASSIGNMENT COMMAND (si_bridge _tch_write_cfg).
#   /dev/shm/calypso_tch_dl  : anneau — entete 8 o (w_seq u32@0 | n_slots u32@4),
#                              16 slots de 48 o : seq@0 l1s_fn@4 fn@8 fr[33]@16.
#                              ⚠️ ORDRE OBLIGATOIRE : le SLOT d'abord, w_seq ENSUITE.
#   /dev/shm/calypso_tch_ul  : meme format d'anneau, ecrit par le shunt (voix montante).
# TCH/F sur multitrame 26 : fn%26 0-11 et 13-24 = TCH, 12 = SACCH, 25 = idle.
TCH_ENABLED  = os.environ.get("PONT_TCH", "1") == "1"
TCH_CFG      = "/dev/shm/calypso_tch_cfg"
TCH_DL_PATH  = "/dev/shm/calypso_tch_dl"
TCH_UL_PATH  = "/dev/shm/calypso_tch_ul"
TCH_DL_SLOTS = 16          # = TCH_DL_RING_N du shunt, ne pas desynchroniser
TCH_DL_SLOT  = 48          # slot DESCENDANT : seq@0 | fn@4 | fr[33]@8
FR_BYTES     = 33
# ⚠️ LES DEUX ANNEAUX N'ONT PAS LE MEME SLOT. Le montant est publie par
# `tch_ul_publish_speech` (calypso_dsp_shunt.c) avec TCH_UL_SLOT_SZ=64 et une
# charge `seq@0 | l1s_fn@4 | fn@8 | fr[33]@16` — le commentaire du shunt dit
# « format IDENTIQUE au descendant », ce qui est vrai de la DISCIPLINE (entete
# 8 o, slot d'abord / w_seq ensuite) mais PAS de la taille de slot ni de
# l'offset de la trame. Reutiliser TCH_DL_SLOT ici lisait au pas de 48 dans un
# anneau de pas 64 (derive de +16 o par slot) et, comme `pread(48)` ne peut pas
# rendre les 49 octets exiges par la garde `len(sl) >= 16 + 33`, le `continue`
# etait INCONDITIONNEL : la voix montante du pont n'a jamais pu emettre une
# seule trame, par construction.
TCH_UL_SLOT  = 64          # slot MONTANT : seq@0 | l1s_fn@4 | fn@8 | fr[33]@16
TCH_UL_FR_OFS = 16
GSM_MACBLOCK_LEN = 23      # une FACCH decodee rend 23 (et non 33)
# [2026-08-16] 0x08 etait FAUX : 0x08 = GSMTAP_CHANNEL_SDCCH8. Le sous-type
# canonique de la FACCH/F est 0x09. Le shunt filtre sur un ensemble ferme
# {0x01, 0x04, 0x07, 0x87, 0x09, 0x89} et jette tout le reste (« autres canaux :
# drop ») : avec 0x08 la FACCH descendante etait DETRUITE a l'entree du shunt.
# Mesure du run : feed_facch = 0, alors que feed_si=2495 / feed_agch=4964 /
# feed_sdcch=50 / feed_sacch=16 — donc ni UA, ni ALERTING, ni CONNECT
# n'atteignaient le mobile pendant l'appel.
# ⚠️ C'est la REGRESSION d'un defaut deja solde le 12/08 cote gr-gsm
# (sous-type FACCH compare a 0x08 au lieu de 0x09), reintroduit ici.
GSMTAP_FACCH = 0x09        # GSMTAP_CHANNEL_FACCH_F

_tch_tn   = None           # timeslot TCH arme (None = pas d'appel)
_tch_seq  = 0
_tch_dl_w = 0              # w_seq de l'anneau descendant
_tch_fd   = None
_tch_acc  = []             # fenetre glissante des 8 derniers bursts (114 bits)
_ded_n    = 0              # compteur de blocs dedies traces
_tch_last_fn = None        # derniere FN TCH vue (continuite de la fenetre)

def _tch_next_fn(fn):
    """FN suivante PORTANT DE LA VOIX sur le TCH/F (saute 12=SACCH, 25=idle)."""
    n = (fn + 1) % GSM_HYPERFRAME
    while n % 26 in (12, 25):
        n = (n + 1) % GSM_HYPERFRAME
    return n

# --- PRODUCTEUR de calypso_tch_cfg (c'etait si_bridge, eteint en mode pont) ---
# Sans ce fichier, tch_cfg_read() rend None et TOUT le code TCH est mort
# (compteurs TCH dl=0 ul=0). On decode donc l'ASSIGNMENT COMMAND nous-memes,
# en miroir de si_bridge.check_assignment / _tch_write_cfg.
SB_FACCH_UL = "/dev/shm/calypso_tch_facch_ul"
_tch_wseq = 0

def tch_write_cfg(tn, tsc, arfcn):
    """Publie TN/TSC/ARFCN (16 o : seq u32@0 | tn@4 | tsc@5 | arfcn u16@6).
    seq ECRIT EN DERNIER = publication atomique (contrat si_bridge)."""
    global _tch_wseq
    _tch_wseq += 1
    buf = bytearray(16)
    buf[4] = tn & 0xff
    buf[5] = tsc & 0xff
    buf[6:8] = int(arfcn).to_bytes(2, "little")
    buf[0:4] = _tch_wseq.to_bytes(4, "little")
    fd = os.open(TCH_CFG, os.O_CREAT | os.O_WRONLY, 0o644)
    try:    os.pwrite(fd, bytes(buf), 0)
    finally: os.close(fd)
    ST.log("ASSIGNMENT COMMAND -> TCH arme : TN=%d TSC=%d ARFCN=%d (seq=%u)"
           % (tn, tsc, arfcn, _tch_wseq))

def check_assignment(l2, fn):
    """Detecte un ASSIGNMENT COMMAND (RR PD=0x06, MT=0x2e) sur le SDCCH DL et
    publie le TCH. Channel Description 2 (GSM 04.08 10.5.2.5), 3 octets :
      b0 chan_nr -> TN = b0 & 7
      b1 : TSC=(b1>>5)&7, H=(b1>>4)&1, ARFCN_high = b1 & 3
      b2 : ARFCN_low -> ARFCN = (high<<8)|low   [si H=0]"""
    for off in range(2, min(7, len(l2) - 5)):
        if l2[off] != 0x06 or l2[off + 1] != 0x2e:
            continue
        b0, b1, b2 = l2[off + 2], l2[off + 3], l2[off + 4]
        if (b1 >> 4) & 1:
            # Saut de frequence : REFUS EXPLICITE (comme si_bridge). Fabriquer
            # une ARFCN depuis MAIO/HSN donnerait un nombre FAUX en silence.
            ST.log("ASSIGNMENT COMMAND avec SAUT DE FREQUENCE (H=1) : TCH NON arme (fn=%u)" % fn)
            return
        tch_write_cfg(b0 & 0x07, (b1 >> 5) & 0x07, ((b1 & 0x03) << 8) | b2)
        return

def ul_facch_from_sideband():
    """FACCH montante : l'ASSIGNMENT COMPLETE du mobile part par la. Sans elle,
    le BSC reste en rll_ready=no et l'assignation echoue (EQUIPMENT FAILURE).
    Meme layout 48 o que le SDCCH UL : seq@0 l1s_fn@4 fn@8 task_u@12 l1s%51@14 l2[23]@16."""
    fd = None; last = 0
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.1); continue
        try:
            if fd is None:
                fd = os.open(SB_FACCH_UL, os.O_RDONLY)
            b = os.pread(fd, 48, 0)
            if len(b) >= 39:
                seq = struct.unpack_from("<I", b, 0)[0]
                if seq and seq != last:
                    last = seq
                    l2 = b[16:39]
                    # FACCH = bloc L2 de 23 o encode par gsm0503_tch_fr_encode
                    # avec len=GSM_MACBLOCK_LEN : la lib pose les bits de vol.
                    # [2026-08-16] ALIMENTATEUR, PLUS EMETTEUR. Ce thread postait
                    # lui-meme 8 bursts via emit_with_timing, en meme temps que
                    # tch_ul_loop faisait pareil pour la voix : deux threads sans
                    # aucun verrou (il n'y a AUCUN Lock dans ce fichier) qui
                    # calculaient chacun leur next_tch_fn() sur le MEME slot. Les
                    # deux sequences de 8 bursts s'entrelacaient et se
                    # detruisaient mutuellement -> voix hachee ET liberation
                    # d'appel qui n'aboutit pas (le DISC part sur FACCH).
                    # Desormais on FILE le bloc L2 ; l'ordonnanceur unique
                    # l'emettra, en volant la voix comme le fait une vraie FACCH.
                    with _tch_q_lock:
                        _tch_q_facch.append(bytes(l2[:GSM_MACBLOCK_LEN]))
                    ST.n_facch_ul += 1
        except OSError:
            fd = None; time.sleep(0.05)
        time.sleep(FRAME_DUR / 8)

def tch_cfg_read():
    """TN du TCH assigne, ou None. Publie a l'ASSIGNMENT, donc jamais devine."""
    global _tch_tn, _tch_seq
    try:
        fd = os.open(TCH_CFG, os.O_RDONLY)
        try:    b = os.pread(fd, 16, 0)
        finally: os.close(fd)
    except OSError:
        return _tch_tn
    if len(b) >= 8:
        seq = struct.unpack_from("<I", b, 0)[0]
        if seq and seq != _tch_seq:
            _tch_seq = seq
            _tch_tn  = b[4] & 7
            ST.log("TCH arme : TN=%d TSC=%d ARFCN=%d (seq=%u)"
                   % (_tch_tn, b[5], struct.unpack_from("<H", b, 6)[0], seq))
    return _tch_tn

def _tch_dl_open():
    """Cree/ouvre l'anneau descendant au format attendu par le shunt."""
    global _tch_fd, _tch_dl_w
    if _tch_fd is not None:
        return _tch_fd
    _tch_fd = os.open(TCH_DL_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    os.ftruncate(_tch_fd, 8 + TCH_DL_SLOTS * TCH_DL_SLOT)
    os.pwrite(_tch_fd, (0).to_bytes(4, "little") + TCH_DL_SLOTS.to_bytes(4, "little"), 0)
    _tch_dl_w = 0
    ST.log("anneau voix DL pret : %s (%d slots de %d o)" % (TCH_DL_PATH, TCH_DL_SLOTS, TCH_DL_SLOT))
    return _tch_fd

def tch_dl_publish(fr33, fn):
    """Publie une trame FR dans l'anneau : SLOT d'abord, w_seq ENSUITE."""
    global _tch_dl_w
    fd = _tch_dl_open()
    _tch_dl_w += 1
    # [2026-08-16] OFFSET CORRIGE — la trame FR se pose a 8, pas a 16.
    # Contrat REEL du shunt (calypso_dsp_shunt.c) : slot de TCH_DL_SLOT=48 o, et
    # la trame est lue par `memcpy(g_shunt.tch_dl_fr, buf + 8, 33)` — deux sites,
    # le tirage direct et le depilage de la file. Donc : seq@0 | fn@4 | fr[33]@8.
    # L'arithmetique suffit a le prouver : a l'offset 16 il faudrait 16+33 = 49 o
    # dans un slot de 48.
    # CE QUE L'ANCIENNE VERSION PRODUISAIT : elle ecrivait seq@0 | fn@4 | fn@8 |
    # 0x00 x4 @12 | fr@16, et son bourrage `b"\x00" * (48 - 16 - 33)` valait
    # `b"\x00" * -1` = b"" — donc rec faisait 49 o et le `rec[:48]` AMPUTAIT
    # fr[32]. Le shunt recopiait alors buf+8 = les 4 octets de fn, 4 zeros, puis
    # seulement fr[0..24] : signature FR a 0x7 au lieu de 0xD, 25 octets de voix
    # sur 33, decales de 8. gapk ne pouvait rendre que du bruit.
    rec = (_tch_dl_w.to_bytes(4, "little")
           + (fn & 0xffffffff).to_bytes(4, "little")
           + bytes(fr33)[:FR_BYTES])
    rec += b"\x00" * (TCH_DL_SLOT - len(rec))     # 48 - 41 = 7 o de bourrage
    assert len(rec) == TCH_DL_SLOT
    os.pwrite(fd, rec, 8 + ((_tch_dl_w - 1) % TCH_DL_SLOTS) * TCH_DL_SLOT)
    os.pwrite(fd, _tch_dl_w.to_bytes(4, "little"), 0)     # w_seq EN DERNIER
    ST.n_tch_dl += 1

def tch_dl_burst(fn, burst148):
    """DL : accumule les bursts TCH et decode un bloc voix tous les 4 bursts
    (entrelacement diagonal : la fenetre porte les 8 derniers)."""
    m26 = fn % 26
    if m26 in (12, 25):          # 12 = SACCH du TCH, 25 = idle : pas de voix
        return
    burst148 = a5_apply(burst148, fn, False)      # TCH : canal dedie -> chiffre
    # ⚠️ CONTINUITE DES FN. La fenetre de 8 bursts n'a de sens que si les bursts
    # sont CONSECUTIFS sur le canal. On accumulait a l'aveugle : un seul burst
    # manquant (perdu, ou un autre timeslot intercale) desalignait le bloc et
    # TOUT echouait ensuite en silence (mesure : 29 decodes pour 3653 echecs).
    # On repart donc de zero des qu'il y a un trou.
    global _tch_last_fn
    exp = _tch_next_fn(_tch_last_fn) if _tch_last_fn is not None else None
    if exp is not None and fn != exp:
        del _tch_acc[:]                          # trou -> fenetre invalide
        ST.n_tch_gap += 1
    _tch_last_fn = fn
    _tch_acc.append(burst116_from_normal(burst148))
    if len(_tch_acc) > 8:
        del _tch_acc[0]
    # ⚠️ CORRIGE (audit) : l'indice de burst n'est PAS fn%26 — le trou SACCH a
    # m26==12 le decale. idx = m26 si m26<12, sinon m26-1. Les frontieres de bloc
    # (idx 7,11,15,19,23) tombent donc sur m26 ∈ {7,11,16,20,24}.
    idx = _tch_burst_idx(fn)
    if len(_tch_acc) < 8 or (idx % 4) != 3:
        return
    # ⚠️ CORRIGE (audit) : gsm0503_tch_fr_decode indexe &bursts[i*116] — 8x116,
    # PAS 8x114 (les 2 bits de vol sont DANS les 116, poses par tch_burst_map).
    # L'ancienne allocation 8*114 faisait lire 928 octets dans 912 (hors bornes)
    # avec un pas decale : le codec ne pouvait produire que du bruit.
    buf = (sbit * (8 * 116))()
    for k in range(8):
        b = _tch_acc[k]
        for i in range(116):
            buf[k * 116 + i] = -127 if b[i] else 127
    fr = (ctypes.c_uint8 * FR_BYTES)()
    ne = ctypes.c_int(); nb = ctypes.c_int()
    # net_order = 1 (3e argument). osmo-bts et trxcon decodent TOUS DEUX avec 1
    # (sched_lchan_tchf.c : `gsm0503_tch_fr_decode(..., 1, 0, ...)`). A 0,
    # tch_fr_reassemble range autrement les bits de la trame de parole : les
    # parametres GSM 06.10 atterrissent aux mauvaises places et gapk rend un son
    # robotise. La FACCH (rc == 23) ne passe pas par ce chemin et restait donc
    # correcte — d'ou une signalisation saine et une voix fausse.
    rc = _cod.gsm0503_tch_fr_decode(fr, buf, 1, 0, ctypes.byref(ne), ctypes.byref(nb))
    if rc == FR_BYTES:
        tch_dl_publish(bytes(fr), fn)          # 33 o = trame voix FR
    elif rc == GSM_MACBLOCK_LEN:
        # ⚠️ CORRIGE (audit) : la lib rend 23 quand les bits de vol disent FACCH.
        # On jetait donc UA / ALERTING / CONNECT en les comptant « CRC fail ».
        feed_dl_l2(fn, GSMTAP_FACCH, bytes(fr)[:GSM_MACBLOCK_LEN], PORT_GSMTAP)
        ST.n_facch_dl += 1
    else:
        ST.n_tch_crc += 1

def tch_ul_loop():
    """UL : consomme l'anneau voix montant EN ORDRE et emet 8 bursts TCH."""
    fd = None; last = 0
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.1); continue
        try:
            if fd is None:
                fd = os.open(TCH_UL_PATH, os.O_RDONLY)
            hdr = os.pread(fd, 8, 0)
            if len(hdr) < 8:
                time.sleep(0.02); continue
            w, n = struct.unpack("<II", hdr)
            if not w or not n:
                time.sleep(0.02); continue
            if last == 0 or (w - last) > n:      # retard > 1 tour : on saute
                last = max(0, w - 1)
            while last < w:
                last += 1
                sl = os.pread(fd, TCH_UL_SLOT, 8 + ((last - 1) % n) * TCH_UL_SLOT)
                if len(sl) < TCH_UL_FR_OFS + FR_BYTES:
                    ST.n_tch_ul_court += 1       # ne doit JAMAIS bouger : slot tronque
                    continue
                fr = sl[TCH_UL_FR_OFS:TCH_UL_FR_OFS + FR_BYTES]
                # ALIMENTATEUR, PLUS EMETTEUR — cf. le commentaire de
                # ul_facch_from_sideband. En prime, emit_with_timing attendait
                # ACTIVEMENT chaque burst : 40 a 160 ms par trame vocale, quand
                # la voix arrive toutes les 20 ms. Ce thread ne pouvait pas
                # suivre, le garde « retard > 1 tour » remettait last = w-1 et
                # des TOURS ENTIERS de l'anneau partaient a la poubelle. C'est
                # ca, le son robotise. Une file bornee absorbe la gigue et le
                # trop-plein est compte, pas tu.
                with _tch_q_lock:
                    if len(_tch_q_voice) == _tch_q_voice.maxlen:
                        ST.n_tch_ul_drop += 1
                    _tch_q_voice.append(bytes(fr))
                ST.n_tch_ul += 1
        except OSError:
            fd = None; time.sleep(0.05)
        time.sleep(0.002)

# ====================== ORDONNANCEUR UNIQUE DU TCH MONTANT ====================
# Portage fidele de `tx_tchf_fn` (trxcon, sched_lchan_tchf.c) — la reference du
# cote MS, celle que qemu_wrap.c:1555-1560 suit deja et qui AVAIT la voix.
#
# CE QU'ON REMPLACE. Le pont emettait 8 bursts d'un coup depuis un tampon NEUF a
# chaque trame, depuis deux threads concurrents et sans verrou. Trois defauts en
# un : (1) blocs consecutifs qui se detruisent, faute du recouvrement de 4 bursts
# qu'impose l'entrelacement diagonal ; (2) voix et FACCH qui se marchent dessus
# sur le meme slot ; (3) debit impossible a tenir (attente active).
#
# LA DISCIPLINE, telle que la fixe tx_tchf_fn :
#   - tampon PERSISTANT de 24 bursts de 116 bits ;
#   - a chaque frontiere de bloc (bid == 0) : decalage de 4 bursts vers la
#     gauche, mise a zero des 4 derniers, masque decale de 4 ;
#   - on retire alors UNE trame voix et UN bloc FACCH, et la FACCH GAGNE : c'est
#     le vol de trame, le comportement normatif ;
#   - `gsm0503_tch_fr_encode(buf, NULL, 0, 1)` quand il n'y a rien : la lib pose
#     un bloc muet a CRC3 inverse. Le silence se TRANSMET, il ne s'omet pas ;
#   - on emet EXACTEMENT UN burst par trame porteuse, celui d'indice bid ;
#   - a bid > 0, si le bit 0 du masque n'est pas pose, aucun bloc n'a ete charge :
#     on n'emet rien plutot que du tampon vide.
TCH_TX_NBURSTS = 24
BPLEN          = 116
_tch_tx_buf    = (ubit * (TCH_TX_NBURSTS * BPLEN))()
_tch_tx_mask   = 0
_tch_q_lock    = threading.Lock()
_tch_q_facch   = collections.deque(maxlen=8)    # blocs L2 de 23 o
_tch_q_voice   = collections.deque(maxlen=4)    # trames FR de 33 o (80 ms de gigue)

def _tch_tx_load_block():
    """Frontiere de bloc : decale le tampon et y encode le prochain contenu."""
    global _tch_tx_mask
    ctypes.memmove(_tch_tx_buf, ctypes.byref(_tch_tx_buf, 4 * BPLEN), 20 * BPLEN)
    ctypes.memset(ctypes.byref(_tch_tx_buf, 20 * BPLEN), 0, 4 * BPLEN)
    _tch_tx_mask = (_tch_tx_mask << 4) & 0xFFFFFFFF
    with _tch_q_lock:
        facch = _tch_q_facch.popleft() if _tch_q_facch else None
        voice = _tch_q_voice.popleft() if _tch_q_voice else None
    msg = facch if facch is not None else voice     # la FACCH VOLE la voix
    if msg is None:
        # NULL -> bloc muet a CRC3 inverse (tx_tchf_fn fait exactement ca).
        _cod.gsm0503_tch_fr_encode(_tch_tx_buf, None, 0, 1)
    else:
        data = (ctypes.c_uint8 * len(msg))(*msg)
        # net_order = 1 : valeur de TOUTES les implementations qui font autorite
        # (osmo-bts, trxcon, qemu_wrap). A 0, tch_fr_disassemble range les bits
        # de la trame de parole autrement -> voix robotisee. Sans effet sur la
        # FACCH, qui ne passe pas par ce chemin : d'ou une signalisation saine
        # et un son faux, exactement le tableau observe.
        _cod.gsm0503_tch_fr_encode(_tch_tx_buf, data, len(msg), 1)
    if facch is not None and voice is not None:
        ST.n_tch_ul_vole += 1      # la voix cedee a la FACCH, c'est normatif

def tch_ul_scheduler():
    """UN SEUL emetteur sur le TCH montant : un burst par trame porteuse."""
    global _tch_tx_mask
    last_fn = None
    while True:
        tn = tch_cfg_read()
        if tn is None or not TCH_ENABLED:
            time.sleep(0.05); last_fn = None; continue
        fn_air = (now_fn() + UL_FN_ADVANCE) % GSM_HYPERFRAME
        if fn_air == last_fn:
            time.sleep(FRAME_DUR / 4); continue
        last_fn = fn_air
        if fn_air % 26 in (12, 25):        # SACCH / idle : pas de burst TCH
            continue
        bid = _tch_burst_idx(fn_air) % 4
        if bid == 0:
            _tch_tx_load_block()
        elif not (_tch_tx_mask & 0x01):
            continue                        # aucun bloc charge : on se tait
        base = bid * BPLEN
        b148 = normal_from_burst116([_tch_tx_buf[base + i] for i in range(BPLEN)])
        _tch_tx_mask |= (1 << bid)
        send_trxd_ul(tn, fn_air, b148, cipher=True)
        ST.n_tch_burst += 1

def _tch_burst_idx(fn):
    """Indice du burst dans le multiframe 26, SANS les trames 12 (SACCH) et
    25 (idle) : m26<12 -> m26 ; 13..24 -> m26-1. Va de 0 a 23."""
    m = fn % 26
    return m if m < 12 else m - 1

def next_tch_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge ouvrant un BLOC TCH/FACCH.

    ⚠️ Pas n'importe quelle trame porteuse : un bloc occupe 8 bursts et commence
    sur une FRONTIERE (indice multiple de 4). Demarrer au milieu produit un bloc
    que la BTS ne reassemble jamais — c'est ce qui laissait le BSC en
    « rll_ready=no » malgre une FACCH montante bien emise."""
    start = now_fn() + min_advance
    for k in range(52):
        fn = (start + k) % GSM_HYPERFRAME
        if fn % 26 in (12, 25):
            continue
        if _tch_burst_idx(fn) % 4 == 0:
            return fn
    return start % GSM_HYPERFRAME

# =========================== DISPATCH par canal (POINT 2) =====================
# (tn, fn) -> quel codage + où router. v1 : SCH, BCCH/CCCH, SDCCH+SACCH, RACH.
# TCH réservé (entrées présentes, non câblées) — cf. ordre de mise au point.
def dl_dispatch(tn, fn, burst148):
    """Décode un burst DL reçu de la BTS et le route vers le shunt. Gère le
    réassemblage 4-bursts pour xcch (POINT 1)."""
    # ⚠️ PAS de dechiffrement global ici : BCCH / SCH / FCCH / CCCH (AGCH, PCH)
    # ne sont JAMAIS chiffres. Leur appliquer le keystream les DETRUIT (mesure :
    # dl_dec effondre a 26 %, A5 dl=40198). Le A5 ne s'applique QU'AU CANAL DEDIE
    # (SDCCH/SACCH/TCH), et seulement la — cf. _acc_dl et tch_dl_burst.
    phys = TS_CONFIG.get(tn, "")
    m51 = fn % 51
    # --- SCH : 1 burst (pas de réassemblage) ---
    if tn == 0 and m51 in (1, 11, 21, 31, 41):
        # Burst SCH = [3 tail][39 data][64 training etendu][39 data][3 tail] = 148.
        # gsm0503_sch_decode attend les 2x39 bits de DONNEES (78), pas le burst
        # brut. Et meme convention sbit que xcch : ubit 1 -> -127, 0 -> +127.
        d78 = list(burst148[3:42]) + list(burst148[106:145])
        buf = (sbit*78)(*[-127 if b else 127 for b in d78])
        sb = (ctypes.c_uint8*4)()
        if _cod.gsm0503_sch_decode(sb, buf) == 0:
            # SCH -> feed_sb (4731) : BSIC + FN
            sk_gsmtap.sendto(b"SCH1" + struct.pack("<iii", BSIC, fn, 0), (GSMTAP_HOST, PORT_SCH))
        return
    # --- xcch : UNIQUEMENT les slots de signalisation. Les TS TCH/F envoient
    # de la voix/du dummy : les passer a xcch_decode ne produit que des CRC
    # fail et noie le compteur. v1 = CCCH+SDCCH4 / SDCCH8 seulement.
    if TCH_ENABLED and tn == tch_cfg_read():
        tch_dl_burst(fn, burst148)            # TS du TCH assigne -> voix
        return
    if not (phys.startswith("CCCH") or phys.startswith("SDCCH")):
        return
    _acc_dl(tn, phys, fn, burst148)

_DL_ACC = {}   # clé bloc -> {fn0, bursts[4]}

# GSM 05.02 — multiframe 51 sur TS0 (référence si_bridge.py:10-13, fn51_role) :
#   FCCH {0,10,20,30,40} · SCH {1,11,21,31,41} · BCCH {2..5} · idle 50
#   blocs de 4 bursts, bases : 2(BCCH) 6,12,16(CCCH) 22,26,32,36(SDCCH/4 SS0..3)
#   42,46(SACCH) — c'est la table que si_bridge utilise (_SD4_DL=[22,26,32,36]).
# Le groupement fn//4 de la v1 était FAUX : il coupait les blocs n'importe où,
# d'où 100 % de CRC fail.
_BLOCK_BASES = (2, 6, 12, 16, 22, 26, 32, 36, 42, 46)
_SD4_DL = (22, 26, 32, 36)   # base DL par sous-voie SS0..3 (si_bridge)

def _block_key(tn, phys, fn):
    """Identifie le bloc de 4 bursts auquel `fn` appartient.
    Retourne (tn, fn_du_1er_burst) ou None si `fn` n'est pas dans un bloc
    (FCCH, SCH, idle) — ces bursts ne vont PAS dans xcch."""
    m51 = fn % 51
    for b in _BLOCK_BASES:
        if b <= m51 <= b + 3:
            return (tn, fn - (m51 - b))     # clé = FN du 1er burst du bloc
    return None

def _acc_dl(tn, phys, fn, burst148):
    k = _block_key(tn, phys, fn)
    if k is None:
        return                       # FCCH / SCH / idle : rien à décoder en xcch
    # A5 : seulement le canal DEDIE (SDCCH 22/26/32/36, SACCH 42/46).
    if (k[1] % 51) in (22, 26, 32, 36, 42, 46):
        burst148 = a5_apply(burst148, fn, False)
    d = _DL_ACC.setdefault(k, {"fn0": k[1], "b": []})
    d["b"].append(burst116_from_normal(burst148))
    ST.n_dl_bursts += 1
    if len(d["b"]) == 4:
        l2, rc, ne = xcch_decode_4(d["b"])
        del _DL_ACC[k]
        base51 = k[1] % 51
        st = ST.n_by_base.setdefault(base51, [0, 0])
        # TRACE DEDIE : la seule mesure qui tranche « le keystream est-il bon ? ».
        # Si les decodages s'ARRETENT pile quand A5=oui, le keystream est faux —
        # et on a le FN exact pour calculer l'ecart au lieu de balayer FN_ADJ.
        # MESURE DECISIVE : seulement la sous-voie ACTIVE (les autres sont vides
        # par construction et noieraient le signal). Sans plafond : c'est un
        # RATIO, il doit etre exact.
        if base51 == _SD4_DL[_dcch_ss() & 3]:
            tgt = ST.n_act_ciph if _a5_last["applied"] else ST.n_act_clear
            tgt[1] += 1
            if l2 is not None:
                tgt[0] += 1
        if base51 in (22, 26, 32, 36, 42, 46):
            global _ded_n
            _ded_n += 1
            if _ded_n <= 60 or (_ded_n % 20) == 0:
                ST.log("DEDIE-TRACE base=%d fn=%u fn%%51=%u A5=%s%s decode=%s"
                       % (base51, k[1], k[1] % 51,
                          "OUI" if _a5_last["applied"] else "non",
                          ("(a5/%d kc=%s)" % (_a5_last["algo"], _a5_last["kc4"]))
                          if _a5_last["applied"] else "",
                          "OUI" if l2 is not None else "NON"))
        if l2 is None:
            ST.n_dl_crc_fail += 1
            st[1] += 1
            return
        st[0] += 1
        ST.n_dl_decoded += 1
        # ROUTAGE PAR CONTENU (comme si_bridge.py:145-155), pas par FN : le shunt
        # dispatche sur le sub_type GSMTAP. Un SI3 annonce en AGCH n'est jamais
        # traite comme un SI -> "No sysinfo yet" cote mobile.
        # L2 = trame LAPDm : [0]addr [1]ctrl [2]len puis L3 -> [3]=PD(0x06=RR)
        # [4]=type. (Repli sur by[1]/by[2] si le bloc est deja deshabille.)
        base51 = k[1] % 51
        if base51 in (22, 26, 32, 36):
            # CANAL DEDIE descendant (SDCCH/4 SS0..3) : LAPDm pur (UA, AUTH REQ,
            # LU ACCEPT, ...). NE PAS filtrer par type RR — ce n'est pas du RR.
            # C'etait LE trou : tout le DL dedie etait jete, donc l'UA n'arrivait
            # jamais au mobile -> il repetait sa SABM -> "SABM not allowed in
            # this state" cote BTS alors que le lchan etait ESTABLISHED.
            feed_dl_l2(d["fn0"], GSMTAP_SDCCH4, l2, PORT_GSMTAP)
            check_assignment(l2, d["fn0"])     # arme le TCH si c'est un ASSIGNMENT
            return
        if base51 in (42, 46):
            feed_dl_l2(d["fn0"], GSMTAP_SACCH, l2, PORT_GSMTAP)   # SACCH dediee
            return
        # BCCH / CCCH : routage PAR CONTENU (le shunt dispatche sur le sub_type).
        mt = None
        if len(l2) >= 5 and l2[3] == 0x06:   mt = l2[4]
        elif len(l2) >= 3 and l2[1] == 0x06: mt = l2[2]
        if mt is None:
            return
        if mt in SI_TYPES:
            chan = GSMTAP_BCCH                # SI1/2/3/4/2bis/2ter -> feed_si
        elif mt in CCCH_TYPES:
            chan = GSMTAP_CCCH                # IMM-ASSIGN / PAGING -> feed_agch
        else:
            return
        feed_dl_l2(d["fn0"], chan, l2, PORT_GSMTAP)

# =========================== UL : sidebands -> TRXD (POINT 3) ==================
# ============================ CAPTURE (A et B) ================================
# A — PONT_BURST_FILE : dump des bursts. Si `pmt` est importable (interpreteur
#     /root/.env/bin/python3), on ecrit le VRAI format gr-gsm (pmt serialise,
#     lisible par `grgsm_decode -b`). Sinon, dump brut auto-decrit :
#     [magic 'PBST'][fn u32 LE][tn u8][len u8][bits...] par burst — honnete, pas
#     compatible gr-gsm, mais rejouable par le pont.
# B — PONT_CFILE : vrai cfile IQ complex float32 en MODULANT les bursts (l'etage
#     GMSK que l'architecture burst-level supprime). L'IQ est donc RECONSTRUITE
#     (fidele aux bits, sans bruit ni ToA reelle) — ce n'est pas une capture d'air.
BURST_FILE = os.environ.get("PONT_BURST_FILE", "")
CFILE      = os.environ.get("PONT_CFILE", "")
CFILE_OSR  = int(os.environ.get("PONT_CFILE_OSR", "4"))

# ------------------------------- AIRREC : cfile DL permanent -----------------
# Enregistrement PERMANENT du DESCENDANT, en temps TDMA reel, dans un cfile fc32
# a 1 083 333 sps — exactement ce que `grgsm_decode -s 1083333` attend et ce que
# rec.js code en dur (SAMP).
#
# POURQUOI PAS capture_iq(), QUI EXISTE DEJA. Deux defauts redhibitoires :
#   1. UN SEUL APPELANT, send_trxd_ul() : capture_iq ne voit que le MONTANT. Le
#      descendant — celui que `-m BCCH_SDCCH4` decode — n'etait ecrit NULLE PART.
#   2. IL COMPRIME LE TEMPS. Il concatene 148 symboles par burst, dos a dos, or
#      un slot GSM dure 156,25 symboles. En supprimant les 8,25 symboles de garde
#      on raccourcit le fichier de 5,3 % : la recuperation d'horloge de gr-gsm ne
#      raccroche jamais. Le fichier s'ouvre, se lit comme un fc32 valide, et ne
#      decode RIEN — sans une seule erreur.
#
# ON ECRIT DONC UNE TRAME ENTIERE (8 slots x 156,25 = 1250 symboles) A CHAQUE
# PERIODE TDMA, Y COMPRIS QUAND LA BTS N'EMET RIEN. Le silence FAIT PARTIE du
# signal : c'est lui qui porte le temps. C'est ce qui rend le fichier decodable,
# et c'est ce qui en fixe le debit :
#     1250 x OSR 4 x 8 o x 216,68 trames/s = 8,67 Mo/s = 31 Go/h.
# CE DEBIT N'EST PAS NEGOCIABLE — c'est ce que « enregistrer l'air a 1083333 sps »
# veut dire. Sans plafond, /dev/shm (8 Go, QUI PORTE LES JOURNAUX) est plein en
# 13 minutes. D'ou la rotation par segments, non optionnelle.
#
# @BEQUILLE — CE N'EST PAS UNE CAPTURE D'AIR. Cette I/Q est RECONSTRUITE a partir
#   des bits que la BTS a emis : pas de bruit, pas de ToA reelle, pas de derive de
#   frequence, pas de fading, pas d'interference. Decoder ce cfile rend donc
#   exactement les bits dont il est issu — c'est un rejeu fidele aux BITS, utile
#   pour rejouer/demontrer, PAS une preuve de ce qui est passe sur l'air.
#   masque : en mode pont il n'existe aucune chaine IQ reelle a capturer.
#   retirer : le jour ou une vraie source RF alimente le chemin.
AIRREC      = os.environ.get("PONT_AIRREC", "1") not in ("0", "", "no")
AIRREC_DIR  = os.environ.get("PONT_AIRREC_DIR", "/dev/shm/osmo-rec")
AIRREC_OSR  = int(os.environ.get("PONT_AIRREC_OSR", "4"))            # 4 -> 1083333 sps
AIRREC_SEG  = int(os.environ.get("PONT_AIRREC_SEG_MB",     "256")) * 1024 * 1024
AIRREC_KEEP = int(os.environ.get("PONT_AIRREC_KEEP",         "6"))
AIRREC_FREE = int(os.environ.get("PONT_AIRREC_MINFREE_MB", "1024")) * 1024 * 1024

_pmt = None
if BURST_FILE:
    try:
        import pmt as _pmt
    except ImportError:
        _pmt = None
_bf = open(BURST_FILE, "ab") if BURST_FILE else None
_cf = None
_np = None
if CFILE:
    try:
        import numpy as _np
        _cf = open(CFILE, "ab")
    except ImportError:
        print("[pont] PONT_CFILE demande mais numpy absent -> pas de cfile", flush=True)

def capture_burst(fn, tn, bits148, uplink):
    """A : ecrit le burst dans le dump si le gate est pose."""
    if _bf is None:
        return
    b = bytes(1 if x == 0x01 else 0 for x in bits148)
    if _pmt is not None:
        hdr = gsmtap(fn, GSMTAP_SDCCH4, b"")            # en-tete GSMTAP 16 o
        msg = _pmt.cons(_pmt.PMT_NIL,
                        _pmt.init_u8vector(len(hdr) + len(b), list(hdr + b)))
        _bf.write(_pmt.serialize_str(msg))
    else:
        _bf.write(b"PBST" + struct.pack("<IBB", fn, tn, len(b)) + b)
    _bf.flush()

def capture_iq(bits148):
    """B : module le burst en GMSK et l'ajoute au cfile (complex float32)."""
    if _cf is None or _np is None:
        return
    # NRZ -> MSK/GMSK : phase +/- pi/2 par symbole, mise en forme gaussienne.
    d = _np.array([1.0 if x == 0x01 else -1.0 for x in bits148])
    up = _np.zeros(len(d) * CFILE_OSR); up[::CFILE_OSR] = d
    n = 4 * CFILE_OSR
    t = (_np.arange(-n, n + 1)) / float(CFILE_OSR)
    g = _np.exp(-2.0 * (_np.pi ** 2) * (0.3 ** 2) * t ** 2 / _np.log(2.0))
    g /= g.sum()
    phase = _np.cumsum(_np.convolve(up, g, mode="same")) * (_np.pi / 2.0 / CFILE_OSR)
    _np.exp(1j * phase).astype(_np.complex64).tofile(_cf)
    _cf.flush()

# ======================= AIRREC : enregistrement DL permanent =================
_ar_lock   = threading.Lock()
_ar_frames = {}                     # fn -> {tn: bits148}, vide par l'ecrivain
_ar_fh     = None
_ar_path   = None
_ar_bytes  = 0
_ar_split  = False                  # arme par SIGUSR1 (bouton « Split » du web)
_ar_off    = False                  # coupure definitive (tmpfs plein, I/O KO)
_ar_g      = None                   # gabarit gaussien, calcule UNE fois
_ar_stats  = {"frames": 0, "bursts": 0, "segs": 0}

def _ar_mod(bits148):
    """148 bits -> 148*OSR echantillons complex64 (GMSK BT=0.3).
    Meme modulation que capture_iq, mais le gabarit gaussien est PRECALCULE : il
    ne depend pas du burst, et le recalculer a chaque fois coutait le gros du
    temps de traitement."""
    d  = _np.where(_np.frombuffer(bits148, dtype=_np.uint8) == 0x01, 1.0, -1.0)
    up = _np.zeros(len(d) * AIRREC_OSR)
    up[::AIRREC_OSR] = d
    ph = _np.cumsum(_np.convolve(up, _ar_g, mode="same")) * (_np.pi / 2.0 / AIRREC_OSR)
    return _np.exp(1j * ph).astype(_np.complex64)

def _ar_purge():
    """Ne garde que KEEP-1 segments (on fait la place pour le neuf)."""
    try:
        segs = sorted(f for f in os.listdir(AIRREC_DIR)
                      if f.startswith("air_pont_") and f.endswith(".cfile"))
    except OSError:
        return
    for f in segs[:max(0, len(segs) - (AIRREC_KEEP - 1))]:
        try:
            os.unlink(os.path.join(AIRREC_DIR, f))
            ST.log("airrec purge %s" % f)
        except OSError:
            pass

def _ar_rotate():
    """Ferme le segment courant, en ouvre un neuf, purge les plus vieux.
    SEGMENTS et non anneau binaire : chaque segment reste INDEPENDAMMENT
    decodable (gr-gsm se resynchronise sur FCCH/SCH, qui reviennent toutes les
    51 trames, ~235 ms). Un anneau avec point de bouclage aurait corrompu le flux
    a chaque tour, precisement la ou on a besoin qu'il soit lisible."""
    global _ar_fh, _ar_path, _ar_bytes
    if _ar_fh is not None:
        try:    _ar_fh.close()
        except OSError: pass
        _ar_fh = None
        ST.log("airrec segment clos : %s (%.1f Mo)" % (_ar_path, _ar_bytes / 1048576.0))
    try:
        os.makedirs(AIRREC_DIR, exist_ok=True)
    except OSError as e:
        ST.log("airrec: %s inaccessible (%s) — enregistrement COUPE" % (AIRREC_DIR, e))
        return False
    # GARDE TMPFS. /dev/shm porte AUSSI les journaux du run : on s'arrete AVANT
    # de le remplir. Un enregistrement qui tue la machine qu'il observe n'a
    # aucune valeur, et la panne se manifesterait dix modules plus loin.
    try:
        st = os.statvfs(AIRREC_DIR)
        if st.f_bavail * st.f_frsize < AIRREC_FREE:
            ST.log("airrec: moins de %d Mo libres sur %s — enregistrement COUPE"
                   % (AIRREC_FREE // 1048576, AIRREC_DIR))
            return False
    except OSError:
        pass
    _ar_purge()
    _ar_path = os.path.join(AIRREC_DIR, "air_pont_%s.cfile"
                            % time.strftime("%Y%m%d%H%M%S", time.gmtime()))
    try:
        _ar_fh = open(_ar_path, "wb", buffering=1024 * 1024)
    except OSError as e:
        ST.log("airrec: ouverture %s impossible (%s)" % (_ar_path, e))
        return False
    _ar_bytes = 0
    _ar_stats["segs"] += 1
    ST.log("airrec segment ouvert : %s" % _ar_path)
    return True

def airrec_feed(fn, tn, bits148):
    """Appele depuis th_data_rx. NE CALCULE RIEN : th_data_rx est le chemin temps
    reel du pont (il relaie aussi vers le BSP), on n'y met qu'un depot sous
    verrou. Toute la modulation se fait dans le thread ecrivain."""
    if _ar_off or not AIRREC:
        return
    with _ar_lock:
        _ar_frames.setdefault(fn, {})[tn] = bits148

def _ar_on_usr1(_sig, _frm):
    """SIGUSR1 = « Split » : clot le segment courant pour le figer et le rendre
    telechargeable, et en rouvre un immediatement. Pas de socket de controle
    supplementaire : le pont a deja trois ports a lui, un quatrieme serait un
    quatrieme reste a nettoyer au teardown."""
    global _ar_split
    _ar_split = True

def th_airrec():
    """Ecrit UNE trame TDMA par periode, cadencee par l'horloge du pont
    (now_fn(), derivee du temps absolu) : c'est ce qui garantit que le fichier a
    la bonne DUREE, donc qu'il est decodable. On ecrit avec 2 trames de retard,
    le temps que les 8 slots d'une meme trame soient arrives — ils viennent en 8
    datagrammes distincts et rien ne garantit leur ordre."""
    global _ar_bytes, _ar_split, _ar_off, _ar_g
    if not AIRREC:
        ST.log("airrec DESACTIVE (PONT_AIRREC=0) — aucun cfile ne sera ecrit")
        return
    if _np is None:
        try:
            import numpy as _n2
            globals()["_np"] = _n2
        except ImportError:
            ST.log("airrec demande mais numpy absent -> pas d'enregistrement")
            _ar_off = True
            return
    if AIRREC_OSR % 4 != 0:
        ST.log("airrec: OSR=%d refuse (156,25 x OSR doit etre entier) -> multiple de 4"
               % AIRREC_OSR)
        _ar_off = True
        return
    n = 4 * AIRREC_OSR
    t = (_np.arange(-n, n + 1)) / float(AIRREC_OSR)
    g = _np.exp(-2.0 * (_np.pi ** 2) * (0.3 ** 2) * t ** 2 / _np.log(2.0))
    _ar_g = g / g.sum()
    try:
        signal.signal(signal.SIGUSR1, _ar_on_usr1)
    except ValueError:
        pass                        # pas le thread principal : Split indisponible
    if not _ar_rotate():
        _ar_off = True
        return
    ST.log("airrec ACTIF -> %s (segments de %d Mo, %d gardes, coupure sous %d Mo libres). "
           "⚠️ I/Q RECONSTRUITE a partir des bits emis : ni bruit, ni ToA reelle, "
           "ni fading — rejeu fidele aux BITS, PAS une capture d'air."
           % (AIRREC_DIR, AIRREC_SEG // 1048576, AIRREC_KEEP, AIRREC_FREE // 1048576))
    spf     = 1250 * AIRREC_OSR                 # 8 slots x 156,25 symboles
    step    = (625 * AIRREC_OSR) // 4           # 156,25 x OSR, entier si OSR%4==0
    blen    = 148 * AIRREC_OSR
    silence = _np.zeros(spf, dtype=_np.complex64)
    nxt = (now_fn() + 2) % GSM_HYPERFRAME
    while True:
        lag = (now_fn() - nxt) % GSM_HYPERFRAME
        if lag > 650:            # >3 s de retard : on ne rattrapera pas, on recale
            with _ar_lock:
                _ar_frames.clear()
            nxt = (now_fn() + 2) % GSM_HYPERFRAME
            continue
        if lag < 2:
            time.sleep(FRAME_DUR / 2.0)
            continue
        with _ar_lock:
            slots = _ar_frames.pop(nxt, None)
            if len(_ar_frames) > 512:   # trames jamais reclamees : pas de fuite
                _ar_frames.clear()
        if slots:
            frame = _np.zeros(spf, dtype=_np.complex64)
            for tn, bits in slots.items():
                o = tn * step
                frame[o:o + blen] = _ar_mod(bits)
                _ar_stats["bursts"] += 1
        else:
            frame = silence         # le SILENCE porte le temps : on l'ecrit
        try:
            _ar_fh.write(frame.tobytes())
            _ar_bytes += frame.nbytes
            _ar_stats["frames"] += 1
        except OSError as e:
            ST.log("airrec ecriture ECHEC (%s) — enregistrement COUPE" % e)
            _ar_off = True
            return
        if _ar_split or _ar_bytes >= AIRREC_SEG:
            _ar_split = False
            if not _ar_rotate():
                _ar_off = True
                return
        nxt = (nxt + 1) % GSM_HYPERFRAME

def send_trxd_ul(tn, fn, burst148, cipher=False):
    """Émet un burst UL vers la BTS (rôle RX de la BTS) : hdr TRXDv0 + RSSI + ToA."""
    if _bts_addr["data"] is None:
        return
    buf = bytearray()
    buf.append((0 << 4) | (tn & 0x07))            # ver=0 | TN
    buf += struct.pack(">L", fn)                  # FN (BE)
    # RSSI : uint8 = -dBm. 0 signifie "0 dBm" et peut etre lu comme une valeur
    # aberrante/absente par le recepteur. On annonce un niveau realiste.
    buf.append(PONT_RSSI & 0xFF)                  # ex. 60 -> -60 dBm
    buf += struct.pack(">h", 0)                   # ToA256 = 0 (aligné)
    # osmo-bts convertit : sbit = 127 - octet (255 -> -127). Donc un bit 1 doit
    # partir en octet 255 et un bit 0 en octet 0. Envoyer 127 = sbit 0 = bit
    # TOTALEMENT AMBIGU -> le decodeur ne peut jamais conclure (trx_if.c:958).
    if cipher:                                   # RACH : JAMAIS chiffre
        burst148 = a5_apply(burst148, fn, True)
    buf += bytes(255 if b == 0x01 else 0 for b in burst148)
    sk_data.sendto(bytes(buf), _bts_addr["data"])
    capture_burst(fn, tn, burst148, True)
    capture_iq(burst148)
    ST.n_ul_sent += 1

def emit_with_timing(tn, target_fn, bursts, cipher=False, tch=False):
    """POINT 3 — poste chaque burst quand l'horloge atteint (target_fn - AVANCE).
    Compte les hors-fenêtre. bursts = liste de bursts, étalés sur des FN consécutifs
    du canal (POINT 1 : étalement UL des 4 bursts xcch)."""
    # ⚠️ Sur un TCH/F, les 8 bursts d'un bloc occupent des trames PORTEUSES
    # consecutives : il faut SAUTER fn%26 == 12 (SACCH) et 25 (idle). Emettre
    # sur target_fn+j les fait atterrir sur les mauvaises trames des que le bloc
    # traverse un de ces trous -> la BTS ne reassemble jamais le bloc, d'ou
    # "WAIT_RR_ASS_COMPLETE ... EQUIPMENT FAILURE" cote BSC.
    if tch:
        fns = []
        f = target_fn
        while f % 26 in (12, 25):
            f = (f + 1) % GSM_HYPERFRAME
        for _ in bursts:
            fns.append(f)
            f = _tch_next_fn(f)
    else:
        fns = [(target_fn + j) % GSM_HYPERFRAME for j in range(len(bursts))]
    for j, b148 in enumerate(bursts):
        fn_air = fns[j]                                 # FN cible de CE burst
        fn_post = (fn_air - UL_FN_ADVANCE) % GSM_HYPERFRAME
        # attente active bornée jusqu'à l'instant de post
        while True:
            cur = now_fn()
            delta = (fn_post - cur) % GSM_HYPERFRAME
            if delta == 0 or delta > GSM_HYPERFRAME // 2:
                break
            time.sleep(FRAME_DUR / 4)
        cur = now_fn()
        # fenêtre : le FN air visé doit être ~ cur + AVANCE
        if abs(((fn_air - (cur + UL_FN_ADVANCE)) + GSM_HYPERFRAME//2) % GSM_HYPERFRAME - GSM_HYPERFRAME//2) > WINDOW_TOL:
            ST.n_ul_out_of_window += 1
            ST.log("UL HORS-FENETRE : FN air=%u, FN courant=%u (attendu ~%u)"
                   % (fn_air, cur, (cur + UL_FN_ADVANCE) % GSM_HYPERFRAME))
            continue
        send_trxd_ul(tn, fn_air, b148, cipher)

# Bases UL du SDCCH/4 combine, par sous-voie SS0..3 (qemu_wrap.c UL4).
# La sous-voie active est publiee par le firmware dans /dev/shm/calypso_dcch_cfg
# (format qemu_wrap.c:1017 : seq u32@0, kind@4, ss@5, tn@6, chan_nr@7).
_UL4 = (37, 41, 47, 0)

_dcch_fd = None

def _dcch_ss():
    """Sous-voie dediee active (0..3), lue et jamais supposee.

    ⚠️ CORRIGE (audit) : la version precedente faisait
    `os.pread(os.open(DCCH_CFG, ...), 16, 0)` sans jamais fermer le fd. Appelee
    ~42 fois/s par TROIS threads, elle saturait la table de descripteurs (1024)
    en ~24 s — mesure live : 1015 fd sur calypso_dcch_cfg. Ensuite TOUT os.open
    echouait EN SILENCE : kc_read() rendait « pas de Kc » (A5 mort), tch_cfg_read()
    restait fige (TCH jamais arme), _tch_dl_open() levait. On garde donc UN fd
    persistant et on ne fait que des pread, comme tch_ul_loop pour l'anneau."""
    global _dcch_fd
    try:
        if _dcch_fd is None:
            _dcch_fd = os.open(DCCH_CFG, os.O_RDONLY)
        b = os.pread(_dcch_fd, 16, 0)
        if len(b) >= 8 and struct.unpack_from("<I", b, 0)[0]:
            return b[5] & 3
    except OSError as e:
        # Une sonde muette rend son silence indecidable (regle du projet) :
        # on compte et on annonce la premiere erreur.
        try:
            if _dcch_fd is not None:
                os.close(_dcch_fd)
        except OSError:
            pass
        _dcch_fd = None
        ST.n_dcch_err += 1
        if ST.n_dcch_err == 1:
            ST.log("dcch_cfg illisible (%s) — sous-voie supposee SS0 jusqu'a nouvel ordre" % e)
    return 0

def next_sdcch_ul_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge ouvrant un bloc SDCCH montant."""
    base51 = _UL4[_dcch_ss()]
    start = now_fn() + min_advance
    for k in range(51):
        fn = (start + k) % GSM_HYPERFRAME
        if fn % 51 == base51:
            return fn
    return start % GSM_HYPERFRAME

def ul_sdcch_from_sideband():
    """Lit la L2 SDCCH déposée par l'ARM, l'encode et l'émet (4 bursts étalés)."""
    fd = None; last_seq = -1
    while True:
        try:
            if fd is None:
                fd = os.open(SB_SDCCH_UL, os.O_RDONLY)
            b = os.pread(fd, 48, 0)               # pread : jamais bufferisé (piège connu)
            if len(b) >= 39:
                # Layout figé (qemu_wrap.c:944-946) : seq@0 l1s_fn@4 fn@8
                # task_u@12 l1s%51@14 l2[23]@16 (48 o).
                seq = struct.unpack_from("<I", b, 0)[0]
                if seq and seq != last_seq:
                    last_seq = seq
                    l1s_fn = struct.unpack_from("<I", b, 4)[0]
                    l2 = b[16:39]
                    bursts = xcch_encode_4(l2)
                    # ⚠️ MEME BUG QUE LE RACH : `l1s_fn` est l'horloge du FIRMWARE,
                    # pas celle du pont (que la BTS suit via IND CLOCK). Emettre
                    # dedans donnait 35 bursts "hors fenetre". On vise le prochain
                    # bloc SDCCH montant de NOTRE horloge.
                    emit_with_timing(0, next_sdcch_ul_fn(), bursts, cipher=True)
        except OSError:
            fd = None
        time.sleep(FRAME_DUR / 8)

# Access burst RACH — mirror EXACT de qemu_wrap.c `ul_build_rach_ra` :
#   [8 tail][41 sync TS0][36 bits codes rach_ext_encode][3 tail] = 88 actifs,
#   le reste (88..147) en garde. En TRXDv0 osmo-bts n'accepte QUE 148 bits
#   (trx_if.c:816 GSM_BURST_LEN) : l'access burst est donc un burst de 148
#   dont seuls les 88 premiers portent le signal.
# Slots RACH valides, combination V (CCCH+SDCCH/4 combine) : osmo-trx ne fait
# tourner le correlateur RACH que sur ces positions (Transceiver::expectedCorrType
# case V) — reference qemu_wrap.c:2005-2011. Ailleurs, c'est le correlateur
# NORMAL-BURST qui tourne : l'access burst n'est JAMAIS detecte.
RACH_SLOTS_51 = frozenset([4, 5] + list(range(14, 37)) + [45, 46])

def next_rach_fn(min_advance=4):
    """Prochaine FN de NOTRE horloge tombant sur un slot RACH eligible."""
    base = now_fn() + min_advance
    for k in range(51):
        fn = (base + k) % GSM_HYPERFRAME
        if fn % 51 in RACH_SLOTS_51:
            return fn
    return base % GSM_HYPERFRAME

RACH_SYNC = "01001011011111111001100110101010001111000"   # 41, GSM::gRACHSynchSequenceTS0

def build_rach_burst(ra, bsic):
    coded = (ubit * 40)()
    _cod.gsm0503_rach_ext_encode(coded, ctypes.c_uint16(ra), ctypes.c_uint8(bsic), False)
    b = bytearray([0xFF]) * 148          # tout a -1 (tail/garde)
    p = 0
    for _ in range(8):  b[p] = 0xFF; p += 1                          # extended tail
    for i in range(41): b[p] = 0x01 if RACH_SYNC[i] == "1" else 0xFF; p += 1
    for i in range(36): b[p] = 0x01 if coded[i] else 0xFF; p += 1    # RA codee (BSIC color)
    for _ in range(3):  b[p] = 0xFF; p += 1                          # tail  -> p == 88
    return bytes(b)

def ul_rach_from_sideband():
    """POINT 3 — RACH : UL-only, 1 SEUL burst (access), pas de réassemblage xcch."""
    fd = None; last = None
    while True:
        try:
            if fd is None:
                fd = os.open(SB_RACH, os.O_RDONLY)
            b = os.pread(fd, 16, 0)
            if len(b) >= 8:
                # Layout figé (calypso_trx.c:687 / qemu_wrap.c:899) :
                # [0..3]seq u32 LE | [4]ra | [5]bsic | [8..11]fn u32 LE (16 o).
                seq, ra, bsic, fn = struct.unpack_from("<IBBxxI", b, 0) if len(b) >= 12 else (0, 0, BSIC, 0)
                if seq and seq != last:
                    last = seq
                    b148 = build_rach_burst(ra, bsic)
                    # ⚠️ NE PAS emettre au l1s_fn du FIRMWARE : c'est une AUTRE
                    # base de temps que l'horloge du pont (que la BTS suit via
                    # IND CLOCK). Emettre dedans faisait attendre une FN qui
                    # n'arrive jamais -> 2 RACH envoyes sur 16 publies.
                    # On emet au PROCHAIN slot RACH eligible de NOTRE horloge.
                    emit_with_timing(0, next_rach_fn(), [b148])   # 1 seul burst
                    ST.n_rach += 1
        except OSError:
            fd = None
        time.sleep(FRAME_DUR / 8)

# =========================== threads réseau TRX ===============================
def th_ctrl():
    while True:
        data, addr = sk_ctrl.recvfrom(1500)
        req = data.decode("latin1").strip("\0").strip()
        if not req.startswith("CMD"):
            continue
        parts = req.split()
        cmd = parts[1] if len(parts) > 1 else ""
        # On répond RSP <cmd> 0 [écho des args] — suffit à POWERON->actif.
        rsp = "RSP %s 0%s" % (cmd, ("" if len(parts) <= 2 else " " + " ".join(parts[2:])))
        sk_ctrl.sendto(rsp.encode() + b"\0", addr)
        # L'horloge DOIT partir des le POWERON : osmo-bts-trx coupe la BTS avec
        # "No clock since TRX was started" s'il ne recoit pas d'IND CLOCK. On
        # apprend donc l'adresse CLCK ICI (meme IP que le CTRL, port base+100),
        # et surtout PAS en attendant un burst DATA (deadlock : pas de DATA tant
        # que la BTS n'est pas active).
        if _bts_addr["clck"] is None:
            _bts_addr["clck"] = (addr[0], TRX_BASE + 100)
            ST.log("horloge armee vers %s:%d (apprise du CTRL)" % (addr[0], TRX_BASE + 100))
        ST.log("CTRL %s -> %s" % (cmd, rsp))

def th_data_rx():
    while True:
        data, addr = sk_data.recvfrom(2000)
        _bts_addr["data"] = addr
        if len(data) < 5:
            continue
        tn = data[0] & 0x07
        fn = struct.unpack_from(">L", data, 1)[0]
        # DL TX de la BTS (L12TRX) : en-tete TxMsg = 6 octets et non 5 —
        # [0]=ver|tn, [1:5]=fn (BE), [5]=pwr (attenuation Tx, data_msg.py:320
        # `self.pwr = hdr[5]`). Le burst commence donc a l'offset 6. Lire a 5
        # decalait TOUS les bits d'un octet -> 100 % de CRC fail.
        burst = data[6:6+148]
        if len(burst) == 148:
            # Relais vers le BSP AVANT tout traitement : sendto est non bloquant
            # et on ne veut pas que le cout du decodage decale l'I/Q publiee.
            # En-tete 6 o de la BTS + 2 o de ToA (le BSP lit buf[5] puis saute 8).
            if BSP_FEED:
                try:
                    sk_bsp.sendto(bytes(data[0:6]) + b"\x00\x00" + bytes(burst),
                                  (BSP_HOST, BSP_PORT))
                    ST.n_bsp_fed += 1
                except OSError as e:
                    ST.n_bsp_err += 1
                    if ST.n_bsp_err <= 3:
                        ST.log("BSP relais ECHEC #%d (%s)" % (ST.n_bsp_err, e))
            _b = bytes(0x01 if b else 0xFF for b in burst)
            capture_burst(fn, tn, _b, False)
            # AIRREC : depot seul, aucun calcul ici (cf. airrec_feed). C'est le
            # SEUL point du programme ou le descendant est visible sous forme de
            # bits — capture_iq, lui, n'est appele que depuis send_trxd_ul et ne
            # voyait donc que le montant.
            airrec_feed(fn, tn, _b)
            dl_dispatch(tn, fn, burst)

def th_clck():
    # POINT 4 — IND CLOCK périodique, FN dérivé du temps absolu.
    while True:
        fn = now_fn()
        if _bts_addr["clck"]:
            sk_clck.sendto(("IND CLOCK %u" % fn).encode() + b"\0", _bts_addr["clck"])
        time.sleep(FRAME_DUR)   # cadence d'indication ; le FN reste f(t), pas accumulé

def th_stats():
    while True:
        time.sleep(5)
        ST.log("STATS dl_bursts=%d dl_dec=%d crc_fail=%d | ul_sent=%d hors_fenetre=%d rach=%d | FN=%u"
               % (ST.n_dl_bursts, ST.n_dl_decoded, ST.n_dl_crc_fail,
                  ST.n_ul_sent, ST.n_ul_out_of_window, ST.n_rach, now_fn())
               + " | TCH dl=%d ul=%d crc=%d" % (ST.n_tch_dl, ST.n_tch_ul, ST.n_tch_crc)
               + " | A5 dl=%d ul=%d" % (ST.n_a5_dl, ST.n_a5_ul)
               + " | FACCH dl=%d ul=%d gap=%d" % (ST.n_facch_dl, ST.n_facch_ul, ST.n_tch_gap)
               + " | BSP fed=%d err=%d" % (ST.n_bsp_fed, ST.n_bsp_err)
               + " | ul_court=%d" % ST.n_tch_ul_court
               + " | TCHUL bursts=%d file_v=%d file_f=%d drop=%d vol=%d"
                 % (ST.n_tch_burst, len(_tch_q_voice), len(_tch_q_facch),
                    ST.n_tch_ul_drop, ST.n_tch_ul_vole))
        # Detail par base de bloc (GSM 05.02) : montre d'ou vient le crc_fail.
        # 2=BCCH  6/12/16=CCCH  22/26/32/36=SDCCH  42/46=SACCH.
        if ST.n_by_base:
            det = " ".join("%d:%d/%d" % (b, v[0], v[0] + v[1])
                           for b, v in sorted(ST.n_by_base.items()))
            ST.log("DETAIL blocs (base51 : decodes/tentes) " + det)
        ST.log("SOUS-VOIE ACTIVE (base %d) : clair %d/%d  chiffre %d/%d"
               % (_SD4_DL[_dcch_ss() & 3],
                  ST.n_act_clear[0], ST.n_act_clear[1],
                  ST.n_act_ciph[0],  ST.n_act_ciph[1]))

def _garde(fn):
    """Enveloppe un thread : toute exception est LOGUEE (et le thread repart).
    Sans ca, une exception non-OSError tue le thread en silence -> l'UL cesse
    d'emettre sans qu'aucun compteur ni journal ne le dise."""
    import traceback
    def run():
        while True:
            try:
                fn()
            except Exception:
                ST.log("THREAD %s EXCEPTION:\n%s" % (fn.__name__, traceback.format_exc()))
                time.sleep(1)
    run.__name__ = fn.__name__
    return run

def main():
    global _T0
    _T0 = time.monotonic()
    # PURGE DU Kc AU DEMARRAGE. /dev/shm survit aux runs : un Kc laisse par un run
    # a5/1 anterieur fait chiffrer le pont avec une cle etrangere — y compris sur un
    # reseau en a5 0. Mesure : A5 dl=680 alors qu'osmocon n'avait ecrit AUCUN Kc.
    # (Prescrit par SHUNT_LEGIT_ADDRESS_MAP.md:271 ; 09-teardown.sh:175 le fait pour
    # le pipeline qemu-src, mais pas pour le pont.)
    try:
        os.unlink(KC_PATH)
        ST.log("Kc purge au demarrage (%s) — pas de cle heritee d'un run precedent" % KC_PATH)
    except OSError:
        pass
    ST.log("pont TRX démarré : base=%d (CLCK/CTRL/DATA %d/%d/%d) BSIC=%d ARFCN=%d UL_FN_ADVANCE=%d"
           % (TRX_BASE, TRX_BASE, TRX_BASE+1, TRX_BASE+2, BSIC, ARFCN, UL_FN_ADVANCE))
    ST.log("slot-map (osmo-bsc.cfg) : %s" % TS_CONFIG)
    # Toute sonde s'annonce au demarrage : une sonde muette est indiscernable
    # d'une sonde absente (regle de mesure du projet).
    if BSP_FEED:
        ST.log("relais BSP ACTIF -> %s:%d (bursts DL, TRXDv0 156 o). Sous DSP_SHUNT "
               "le BSP draine + publie l'I/Q + apprend son peer, il ne fait PAS "
               "demoduler le DSP. PONT_BSP_FEED=0 pour couper." % (BSP_HOST, BSP_PORT))
    else:
        ST.log("relais BSP desactive (PONT_BSP_FEED=0) — le BSP reste a sec")
    # apprend l'adresse CLCK/CTRL du BTS via un premier RSP/echo : simplifié, on
    # réutilise l'adresse DATA pour CLCK (même IP) dès qu'un burst arrive.
    for fn in (th_ctrl, th_data_rx, th_clck, th_stats,
               ul_sdcch_from_sideband, ul_rach_from_sideband, tch_ul_loop,
               ul_facch_from_sideband, tch_ul_scheduler, th_airrec):
        threading.Thread(target=_garde(fn), daemon=True, name=fn.__name__).start()
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
