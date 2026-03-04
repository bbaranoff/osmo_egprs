#!/bin/bash
# run.sh — Orchestrateur tmux multi-session Osmocom
#
# Lance et synchronise les services dans un ordre correct :
#   1. OsmoBTS (fake_trx)
#   2. OsmoBSC
#   3. OsmoMSC
#   4. OsmoHLR
#   5. osmo-gapk (optionnel, voix)
#   6. Relais SMS (optionnel)
#
# Logs agrégés dans /var/log/osmocom/
#
# Entré via :
#   docker run ... /root/run.sh
#   
# Variables d'environnement :
#   OPERATOR_ID  — ID opérateur (1…N)
#   N_MS         — Nombre MS (1…9)
#   CONTAINER_IP — IP privée (172.20.N.10)
#   INTER_STP_IP — IP inter-STP (172.20.0.10 ou 127.0.0.1)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'; BOLD='\033[1m'

OPERATOR_ID="${OPERATOR_ID:-1}"
N_MS="${N_MS:-1}"
CONTAINER_IP="${CONTAINER_IP:-127.0.0.1}"
INTER_STP_IP="${INTER_STP_IP:-127.0.0.1}"

LOG_DIR="/var/log/osmocom"
mkdir -p "$LOG_DIR"

echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Osmocom Multi-Operator Orchestrator (run.sh)         ║${NC}"
echo -e "${CYAN}║  Op${OPERATOR_ID} • N_MS=${N_MS} • IP=${CONTAINER_IP}              ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"

# ══════════════════════════════════════════════════════════════════════════════
# Session tmux
# ══════════════════════════════════════════════════════════════════════════════

tmux_session="osmo-op${OPERATOR_ID}"
[ -n "$(tmux list-sessions 2>/dev/null | grep -F "$tmux_session")" ] && tmux kill-session -t "$tmux_session"

tmux new-session -d -s "$tmux_session" -x 180 -y 50 \
    -c /root \
    bash -c "echo '=== Osmocom Op${OPERATOR_ID} ===' && sleep infinity"

tmux_exec() {
    local win="$1" cmd="$2" title="$3"
    tmux new-window -t "$tmux_session" -n "$win"
    tmux send-keys -t "$tmux_session:$win" "cd /root && $cmd" Enter
    echo -e "  ${GREEN}✓${NC} Fenêtre ${MAGENTA}${win}${NC} : ${YELLOW}${title}${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. OsmoBTS — DAQ + Transceiver virtuel
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[1/6] OsmoBTS (fake_trx)${NC}"

# fake_trx.py consolidée : support multi-TRX
# Écoute sur 127.0.0.1:6700 par défaut, TRX sur :6701, :6702, :6703 (si N_MS > 1)
tmux_exec "osmo-bts" \
    "sleep 3 && osmo-bts-trx -c /etc/osmocom/osmo-bts.cfg 2>&1 | tee ${LOG_DIR}/osmo-bts.log" \
    "OsmoBTS-TRX"

# fake_trx.py (simule le transceiver matériel)
# Lance N_MS instances logiques (une par MS ou partagées en multi-TRX)
(
    sleep 8  # Augmenté : attendre osmo-bts-trx complètement prêt (connexion + init)
    python3 /root/fake_trx.py \
        --gsmtap-ip 127.0.0.1 \
        --bind-port 6700 \
        --num-trx "$N_MS" \
        2>&1 | tee "${LOG_DIR}/fake_trx.py.log"
) &

echo -e "  ${GREEN}✓${NC} Fenêtre ${MAGENTA}osmo-bts${NC} lancée"

# ══════════════════════════════════════════════════════════════════════════════
# 2. OsmoBSC — Base Station Controller
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[2/6] OsmoBSC${NC}"

tmux_exec "osmo-bsc" \
    "osmo-bsc -c /etc/osmocom/osmo-bsc.cfg 2>&1 | tee ${LOG_DIR}/osmo-bsc.log" \
    "Base Station Controller"

# ══════════════════════════════════════════════════════════════════════════════
# 3. OsmoMSC — Mobile Switching Center (avec Asterisk SIP)
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[3/6] OsmoMSC${NC}"

tmux_exec "osmo-msc" \
    "osmo-msc -c /etc/osmocom/osmo-msc.cfg 2>&1 | tee ${LOG_DIR}/osmo-msc.log" \
    "Mobile Switching Center"

# Asterisk (VoIP/SIP inter-op)
# [PATCH] Timing augmenté : fake_trx + BTS + MSC stabilisation
(
    sleep 12  # Augmenté : attendre fake_trx, BTS, BSC, MSC complètement prêts
    echo -e "${CYAN}[osmo-asterisk]${NC} Démarrage Asterisk (SIP inter-op)..." >&2
    asterisk -f -c 2>&1 | tee "${LOG_DIR}/asterisk.log"
) &

echo -e "  ${GREEN}✓${NC} Asterisk SIP en background (démarrage différé 12s)"

# ══════════════════════════════════════════════════════════════════════════════
# 4. OsmoHLR — Home Location Register (réplique locale du HLR)
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[4/6] OsmoHLR (réplique locale 127.0.0.2)${NC}"

# Si mode bridge (inter_stp != 127.0.0.1), laisser le HLR centralisé,
# sinon lancer une réplique locale
if [ "$INTER_STP_IP" != "127.0.0.1" ]; then
    echo -e "  ${YELLOW}[*]${NC} Mode bridge détecté → HLR centralisé @ 127.0.0.2"
    # On attend juste que le HLR distant soit UP
    echo "  Vérification HLR centralisé..."
    timeout 30 bash -c \
        "until nc -zv 127.0.0.2 4238 2>/dev/null; do sleep 2; done" || true
else
    # Mode net-host : lancer HLR local
    tmux_exec "osmo-hlr" \
        "osmo-hlr -c /etc/osmocom/osmo-hlr.cfg 2>&1 | tee ${LOG_DIR}/osmo-hlr.log" \
        "Home Location Register"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. osmo-gapk — Audio (optionnel, GSM codec transcoding)
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[5/6] osmo-gapk (audio GSM↔ALSA)${NC}"

if [ -f /etc/osmocom/gapk-alsa.sh ]; then
    (
        sleep 8  # Attendre MSC + Asterisk
        bash /etc/osmocom/gapk-alsa.sh 2>&1 | tee "${LOG_DIR}/gapk-alsa.log"
    ) &
    echo -e "  ${GREEN}✓${NC} gapk-alsa en background"
else
    echo -e "  ${YELLOW}[*]${NC} gapk-alsa.sh non trouvé (mode sans audio)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. Relais SMS inter-opérateurs (optionnel)
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}[6/6] Relais SMS (inter-opérateurs)${NC}"

if [ -f /etc/osmocom/sms-routing.conf ]; then
    (
        sleep 10
        python3 /root/sms-relay.py \
            --config /etc/osmocom/sms-routing.conf \
            --msc-port 2775 \
            2>&1 | tee "${LOG_DIR}/sms-relay.log"
    ) &
    echo -e "  ${GREEN}✓${NC} sms-relay.py en background"
else
    echo -e "  ${YELLOW}[*]${NC} sms-routing.conf absent (SMS basique uniquement)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Attente & Status
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Session tmux : ${MAGENTA}${tmux_session}${NC}${BOLD}${NC}"
echo -e "  Accès  : ${CYAN}tmux attach -t ${tmux_session}${NC}"
echo -e "  Select : ${CYAN}tmux select-window -t ${tmux_session}:N${NC}"
echo -e "  Status : ${CYAN}tmux list-windows -t ${tmux_session}${NC}"
echo ""

sleep 2

echo -e "${CYAN}─ Status VTY ─${NC}"
for service in BTS BSC MSC HLR; do
    case "$service" in
        BTS) port=4241 ;;
        BSC) port=4242 ;;
        MSC) port=4254 ;;
        HLR) port=4258 ;;
    esac
    if timeout 2 bash -c "echo 'help' | nc 127.0.0.1 $port &>/dev/null"; then
        echo -e "  ${GREEN}✓${NC} ${service} @ 127.0.0.1:$port"
    else
        echo -e "  ${YELLOW}○${NC} ${service} @ 127.0.0.1:$port (démarrage...)"
    fi
done

echo ""
echo -e "${BOLD}Logs${NC} → ${LOG_DIR}/"
ls -lh "${LOG_DIR}"/*.log 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || true

# ══════════════════════════════════════════════════════════════════════════════
# Boucle monitoring
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}[✓] Orchestration complète — Op${OPERATOR_ID} prêt${NC}"
echo ""
echo "Commandes útiles :"
echo "  sudo docker exec -it osmo-operator-${OPERATOR_ID} tmux attach -t ${tmux_session}"
echo ""

# Rester actif
while true; do
    sleep 60
    # Monitoring léger : vérifier que les processus principaux tournent
    if ! pgrep -f "osmo-bts-trx" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} osmo-bts-trx ne répond pas — redémarrage..." >&2
    fi
    if ! pgrep -f "osmo-bsc" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} osmo-bsc ne répond pas — redémarrage..." >&2
    fi
done
