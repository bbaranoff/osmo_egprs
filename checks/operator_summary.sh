#!/bin/bash
# operator_summary.sh — Résumé des caractéristiques principales de chaque opérateur
#
# Analyse le dump produit par checks/vty-debug-dump.sh et en extrait, opérateur
# par opérateur, les quelques chiffres qui disent si le réseau vit : ASP actifs,
# routes SS7, abonnés HLR/VLR, état des BTS, contextes PDP, appels en cours.
#
# DOUBLE MODE (docker / natif)
# ----------------------------
# Ce script ne parle à AUCUN démon : il lit un fichier. Le mode ne change donc
# pas ses quinze extractions — il change trois choses, et il faut les dire :
#
#   1. la GÉNÉRATION du dump (--live) : le générateur doit regarder le MÊME
#      monde que nous, sinon on analyse le dump d'un autre lab. Le mode lui est
#      transmis par OSMO_MODE, y compris quand il a été forcé ici.
#
#   2. l'INTER-STP : en docker c'est le conteneur osmo-inter-stp ; en natif
#      c'est soit cette machine (rôle interstp), soit une AUTRE machine — et
#      dans ce dernier cas son VTY n'est pas joignable d'ici, donc le dump n'en
#      contient rien. La section est alors IGNORÉE, explicitement : un
#      « 0 AS actif » fabriqué se lirait comme une panne du cœur SS7.
#
#   3. l'étiquette « container=osmo-operator-N » du dump : en natif elle reste
#      la même (checks/_mode.sh, osmo_node). C'est une CLÉ DE CORRÉLATION entre
#      les blocs du dump, pas un objet docker interrogeable — on ne la renomme
#      donc pas, sous peine de casser toutes les extractions ci-dessous.
#
# Le mode retenu est affiché en tête : un résumé qui ne dit pas dans quel monde
# il a regardé n'est pas exploitable.
#
# Usage :
#   sudo ./operator_summary.sh [--dump=/chemin/dump.txt] [--live]
#                              [--docker|--native]

set -euo pipefail

# ── Bibliothèque commune de détection docker/natif ────────────────────────────
# Chemin relatif à CE fichier (jamais absolu) : le dépôt vit dans /home/... en
# développement et dans /opt/osmo_egprs sur l'ISO.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_here/_mode.sh" /opt/osmo_egprs/checks/_mode.sh; do
    [ -r "$_c" ] && { . "$_c"; break; }
done
command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }

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
TEMP_DUMP=""

# OSMO_MODE hérité de l'environnement vaut choix explicite, au même titre que
# --docker/--native : on le signale comme « forcé » dans l'en-tête.
MODE_FORCED=0
[ -n "${OSMO_MODE:-}" ] && MODE_FORCED=1

for arg in "$@"; do
    case "$arg" in
        --dump=*) DUMP_FILE="${arg#*=}" ;;
        --live)   LIVE_MODE=1 ;;
        --docker|--native|--mode=*)
            # osmo_mode_force rend 2 si l'argument n'est pas un mode : seul
            # « --mode=n'importe-quoi » peut encore échouer ici.
            if osmo_mode_force "$arg"; then
                MODE_FORCED=1
            else
                echo "Mode inconnu : ${arg} (attendu : --docker, --native)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [--dump=/chemin/dump.txt] [--live] [--docker|--native]"
            echo "  --dump   : Utilise un fichier de dump existant"
            echo "  --live   : Génère un dump live avant l'analyse"
            echo "  --docker : Force le mode conteneurs (osmo-operator-N)"
            echo "  --native : Force le mode natif (ISO, VM, machine nue)"
            echo "             sans option, le mode est détecté automatiquement"
            exit 0
            ;;
    esac
done

MODE="$(osmo_mode)"
if [ "$MODE_FORCED" -eq 1 ]; then MODE_SRC="forcé"; else MODE_SRC="détecté"; fi

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

# Ligne de la boîte d'en-tête, calée sur les 58 colonnes du filet ╔══╗.
box_line() {
    local txt="$1" pad
    pad=$(( 58 - 5 - ${#txt} ))
    [ "$pad" -ge 0 ] || pad=0
    echo -e "${CYAN}║     ${txt}$(printf '%*s' "$pad" '')║${NC}"
}

# ── Extraction de données depuis le dump ──────────────────────────────────────
#
# PIÈGE PIPEFAIL, valable pour TOUTES les extractions de ce fichier : sous
# « set -o pipefail », un grep qui ne trouve rien (rc 1) ou un « head -1 » qui
# sort tôt (le producteur meurt en SIGPIPE, rc 141) fait échouer le tube entier,
# donc l'affectation « var=$(…) », donc — sous « set -e » — le script lui-même.
# Sur un dump vide ou partiel (mode natif où tout est absent, dump produit
# ailleurs) le résumé s'interrompait sans un mot. D'où les « || true » : ils ne
# masquent aucune erreur, ils disent « rien trouvé = zéro », ce que wc et grep -c
# ont déjà écrit sur leur sortie.

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
        | tr -d ' ' \
        || true
}

extract_subscriber_count() {
    local container="$1"
    local count

    count=$(grep -A20 "\[OsmoHLR\]" "$DUMP_FILE" \
        | grep -A5 "container=${container}" \
        | grep -E "subscriber count.*[0-9]+" \
        | grep -oE '[0-9]+' \
        | head -1 || true)

    echo "${count:-0}"
}

# Renseigne BTS_STATE, OML_OK et RSL_OK — des variables GLOBALES, à dessein.
# La version précédente écrivait l'état sur stdout ET posait OML_OK/RSL_OK dans
# la foulée ; appelée en « $( ) » elle tournait dans un SOUS-SHELL, où ces deux
# affectations mouraient avec lui : les lignes OML et RSL affichaient
# « ✗ déconnecté » même quand le dump montrait des liens connectés. On renseigne
# donc les trois au même endroit, sans substitution de commande.
extract_bts_info() {
    local container="$1"
    local bts_id="$2"
    local bts_block oper avail oml rsl

    bts_block=$(grep -A50 "\[OsmoBSC\]" "$DUMP_FILE" \
        | grep -A30 "container=${container}" \
        | grep -A20 "bts ${bts_id}" \
        | sed -n '/bts [0-9]/,/^$/p' || true)

    oper=$(echo "$bts_block" | grep -c "Oper 'Enabled'" || true)
    avail=$(echo "$bts_block" | grep -c "Avail 'OK'" || true)
    oml=$(echo "$bts_block" | grep -c "OML Link state: connected" || true)
    rsl=$(echo "$bts_block" | grep -c "RSL State: connected" || true)

    if [ "$oper" -gt 0 ] && [ "$avail" -gt 0 ]; then
        BTS_STATE="OK"
    elif [ "$oper" -gt 0 ]; then
        BTS_STATE="Enabled"
    else
        BTS_STATE="Down"
    fi

    # Renseigne aussi OML/RSL pour info
    [ "$oml" -gt 0 ] && OML_OK=1 || OML_OK=0
    [ "$rsl" -gt 0 ] && RSL_OK=1 || RSL_OK=0
}

extract_asp_state() {
    local container="$1"
    local component="$2"  # STP, MSC, BSC

    local asp_block=""
    if [ "$component" = "STP" ]; then
        asp_block=$(grep -A30 "\[OsmoSTP\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "MSC" ]; then
        asp_block=$(grep -A30 "\[OsmoMSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    elif [ "$component" = "BSC" ]; then
        asp_block=$(grep -A30 "\[OsmoBSC\]" "$DUMP_FILE" \
            | grep -A20 "container=${container}" || true)
    fi

    echo "$asp_block" | grep -c "ASP_ACTIVE" || true
}

# ── Génération d'un dump live si demandé ──────────────────────────────────────
if [ "$LIVE_MODE" -eq 1 ]; then
    echo -e "${CYAN}Génération d'un dump live (mode ${MODE})...${NC}"
    TEMP_DUMP="/tmp/vty-live-$$.txt"

    # Le générateur est cherché À CÔTÉ DE NOUS (BASH_SOURCE), plus dans le
    # répertoire courant : « ./vty-debug-dump.sh » n'existait que si l'on avait
    # fait « cd checks/ » au préalable, ce qui n'est pas le cas depuis l'ISO.
    DUMPER="$_here/vty-debug-dump.sh"
    [ -x "$DUMPER" ] || DUMPER="./vty-debug-dump.sh"

    # OSMO_MODE est transmis explicitement : le générateur doit interroger le
    # même monde que celui qu'on analysera, même si --native/--docker a forcé
    # un mode qu'il n'aurait pas détecté seul.
    if ! OSMO_MODE="$MODE" "$DUMPER" --out "$TEMP_DUMP" > /dev/null; then
        echo -e "${RED}Échec de la génération du dump (${DUMPER}, mode ${MODE}).${NC}" >&2
        if [ "$MODE" = native ]; then
            echo "  Mode natif : vérifiez que les démons tournent (VTY 4239/4254/4242/4258…)." >&2
        else
            echo "  Mode docker : vérifiez que les conteneurs osmo-operator-N sont en cours." >&2
        fi
        rm -f "$TEMP_DUMP"
        exit 1
    fi
    DUMP_FILE="$TEMP_DUMP"
    echo -e "${GREEN}✓ Dump généré : $DUMP_FILE${NC}"
fi

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo -e "${RED}Erreur : fichier de dump non spécifié ou introuvable${NC}"
    echo "Utilisez --dump=/chemin/vers/dump.txt ou --live pour générer un dump"
    exit 1
fi

# ── Détection des nœuds présents DANS LE DUMP ─────────────────────────────────
# « container=osmo-operator-N » est écrit par vty-debug-dump.sh dans les deux
# mondes : en docker c'est le nom du conteneur, en natif l'étiquette rendue par
# osmo_node(). On lit donc le dump de la même façon des deux côtés.
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
box_line "Mode : ${MODE} (${MODE_SRC})"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

# Dump muet : on le dit. Le comparer à l'inventaire vivant distingue « rien ne
# tourne » de « le dump vient d'ailleurs / est partiel » — deux pannes très
# différentes, surtout en natif où aucun « docker ps » ne peut trancher.
if [ "$N_OPS" -eq 0 ]; then
    live_ops="$(osmo_ops 2>/dev/null | tr '\n' ' ' || true)"
    live_ops="${live_ops% }"
    echo ""
    echo -e "  ${YELLOW}Aucun bloc « container=osmo-operator-N » dans ce dump.${NC}"
    print_row "Opérateurs vus ici" "${live_ops:-aucun} (mode ${MODE})"
    print_row "Dump" "vide, partiel, ou produit sur un autre nœud"
fi

# ── Inter-STP ─────────────────────────────────────────────────────────────────
if [ -n "$INTER_STP" ]; then
    print_header "INTER-STP HUB (${INTER_STP})"

    asp_count=$(extract_asp_state "$INTER_STP" "STP")
    print_row "ASP actifs" "$asp_count"

    # Routes
    routes=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | wc -l || true)
    print_row "Routes configurées" "$routes"

    # AS
    as_count=$(grep -A50 "\[OsmoSTP-hub\]" "$DUMP_FILE" \
        | grep -A30 "container=${INTER_STP}" \
        | grep -c "AS_ACTIVE" || true)
    print_row "AS actifs" "$as_count"

elif osmo_is_native; then
    # Rien sur le hub dans le dump, et nous sommes en natif : soit cette machine
    # EST le hub et le dump est plus vieux qu'elle, soit le hub est une AUTRE
    # machine, dont le VTY 4239 n'écoute que sur son propre 127.0.0.1 — il n'est
    # donc PAS observable d'ici. On l'ignore visiblement au lieu d'afficher des
    # compteurs à zéro qui se liraient comme un cœur SS7 mort.
    print_header "INTER-STP HUB — ignoré (natif)"
    if hub_here="$(osmo_hub)"; then
        print_row "Hub local" "${hub_here} présent ici, mais absent du dump"
        print_row "Pour l'inclure" "relancez avec --live"
    else
        print_row "Hub" "$(osmo_hub_hint)"
    fi

elif hub_here="$(osmo_hub)"; then
    # Mode docker : le conteneur tourne mais ne figure pas dans le dump — le
    # dump est donc antérieur au hub. Sans conteneur hub, on ne dit rien, comme
    # avant : il n'y a simplement pas d'inter-STP dans ce lab.
    print_header "INTER-STP HUB (${hub_here})"
    print_row "État" "conteneur en cours, mais absent du dump"
    print_row "Pour l'inclure" "relancez avec --live"
fi

# ── Boucle sur les opérateurs ─────────────────────────────────────────────────
# « ${CONTAINERS[@]+…} » : sur un dump muet le tableau est vide, et sous
# « set -u » un « "${CONTAINERS[@]}" » nu casserait au lieu de ne rien faire.
for container in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
    # Le numéro est le suffixe de l'étiquette ; la mapfile n'a laissé passer que
    # « osmo-operator-<chiffres> », donc pas de sous-shell ni de grep ici.
    op_id="${container##*-}"

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
        | wc -l || true)
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
        | head -1 || true)
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
    BTS_STATE="Down"
    extract_bts_info "$container" 0
    print_row "BTS 0 état" "$BTS_STATE"
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
