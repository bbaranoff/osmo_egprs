x#!/bin/bash
# run.sh — Orchestrateur intra-container Osmocom
#
# Lancé UNE SEULE FOIS par /etc/osmocom/run.sh (via systemd ou CMD docker).
# NE PAS appeler via docker exec -d depuis start.sh → double exécution = chaos.
#
# Fenêtres tmux (adressées par NOM, jamais par index) :
#   faketrx     → UN SEUL processus fake_trx gérant tous les MS via --trx
#   ms1 … msN   → trxcon | mobile     (2 panneaux — fake_trx est centralisé)
#   asterisk    → Asterisk PBX
#   smsc        → proto-smsc-daemon + relay
#   gapk        → osmo-gapk audio

set -euo pipefail

SESSION="osmocom"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

FAKETRX_PY="/opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py"

OPERATOR_ID="${OPERATOR_ID:-1}"
N_MS="${N_MS:-1}"

if ! [[ "$N_MS" =~ ^[0-9]+$ ]] || [ "$N_MS" -lt 1 ] || [ "$N_MS" -gt 9 ]; then
    echo -e "${YELLOW}[WARN] N_MS='${N_MS}' invalide → forcé à 1${NC}"
    N_MS=1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Formules COMMUNES (identiques à start.sh et hlr-feed-subscribers.sh) :
#
#   MSIN        = printf('%04d%06d', op_id, ms_idx)        → 10 chiffres
#   IMSI        = MCC(3) + MNC(2) + MSIN(10)               → 15 chiffres
#   IMEI        = 3589250059 + printf('%02d%02d', op, ms) + 0
#   KI mobile   = "00 11 22 33 44 55 66 77 88 99 aa bb cc dd <ms_hex> <op_hex>"
#                 (format mobile.cfg : octets séparés par espaces)
#   KI HLR VTY  = 00112233445566778899aabbccdd<ms_hex><op_hex>  (sans espaces)
#   MSISDN      = op_id * 10000 + ms_idx
#
# Octet 15 (avant-dernier) = ms_idx  |  Octet 16 (dernier) = op_id
#
# Ressources par MS :
#   MS i  →  TRX port      : 5700 + (i-1)*20   (sur 127.0.0.1)
#             L1CTL socket  : /tmp/osmocom_l2_{i}
#             VTY bind      : 127.0.{op}.{ms}:4247
#             mobile.cfg    : /root/.osmocom/bb/mobile_ms{i}.cfg
#
# FakeTRX UNIQUE pour tous les MS :
#   MS1 → port 5700 (défaut, pas de --trx)
#   MSi → --trx 127.0.0.1:(5700 + (i-1)*20)
# ══════════════════════════════════════════════════════════════════════════════

generate_ms_configs() {
    local base_cfg="/root/.osmocom/bb/mobile.cfg"

    if [ ! -f "$base_cfg" ]; then
        echo -e "${RED}[ERR] mobile.cfg introuvable : ${base_cfg}${NC}"; return 1
    fi

    # Extraire les valeurs de référence depuis mobile.cfg (déjà résolu par start.sh)
    local ref_imsi ref_imei ref_ki ref_l2
    ref_imsi=$(grep -oP '^\s+imsi \K[0-9]{15}' "$base_cfg" | head -1)
    ref_imei=$(grep -oP '^\s+imei \K[0-9]+' "$base_cfg" | head -1)
    # KI avec espaces — trim indispensable pour que le sed de remplacement matche
    ref_ki=$(grep -oP '^\s+ki comp128 \K[0-9a-f ]+' "$base_cfg" | head -1 \
             | sed 's/[[:space:]]*$//')
    ref_l2=$(grep -oP 'layer2-socket \K\S+' "$base_cfg" | head -1)
    ref_l2="${ref_l2:-\/tmp\/osmocom_l2}"

    if [ -z "$ref_imsi" ] || [ -z "$ref_imei" ] || [ -z "$ref_ki" ]; then
        echo -e "${RED}[ERR] Impossible d'extraire IMSI/IMEI/KI de ${base_cfg}${NC}"
        echo -e "  ref_imsi='${ref_imsi}'  ref_imei='${ref_imei}'  ref_ki='${ref_ki}'"
        return 1
    fi

    local mcc mnc
    mcc=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $2}' | head -1)
    mnc=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $3}' | head -1)
    mcc="${mcc:-001}"; mnc="${mnc:-01}"

    echo -e "  Base : IMSI=${ref_imsi}  KI='${ref_ki}'  MCC=${mcc}  MNC=${mnc}"

    for ms_idx in $(seq 1 "${N_MS}"); do
        local cfg="/root/.osmocom/bb/mobile_ms${ms_idx}.cfg"
        local l2_sock="\/tmp\/osmocom_l2_${ms_idx}"
        local vty_ip="127.0.${OPERATOR_ID}.${ms_idx}"

        if [ "$ms_idx" -eq 1 ]; then
            # MS1 : IMSI/IMEI/KI identiques à mobile.cfg (déjà corrects via start.sh)
            # Modifier SEULEMENT le socket L2 et le VTY bind.
            sed \
                -e "s|layer2-socket ${ref_l2}|layer2-socket ${l2_sock}|" \
                -e "/^line vty/,/^[^ ]/{s|bind [0-9.]*|bind ${vty_ip}|}" \
                "$base_cfg" > "$cfg"
            echo -e "  ${CYAN}[MS1]${NC} IMSI=${ref_imsi}  (=mobile.cfg)  VTY=${vty_ip}:4247  L1CTL=${l2_sock}"
        else
            # MS N>1 : dériver depuis mobile.cfg
            local msin; msin=$(printf '%04d%06d' "${OPERATOR_ID}" "${ms_idx}")
            local new_imsi="${mcc}${mnc}${msin}"
            local new_imei="3589250059$(printf '%02d%02d' "${OPERATOR_ID}" "${ms_idx}")0"
            # KI mobile.cfg : octets séparés par espaces
            # Octet 15 = ms_idx,  octet 16 = op_id
            local new_ki; new_ki=$(printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x ff' \
                                          "${ms_idx}")
            sed \
                -e "s|layer2-socket ${ref_l2}|layer2-socket ${l2_sock}|" \
                -e "/^line vty/,/^[^ ]/{s|bind [0-9.]*|bind ${vty_ip}|}" \
                -e "s|imsi ${ref_imsi}|imsi ${new_imsi}|" \
                -e "s|imei ${ref_imei}|imei ${new_imei}|" \
                -e "s|ki comp128 ${ref_ki}|ki comp128 ${new_ki}|" \
                "$base_cfg" > "$cfg"
            echo -e "  ${CYAN}[MS${ms_idx}]${NC} IMSI=${new_imsi}  KI=…$(printf '%02x %02x' "${ms_idx}" "${OPERATOR_ID}")  VTY=${vty_ip}:4247  L1CTL=${l2_sock}"
        fi

        if ! grep -q "${l2_sock}" "$cfg"; then
            echo -e "${YELLOW}  [WARN] layer2-socket non patché dans ${cfg}, forçage${NC}"
            sed -i "s|layer2-socket .*|layer2-socket ${l2_sock}|" "$cfg"
        fi
    done
}

# ── Reset ─────────────────────────────────────────────────────────────────────
echo -e "${GREEN}=== Reset Asterisk ===${NC}"
usermod -u 0 -o osmocom 2>/dev/null || true
systemctl stop asterisk 2>/dev/null || true
asterisk -rx "core stop now" 2>/dev/null || true
pkill -9 -x asterisk 2>/dev/null || true
sleep 1

echo -e "${GREEN}=== Reset tmux ===${NC}"
tmux kill-server 2>/dev/null || true
sleep 0.3
tmux start-server

echo -e "${GREEN}=== Génération configs MS (N=${N_MS}) ===${NC}"
generate_ms_configs
echo ""

echo -e "${GREEN}=== Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh
chmod 666 /tmp/pcu_bts 2>/dev/null || true
sleep 5

# ══════════════════════════════════════════════════════════════════════════════
# FakeTRX — UN SEUL processus pour TOUS les MS de la BTS
#
# Référence : https://osmocom.org/projects/baseband/wiki/FakeTRX
#   "It's possible to handle multiple MS and/or BTS connections
#    in a single FakeTRX process using --trx option."
#
# MS1 → transceiver par défaut (port 5700, inclus sans --trx)
# MSi → --trx 127.0.0.1:(5700+(i-1)*20)
#
# Chaque trxcon MS_i se connecte via :  trxcon -r 127.0.0.1 -p PORT_i -s SOCK_i
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}=== FakeTRX — 1 processus, ${N_MS} MS ===${NC}"

tmux new-session -d -s "$SESSION" -n faketrx

# Construire les arguments --trx pour MS 2..N
FAKETRX_CMD="python3 ${FAKETRX_PY}"
for ms_idx in $(seq 2 "${N_MS}"); do
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))
    FAKETRX_CMD="${FAKETRX_CMD} --trx 127.0.0.1:${trx_port}"
done

echo -e "  ${CYAN}Cmd:${NC} ${FAKETRX_CMD}"
tmux send-keys -t "${SESSION}:faketrx" \
    "echo '=== FakeTRX — ${N_MS} transceiver(s) ===' && ${FAKETRX_CMD}" \
    C-m
# Laisser fake_trx lier ses sockets avant que les trxcon se connectent
sleep 2

# ══════════════════════════════════════════════════════════════════════════════
# Fenêtres MS — 2 panneaux (trxcon + mobile)
#
# RÈGLE : adresser TOUJOURS par nom de fenêtre, jamais par index numérique.
#
# Architecture par MS :
#   ┌──────────────────────────────────────────────────────┐
#   │  trxcon -r 127.0.0.1 -p PORT_i -s /tmp/osmocom_l2_i │  pane 0
#   │    ↳ se connecte au fake_trx centralisé              │
#   │    ↳ expose socket L1CTL pour l'application mobile   │
#   ├──────────────────────────────────────────────────────┤
#   │  mobile -c /root/.osmocom/bb/mobile_ms{i}.cfg        │  pane 1
#   └──────────────────────────────────────────────────────┘
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}=== Démarrage des ${N_MS} MS ===${NC}"

for ms_idx in $(seq 1 "${N_MS}"); do
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))
    l2_socket="/tmp/osmocom_l2_${ms_idx}"
    cfg="/root/.osmocom/bb/mobile_ms${ms_idx}.cfg"
    win="ms${ms_idx}"

    echo -e "  ${CYAN}[MS${ms_idx}]${NC} TRX:127.0.0.1:${trx_port}  L1CTL:${l2_socket}  VTY:127.0.${OPERATOR_ID}.${ms_idx}:4247"

    tmux new-window -t "$SESSION" -n "$win"

    # Pane 0 : trxcon
    #   -r 127.0.0.1  IP du fake_trx (unique, local)
    #   -p PORT_i     port du transceiver de ce MS dans fake_trx
    #   -s SOCKET_i   socket L1CTL → mobile attend la connexion ici
    tmux send-keys -t "${SESSION}:${win}.0" \
        "echo '=== trxcon MS${ms_idx} → fake_trx:${trx_port} ===' && sleep 2 && \
         trxcon -p ${trx_port} -s ${l2_socket}" \
        C-m

    # Pane 1 : mobile
    tmux split-window -v -t "${SESSION}:${win}"
    tmux send-keys -t "${SESSION}:${win}.1" \
        "echo '=== mobile MS${ms_idx} ===' && sleep 5 && \
         mobile -c ${cfg}" \
        C-m

    tmux select-layout -t "${SESSION}:${win}" even-vertical
done

# ── Asterisk ──────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION" -n asterisk
tmux send-keys -t "${SESSION}:asterisk" \
    "rm -f /var/lib/asterisk/astdb.sqlite3 && asterisk -cvvv" C-m

# ── SMSC ──────────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION" -n smsc
tmux send-keys -t "${SESSION}:smsc" "/etc/osmocom/smsc-start.sh" C-m

# ── gapk audio ────────────────────────────────────────────────────────────────
tmux new-window -t "$SESSION" -n gapk
tmux send-keys -t "${SESSION}:gapk" \
    "echo '=== gapk audio ===' && \
     echo 'Mode auto : surveille OsmoMGW pour endpoints RTP actifs' && \
     echo 'Mode BB   : appeler ext 888 depuis mobile → voix ALSA directe' && \
     echo '  Pour passer en mode BB : Ctrl-C puis : gapk-start.sh bb-audio' && \
     sleep 3 && gapk-start.sh auto" \
    C-m

# ── Sélectionner MS1 ─────────────────────────────────────────────────────────
tmux select-window -t "${SESSION}:ms1"

# ══════════════════════════════════════════════════════════════════════════════
# Résumé
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Opérateur ${OPERATOR_ID} — Stack prête  (${N_MS} MS)${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}FakeTRX :${NC}  1 processus, ${N_MS} transceiver(s)  (fenêtre: faketrx)"
echo ""
echo -e "  ${CYAN}Mobile Stations :${NC}"
for ms_idx in $(seq 1 "${N_MS}"); do
    trx_port=$(( 5700 + (ms_idx - 1) * 20 ))
    msisdn=$(( OPERATOR_ID * 10000 + ms_idx ))
    echo -e "    ms${ms_idx}  TRX:${trx_port}  L1CTL:/tmp/osmocom_l2_${ms_idx}  VTY:127.0.${OPERATOR_ID}.${ms_idx}:4247  MSISDN:${msisdn}"
done
echo ""
echo -e "  ${CYAN}Fenêtres de service :${NC}  faketrx  asterisk  smsc  gapk"
echo ""
echo -e "  ${CYAN}Navigation :${NC}  Ctrl-b w (liste)   Ctrl-b [nom_fenetre]"
echo -e "  ${CYAN}VTY HLR   :${NC}  telnet 127.0.0.2 4258"
echo -e "  ${CYAN}Voix BB   :${NC}  appeler ext 888  (gapk → ALSA)"
echo ""

tmux attach-session -t "$SESSION"
