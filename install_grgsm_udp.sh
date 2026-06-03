#!/bin/bash
# install_grgsm_udp.sh — installe le backend UDP du transceiver gr-gsm (mode
# full-grgsm) dans le conteneur osmo-operator-1. Idempotent.
#
#   1. copie radio_if_udp.py dans le module gnuradio.gsm.trx
#   2. patche grgsm_trx pour accepter --driver udp
#
# Après : lancer le mode full-grgsm (voir recette en bas).
set -e
C=osmo-operator-1
MOD=/root/.env/lib/python3.10/site-packages/gnuradio/gsm/trx
TRX=/opt/GSM/gr-gsm/apps/grgsm_trx

# 1. radio_if_udp -> module
docker cp "$(dirname "$0")/radio_if_udp.py" "$C:$MOD/radio_if_udp.py"
echo "[install] radio_if_udp.py -> $MOD"

# 2. patch grgsm_trx (--driver udp) si pas déjà fait
docker exec "$C" bash -lc '
F='"$TRX"'
if ! grep -q "radio_if_udp" "$F"; then
  cp "$F" "$F.bak.preudp"
  sed -i "s|elif argv.driver == \"lms\":|elif argv.driver == \"udp\":\n\t\t\tfrom gnuradio.gsm.trx.radio_if_udp import RadioInterfaceUDP as Radio\n\t\telif argv.driver == \"lms\":|" "$F"
  sed -i "s|choices = \[\"uhd\", \"lms\"\]|choices = [\"uhd\", \"lms\", \"udp\"]|" "$F"
  echo "[install] grgsm_trx patché (--driver udp)"
else
  echo "[install] grgsm_trx déjà patché"
fi'

cat <<'RECETTE'

=== RECETTE mode full-grgsm (IPC pour BTS, trxcon+gr-gsm pour mobile) ===
Côté BTS (inchangé) : Core Osmocom + osmo-bts + osmo-trx-ipc(tx-sps 1) +
  calypso-ipc-device lancé avec CALYPSO_IPC_RELAY=1 (relaie l'I/Q continu
  fc32 : DL→udp 5810, UL←udp 5811 ; plus de TRXDv0/BSP Calypso).

Côté mobile (nouveau, PAS de qemu/DSP) :
  # 1. transceiver gr-gsm (osr=1 car osmo-trx tx-sps=1) :
  CALYPSO_TRX_OSR=1 grgsm_trx --driver udp -s 270833 -p 6700 \
      -i 127.0.0.1 -b 0.0.0.0
  #    (RX I/Q sur udp 5810, TX I/Q vers udp 5811 ; TRX vers trxcon @6700+)
  # 2. trxcon (L1 TRX) :
  trxcon -i 127.0.0.1 -p 6700
  # 3. mobile (L23) sur la socket de trxcon :
  mobile -c /root/.osmocom/bb/mobile_group1.cfg

Le DSP Calypso n'est plus émulé → plus de congestion → timing ~ no-dsp.
L'I/Q continu reste tappable sur udp 5810 (FFT/diag).
RECETTE
