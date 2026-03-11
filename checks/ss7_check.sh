#!/bin/bash
# ss7_check.sh — Vérification SS7 pour architecture Inter-STP central
#
# Architecture cible :
#   - Inter-STP (0.23.0) central
#   - Chaque opérateur a STP local (N.23.2) avec route par défaut vers inter-STP
#   - Routes dynamiques apprises via M3UA
#
# Ce qui est vérifié :
#   1. Inter-STP : AS actifs pour chaque opérateur
#   2. Inter-STP : ASP connectés
#   3. Inter-STP : pas de PROHIB
#   4. Chaque opérateur : ASP actif vers inter-STP
#   5. Chaque opérateur : routes locales (MSC/BSC) actives
#   6. Chaque opérateur : route par défaut (0.0.0/0) vers inter-STP
#   7. Matrice de connectivité basique
#
# Usage :
#   sudo ./ss7_check.sh [--verbose] [--quick]

set -u

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
VERBOSE=0
QUICK=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quick|-q)   QUICK=1 ;;
    esac
done

INTER_STP="osmo-inter-stp"
PASS=0
FAIL=0
WARN=0
SKIP=0

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
skip() { echo -e "  ${YELLOW}—${NC} $*"; SKIP=$((SKIP+1)); }
info() { [[ $VERBOSE -eq 1 ]] && echo -e "    ${CYAN}│${NC} $*"; }

banner() {
    echo ""
    echo -e "${BOLD}$*${NC}"
    echo -e "$(printf '─%.0s' {1..60})"
}

# ── Fonction VTY ──────────────────────────────────────────────────────────────
vty_cmd() {
    local container="$1"
    local port="$2"
    local cmd="$3"

    # Test de connectivité rapide
    if ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        return 1
    fi

    # Construire le script VTY
    local vty_script
    vty_script="enable
${cmd}
end
"

    # Envoyer via nc ou telnet
    local raw_output
    raw_output=$(docker exec "$container" bash -c "
        VTY_SCRIPT=\$(cat << 'VTYEOF'
${vty_script}
VTYEOF
)
        if command -v nc >/dev/null 2>&1; then
            ( sleep 1; printf '%s' \"\$VTY_SCRIPT\"; sleep 1.5 ) \
                | nc -q1 127.0.0.1 ${port} 2>/dev/null || true
        else
            ( sleep 1; printf '%s' \"\$VTY_SCRIPT\"; sleep 1.5 ) \
                | telnet 127.0.0.1 ${port} 2>/dev/null || true
        fi
    " 2>/dev/null || true)

    # Filtrer les lignes de bannière/prompt
    local clean_output
    clean_output=$(echo "$raw_output" \
        | grep -vE \
            "^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete|% Error|\
Connection closed|Free Software lives)" \
        | sed 's/\r//' \
        | grep -v '^[[:space:]]*$' || true)

    echo "$clean_output"
    return 0
}

# ── Vérification rapide de disponibilité VTY ──────────────────────────────────
vty_available() {
    local container="$1"
    local port="$2"
    if docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ── Détection containers ──────────────────────────────────────────────────────
mapfile -t OP_CONTAINERS < <(
    docker ps --format '{{.Names}}' \
        | grep -E '^osmo-operator-[0-9]+$' \
        | sort -t '-' -k 3 -n
)

HAS_INTER_STP=0
if docker ps --format '{{.Names}}' | grep -qx "$INTER_STP"; then
    HAS_INTER_STP=1
fi

N_OPS=${#OP_CONTAINERS[@]}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          SS7 Health Check — $(date '+%H:%M:%S')                     ║${NC}"
echo -e "${CYAN}║          ${N_OPS} opérateur(s)  inter-stp=${HAS_INTER_STP}                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

if [ "$N_OPS" -eq 0 ] && [ "$HAS_INTER_STP" -eq 0 ]; then
    echo -e "${RED}Aucun container trouvé${NC}"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 1 : Inter-STP (hub central)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ]; then
    banner "INTER-STP (hub SS7) — 0.23.0"

    if ! vty_available "$INTER_STP" 4239; then
        fail "VTY inter-STP (4239) inaccessible"
    else
        ok "VTY accessible"

        # Vérifier que l'inter-STP voit tous les opérateurs comme AS
        as_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 as all")
        n_as_total=$(echo "$as_output" | grep -cE 'as-op[0-9]+' || true)
        n_as_active=$(echo "$as_output" | grep -cE 'AS_ACTIVE' || true)

        if [ "$n_as_active" -eq "$N_OPS" ]; then
            ok "AS : ${n_as_active}/${N_OPS} actifs (tous)"
        elif [ "$n_as_active" -gt 0 ]; then
            warn "AS : ${n_as_active}/${N_OPS} actifs"
        else
            fail "AS : aucun actif"
        fi

        # Vérifier les ASP connectés
        asp_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 asp")
        n_asp_active=$(echo "$asp_output" | grep -cE 'ASP_ACTIVE' || true)

        if [ "$n_asp_active" -eq "$N_OPS" ]; then
            ok "ASP : ${n_asp_active}/${N_OPS} connectés (tous)"
        else
            warn "ASP : ${n_asp_active}/${N_OPS} connectés"
        fi

        # Vérifier l'absence de PROHIB (routes bloquées)
        route_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 route")
        n_prohib=$(echo "$route_output" | grep -ciE 'prohib' || true)

        if [ "$n_prohib" -eq 0 ]; then
            ok "Routes : aucun PROHIB"
        else
            fail "Routes : ${n_prohib} PROHIB détectées"
        fi
    fi
else
    banner "INTER-STP"
    skip "Container ${INTER_STP} absent"
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 2 : Chaque opérateur
# ══════════════════════════════════════════════════════════════════════════════
for container in "${OP_CONTAINERS[@]}"; do
    op_id="${container##*-}"
    banner "OPÉRATEUR ${op_id} (${container}) — STP ${op_id}.23.2"

    # ── STP local (4239) ─────────────────────────────────────────────────
    echo -e "  ${BOLD}STP local :${NC}"
    if ! vty_available "$container" 4239; then
        fail "STP VTY (4239) inaccessible"
    else
        # Vérifier la connexion vers l'inter-STP
        as_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 as all")
        inter_state=$(echo "$as_out" | grep -oP 'as-inter\s+\K(AS_\w+)' || echo "ABSENT")

        if [[ "$inter_state" == "AS_ACTIVE" ]]; then
            ok "as-inter → hub : ACTIVE"
        elif [[ "$inter_state" == "ABSENT" ]] && [ "$HAS_INTER_STP" -eq 1 ]; then
            fail "as-inter absent (pas de connexion au hub)"
        else
            warn "as-inter : ${inter_state}"
        fi

        # Vérifier les ASP locaux (MSC/BSC)
        asp_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 asp")
        n_asp_ok=$(echo "$asp_out" | grep -cE 'ASP_ACTIVE' || true)

        if [ "$n_asp_ok" -ge 2 ]; then
            ok "ASP locaux : au moins 2 actifs (MSC+BSC)"
        elif [ "$n_asp_ok" -eq 1 ]; then
            warn "ASP locaux : 1 seul actif (manque MSC ou BSC)"
        else
            fail "ASP locaux : aucun actif"
        fi

        # Vérifier la route par défaut vers l'inter-STP (élément clé)
        route_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 route")
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0.*avail' || true)

        if [ "$has_default" -gt 0 ] && [ "$HAS_INTER_STP" -eq 1 ]; then
            ok "Route par défaut → inter-STP : présente et avail"
        elif [ "$HAS_INTER_STP" -eq 1 ]; then
            fail "Route par défaut → inter-STP absente ou non avail"
        fi

        # Vérifier l'absence de PROHIB
        n_prohib=$(echo "$route_out" | grep -ciE 'prohib' || true)
        if [ "$n_prohib" -gt 0 ]; then
            fail "Routes PROHIB détectées : ${n_prohib}"
        fi

        # Compter les routes dynamiques (juste pour info)
        n_dyn=$(echo "$route_out" | grep -c 'dyn' || true)
        info "Routes dynamiques apprises : ${n_dyn} (normal: devrait augmenter avec le nombre d'opérateurs)"
    fi

    # En mode quick, on passe au prochain opérateur
    if [ "$QUICK" -eq 1 ]; then
        continue
    fi

    # ── MSC (4254) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}MSC :${NC}"
    if ! vty_available "$container" 4254; then
        fail "MSC VTY (4254) inaccessible"
    else
        msc_asp=$(vty_cmd "$container" 4254 "show cs7 instance 0 asp")
        msc_active=$(echo "$msc_asp" | grep -cE 'ASP_ACTIVE' || true)
        [ "$msc_active" -gt 0 ] && ok "MSC→STP : ASP_ACTIVE" || fail "MSC→STP : pas de ASP actif"

        # SCCP
        msc_sccp=$(vty_cmd "$container" 4254 "show cs7 instance 0 sccp users")
        echo "$msc_sccp" | grep -qE 'SSN 254' && ok "SCCP SSN 254 (MSC-A) enregistré" || fail "SCCP SSN 254 absent"
    fi

    # ── BSC (4242) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}BSC :${NC}"
    if ! vty_available "$container" 4242; then
        fail "BSC VTY (4242) inaccessible"
    else
        bsc_asp=$(vty_cmd "$container" 4242 "show cs7 instance 0 asp")
        bsc_active=$(echo "$bsc_asp" | grep -cE 'ASP_ACTIVE' || true)
        [ "$bsc_active" -gt 0 ] && ok "BSC→STP : ASP_ACTIVE" || fail "BSC→STP : pas de ASP actif"

        # SCCP
        bsc_sccp=$(vty_cmd "$container" 4242 "show cs7 instance 0 sccp users")
        echo "$bsc_sccp" | grep -qE 'SSN 254' && ok "SCCP SSN 254 (BSC) enregistré" || fail "SCCP SSN 254 absent"

        # BTS state (optionnel)
        bsc_bts=$(vty_cmd "$container" 4242 "show bts 0" 2>/dev/null || echo "")
        if echo "$bsc_bts" | grep -qE "Oper 'Enabled'.*Avail 'OK'"; then
            ok "BTS 0 : OK"
        fi
    fi

    # ── HLR (4258) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}HLR :${NC}"
    if ! vty_available "$container" 4258; then
        fail "HLR VTY (4258) inaccessible"
    else
        hlr_gsup=$(vty_cmd "$container" 4258 "show gsup-connections")
        vlr_conn=$(echo "$hlr_gsup" | grep -cE "VLR" || true)
        [ "$vlr_conn" -gt 0 ] && ok "GSUP : VLR connecté" || fail "GSUP : VLR absent"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 3 : Matrice de connectivité simple
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ] && [ "$N_OPS" -gt 1 ]; then
    banner "MATRICE DE CONNECTIVITÉ (via inter-STP)"

    printf "  %-8s" ""
    for j in $(seq 1 "$N_OPS"); do printf "  Op%-3s" "$j"; done
    echo ""

    for container in "${OP_CONTAINERS[@]}"; do
        src_id="${container##*-}"
        printf "  Op%-5s" "${src_id}"

        # On ne teste que la connectivité de base : l'opérateur a-t-il une route par défaut ?
        route_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 route" 2>/dev/null || echo "")
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0.*avail' || true)

        for j in $(seq 1 "$N_OPS"); do
            if [ "$j" -eq "$src_id" ]; then
                printf "  ${CYAN}%-5s${NC}" "self"
            elif [ "$has_default" -gt 0 ]; then
                # Si route par défaut, on suppose que la connectivité est possible via l'inter-STP
                printf "  ${GREEN}%-5s${NC}" "via"
            else
                printf "  ${RED}%-5s${NC}" "FAIL"
                FAIL=$((FAIL+1))
            fi
        done
        echo ""
    done
    echo ""
    echo "  Note: 'via' signifie que l'opérateur a une route par défaut vers l'inter-STP"
    echo "  Les routes dynamiques spécifiques sont apprises au fur et à mesure"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "$(printf '═%.0s' {1..60})"

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}SS7 OK${NC}  —  ${GREEN}${PASS} pass${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
elif [ "$FAIL" -le 3 ]; then
    echo -e "  ${YELLOW}${BOLD}SS7 DÉGRADÉ${NC}  —  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
else
    echo -e "  ${RED}${BOLD}SS7 KO${NC}  —  ${GREEN}${PASS} pass${NC}  ${RED}${FAIL} fail${NC}  ${YELLOW}${WARN} warn${NC}  ${SKIP} skip"
fi
echo -e "$(printf '═%.0s' {1..60})"
echo ""

exit "$FAIL"
