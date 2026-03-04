#!/bin/bash
# vty-debug-dump.sh
#
# Parcourt tous les VTY Osmocom de chaque container osmo-operator-N,
# active le niveau de log DEBUG sur chaque composant, exécute les
# commandes "show" pertinentes, et consolide le tout dans un log.txt.
#
# VTY couverts par container :
#   OsmoSTP          4239
#   OsmoHLR          4258
#   OsmoMGW          4243
#   OsmoMSC          4254
#   OsmoBSC          4242
#   OsmoBTS          4241
#   OsmoPCU          4240
#   OsmoSGSN         4245
#   OsmoGGSN         4260
#   OsmoSIP-conn     4255
#
# Usage :
#   sudo ./vty-debug-dump.sh [--out /chemin/log.txt]

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

OUTFILE="${OUTFILE:-/tmp/vty-debug-dump.txt}"
[[ "${1:-}" == "--out" && -n "${2:-}" ]] && OUTFILE="$2"

# ── Table des VTY : "nom:port:commandes_show" ─────────────────────────────────
# Les commandes show sont séparées par des pipes | (parsées plus bas).
# Chaque composant a ses commandes "show" les plus utiles en debug.
declare -A VTY_NAME VTY_SHOW
register_vty() {
    local port="$1" name="$2" show_cmds="$3"
    VTY_NAME[$port]="$name"
    VTY_SHOW[$port]="$show_cmds"
}

register_vty 4239 "OsmoSTP"      "show cs7 instance 0 users|show cs7 instance 0 as all|show cs7 instance 0 asp|show cs7 instance 0 route|show talloc-context all brief"
register_vty 4258 "OsmoHLR"      "show subscriber all|show talloc-context all brief"
register_vty 4243 "OsmoMGW"      "show mgcp stats|show talloc-context all brief"
register_vty 4254 "OsmoMSC"      "show network|show subscriber all|show transaction all|show call-legs|show cs7 instance 0 users|show talloc-context all brief"
register_vty 4242 "OsmoBSC"      "show network|show bts all|show paging all|show lchan all|show cs7 instance 0 users|show cs7 instance 0 asp|show talloc-context all brief"
register_vty 4241 "OsmoBTS"      "show bts 0|show trx 0 0|show ts all|show lchan all|show talloc-context all brief"
register_vty 4240 "OsmoPCU"      "show talloc-context all brief"
register_vty 4245 "OsmoSGSN"     "show sgsn|show pdp-context all|show talloc-context all brief"
register_vty 4260 "OsmoGGSN"     "show ggsn|show pdp-context all|show talloc-context all brief"
register_vty 4255 "OsmoSIPconn"  "show talloc-context all brief"

VTY_PORTS=(4239 4258 4243 4254 4242 4241 4240 4245 4260 4255)

# ── Détection des containers ──────────────────────────────────────────────────
mapfile -t OP_CONTAINERS < <(
    docker ps --format '{{.Names}}' \
        | grep -E '^osmo-operator-[0-9]+$' \
        | sort -t '-' -k 3 -n
)

if [ ${#OP_CONTAINERS[@]} -eq 0 ]; then
    echo -e "${RED}Aucun container osmo-operator-N trouvé.${NC}"
    echo -e "  Containers actifs : $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
    exit 1
fi

N_OPS=${#OP_CONTAINERS[@]}
echo -e "${GREEN}=== VTY Debug Dump — ${N_OPS} opérateur(s) → ${OUTFILE} ===${NC}"
echo ""

# ── Vider / initialiser le fichier de sortie ─────────────────────────────────
: > "$OUTFILE"
log() { echo -e "$*" | tee -a "$OUTFILE"; }
logsep() {
    local title="$1"
    log ""
    log "$(printf '═%.0s' {1..72})"
    log "  ${title}"
    log "$(printf '═%.0s' {1..72})"
}
logsubsep() {
    local title="$1"
    log ""
    log "  $(printf '─%.0s' {1..68})"
    log "  ${title}"
    log "  $(printf '─%.0s' {1..68})"
}

log "VTY DEBUG DUMP — $(date '+%Y-%m-%d %H:%M:%S')"
log "Opérateurs : ${N_OPS}   Containers : ${OP_CONTAINERS[*]}"

# ── Interroger un VTY dans un container ──────────────────────────────────────
# Séquence envoyée :
#   enable
#   logging level all debug
#   logging filter all 1
#   <commandes show>
#   end
query_vty() {
    local container="$1"
    local port="$2"
    local name="${VTY_NAME[$port]}"
    local show_str="${VTY_SHOW[$port]}"

    # Test de connectivité rapide
    if ! docker exec "$container" bash -c \
            "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        echo -e "  ${YELLOW}[SKIP]${NC} ${name} (port ${port}) — non disponible"
        log "  [SKIP] ${name} port ${port} — non disponible"
        return 0
    fi

    echo -ne "  ${CYAN}${name}${NC} (${port}) … "

    # Construire le script VTY
    local vty_script
    vty_script="$(printf 'enable\nlogging level all debug\nlogging filter all 1\n')"
    # Ajouter chaque commande show
    IFS='|' read -ra SHOW_CMDS <<< "$show_str"
    for cmd in "${SHOW_CMDS[@]}"; do
        vty_script+="${cmd}"$'\n'
    done
    vty_script+=$'end\n'

    # Envoyer via nc ou telnet
    local raw_output
    raw_output=$(docker exec "$container" bash -c "
        VTY_SCRIPT=\$(cat << 'VTYEOF'
${vty_script}
VTYEOF
)
        if command -v nc >/dev/null 2>&1; then
            ( sleep 0.5; printf '%s' \"\$VTY_SCRIPT\"; sleep 1 ) \
                | nc -q2 127.0.0.1 ${port} 2>/dev/null || true
        else
            ( sleep 0.5; printf '%s' \"\$VTY_SCRIPT\"; sleep 1.5 ) \
                | telnet 127.0.0.1 ${port} 2>/dev/null || true
        fi
    " 2>/dev/null || true)

    # Filtrer les lignes de bannière/prompt VTY
    local clean_output
    clean_output=$(echo "$raw_output" \
        | grep -vE \
            "^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete)" \
        | sed 's/\r//' \
        | grep -v '^[[:space:]]*$' || true)

    local n_lines
    n_lines=$(echo "$clean_output" | wc -l)
    echo -e "${GREEN}${n_lines} lignes${NC}"

    # Écrire dans le log
    {
        echo ""
        echo "  [${name}] port=${port}"
        echo "  Commandes show : $(echo "$show_str" | tr '|' ',')"
        echo ""
        echo "$clean_output" | sed 's/^/    /'
    } >> "$OUTFILE"
}

# ── Boucle principale ─────────────────────────────────────────────────────────
TOTAL_OK=0
TOTAL_SKIP=0

for container in "${OP_CONTAINERS[@]}"; do
    logsep "Container : ${container}  —  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${container} ---${NC}"

    for port in "${VTY_PORTS[@]}"; do
        logsubsep "${VTY_NAME[$port]} (port ${port})"
        query_vty "$container" "$port"
        # Compter disponibilité
        if docker exec "$container" bash -c \
                "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
done

# ── Résumé ────────────────────────────────────────────────────────────────────
logsep "RÉSUMÉ — $(date '+%Y-%m-%d %H:%M:%S')"
log "  VTY interrogés : ${TOTAL_OK}"
log "  VTY non disponibles : ${TOTAL_SKIP}"
log "  Fichier : ${OUTFILE}"
log "  Taille  : $(wc -c < "$OUTFILE") octets  /  $(wc -l < "$OUTFILE") lignes"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Dump complet → ${OUTFILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Consulter :${NC}  less ${OUTFILE}"
echo -e "  ${CYAN}Filtrer   :${NC}  grep -A5 'OsmoBSC' ${OUTFILE}"
echo -e "  ${CYAN}Erreurs   :${NC}  grep -i 'error\|fail\|warn' ${OUTFILE}"

# Copie locale si lancé depuis l'hôte
if [ -w "$(pwd)" ]; then
    cp "$OUTFILE" "$(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" 2>/dev/null && \
        echo -e "  ${CYAN}Copie locale :${NC} $(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" || true
fi
