#!/bin/bash
# op-summary.sh — Affiche un résumé des caractéristiques principales de chaque opérateur
#
# Utilise les données du vty-debug-dump pour extraire les informations clés
#
# Usage :
#   sudo ./op-summary.sh [--dump /chemin/vers/dump.txt] [--live]

set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
DUMP_FILE=""
LIVE_MODE=0

for arg in "$@"; do
    case "$arg in
        --dump=*) DUMP_FILE="${arg#*=}" ;;
        --live)   LIVE_MODE=1 ;;
        --help|-h)
            echo "Usage: $0 [--dump=/chemin/dump.txt] [--live]"
            echo "  --dump : Utilise un fichier de dump existant"
            echo "  --live : Génère un dump live avant l'analyse"
            exit 0
            ;;
    esac
done

# ── Helper d'affichage ────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo -e "$(printf '─%.0s' {1..70})"
}

print_row() {
    printf "  %-20s : %s\n" "$1" "$2"
}

print_section() {
    echo -e "\n  ${CYAN}${BOLD}$1${NC}"
}

# ── Extraction de données depuis le dump ──────────────────────────────────────
extract_value() {
    local container="$1"
    local pattern="$2"
    local default="${3:-?}"
    
    grep -A20 "\[.*\] port=.* container=${container}" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | head -1 \
        | sed -E 's/^[[:space:]]+//' \
        || echo "$default"
}

extract_count() {
    local container="$1"
    local section="$2"
    local pattern="$3"
    
    grep -A50 "\[.*\] port=.* container=${container}.*$section" "$DUMP_FILE" \
        | grep -E "$pattern" \
        | wc -l \
        | tr -d ' '
}

extract_subscriber_count() {
    local container="$1"
    local count
    
    count=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1)
    
    echo "${count:-0}"
}

extract_bts_info() {
    local container="$1"
    local bts_id="$2"
    
    local bts_block
    bts_block=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -A20 "bts ${bts_id}" \
        | sed -n '/bts [0-9]/,/^$/p')
    
    local oper=$(echo "$bts_block" | grep -c "Oper 'Enabled'" || true)
    local avail=$(echo "$bts_block" | grep -c "Avail 'OK'" || true)
    local oml=$(echo "$bts_block" | grep -c "OML Link state: connected" || true)
    local rsl=$(echo "$bts_block" | grep -c "RSL State: connected" || true)
    
    if [ "$oper" -gt 0 ] && [ "$avail" -gt 0 ]; then
        echo "OK"
    elif [ "$oper" -gt 0 ]; then
        echo "Enabled"
    else
        echo "Down"
    fi
    
    # Retourne aussi OML/RSL pour info
    [ "$oml" -gt 0 ] && OML_OK=1 || OML_OK=0
    [ "$rsl" -gt 0 ] && RSL_OK=1 || RSL_OK=0
}

extract_asp_state() {
    local container="$1"
    local component="$2"  # STP, MSC, BSC
    
    local asp_block
    if [ "$component" = "STP" ]; then
        asp_block=$(grep -A30 "\[OsmoSTP\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}")
    elif [ "$component" = "MSC" ]; then
        asp_block=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}")
    elif [ "$component" = "BSC" ]; then
        asp_block=$(grep -A30 "\[OsmoBSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}")
    fi
    
    echo "$asp_block" | grep -c "ASP_ACTIVE" || true
}

# ── Génération d'un dump live si demandé ──────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ]; then
    echo -e "${CYAN}Génération d'un dump live...${NC}"
    TEMP_DUMP="/tmp/vty-live-$$.txt"
    ./vty-debug-dump.sh --out "$TEMP_DUMP" > /dev/null
    DUMP_FILE="$TEMP_DUMP"
    echo -e "${GREEN}✓ Dump généré : $DUMP_FILE${NC}"
fi

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo -e "${RED}Erreur : fichier de dump non spécifié ou introuvable${NC}"
    echo "Utilisez --dump=/chemin/vers/dump.txt ou --live pour générer un dump"
    exit 1
fi

# ── Détection des containers dans le dump ─────────────────────────────────────
mapfile -t CONTAINERS < <(
    grep -E "container=osmo-operator-[0-9]+" "$DUMP_FILE" \
        | sed -E 's/.*container=([^ ]+).*/\1/' \
        | sort -u
)

INTER_STP=$(grep -E "container=osmo-inter-stp" "$DUMP_FILE" \
    | sed -E 's/.*container=([^ ]+).*/\1/' \
    | head -1 || true)

N_OPS=${#CONTAINERS[@]}

# ── En-tête ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Résumé Opérateurs — $(date '+%Y-%m-%d %H:%M')              ║${NC}"
echo -e "${CYAN}║     ${N_OPS} opérateur(s) trouvé(s)                             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ -n "$INTER_STP" ]; then
    print_header "INTER-STP HUB (${INTER_STP})"
    
    asp_count=$(extract_asp_state "$INTER_STP" "STP")
    print_row "ASP actifs" "$asp_count"
    
    # Routes
    routes=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l)
    print_row "Routes configurées" "$routes"
    
    # AS
    as_count=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -c "AS_ACTIVE" || true)
    print_row "AS actifs" "$as_count"
fi

# ── Boucle sur les opérateurs ─────────────────────────────────────────────────
for container in "${CONTAINERS[@]}"; do
    op_id=$(echo "$container" | grep -oE '[0-9]+$')
    
    print_header "OPÉRATEUR ${op_id} (${container})"
    
    # ── STP local ────────────────────────────────────────────────────────
    print_section "SS7"
    
    # ASP actifs dans STP
    stp_asp=$(extract_asp_state "$container" "STP")
    print_row "ASP actifs (STP)" "$stp_asp"
    
    # Routes
    routes=$(grep -A50 "\[OsmoSTP\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l)
    print_row "Routes configurées" "$routes"
    
    # ── MSC ───────────────────────────────────────────────────────────────
    print_section "MSC"
    
    msc_asp=$(extract_asp_state "$container" "MSC")
    print_row "ASP actif" "$([ "$msc_asp" -gt 0 ] && echo "✓" || echo "✗")"
    
    # Subscribers VLR
    vlr_count=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A20 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1)
    print_row "Subscribers VLR" "${vlr_count:-0}"
    
    # Transactions
    trans=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "transaction" || true)
    print_row "Transactions" "$trans"
    
    # ── BSC ───────────────────────────────────────────────────────────────
    print_section "BSC"
    
    bsc_asp=$(extract_asp_state "$container" "BSC")
    print_row "ASP actif" "$([ "$bsc_asp" -gt 0 ] && echo "✓" || echo "✗")"
    
    # BTS 0 état
    OML_OK=0
    RSL_OK=0
    bts_state=$(extract_bts_info "$container" 0)
    print_row "BTS 0 état" "$bts_state"
    print_row "  ├─ OML" "$([ "$OML_OK" -eq 1 ] && echo "✓ connecté" || echo "✗ déconnecté")"
    print_row "  └─ RSL" "$([ "$RSL_OK" -eq 1 ] && echo "✓ connecté" || echo "✗ déconnecté")"
    
    # Nombre de BTS total
    n_bts=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -c "^ bts [0-9]" || true)
    print_row "BTS totales" "$n_bts"
    
    # ── HLR ───────────────────────────────────────────────────────────────
    print_section "HLR"
    
    subs_count=$(extract_subscriber_count "$container")
    print_row "Abonnés" "$subs_count"
    
    # Connexions GSUP
    gsup=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "GSUP" || true)
    print_row "Connexions GSUP" "$gsup"
    
    # ── BTS (si disponible) ───────────────────────────────────────────────
    print_section "BTS (phy)"
    
    # LCHAN actifs
    lchan=$(grep -A30 "\[OsmoBTS\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "lchan" || true)
    print_row "LCHAN" "$lchan"
    
    # ── SGSN/GGSN (si GPRS actif) ─────────────────────────────────────────
    print_section "GPRS"
    
    # NS entities
    ns=$(grep -A30 "\[OsmoSGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "NS entity" || true)
    print_row "NS entities" "$ns"
    
    # PDP contexts
    pdp=$(grep -A30 "\[OsmoGGSN\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "PDP context" || true)
    print_row "PDP contexts" "$pdp"
    
    # ── Services auxiliaires ─────────────────────────────────────────────
    print_section "Services"
    
    # SIP connector
    sip_logs=$(grep -A10 "\[OsmoSIPconn\]" "$DUMP_FILE" \
        | grep -c "container=${container}" || true)
    print_row "SIP connector" "$([ "$sip_logs" -gt 0 ] && echo "✓ actif" || echo "?")"
    
    # SMS relay port
    sms=$(grep -A10 "\[.*\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -c "port 7890" || true)
    print_row "SMS relay" "$([ "$sms" -gt 0 ] && echo "✓ actif" || echo "?")"
    
    # ── Statistiques rapides ─────────────────────────────────────────────
    print_section "Statistiques"
    
    # Appels actifs
    calls=$(grep -A20 "\[OsmoMSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "call-leg" || true)
    print_row "Appels actifs" "$calls"
    
    # Paging
    paging=$(grep -A20 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A10 "container=${container}" \
        | grep -c "paging" || true)
    print_row "Paging actifs" "$paging"
    
done

# ── Nettoyage ─────────────────────────────────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ] && [ -n "$TEMP_DUMP" ]; then
    rm -f "$TEMP_DUMP"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Analyse terminée — Dump utilisé : ${DUMP_FILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
