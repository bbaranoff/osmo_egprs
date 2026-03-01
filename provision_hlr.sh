#!/bin/bash
# provision_hlr.sh — Provisionnement HLR abonnés pour N opérateurs
#
# Crée un abonné OsmocomBB de test par opérateur dans chaque HLR.
# Les valeurs sont cohérentes avec mobile.cfg.template et start.sh.
#
# Convention :
#   IMSI   = MCC(3) + MNC(2) + MSIN(10)   ex: 001010000000001
#   KI     = 00112233445566778899aabbccdd<op_hex>ff
#   MSISDN = op_id * 10000 + 1             ex: 10001, 20001, 30001…
#
# Usage :
#   sudo ./provision_hlr.sh              # 2 opérateurs
#   sudo ./provision_hlr.sh 3            # 3 opérateurs
#   sudo ./provision_hlr.sh 3 001 01 001 02 001 03   # MCC/MNC explicites

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

N_OPERATORS=${1:-2}
shift 2>/dev/null || true   # Retirer $1 pour accéder aux MCC/MNC positionnels

# ── Provisionnement VTY HLR ───────────────────────────────────────────────────
provision_hlr_subscriber() {
    local container=$1 imsi=$2 ki_nospace=$3 msisdn=$4

    echo -ne "  ${CYAN}[HLR] Connexion VTY"
    local retries=30 hlr_ready=0
    while [ $retries -gt 0 ]; do
        if docker exec "$container" sh -c \
            'printf "show subscriber all\n" | telnet 127.0.0.1 4258 2>/dev/null' \
            2>/dev/null | grep -qE "OsmoHLR[>#]"; then
            hlr_ready=1; break
        fi
        echo -n "."; sleep 1; retries=$(( retries - 1 ))
    done
    [ $hlr_ready -eq 1 ] && echo -e " ${GREEN}✓${NC}" || echo -e " ${YELLOW}timeout${NC}"

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

# Récupérer MCC/MNC depuis les arguments positionnels restants
# Format attendu : MCC1 MNC1 MCC2 MNC2 … MCCn MNCn
declare -a ARG_MCC ARG_MNC
idx=0
while [ $# -ge 2 ]; do
    ARG_MCC[$idx]=$1; ARG_MNC[$idx]=$2
    shift 2; idx=$(( idx + 1 ))
done

for op_id in $(seq 1 "$N_OPERATORS"); do
    arr_idx=$(( op_id - 1 ))
    mcc="${ARG_MCC[$arr_idx]:-001}"
    mnc="${ARG_MNC[$arr_idx]:-$(printf '%02d' "${op_id}")}"
    container="osmo-operator-${op_id}"

    echo -e "${BOLD}── Opérateur ${op_id} (${container})  MCC=${mcc} MNC=${mnc} ──${NC}"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        echo -e "  ${RED}✗ Container '${container}' non démarré — skip${NC}"; echo ""; continue
    fi

    imsi="${mcc}${mnc}$(printf '%010d' "${op_id}")"
    ki_nospace="00112233445566778899aabbccdd$(printf '%02x' "${op_id}")ff"
    msisdn="${op_id}0001"

    echo -e "  IMSI   : ${CYAN}${imsi}${NC}"
    echo -e "  KI     : ${CYAN}${ki_nospace}${NC}"
    echo -e "  MSISDN : ${CYAN}${msisdn}${NC}"

    provision_hlr_subscriber "$container" "$imsi" "$ki_nospace" "$msisdn"
    echo ""
done

echo -e "${GREEN}${BOLD}Done.${NC}"
