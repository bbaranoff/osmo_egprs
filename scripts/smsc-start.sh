#!/bin/bash
# smsc-start.sh — Lance le proto-smsc-daemon + le relay interop
#
# 1. proto-smsc-daemon : connecté au HLR via GSUP
#    - MO SMS → log fichier
#    - MT SMS ← socket UNIX
#
# 2. sms-interop-relay.py : pont entre opérateurs
#    - Surveille le log MO, parse les TPDU
#    - Route vers l'opérateur cible via TCP (port 7890)
#    - Écoute en TCP pour les MT venant d'autres opérateurs
#    - Résout MSISDN→IMSI via HLR VTY, injecte les MT localement

set -euo pipefail

OPERATOR_ID="${OPERATOR_ID:-1}"
HLR_IP="${HLR_IP:-127.0.0.2}"
SMSC_IPA_NAME="SMSC-OP${OPERATOR_ID}"
MO_LOG="/var/log/osmocom/mo-sms-op${OPERATOR_ID}.log"
SENDMT_SOCKET="/tmp/sendmt_socket"
ROUTING_CONF="/etc/osmocom/sms-routing.conf"
RELAY_PORT="${RELAY_PORT:-7890}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  SMS Gateway — Opérateur ${OPERATOR_ID}                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  HLR        : ${CYAN}${HLR_IP}${NC}"
echo -e "  IPA name   : ${CYAN}${SMSC_IPA_NAME}${NC}"
echo -e "  MO log     : ${CYAN}${MO_LOG}${NC}"
echo -e "  MT socket  : ${CYAN}${SENDMT_SOCKET}${NC}"
echo -e "  Relay port : ${CYAN}${RELAY_PORT}${NC} (TCP interop)"
echo -e "  Routing    : ${CYAN}${ROUTING_CONF}${NC}"

# Nettoyage
rm -f "$SENDMT_SOCKET"
mkdir -p /var/log/osmocom

# Attente OsmoHLR GSUP (port 4222)
echo -ne "${YELLOW}[SMSC] Attente OsmoHLR GSUP"
retries=30
while [ $retries -gt 0 ]; do
    if ss -tln | grep -q ":4222 "; then
        echo -e " ✓${NC}"
        break
    fi
    echo -n "."
    sleep 1
    retries=$(( retries - 1 ))
done
[ $retries -eq 0 ] && echo -e " timeout${NC}"

sleep 2

# ── 1. proto-smsc-daemon (background) ────────────────────────────────────────
echo -e "${GREEN}[1/2] proto-smsc-daemon${NC}"
proto-smsc-daemon "$HLR_IP" "$SMSC_IPA_NAME" "$MO_LOG" "$SENDMT_SOCKET" &
DAEMON_PID=$!
echo -e "  PID: ${CYAN}${DAEMON_PID}${NC}"

sleep 2
[ -S "$SENDMT_SOCKET" ] && echo -e "  Socket: ${GREEN}✓${NC}" || echo -e "  Socket: ${YELLOW}attente...${NC}"

# ── 2. Relay interop (background) ────────────────────────────────────────────
echo -e "${GREEN}[2/2] sms-interop-relay${NC}"
python3 /etc/osmocom/sms-interop-relay.py \
    --config "$ROUTING_CONF" \
    --port "$RELAY_PORT" \
    --mo-log "$MO_LOG" \
    --operator-id "$OPERATOR_ID" &
RELAY_PID=$!
echo -e "  PID: ${CYAN}${RELAY_PID}${NC}"

echo -e ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SMS Gateway actif${NC}"
echo -e "${GREEN}  daemon=${DAEMON_PID}  relay=${RELAY_PID}${NC}"
echo -e "${GREEN}  MT local : send-mt-sms.sh <imsi> 'msg'${NC}"
echo -e "${GREEN}  MO log   : tail -f ${MO_LOG}${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}[SMSC] Arrêt...${NC}"
    kill $DAEMON_PID 2>/dev/null || true
    kill $RELAY_PID 2>/dev/null || true
    rm -f "$SENDMT_SOCKET"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Attendre fin d'un processus
wait -n $DAEMON_PID $RELAY_PID 2>/dev/null || true
echo -e "${YELLOW}[SMSC] Processus terminé, arrêt...${NC}"
cleanup
