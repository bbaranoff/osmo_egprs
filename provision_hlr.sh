#!/bin/bash
# provision_hlr.sh — Provisionnement HLR abonnés OsmocomBB
#
# Usage :
#   sudo ./provision_hlr.sh                     # 2 opérateurs, MCC/MNC par défaut
#   sudo ./provision_hlr.sh 3                   # 3 opérateurs
#   sudo ./provision_hlr.sh 2 001 01 001 02     # MCC/MNC explicites par opérateur
#
# Valeurs cohérentes avec mobile.cfg.template et start.sh :
#   IMSI       = MCC(3) + MNC(2) + MSIN(10 digits = op_id zero-padded)
#   KI         = 00112233445566778899aabbccdd<op_id_hex>ff
#   MSISDN     = op_id * 10000 + 1  (10001, 20001…)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

N_OPERATORS=${1:-2}

# ── Attente + envoi commandes VTY HLR ────────────────────────────────────────
provision_hlr_subscriber() {
    local container=$1 imsi=$2 ki_nospace=$3 msisdn=$4

    echo -ne "  ${CYAN}[HLR] Attente OsmoHLR"
    local retries=30
    local hlr_ready=0
    while [ $retries -gt 0 ]; do
        if docker exec "$container" sh -c \
            'printf "show subscriber all\n" | telnet 127.0.0.1 4258 2>/dev/null' \
            2>/dev/null | grep -qE "OsmoHLR[>#]"; then
            hlr_ready=1
            break
        fi
        echo -n "."
        sleep 1
        retries=$(( retries - 1 ))
    done

    if [ $hlr_ready -eq 1 ]; then
        echo -e " ${GREEN}✓${NC}"
    else
        echo -e " ${YELLOW}timeout — provisionnement quand même${NC}"
    fi

    local vty_cmds
    vty_cmds=$(printf \
        "enable\nsubscriber imsi %s create\nsubscriber imsi %s update aud2g comp128 ki %s\nsubscriber imsi %s update msisdn %s\nshow subscriber imsi %s\n" \
        "$imsi" "$imsi" "$ki_nospace" "$imsi" "$msisdn" "$imsi")

    local result
    result=$(echo "$vty_cmds" | docker exec -i "$container" \
        sh -c 'sleep 0.5; cat | telnet 127.0.0.1 4258 2>/dev/null' \
        | grep -v "^Trying\|^Connected\|^Escape\|Welcome\|Copyright\|License\|free\|Free\|NO WARRANTY")

    if echo "$result" | grep -q "$imsi"; then
        echo -e "  ${GREEN}✓ HLR : IMSI ${imsi} → MSISDN ${msisdn}${NC}"
    else
        echo -e "  ${YELLOW}⚠ HLR : réponse inattendue pour ${imsi}${NC}"
        echo "$result" | sed 's/^/    /'
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║          OsmoHLR — Provisionnement abonnés          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

for op_id in $(seq 1 "$N_OPERATORS"); do
    mcc_arg=$(( (op_id - 1) * 2 + 2 ))
    mnc_arg=$(( (op_id - 1) * 2 + 3 ))
    mcc="${!mcc_arg:-001}"
    mnc="${!mnc_arg:-$(printf '%02d' ${op_id})}"
    container="osmo-operator-${op_id}"

    echo -e "${BOLD}── Opérateur ${op_id} (${container}) MCC=${mcc} MNC=${mnc} ──${NC}"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        echo -e "  ${RED}✗ Container '${container}' non démarré — skip${NC}"
        echo ""
        continue
    fi

    imsi="${mcc}${mnc}$(printf '%010d' ${op_id})"
    ki_nospace="00112233445566778899aabbccdd$(printf '%02x' ${op_id})ff"
    msisdn="${op_id}0001"

    echo -e "  IMSI   : ${CYAN}${imsi}${NC}"
    echo -e "  KI     : ${CYAN}${ki_nospace}${NC}"
    echo -e "  MSISDN : ${CYAN}${msisdn}${NC}"

    provision_hlr_subscriber "$container" "$imsi" "$ki_nospace" "$msisdn"
    echo ""
done

echo -e "${GREEN}${BOLD}Done.${NC}"
