#!/bin/bash
# send-mt-sms.sh — Envoi de SMS MT (réseau → mobile) via proto-smsc-sendmt
#
# Usage :
#   ./send-mt-sms.sh <imsi_destinataire> <texte_message> [from_number]
#
# Exemples :
#   # Envoi simple (IMSI complet)
#   ./send-mt-sms.sh 001010000000001 "Bonjour depuis Op1!"
#
#   # Avec numéro expéditeur personnalisé
#   ./send-mt-sms.sh 001010000000001 "Test SMS" 33601000001
#
#   # IMSI raccourci FreeCalypso (001-01 préfixe, id 1)
#   ./send-mt-sms.sh 00101-001 "Hello!"
#
# Prérequis dans le container :
#   - sms-encode-text  (sms-coding-utils)
#   - gen-sms-deliver-pdu (sms-coding-utils)
#   - proto-smsc-sendmt (gsup-smsc-proto)
#   - proto-smsc-daemon en cours d'exécution

set -euo pipefail

OPERATOR_ID="${OPERATOR_ID:-1}"
# SC-address fictif unique par opérateur (range réservé NANP)
SC_ADDRESS="1999001${OPERATOR_ID}444"
SENDMT_SOCKET="/tmp/sendmt_socket"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

if [ $# -lt 2 ]; then
    echo "Usage: $0 <imsi_dest> <message> [from_number]"
    echo ""
    echo "  imsi_dest   : IMSI du destinataire (15 chiffres ou notation FreeCalypso)"
    echo "  message     : Texte du SMS (entre guillemets)"
    echo "  from_number : Numéro expéditeur affiché (défaut: SC_ADDRESS)"
    echo ""
    echo "Exemples :"
    echo "  $0 001010000000001 'Bonjour!'"
    echo "  $0 00101-001 'Test' 33601000001"
    exit 1
fi

DEST_IMSI="$1"
MESSAGE="$2"
FROM_NUMBER="${3:-${SC_ADDRESS}}"

# Vérification du socket
if [ ! -S "$SENDMT_SOCKET" ]; then
    echo -e "${RED}[ERREUR] Socket $SENDMT_SOCKET introuvable.${NC}"
    echo "Le proto-smsc-daemon est-il en cours d'exécution ?"
    echo "  Vérifier : ps aux | grep proto-smsc-daemon"
    exit 1
fi

echo -e "${GREEN}[MT-SMS] Envoi${NC}"
echo -e "  De      : ${CYAN}${FROM_NUMBER}${NC}"
echo -e "  Vers    : ${CYAN}${DEST_IMSI}${NC}"
echo -e "  SC-Addr : ${CYAN}${SC_ADDRESS}${NC}"
echo -e "  Message : ${CYAN}${MESSAGE}${NC}"

# Pipeline : encode texte → génère TPDU SMS-DELIVER → envoi via GSUP
sms-encode-text "$MESSAGE" \
    | gen-sms-deliver-pdu "$FROM_NUMBER" \
    | proto-smsc-sendmt "$SC_ADDRESS" "$DEST_IMSI" "$SENDMT_SOCKET"

RC=$?
if [ $RC -eq 0 ]; then
    echo -e "${GREEN}[MT-SMS] ✓ Message envoyé${NC}"
else
    echo -e "${RED}[MT-SMS] ✗ Échec (code $RC)${NC}"
fi
exit $RC
