# DIAG — Location Update bloqué : la RACH (UL) n'atteint jamais la BTS

> Document autonome pour Claude web. Contexte : émulateur GSM "Calypso" sous QEMU
> (firmware osmocom-bb) relié à un réseau Osmocom (osmo-bts-trx + osmo-trx-ipc +
> osmo-bsc/msc/hlr), mode **full-grgsm** où gr-gsm joue le rôle du DSP via un
> "shunt" qui réinjecte le SI/SCH décodé dans l'API RAM du firmware.
> Container Docker : `osmo-operator-1`. Sources : `/opt/GSM/qemu-src` (+ `/opt/GSM/osmo-trx`).

## 1. Symptôme

Le mobile **campe** (lit FCCH/SCH/SI réels via gr-gsm, CGI=001-01-1-6001, IMSI carte
test `001010001000001`) mais la **Location Update échoue** en boucle :
```
mobile.log:  RR CHANNEL REQUEST: 00 (Location Update)  -> RANDOM ACCESS bursts
mobile.log:  "Requesting channel failed"
mobile.log:  DMM new state U2_NOT_UPDATED -> U2_NOT_UPDATED
```
Réseau (HLR/MSC) : **aucun subscriber/IMSI** reçu → le LU REQUEST ne part jamais.

## 2. Chaîne UL, hop par hop (tout MESURÉ)

| # | Hop | État | Preuve |
|---|---|---|---|
| 1 | Mobile émet RACH (access burst) | ✅ | mobile.log RANDOM ACCESS, ra=0x06/07/0d |
| 2 | RACH → firmware → QEMU BSP | ✅ | qemu.log `D_RACH-FINDER ra=0x06…` |
| 3 | BSP → ipc-device : module GMSK + inject UL | ✅ | `UL inject #N`, `CALYPSO_IPC_UL=1` |
| 4 | inject → osmo-trx (shm RX) → démod → TRXD UL → BTS | ❌ | **UL TRXD 5702→5802 = 100% NOPE (length-11), RSSI plancher -110** |
| 5 | osmo-bts décode RACH → CHAN RQD | ❌ | bts.log : jamais de CHAN RQD |
| 6 | BSC → IMMEDIATE ASSIGN (AGCH) → mobile | ❌ | jamais |
| 7 | mobile → LU REQUEST (SDCCH) → MSC | ❌ | jamais |

**Le hop #4 casse** : osmo-trx n'émet QUE des NOPE vers la BTS pour l'UL.

## 3. Instrumentation au point d'injection (ground truth)

Ajout d'un log dans `ul_drain` (qemu_wrap.c) — le burst émis est CORRECT :
```
UL-DBG #1 in=148b(nz=148) out=592 samp [20000,0..mid=20000]
         bits=0011011110111111000000001101001111 000…000  (access-burst: sync actif puis guard)
```
→ contenu = vrai access-burst, amplitude 20000 (~0.61 FS), **OSR=4 (592 samples)**. 

## 4. Ce qui est VÉRIFIÉ / ÉCARTÉ (2 investigations multi-agents, citations source)

- **La modulation / amplitude / OSR ne sont PAS en cause** : UL-DBG = 592 samples, 20000, contenu access-burst.
- **Le FN attaché par si_bridge au feed_si (UDP 4730) est DEAD DATA** (≠ blocage LU) :
  - `calypso_dsp_shunt.c:671-702` `shunt_gsmtap_read` ne lit que `buf[2]` (type),
    `buf[12]` (channel), `buf[16+]` (L2). Les octets 8-11 (frame_number) **jamais lus**.
  - `calypso_dsp_shunt.c:989` `calypso_dsp_shunt_feed_si(const uint8_t *l2, int len)` —
    **aucun paramètre FN**. Tout le FN vu par le firmware vient de `calypso_trx_get_fn()`
    (`:504` scheduling BCCH `tc=fn%51`, `:1028` `l1ctl_inject_dl_si(...,calypso_trx_get_fn())`).
  - (corrigé pour l'affichage quand même : si_bridge lit maintenant le vrai FN par-SI.)
- **Le mismatch shm `buffer_size=5000` (osmo-trx) vs commit `CALYPSO_SHM_BUFSIZE=2500` (device)
  n'est PAS le bug** : `ipc_shm.c` `ipc_shm_enqueue` écrit `data_len=min(len,buffer_size)=2500`
  et `ipc_shm_read` gère le partial read (lit exactement `data_len`=2500 par slot, FIFO strict,
  `read_next`/`write_next`). Pas de trou de zéros.

## 5. CAUSE RACINE confirmée (workflow "ul-rx-plumbing", haute confiance)

**Désalignement de phase de slot/trame entre les deux horloges TDMA.**
- Le device place la RACH à **sa** frontière de trame : `qemu_wrap.c` inject sur
  `d->rx_ts % CALYPSO_FRAME_SAMPLES(5000) == 0`, burst à l'offset 0 du chunk.
  `d->rx_ts` est un compteur indépendant (init 0, `qemu_wrap.c:379`, `+= 2500` par heartbeat).
- osmo-trx ancre sa grille TS0 sur un **`ts_initial` ARBITRAIRE** issu d'un flush
  (`IPCDevice.cpp:1075` `ts_initial = tmps + read`), et découpe le flux RX continu en
  slots fixes de **625 samples** (4 SPS) en comptant les samples (`radioInterface.cpp:257-285`),
  **sans aucun réalignement modulo-trame**. Le timestamp shm n'est qu'un contrôle de
  continuité (`IPCDevice.cpp:1167` logue mais ne réaligne pas).
- Conséquence : la RACH tombe à un **TN/FN aléatoire** relatif à la grille osmo-trx →
  le slot que la BTS traite comme TS0/RACH lit du zéro → NOPE → RSSI -110.

Contraintes du corrélateur RACH d'osmo-trx (combined CCCH+SDCCH4, TS0 = `phys_chan_config CCCH+SDCCH4`):
- RACH détectée seulement si **FN%51 ∈ {4,5,14..36,45,46}** (`Transceiver.cpp:558-573`).
- Le corrélateur cherche la sync ~symbole 48, fenêtre 39..56, et **rejette TOA < 3·sps (12 samples)**
  (`sigProcLib.cpp:1683,1752,1788`) → un burst à l'offset 0 du slot est rejeté (bord).
- Un access-burst a ~68 symboles de guard AVANT les bits actifs (`sigProcLib.cpp:839`).

## 6. OBSERVATION CLÉ de l'opérateur (humain)

> **"il y a un décalage FN de 31"** — l'offset de trame entre device et osmo-trx (ou
> mobile↔BTS) vaut **31**. (C'est aussi le "31" récurrent dès le début : positions SCH
> FN%51∈{1,11,21,31,41} ; 31 est une position SCH.)

À confirmer : est-ce un décalage **constant de 31 trames** (alors corrigeable par un offset
fixe) ou dépendant du run (ts_initial dépend du flush) ?

## 7. Fixes DÉJÀ appliqués (qemu_wrap.c, compilés, non commités)

1. **Relais ne clobber plus la RACH** : le bloc relais UL (depuis UDP 5811, vide en
   full-grgsm) n'écrase plus `ul_chunk` quand il n'a pas de données. (nécessaire)
2. **OSR=4** : `ul_gmsk_mod` produit 148 symboles × 4 = 592 samples (MSK phase-continue),
   `g_ul_iq[CALYPSO_BSP_BURSTLEN*CALYPSO_TRX_OSR*2]`. (nécessaire, confirmé par UL-DBG)
3. **Offset intra-slot** `CALYPSO_UL_SLOT_OFFSET` (testé 128 → échec : 128+592=720 > 625,
   le burst déborde le slot).
4. **Réglages sweepables (dernier en date, à rebuild)** :
   - `CALYPSO_UL_FN_OFFSET` (défaut **31**) : corrige le décalage FN.
   - `CALYPSO_UL_FN_GATE` (défaut 1) : n'injecte que si `osmo_fn%51` ∈ {4,5,14..36,45,46}.
   - `CALYPSO_UL_SLOT_OFFSET` (samples) : TOA intra-slot.
   - log inject : `internal_fn=… osmo_fn=… (%51=…) slotoff=…`.

## 8. Problème résiduel / tensions non résolues

- **Le burst fait 592 samples ≈ tout le slot (625).** Un access-burst doit être COURT
  (~88 symboles actifs = 352 samples + guard avant ET après) et placé à un TOA tel que la
  sync tombe vers le symbole 48. Avec 592 samples on ne peut pas (déborde). → il faut sans
  doute **moduler seulement les symboles actifs de l'access-burst et silencer le guard**
  (mettre les IQ à 0, pas du GMSK continu), puis placer au bon TOA.
  Or `ul_gmsk_mod` module les 148 bits en GMSK continu (enveloppe constante) → pas de vrai
  guard silencieux. Comment savoir où finit la partie active de l'access-burst dans les 148
  bits que le firmware envoie ? (UL-DBG montre ~42 bits actifs puis des "0" — mais "0" =
  soft -127, indistinguable d'un bit de données par la valeur ; la structure est positionnelle.)
- **Ancrage `ts_initial%5000`** : même avec le bon offset FN, la phase sous-trame (quel
  sous-slot des 4 d'un chunk = TN0 d'osmo-trx) dépend de `ts_initial`, non négocié.

## 9. Questions pour Claude web

1. Quelle est la façon CANONIQUE, dans un device IPC custom alimentant `osmo-trx-ipc`
   (Transceiver52M, `device/ipc`), d'aligner la **grille de slots UL (RX)** du device sur
   celle d'osmo-trx, sachant qu'osmo-trx ancre sur `ts_initial` (flush) et compte 625
   samples/slot sans réalignement ? Faut-il forcer `ts_initial%5000==0` (flush d'un nombre
   entier de trames) et/ou initialiser `d->rx_ts` à `initialReadTimestamp()+path_delay` ?
2. Comment synthétiser correctement un **access-burst RACH** GMSK à OSR=4 que le corrélateur
   d'osmo-trx (`sigProcLib.cpp` `detectRACHBurst`/`detectGeneralBurst`) décode : structure
   exacte (8 tail + 41 sync étendu + 36 data + 3 tail + 68.25 guard), TOA cible, et faut-il
   silencer le guard (IQ=0) plutôt que GMSK continu ?
3. Le firmware osmocom-bb (BSP, calypso) envoie 148 "bits" pour un burst UL : pour une RACH,
   comment l'access-burst (88 symboles utiles) est-il disposé dans ces 148 bits, et comment
   le distinguer d'un normal burst côté device ?
4. Le décalage FN de 31 observé : est-ce un artefact déterministe du pipeline (alors offset
   fixe) ou faut-il un mécanisme d'alignement dynamique (apprendre la phase d'osmo-trx) ?

## 10. Repro / vérif (NE JAMAIS lire/grep/cat sous /tmp — FIFO live, ça casse le pipeline)

```bash
# UL : doit cesser d'être 100% NOPE/length-11 et montrer des bursts 154o (RSSI != -110)
docker exec osmo-operator-1 timeout 25 /usr/bin/tcpdump -i any -n -l \
  "src port 5702 and dst port 5802" 2>/dev/null | grep -oE "length [0-9]+" | sort | uniq -c
# DL (référence qui marche) : 5802->5702 = bursts 154o
# BTS Graal :
docker exec osmo-operator-1 grep -aiE "chan rqd|rach|immediate" /tmp/bts.log | tail
# log inject device :
docker exec osmo-operator-1 grep -a "UL inject\|UL-DBG" /tmp/calypso-ipc-device.log | tail
# rebuild device : cd /opt/GSM/qemu-src/tools/calypso-ipc-device && make ; puis ./run.sh (rerun)
```

## 11. Fichiers clés (container osmo-operator-1)
- `/opt/GSM/qemu-src/tools/calypso-ipc-device/qemu_wrap.c` — UL : `ul_gmsk_mod`(~522),
  `ul_drain`(~547), inject+enqueue(~650-776), `d->rx_ts` init(~379). Constantes(~55-60).
- `/opt/GSM/qemu-src/tools/calypso-ipc-device/ipc_shm.c` — `ipc_shm_enqueue`/`_read`.
- `/opt/GSM/osmo-trx/Transceiver52M/radioInterface.cpp` (slicing 625), `Transceiver.cpp`
  (RACH FN gate :558-573, RSSI :751), `sigProcLib.cpp` (TOA gate :1683, target :1788),
  `device/ipc/IPCDevice.cpp` (ts_initial :1075, timestamp check :1167).
- `/opt/GSM/si_bridge.py` (gr-gsm decode → feed_si 4730 / feed_sb SCH 4731).
- gr-gsm patch : `/home/nirvana/osmo_egprs/patches/grgsm-receiver-publish-bsic-fn.patch`.

---
# MISE À JOUR 2026-06-05 — UL/RACH cracké couche par couche (état quasi-final)

La RACH UL a été remontée hop par hop. Chaque couche corrigée a révélé la suivante :

1. **Clobber relais (corrigé)** — en full-grgsm, le bloc relais UL de `qemu_wrap.c`
   écrasait `ul_chunk` (la RACH injectée) par `relay_ul` (lu sur 5811, n>0 car le
   flowgraph gr-gsm émet dessus). Fix : priorité absolue à la RACH —
   `if (g_relay_on && g_relay_ul_fd>=0 && ul_src != ul_chunk)`. Vérifié : `ENQ-RACH>0`,
   le burst atteint enfin osmo-trx (nz=1036, s0=[20000,0], ts%5000==0).

2. **Alignement de slot (corrigé)** — le burst à l'offset 0 du chunk atterrissait sur
   **osmo-TN5** (mesuré par instrumentation `ENERGY fn=… tn=5 type=1 avg=20000`).
   Fix : `CALYPSO_UL_SLOT_OFFSET=1875` (3 slots × 625) → le burst tombe sur **TN0**
   (`ENERGY tn=0 type=3` ; type=3=RACH dans l'enum OFF=0,TSC=1,EXT_RACH=2,RACH=3).
   NB : le décalage device↔osmo-trx vaut 5 slots, pas le "31" (qui était pré-Q1).

3. **Corrélation RACH (RACINE FINALE, à corriger)** — sur TN0/RACH/pleine énergie,
   `detectRACHBurst` rend `rc=0` (`RACH-DET fn=… rc=0 toa=0`). Cause prouvée :
   - osmo-trx corrèle `GSM::gRACHSynchSequenceTS0 = "01001011011111111001100110101010001111000"`
     (41 bits, cible symbole 48) — `GSM/GSMCommon.cpp:61`, `sigProcLib.cpp:1782`.
   - Les bits UL du firmware n'ont **AUCUNE région constante = cette sync** : seuls
     les ~34 premiers bits varient (RA/data), le reste = guard à zéro. La sync est
     **absente**.
   - Pourquoi : le mobile envoie `L1CTL_RACH_REQ (ra=0x0a)` (osmocon.log) → le firmware
     écrit le **RA brut** dans l'API DSP (`qemu.log: D_RACH-FINDER ra=0x0a bsic=…`).
     C'est le **DSP** qui code RA→canal + ajoute `[8 tail][41 sync][3 tail]`. Or le DSP
     est **court-circuité par le shunt** → l'access-burst n'est jamais construit → pas
     de sync → osmo-trx ne corrèle jamais.

## FIX FINAL (à implémenter) — encoder la RACH dans le device
`gsm0503_rach_ext_encode(ubit_t *burst, uint16_t ra, uint8_t bsic, bool is_11bit)` est
DISPONIBLE (libosmocoding ; header `/usr/local/include/osmocom/coding/gsm0503_coding.h`,
lib `/usr/local/lib/libosmocoding.so`). Plan :
1. **Récupérer le RA** (le device ne l'a pas proprement) : soit QEMU BSP l'extrait de
   l'API DSP (le D_RACH-FINDER le fait déjà : `ra`,`bsic`) et le tague dans l'en-tête du
   burst UL envoyé à l'ipc-device ; soit sniffer `L1CTL_RACH_REQ` sur /tmp/osmocom_l2.
   BSIC = 14 (BSIC réel de la cellule, gr-gsm SCH).
2. Dans `ul_drain`/`ul_gmsk_mod` : `gsm0503_rach_ext_encode(ab, ra, 14, false)` → bits de
   l'access-burst (avec sync), puis GMSK (BT=0.3) à OSR=4, placés à SLOT_OFFSET=1875.
   Lier `-losmocoding`.
3. Pour CHAN RQD seul, la sync suffit (la détection corrèle la sync, pas le RA) ; mais
   pour que la **LU aboutisse** il faut le **vrai RA** (le mobile matche le request-ref
   RA+FN de l'IMM ASSIGN). Donc le RA correct est requis pour le bout-en-bout.

## Knobs runtime ajoutés (qemu_wrap.c, sweepables sans rebuild)
CALYPSO_UL_SLOT_OFFSET (=1875 pour TN0), CALYPSO_UL_FN_GATE (0=off), CALYPSO_UL_AMP,
CALYPSO_UL_ACTIVE_SYMS, CALYPSO_UL_INVERT, CALYPSO_UL_GMSK (1=GMSK,0=MSK), CALYPSO_UL_DEBUG.
Instrumentation : `UL-DBG`/`ENQ-RACH` (ipc-device.log), `ENERGY`/`RACH-DET` (osmo-trx-ipc.log).

## Prochaine étape AGCH (après CHAN RQD)
Une fois la RACH détectée → la BTS émet IMM ASSIGN sur AGCH (DL). Vérifier que le mobile
le reçoit (chemin DL gr-gsm→shunt→feed_si/a_cd) et matche le request reference. C'est la
frontière suivante de la LU.
