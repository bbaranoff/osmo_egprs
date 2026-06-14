#!/usr/bin/env python3
"""
qemu_bcch_bridge.py — démodule l'I/Q DL du BTS (depuis qemu BSP) et injecte les
SI décodés dans qemu via GSMTAP → le shunt (CALYPSO_DSP_SHUNT=1) les écrit en
a_cd → le firmware → le mobile campe. ZÉRO hack : vrai signal du BTS décodé.

Chaîne :
  UDP I/Q (port BSP, défaut 6702)  ──parse TRXD──>  148 samples I/Q (cs16)
    ──GMSK demod différentiel (1 SPS)──>  bits
    ──route par FN (BCCH = fn%51 in {2,3,4,5}), accumule 4 bursts──>
    ──gsm0503_xcch_decode (libosmocoding ctypes)──>  23 octets L2 (SI)
    ──GSMTAP UM/BCCH──>  udp 127.0.0.1:4730  (le listener du shunt qemu)

Démod : osmo-trx module en GMSK BT=0.3, 1 SPS, L=4 (cf gmsk_grgsm.py). À 1 SPS
le demod différentiel (d=s[k]·conj(s[k-1]), bit=sign(imag d)) récupère les bits ;
le Viterbi+FIRE de gsm0503 corrige le résiduel d'ISI. Si CRC fail systématique,
inverser BIT_SIGN ou ajuster les positions data (DATA_POS).

Deps : numpy (via gnuradio venv), libosmocoding.so (osmocom).
Usage : source /root/.env/bin/activate ; python qemu_bcch_bridge.py
Env   : BSP_IN_PORT (6702), GSMTAP_HOST/PORT (127.0.0.1/4730), ARFCN (514)
"""
import os, socket, struct, ctypes, sys
import numpy as np

BSP_IN_PORT  = int(os.environ.get("BSP_IN_PORT", "6702"))
GSMTAP_HOST  = os.environ.get("GSMTAP_HOST", "127.0.0.1")
GSMTAP_PORT  = int(os.environ.get("GSMTAP_PORT", "4730"))
ARFCN        = int(os.environ.get("ARFCN", "514"))
BIT_SIGN     = int(os.environ.get("BIT_SIGN", "1"))   # -1 pour inverser si CRC fail

# --- libosmocoding : gsm0503_xcch_decode(uint8 l2[23], sbit bursts[4*116], int*nerr, int*ntot) ---
_lib = ctypes.CDLL("libosmocoding.so.0")
_lib.gsm0503_xcch_decode.restype  = ctypes.c_int
_lib.gsm0503_xcch_decode.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                     ctypes.POINTER(ctypes.c_int),
                                     ctypes.POINTER(ctypes.c_int)]

def xcch_decode(bursts_4x116):
    """bursts_4x116 : list de 4 arrays de 116 sbit (int8). -> (l2bytes|None, nerr)."""
    sb = bytes(bytearray(int(np.clip(x, -127, 127)) & 0xff for b in bursts_4x116 for x in b))
    l2 = ctypes.create_string_buffer(23)
    nerr = ctypes.c_int(0); ntot = ctypes.c_int(0)
    rc = _lib.gsm0503_xcch_decode(l2, sb, ctypes.byref(nerr), ctypes.byref(ntot))
    if rc < 0:
        return None, nerr.value
    return l2.raw[:23], nerr.value

# --- GMSK demod différentiel (1 SPS) : I/Q (148 complex) -> 116 sbit ---
# Burst GSM normal (148 symbols) : 3 tail | e[0..57] (58) | 26 training | e[58..115] (58) | 3 tail
# Les 116 e-bits = positions 3..60 et 87..144.
DATA_POS = list(range(3, 61)) + list(range(87, 145))   # 58 + 58 = 116

def demod_burst(iq):
    """iq : np.complex array (>=148). -> np.int8 array de 116 sbit, ou None."""
    if len(iq) < 148:
        return None
    s = iq[:148].astype(np.complex64)
    # différentiel : rotation symbole-à-symbole
    d = s[1:] * np.conj(s[:-1])
    d = np.concatenate(([d[0]], d))   # aligner sur 148
    # GMSK : la composante quadrature de la rotation porte le bit (±π/2)
    soft = np.imag(d)
    m = np.max(np.abs(soft)) or 1.0
    soft = (soft / m) * 127.0 * BIT_SIGN
    e = np.array([int(soft[p]) for p in DATA_POS], dtype=np.int8)
    return e

# --- GSMTAP ---
def gsmtap(l2, fn, arfcn):
    # hdr 16o : ver=2,hdrlen=4,type=1(UM),ts=0,arfcn,sig=0,snr=0,fn,subtype=1(BCCH),ant,subslot,res
    hdr = bytes([2,4,1,0]) + struct.pack(">H", arfcn) + bytes([0,0]) + \
          struct.pack(">I", fn) + bytes([1,0,0,0])
    return hdr + l2

def main():
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind(("0.0.0.0", BSP_IN_PORT))
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"[bridge] I/Q in udp:{BSP_IN_PORT}  ->  GSMTAP out {GSMTAP_HOST}:{GSMTAP_PORT}  arfcn={ARFCN}",
          flush=True)

    acc = {}   # block_id -> {fn%4 : sbits}  (accumulation des 4 bursts BCCH)
    n_ok = n_fail = n_pkt = 0
    while True:
        pkt, _ = rx.recvfrom(4096)
        n_pkt += 1
        if len(pkt) < 8 + 148*4:        # 8 hdr + 148 I/Q pairs (cs16)
            continue
        # TRXD-ish hdr : tn(1) fn(4 BE) ... ; I/Q à partir de l'octet 8 (int16 LE entrelacé)
        fn = struct.unpack(">I", pkt[1:5])[0]
        raw = np.frombuffer(pkt[8:8+148*4], dtype="<i2").astype(np.float32)
        iq = raw[0::2] + 1j*raw[1::2]
        # BCCH = position 2,3,4,5 du 51-multiframe
        mf = fn % 51
        if mf not in (2, 3, 4, 5):
            continue
        e = demod_burst(iq)
        if e is None:
            continue
        blk = fn // 51                  # numéro de bloc 51-MF (identifie le set SI)
        acc.setdefault(blk, {})[mf - 2] = e
        if len(acc[blk]) == 4:          # 4 bursts du bloc BCCH
            bursts = [acc[blk][i] for i in range(4)]
            del acc[blk]
            l2, nerr = xcch_decode(bursts)
            if l2 is None:
                n_fail += 1
                if n_fail <= 20 or n_fail % 50 == 0:
                    print(f"[bridge] CRC fail blk={blk} nerr={nerr} "
                          f"(ok={n_ok} fail={n_fail}) — si tjrs fail: BIT_SIGN={-BIT_SIGN}", flush=True)
                continue
            n_ok += 1
            tx.sendto(gsmtap(l2, fn, ARFCN), (GSMTAP_HOST, GSMTAP_PORT))
            print(f"[bridge] SI décodé blk={blk} nerr={nerr} L2[0..2]={l2[0]:02x} {l2[1]:02x} {l2[2]:02x}"
                  f" -> GSMTAP (ok={n_ok})", flush=True)

if __name__ == "__main__":
    main()
