#!/bin/bash
# verify-patch.sh — Vérification que le patch PROHIB routes est appliqué correctement
#
# Utilitaire : Contrôle que les configurations contiennent les bonnes routes
# et que les containers Osmocom affichent les états attendus.
#
# Usage :
#   ./verify-patch.sh                    # Vérification complète
#   ./verify-patch.sh --config-only      # Fichiers de config uniquement
#   ./verify-patch.sh --runtime-only     # Containers en cours d'exécution

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

MODE="${1:-all}"  # all, config-only, runtime-only

# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

check_file_content() {
    local file=$1 pattern=$2 description=$3
    if [ ! -f "$file" ]; then
        echo -e "  ${RED}✗${NC} Fichier absent : ${file}"
        return 1
    fi
    if grep -qF "$pattern" "$file"; then
        echo -e "  ${GREEN}✓${NC} ${description}"
        return 0
    else
        echo -e "  ${YELLOW}○${NC} Pattern absent : ${description}"
        echo -e "      Attendu : ${CYAN}${pattern}${NC}"
        echo -e "      Fichier : ${file}"
        return 1
    fi
}

check_docker_status() {
    local container=$1 port=$2 description=$3
    if ! docker inspect "$container" &>/dev/null; then
        echo -e "  ${YELLOW}○${NC} Container ${container} non trouvé"
        return 1
    fi
    if ! docker exec "$container" timeout 2 bash -c \
        "echo 'help' | telnet 127.0.0.1 $port &>/dev/null"; then
        echo -e "  ${YELLOW}○${NC} VTY ${description} (:${port}) non accessible"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} ${description} VTY accessible (:${port})"
    return 0
}

check_route_status() {
    local container=$1 route=$2 expected_status=$3 description=$4
    if ! docker inspect "$container" &>/dev/null; then
        echo -e "  ${YELLOW}○${NC} Container ${container} non trouvé"
        return 1
    fi

    local status
    status=$(docker exec "$container" bash -c \
        "echo \"show cs7 instance 0 route\" | telnet 127.0.0.1 4239 2>/dev/null | \
         grep \"${route}\"" 2>/dev/null | head -1 | awk '{print $(NF-1)}')

    if [ -z "$status" ]; then
        echo -e "  ${YELLOW}○${NC} Route ${route} non trouvée"
        return 1
    fi

    if [[ "$status" == *"$expected_status"* ]]; then
        echo -e "  ${GREEN}✓${NC} Route ${route} → ${expected_status} (${description})"
        return 0
    else
        echo -e "  ${RED}✗${NC} Route ${route} → ${status} (attendu: ${expected_status})"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Vérification Config
# ══════════════════════════════════════════════════════════════════════════════

verify_config_files() {
    echo -e "${BOLD}═ Vérification Fichiers de Config ═${NC}"
    echo ""

    local failed=0

    # start.sh : fonction wait_inter_stp_ready
    echo -e "${CYAN}start.sh${NC}"
    check_file_content "start.sh" "wait_inter_stp_ready()" \
        "Fonction wait_inter_stp_ready() présente" || ((failed++))
    check_file_content "start.sh" 'grep -c "linkset as-op"' \
        "Vérification VTY (grep linkset as-op)" || ((failed++))
    check_file_content "start.sh" "wait_inter_stp_ready \"\$n_operators\"" \
        "Appel wait_inter_stp_ready dans start_bridge_mode" || ((failed++))
    echo ""

    # create_interop.sh : routes explicites
    echo -e "${CYAN}create_interop.sh${NC}"
    check_file_content "create_interop.sh" "route \${pc_msc}/14 as as-op" \
        "Routes MSC explicites (route N.23.1/14)" || ((failed++))
    check_file_content "create_interop.sh" "route \${pc_bsc}/14 as as-op" \
        "Routes BSC explicites (route N.23.3/14)" || ((failed++))
    echo ""

    # osmo-stp.cfg : route par défaut (wildcard)
    echo -e "${CYAN}osmo-stp.cfg${NC}"
    check_file_content "osmo-stp.cfg" "route 0.0.0/14 as as-inter" \
        "Route par défaut wildcard (0.0.0/14 → as-inter)" || ((failed++))
    check_file_content "osmo-stp.cfg" "route __PC_MSC__/14  as as-local" \
        "Routes locales MSC (N.23.1 → as-local)" || ((failed++))
    check_file_content "osmo-stp.cfg" "route __PC_BSC__/14  as as-local" \
        "Routes locales BSC (N.23.3 → as-local)" || ((failed++))
    echo ""

    # run.sh : synchronisation
    echo -e "${CYAN}run.sh${NC}"
    check_file_content "run.sh" "fake_trx.py" \
        "fake_trx.py consolidée" || ((failed++))
    check_file_content "run.sh" "sleep 3" \
        "Attente synchronisation osmo-bts-trx" || ((failed++))
    check_file_content "run.sh" "sleep 5" \
        "Attente synchronisation osmo-bsc" || ((failed++))
    check_file_content "run.sh" "sleep 8" \
        "Attente synchronisation osmo-msc" || ((failed++))
    echo ""

    # osmo-start.sh : vérifications VTY
    echo -e "${CYAN}osmo-start.sh${NC}"
    check_file_content "osmo-start.sh" "vty_check()" \
        "Fonction vty_check() présente" || ((failed++))
    check_file_content "osmo-start.sh" "vty_check 4241" \
        "Vérification VTY OsmoBTS (:4241)" || ((failed++))
    check_file_content "osmo-start.sh" "vty_check 4254" \
        "Vérification VTY OsmoMSC (:4254)" || ((failed++))
    echo ""

    return $failed
}

# ══════════════════════════════════════════════════════════════════════════════
# Vérification Runtime
# ══════════════════════════════════════════════════════════════════════════════

verify_runtime() {
    echo -e "${BOLD}═ Vérification Runtime ═${NC}"
    echo ""

    if ! docker ps -a --filter "name=osmo-" --format "{{.Names}}" | grep -q "osmo-"; then
        echo -e "${YELLOW}[*] Aucun container Osmocom trouvé.${NC}"
        echo "    Lance d'abord : sudo ./start.sh"
        return 0
    fi

    local failed=0

    # Inter-STP
    echo -e "${CYAN}Inter-STP (osmo-inter-stp)${NC}"
    check_docker_status "osmo-inter-stp" 4239 "Inter-STP" || ((failed++))
    
    if docker inspect "osmo-inter-stp" &>/dev/null; then
        echo -e "  ${CYAN}Routes créées :${NC}"
        local route_count
        route_count=$(docker exec osmo-inter-stp bash -c \
            'echo "show cs7 instance 0 route" | telnet 127.0.0.1 4239 2>/dev/null | \
             grep -c "linkset as-op" 2>/dev/null || echo 0')
        echo -e "    ${route_count} routes trouvées"
        if [ "$route_count" -ge 3 ]; then
            echo -e "    ${GREEN}✓${NC} Routes inter-opérateurs créées"
        else
            echo -e "    ${YELLOW}○${NC} Attendez un peu que l'inter-STP stabilise..."
        fi
    fi
    echo ""

    # Op1
    echo -e "${CYAN}Opérateur 1 (osmo-operator-1)${NC}"
    check_docker_status "osmo-operator-1" 4242 "OsmoBSC Op1" || ((failed++))
    check_docker_status "osmo-operator-1" 4254 "OsmoMSC Op1" || ((failed++))
    
    if docker inspect "osmo-operator-1" &>/dev/null; then
        echo -e "  ${CYAN}Route par défaut (0.0.0/14) :${NC}"
        check_route_status "osmo-operator-1" "0.0.0/14" "allowed\|Allowed" \
            "Catch-all vers inter-STP" || ((failed++))
    fi
    echo ""

    # Op2 (si existe)
    if docker inspect "osmo-operator-2" &>/dev/null; then
        echo -e "${CYAN}Opérateur 2 (osmo-operator-2)${NC}"
        check_docker_status "osmo-operator-2" 4242 "OsmoBSC Op2" || ((failed++))
        check_docker_status "osmo-operator-2" 4254 "OsmoMSC Op2" || ((failed++))
        
        echo -e "  ${CYAN}Route par défaut (0.0.0/14) :${NC}"
        check_route_status "osmo-operator-2" "0.0.0/14" "allowed\|Allowed" \
            "Catch-all vers inter-STP" || ((failed++))
        echo ""
    fi

    return $failed
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

banner() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Vérification Patch PROHIB Routes (Race Condition) ║"
    echo "║  osmo_egprs — SS7 Inter-Opérateurs                ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

banner

total_failed=0

case "$MODE" in
    all)
        verify_config_files || total_failed=$?
        echo ""
        verify_runtime || total_failed=$?
        ;;
    config-only)
        verify_config_files || total_failed=$?
        ;;
    runtime-only)
        verify_runtime || total_failed=$?
        ;;
    *)
        echo -e "${RED}Mode inconnu : ${MODE}${NC}"
        echo "Usage : $0 [all|config-only|runtime-only]"
        exit 1
        ;;
esac

echo ""
echo -e "${BOLD}Résumé${NC}"
if [ $total_failed -eq 0 ]; then
    echo -e "  ${GREEN}✓ Patch correctement appliqué${NC}"
    exit 0
else
    echo -e "  ${YELLOW}⚠ ${total_failed} vérification(s) non complétée(s)${NC}"
    echo -e "    (Normal si les containers ne sont pas en cours d'exécution)"
    exit 1
fi
