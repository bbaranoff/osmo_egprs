#!/bin/bash
# smsc-start.sh — Lance le proto-smsc-daemon pour l'opérateur courant
#
# Le daemon se connecte au HLR local (127.0.0.2:4222) en tant que SMSC-OP<N>
# et :
#   - Reçoit les MO SMS (mobile → SMSC) → log dans /var/log/osmocom/mo-sms.log
#   - Expose un socket UNIX pour l'injection de MT SMS via proto-smsc-sendmt
#
# Usage : ./smsc-start.sh  (utilise $OPERATOR_ID de l'environnement)
#
# Dépendances dans le container :
#   - proto-smsc-daemon (compilé depuis gsup-smsc-proto)
#   - OsmoHLR avec : smsc entity SMSC-OP<N> / smsc default-route SMSC-OP<N>
#   - OsmoMSC avec : sms-over-gsup

set -euo pipefail

OPERATOR_ID="${OPERATOR_ID:-1}"
HLR_IP="${HLR_IP:-127.0.0.2}"
SMSC_IPA_NAME="SMSC-OP${OPERATOR_ID}"
MO_LOG="/var/log/osmocom/mo-sms-op${OPERATOR_ID}.log"
SENDMT_SOCKET="/tmp/sendmt_socket"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}[SMSC] Démarrage proto-smsc-daemon${NC}"
echo -e "  HLR        : ${CYAN}${HLR_IP}${NC}"
echo -e "  IPA name   : ${CYAN}${SMSC_IPA_NAME}${NC}"
echo -e "  MO SMS log : ${CYAN}${MO_LOG}${NC}"
echo -e "  MT socket  : ${CYAN}${SENDMT_SOCKET}${NC}"

# Nettoyage socket précédent
rm -f "$SENDMT_SOCKET"

# Attente que le HLR soit prêt (port GSUP 4222)
echo -ne "${GREEN}[SMSC] Attente OsmoHLR GSUP"
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

if [ $retries -eq 0 ]; then
    echo -e " ${NC}timeout — lancement quand même"
fi

# Petit délai pour laisser le HLR finir son init
sleep 2

# Lancement du daemon
# Arguments : <hlr_ip> <ipa_name> <mo_log_file> <sendmt_socket_path>
exec proto-smsc-daemon "$HLR_IP" "$SMSC_IPA_NAME" "$MO_LOG" "$SENDMT_SOCKET"
