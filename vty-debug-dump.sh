#!/bin/bash
# vty-debug-dump.sh
#
# Parcourt tous les VTY Osmocom de chaque container osmo-operator-N
# ET du container osmo-inter-stp, active le niveau de log DEBUG,
# exécute les commandes "show" pertinentes, et consolide dans un log.
#
# VTY couverts par container opérateur :
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
# VTY du container osmo-inter-stp :
#   OsmoSTP (hub)    4239
#
# Usage :
#   sudo ./vty-debug-dump.sh [--out /chemin/log.txt]

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

OUTFILE="${OUTFILE:-/tmp/vty-debug-dump.txt}"
[[ "${1:-}" == "--out" && -n "${2:-}" ]] && OUTFILE="$2"

INTER_STP_CONTAINER="osmo-inter-stp"

# ── Tables VTY : deux jeux (opérateur / inter-stp) ───────────────────────────
declare -A OP_VTY_NAME OP_VTY_SHOW
declare -A ISTP_VTY_NAME ISTP_VTY_SHOW

register_op_vty() {
    local port="$1" name="$2" show_cmds="$3"
    OP_VTY_NAME[$port]="$name"
    OP_VTY_SHOW[$port]="$show_cmds"
}

register_istp_vty() {
    local port="$1" name="$2" show_cmds="$3"
    ISTP_VTY_NAME[$port]="$name"
    ISTP_VTY_SHOW[$port]="$show_cmds"
}

# ── Commandes show opérateur — enrichies ──────────────────────────────────────

register_op_vty 4239 "OsmoSTP" "\
show cs7 instance 0 users|\
show cs7 instance 0 as all|\
show cs7 instance 0 asp|\
show cs7 instance 0 route|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show cs7 instance 0 sccp timers|\
show logging level|\
show talloc-context all brief"

register_op_vty 4258 "OsmoHLR" "\
show subscriber all|\
show subscriber count|\
show gsup-connections|\
show logging level|\
show talloc-context all brief"

register_op_vty 4243 "OsmoMGW" "\
show mgcp stats|\
show mgcp active|\
show mgcp endpoint Name trunk-0|\
show logging level|\
show talloc-context all brief"

register_op_vty 4254 "OsmoMSC" "\
show network|\
show subscriber all|\
show subscriber count|\
show transaction all|\
show call-legs|\
show connection|\
show sgs-connections|\
show cs7 instance 0 users|\
show cs7 instance 0 asp|\
show cs7 instance 0 as all|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4242 "OsmoBSC" "\
show network|\
show bts all|\
show bts 0|\
show trx 0 0|\
show timeslot all|\
show lchan all|\
show lchan summary|\
show paging all|\
show paging-group all|\
show conns|\
show cs7 instance 0 users|\
show cs7 instance 0 asp|\
show cs7 instance 0 as all|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4241 "OsmoBTS" "\
show bts 0|\
show trx 0 0|\
show ts all|\
show lchan all|\
show lchan summary|\
show phy 0 inst all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4240 "OsmoPCU" "\
show bts all|\
show tbf all|\
show ms all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4245 "OsmoSGSN" "\
show sgsn|\
show mm-context all|\
show pdp-context all|\
show subscriber cache|\
show ns|\
show ns stats|\
show ns entities|\
show bssgp|\
show logging level|\
show stats|\
show talloc-context all brief"

register_op_vty 4260 "OsmoGGSN" "\
show ggsn|\
show pdp-context all|\
show apn all|\
show logging level|\
show talloc-context all brief"

register_op_vty 4255 "OsmoSIPconn" "\
show logging level|\
show talloc-context all brief"

OP_VTY_PORTS=(4239 4258 4243 4254 4242 4241 4240 4245 4260 4255)

# ── Commandes show inter-STP — balayage instances 0..9 ────────────────────────
# L'inter-STP hub peut avoir N instances CS7 (une par lien opérateur).

ISTP_SHOW_CMDS="show cs7 instance 0 users|\
show cs7 instance 0 as all|\
show cs7 instance 0 as all active|\
show cs7 instance 0 asp|\
show cs7 instance 0 route|\
show cs7 instance 0 sccp users|\
show cs7 instance 0 sccp connections|\
show cs7 instance 0 sccp timers|\
show cs7 instance 1 users|\
show cs7 instance 1 as all|\
show cs7 instance 1 asp|\
show cs7 instance 1 route|\
show cs7 instance 1 sccp users|\
show cs7 instance 1 sccp connections|\
show cs7 instance 2 users|\
show cs7 instance 2 as all|\
show cs7 instance 2 asp|\
show cs7 instance 2 route|\
show cs7 instance 2 sccp users|\
show cs7 instance 2 sccp connections|\
show cs7 instance 3 users|\
show cs7 instance 3 as all|\
show cs7 instance 3 asp|\
show cs7 instance 3 route|\
show cs7 instance 4 as all|\
show cs7 instance 4 asp|\
show cs7 instance 4 route|\
show cs7 instance 5 as all|\
show cs7 instance 5 asp|\
show cs7 instance 5 route|\
show cs7 instance 6 as all|\
show cs7 instance 6 asp|\
show cs7 instance 6 route|\
show cs7 instance 7 as all|\
show cs7 instance 7 asp|\
show cs7 instance 7 route|\
show cs7 instance 8 as all|\
show cs7 instance 8 asp|\
show cs7 instance 8 route|\
show cs7 instance 9 as all|\
show cs7 instance 9 asp|\
show cs7 instance 9 route|\
show logging level|\
show stats|\
show talloc-context all brief"

register_istp_vty 4239 "OsmoSTP-hub" "$ISTP_SHOW_CMDS"

ISTP_VTY_PORTS=(4239)

# ── Détection des containers ──────────────────────────────────────────────────
mapfile -t OP_CONTAINERS < <(
    docker ps --format '{{.Names}}' \
        | grep -E '^osmo-operator-[0-9]+$' \
        | sort -t '-' -k 3 -n
)

HAS_INTER_STP=0
if docker ps --format '{{.Names}}' | grep -qx "$INTER_STP_CONTAINER"; then
    HAS_INTER_STP=1
fi

if [ ${#OP_CONTAINERS[@]} -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ]; then
    echo -e "${RED}Aucun container osmo-operator-N ni ${INTER_STP_CONTAINER} trouvé.${NC}"
    echo -e "  Containers actifs : $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
    exit 1
fi

N_OPS=${#OP_CONTAINERS[@]}
echo -e "${GREEN}=== VTY Debug Dump — ${N_OPS} opérateur(s) + inter-stp=${HAS_INTER_STP} → ${OUTFILE} ===${NC}"
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
log "Opérateurs : ${N_OPS}   Containers : ${OP_CONTAINERS[*]:-aucun}"
log "Inter-STP  : $([ "$HAS_INTER_STP" -eq 1 ] && echo 'présent' || echo 'absent')"

# ── Interroger un VTY dans un container ──────────────────────────────────────
# $1=container  $2=port  $3=nom  $4=show_commands
query_vty() {
    local container="$1"
    local port="$2"
    local name="$3"
    local show_str="$4"

    # Test de connectivité rapide
    if ! docker exec "$container" bash -c \
            "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        echo -e "  ${YELLOW}[SKIP]${NC} ${name} (port ${port}) — non disponible"
        log "  [SKIP] ${name} port ${port} — non disponible"
        return 1
    fi

    echo -ne "  ${CYAN}${name}${NC} (${port}) … "

    # Construire le script VTY
    local vty_script
    vty_script="$(printf 'enable\nlogging level all debug\nlogging filter all 1\n')"
    IFS='|' read -ra SHOW_CMDS <<< "$show_str"
    for cmd in "${SHOW_CMDS[@]}"; do
        vty_script+="${cmd}"$'\n'
    done
    vty_script+=$'end\n'

    # Envoyer via nc ou telnet — sleep augmenté pour gros jeux de commandes
    local raw_output
    raw_output=$(docker exec "$container" bash -c "
        VTY_SCRIPT=\$(cat << 'VTYEOF'
${vty_script}
VTYEOF
)
        if command -v nc >/dev/null 2>&1; then
            ( sleep 0.5; printf '%s' \"\$VTY_SCRIPT\"; sleep 2 ) \
                | nc -q2 127.0.0.1 ${port} 2>/dev/null || true
        else
            ( sleep 0.5; printf '%s' \"\$VTY_SCRIPT\"; sleep 2.5 ) \
                | telnet 127.0.0.1 ${port} 2>/dev/null || true
        fi
    " 2>/dev/null || true)

    # Filtrer bannière/prompt VTY
    local clean_output
    clean_output=$(echo "$raw_output" \
        | grep -vE \
            "^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete|% Error|\
Connection closed)" \
        | sed 's/\r//' \
        | grep -v '^[[:space:]]*$' || true)

    local n_lines
    n_lines=$(echo "$clean_output" | wc -l)
    echo -e "${GREEN}${n_lines} lignes${NC}"

    {
        echo ""
        echo "  [${name}] port=${port}  container=${container}"
        echo "  Commandes show : $(echo "$show_str" | tr '|' ', ')"
        echo ""
        echo "$clean_output" | sed 's/^/    /'
    } >> "$OUTFILE"

    return 0
}

# ── Boucle principale : containers opérateur ──────────────────────────────────
TOTAL_OK=0
TOTAL_SKIP=0

for container in "${OP_CONTAINERS[@]}"; do
    logsep "Container : ${container}  —  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${container} ---${NC}"

    for port in "${OP_VTY_PORTS[@]}"; do
        logsubsep "${OP_VTY_NAME[$port]} (port ${port})"
        if query_vty "$container" "$port" \
                "${OP_VTY_NAME[$port]}" "${OP_VTY_SHOW[$port]}"; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
done

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ "$HAS_INTER_STP" -eq 1 ]; then
    logsep "Container : ${INTER_STP_CONTAINER} (hub SS7)  —  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${INTER_STP_CONTAINER} ---${NC}"

    for port in "${ISTP_VTY_PORTS[@]}"; do
        logsubsep "${ISTP_VTY_NAME[$port]} (port ${port})"
        if query_vty "$INTER_STP_CONTAINER" "$port" \
                "${ISTP_VTY_NAME[$port]}" "${ISTP_VTY_SHOW[$port]}"; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
else
    log ""
    log "  [INFO] Container ${INTER_STP_CONTAINER} absent — skipped"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
logsep "RÉSUMÉ — $(date '+%Y-%m-%d %H:%M:%S')"
log "  VTY interrogés        : ${TOTAL_OK}"
log "  VTY non disponibles   : ${TOTAL_SKIP}"
log "  Opérateurs            : ${N_OPS}"
log "  Inter-STP             : $([ "$HAS_INTER_STP" -eq 1 ] && echo 'oui' || echo 'non')"
log "  Fichier               : ${OUTFILE}"
log "  Taille                : $(wc -c < "$OUTFILE") octets  /  $(wc -l < "$OUTFILE") lignes"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Dump complet → ${OUTFILE}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Consulter :${NC}  less ${OUTFILE}"
echo -e "  ${CYAN}Filtrer   :${NC}  grep -A5 'OsmoBSC' ${OUTFILE}"
echo -e "  ${CYAN}SS7 hub   :${NC}  grep -A10 'OsmoSTP-hub' ${OUTFILE}"
echo -e "  ${CYAN}Routes    :${NC}  grep -A20 'show cs7.*route' ${OUTFILE}"
echo -e "  ${CYAN}ASP état  :${NC}  grep -iE 'asp|active|inactive|down' ${OUTFILE}"
echo -e "  ${CYAN}SCCP      :${NC}  grep -A10 'sccp' ${OUTFILE}"
echo -e "  ${CYAN}Erreurs   :${NC}  grep -iE 'error|fail|warn|prohib|timeout|refused' ${OUTFILE}"

# Copie locale si lancé depuis l'hôte
if [ -w "$(pwd)" ]; then
    cp "$OUTFILE" "$(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" 2>/dev/null && \
        echo -e "  ${CYAN}Copie locale :${NC} $(pwd)/vty-debug-dump-$(date '+%Y%m%d-%H%M%S').txt" || true
fi
