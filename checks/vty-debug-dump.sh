#!/bin/bash
# vty-debug-dump.sh
#
# Parcourt tous les VTY Osmocom de chaque opérateur ET de l'inter-STP,
# active le niveau de log DEBUG, exécute les commandes "show" pertinentes,
# et consolide dans un log.
#
# DEUX MONDES, détection automatique (checks/_mode.sh) :
#   docker : un conteneur osmo-operator-N par opérateur, le hub SS7 est le
#            conteneur osmo-inter-stp ; on interroge les VTY par « docker exec ».
#   natif  : ISO, VM ou machine nue — un seul opérateur (sauf topologie netns),
#            les VTY sont en telnet sur 127.0.0.1. Ce qui n'existe que sous
#            docker (le conteneur inter-STP) est IGNORÉ EXPLICITEMENT : un dump
#            qui inventerait un hub absent se lirait comme une panne SS7.
#
# L'étiquette « container=osmo-operator-N » est écrite dans le dump DANS LES
# DEUX MODES : checks/operator_summary.sh y accroche toutes ses extractions
# (grep -A20 "container=..."). En natif c'est un nom d'affichage, une clé de
# corrélation, pas un objet interrogeable.
#
# VTY couverts par opérateur :
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
# VTY de l'inter-STP (hub SS7) :
#   OsmoSTP (hub)    4239
#
# Usage :
#   sudo ./vty-debug-dump.sh [--out /chemin/log.txt] [--docker|--native]

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Mémorisé AVANT le sourcing : la bibliothèque écrit dans OSMO_MODE (mémoïsation),
# on ne saurait plus après coup si la valeur venait de l'environnement.
MODE_ENV="${OSMO_MODE:-}"

# ── Bibliothèque commune docker/natif ─────────────────────────────────────────
# Chemin RELATIF au script (BASH_SOURCE) : le dépôt et l'ISO n'ont pas la même
# racine, et l'ISO embarque checks/ en entier — donc _mode.sh est toujours à
# côté de ce fichier, jamais à un chemin absolu du dépôt.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/osmo_egprs/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

# ── Options ───────────────────────────────────────────────────────────────────
# --out reste accepté À N'IMPORTE QUELLE POSITION : operator_summary.sh --live
# lance « ./vty-debug-dump.sh --out /tmp/vty-live-$$.txt » et doit continuer à
# marcher même précédé de --native.
OUTFILE="${OUTFILE:-/tmp/vty-debug-dump.txt}"
MODE_FORCED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ -n "${2:-}" ] || { echo "--out attend un chemin" >&2; exit 1; }
            OUTFILE="$2"; shift 2 ;;
        --out=*)
            OUTFILE="${1#*=}"; shift ;;
        --docker|--native|--mode=*)
            osmo_mode_force "$1" || { echo "mode inconnu : $1" >&2; exit 1; }
            MODE_FORCED=1; shift ;;
        -h|--help)
            echo "Usage : sudo ./vty-debug-dump.sh [--out /chemin/log.txt] [--docker|--native]"
            echo "  --docker  force le mode conteneurs (docker exec)"
            echo "  --native  force le mode natif (VTY locaux sur 127.0.0.1)"
            echo "  sans option : détection automatique"
            exit 0 ;;
        *)
            echo "option inconnue : $1" >&2
            echo "Usage : sudo ./vty-debug-dump.sh [--out /chemin/log.txt] [--docker|--native]" >&2
            exit 1 ;;
    esac
done

INTER_STP_CONTAINER="$(osmo_node hub)"   # « osmo-inter-stp » dans les deux mondes

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

# ── Inventaire des nœuds — docker ou natif ────────────────────────────────────
MODE="$(osmo_mode)"
# Un OSMO_MODE d'environnement qui ne vaut ni docker ni native est ignoré par la
# bibliothèque (elle redétecte) : on ne l'annonce donc pas comme un forçage.
if   [ "$MODE_FORCED" -eq 1 ]; then MODE_SRC="forcé par option"
elif [ "$MODE_ENV" = docker ] || [ "$MODE_ENV" = native ]; then MODE_SRC="forcé par OSMO_MODE"
else MODE_SRC="détection automatique"
fi

# osmo_ops : conteneurs osmo-operator-N en docker ; OSMO_OP_IDS / netns /
# N_OPERATORS (sinon 1) en natif. Déjà trié numériquement et dédoublonné, d'où
# la disparition du « sort -t - -k 3 -n ».
mapfile -t OPS < <(osmo_ops)
OP_CONTAINERS=()
for op in "${OPS[@]:-}"; do
    [ -n "$op" ] && OP_CONTAINERS+=("$(osmo_node "$op")")
done

# Inter-STP : présent SI on peut l'interroger D'ICI.
#   docker : le conteneur osmo-inter-stp tourne.
#   natif  : cette machine EST le hub (OSMO_ROLE=interstp, ou un osmo-stp lancé
#            sur osmo-stp-interop.cfg). Si le hub est une autre machine, son VTY
#            n'écoute que sur SON 127.0.0.1 : rien n'est dumpable d'ici, et on le
#            dit — un bloc « OsmoSTP-hub » vide serait lu comme un hub en panne.
HAS_INTER_STP=0
osmo_hub >/dev/null 2>&1 && HAS_INTER_STP=1

if [ ${#OP_CONTAINERS[@]} -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ]; then
    echo -e "${RED}Aucun container osmo-operator-N ni ${INTER_STP_CONTAINER} trouvé.${NC}"
    if [ "$MODE" = docker ]; then
        echo -e "  Containers actifs : $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
    else
        echo -e "  Mode natif : aucun opérateur déclaré (OSMO_OP_IDS, netns ${OSMO_NETNS_PREFIX}N, N_OPERATORS)."
    fi
    exit 1
fi

N_OPS=${#OP_CONTAINERS[@]}
# Le mode est annoncé AVANT tout le reste : un diagnostic qui ne dit pas dans
# quel monde il a regardé n'est pas exploitable.
echo -e "${CYAN}Mode : ${MODE} (${MODE_SRC})${NC}"
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
log "Mode       : ${MODE} (${MODE_SRC})"
log "Opérateurs : ${N_OPS}   Containers : ${OP_CONTAINERS[*]:-aucun}"
if   [ "$HAS_INTER_STP" -eq 1 ]; then log "Inter-STP  : présent"
elif [ "$MODE" = docker        ]; then log "Inter-STP  : absent"
else                                  log "Inter-STP  : ignoré (natif) — $(osmo_hub_hint)"
fi

# ── Interroger un VTY sur un nœud ─────────────────────────────────────────────
# $1=<op> (numéro d'opérateur ou « hub »)  $2=port  $3=nom  $4=commandes show
# osmo_vty_up / osmo_vty remplacent le couple « docker exec … echo
# >/dev/tcp/127.0.0.1/PORT » + « docker exec … nc » : même dialogue, mais local
# en natif. Le champ « container= » du dump garde l'étiquette du nœud.
query_vty() {
    local op="$1"
    local port="$2"
    local name="$3"
    local show_str="$4"
    local container
    container="$(osmo_node "$op")"

    # Test de connectivité rapide. En natif la sonde passive (ss) passe d'abord :
    # elle n'ouvre aucune session VTY.
    if ! osmo_vty_up "$op" "$port"; then
        echo -e "  ${YELLOW}[SKIP]${NC} ${name} (port ${port}) — non disponible"
        log "  [SKIP] ${name} port ${port} — non disponible"
        return 1
    fi

    echo -ne "  ${CYAN}${name}${NC} (${port}) … "

    # Construire le script VTY : passage en DEBUG, puis les show, puis end.
    local -a VTY_CMDS=(enable "logging level all debug" "logging filter all 1")
    IFS='|' read -ra SHOW_CMDS <<< "$show_str"
    for cmd in "${SHOW_CMDS[@]}"; do
        VTY_CMDS+=("$cmd")
    done
    VTY_CMDS+=(end)

    # Temporisations d'origine conservées telles quelles (nc -q2, 0,5 s avant
    # d'écrire, 2 s de lecture) : ce sont de gros jeux de commandes, et changer
    # ces valeurs changerait la QUANTITÉ de sortie capturée — donc le compteur
    # de lignes affiché juste après.
    local raw_output
    raw_output="$(OSMO_VTY_OPEN=0.5 OSMO_VTY_READ=2 OSMO_VTY_Q=2 \
                  osmo_vty "$op" "$port" "${VTY_CMDS[@]}" || true)"

    # Filtrer bannière/prompt VTY — même motif et même ordre qu'avant.
    # Sans argument : ce dump GARDE la ligne « Free Software lives », contrairement
    # à global_check.sh et ss7_check.sh.
    local clean_output
    clean_output="$(printf '%s\n' "$raw_output" | osmo_vty_clean)"

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

# ── Boucle principale : nœuds opérateur ───────────────────────────────────────
TOTAL_OK=0
TOTAL_SKIP=0

for op in "${OPS[@]:-}"; do
    [ -n "$op" ] || continue
    container="$(osmo_node "$op")"
    logsep "Container : ${container}  —  $(date '+%H:%M:%S')"
    echo -e "${GREEN}--- ${container} ---${NC}"

    for port in "${OP_VTY_PORTS[@]}"; do
        logsubsep "${OP_VTY_NAME[$port]} (port ${port})"
        if query_vty "$op" "$port" \
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
        if query_vty hub "$port" \
                "${ISTP_VTY_NAME[$port]}" "${ISTP_VTY_SHOW[$port]}"; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
        else
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        fi
    done
    echo ""
elif [ "$MODE" = docker ]; then
    log ""
    log "  [INFO] Container ${INTER_STP_CONTAINER} absent — skipped"
else
    # Natif sans hub local : ni OK ni échec, et surtout pas de compteur touché —
    # il n'y a rien à interroger ici, ce n'est pas une panne.
    echo -e "  ${YELLOW}${INTER_STP_CONTAINER} — ignoré (natif)${NC}"
    echo -e "  ${YELLOW}  $(osmo_hub_hint)${NC}"
    log ""
    log "  [INFO] ${INTER_STP_CONTAINER} — ignoré (natif) : $(osmo_hub_hint)"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
logsep "RÉSUMÉ — $(date '+%Y-%m-%d %H:%M:%S')"
log "  Mode                  : ${MODE} (${MODE_SRC})"
log "  VTY interrogés        : ${TOTAL_OK}"
log "  VTY non disponibles   : ${TOTAL_SKIP}"
log "  Opérateurs            : ${N_OPS}"
if   [ "$HAS_INTER_STP" -eq 1 ]; then log "  Inter-STP             : oui"
elif [ "$MODE" = docker        ]; then log "  Inter-STP             : non"
else                                  log "  Inter-STP             : ignoré (natif)"
fi
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
