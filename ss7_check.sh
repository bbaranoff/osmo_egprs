#!/bin/bash
# ss7-check.sh — Vérification rapide de la stack SS7 multi-opérateurs
#
# Vérifie pour chaque container :
#   1. ASP states (ASP_ACTIVE attendu)
#   2. AS states  (AS_ACTIVE attendu)
#   3. Routes     (avail attendu, pas de PROHIB)
#   4. SCCP users (SSN 254 attendu sur MSC/BSC)
#   5. Inter-STP  (tous les AS opérateurs actifs)
#   6. Connectivité inter-op (routes croisées)
#
# Usage :
#   sudo ./ss7-check.sh [--verbose]

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

INTER_STP="osmo-inter-stp"
PASS=0; FAIL=0; WARN=0; SKIP=0

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

# Envoie une commande VTY et retourne le résultat nettoyé
vty_cmd() {
    local container="$1" port="$2" cmd="$3"
    local result
    result=$(docker exec "$container" bash -c "
        ( sleep 0.3; printf 'enable\n${cmd}\n'; sleep 0.5 ) \
        | nc -q1 127.0.0.1 ${port} 2>/dev/null || true
    " 2>/dev/null | grep -vE '^(Welcome|OsmoSTP|OsmoMSC|OsmoBSC|OsmoHLR|VTY|Use|Press|[A-Za-z0-9_-]+[#>] |Enter|Trying|Connected|Escape|$)' | sed 's/\r//' || true)
    echo "$result"
}

# ── Détection containers ──────────────────────────────────────────────────────
mapfile -t OP_CONTAINERS < <(
    docker ps --format '{{.Names}}' \
        | grep -E '^osmo-operator-[0-9]+$' \
        | sort -t '-' -k 3 -n
)

HAS_INTER_STP=0
docker ps --format '{{.Names}}' | grep -qx "$INTER_STP" && HAS_INTER_STP=1

N_OPS=${#OP_CONTAINERS[@]}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          SS7 Health Check — $(date '+%H:%M:%S')                     ║${NC}"
echo -e "${CYAN}║          ${N_OPS} opérateur(s)  inter-stp=${HAS_INTER_STP}                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

if [ "$N_OPS" -eq 0 ]; then
    fail "Aucun container osmo-operator trouvé"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 1 : Inter-STP
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ]; then
    banner "INTER-STP (hub SS7)"

    # VTY accessible ?
    if ! docker exec "$INTER_STP" bash -c "echo >/dev/tcp/127.0.0.1/4239" 2>/dev/null; then
        fail "VTY inter-STP (4239) inaccessible"
    else
        ok "VTY accessible"

        # AS states
        as_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 as all")
        n_as_total=$(echo "$as_output" | grep -cE 'as-op[0-9]+' || true)
        n_as_active=$(echo "$as_output" | grep -cE 'AS_ACTIVE' || true)
        n_as_down=$(echo "$as_output" | grep -cE 'AS_DOWN|AS_INACTIVE' || true)

        if [ "$n_as_active" -eq "$N_OPS" ]; then
            ok "AS : ${n_as_active}/${N_OPS} actifs"
        elif [ "$n_as_active" -gt 0 ]; then
            warn "AS : ${n_as_active}/${N_OPS} actifs (${n_as_down} down)"
        else
            fail "AS : aucun actif sur ${n_as_total} configurés"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$as_output" | grep -E 'as-op' | while read -r line; do info "$line"; done

        # ASP states
        asp_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 asp")
        n_asp_active=$(echo "$asp_output" | grep -cE 'ASP_ACTIVE' || true)
        n_asp_down=$(echo "$asp_output" | grep -cE 'ASP_DOWN|ASP_INACTIVE' || true)

        if [ "$n_asp_active" -eq "$N_OPS" ]; then
            ok "ASP : ${n_asp_active}/${N_OPS} connectés"
        else
            warn "ASP : ${n_asp_active}/${N_OPS} connectés (${n_asp_down} down)"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$asp_output" | grep -E 'asp-' | while read -r line; do info "$line"; done

        # Routes
        route_output=$(vty_cmd "$INTER_STP" 4239 "show cs7 instance 0 route")
        n_routes=$(echo "$route_output" | grep -cE '^\s+[0-9]+\.' || true)
        n_prohib=$(echo "$route_output" | grep -ciE 'prohib' || true)
        n_avail=$(echo "$route_output" | grep -cE '\bavail\b' || true)

        if [ "$n_prohib" -gt 0 ]; then
            fail "Routes : ${n_prohib} PROHIB détectées"
            echo "$route_output" | grep -iE 'prohib' | while read -r line; do info "${RED}${line}${NC}"; done
        elif [ "$n_routes" -gt 0 ]; then
            ok "Routes : ${n_routes} destinations (aucun PROHIB)"
        else
            warn "Routes : aucune route trouvée"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$route_output" | grep -E '^\s+[0-9]+\.' | while read -r line; do info "$line"; done
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
    banner "OPÉRATEUR ${op_id} (${container})"

    # ── STP local (4239) ─────────────────────────────────────────────────
    echo -e "  ${BOLD}STP local :${NC}"
    if ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4239" 2>/dev/null; then
        fail "STP VTY (4239) inaccessible"
    else
        # AS states
        as_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 as all")

        # as-inter → vers le hub
        inter_state=$(echo "$as_out" | grep -oP 'as-inter\s+\K(AS_\w+)' || echo "ABSENT")
        if [[ "$inter_state" == "AS_ACTIVE" ]]; then
            ok "as-inter → hub : ACTIVE"
        elif [[ "$inter_state" == "ABSENT" ]]; then
            if [ "$HAS_INTER_STP" -eq 1 ]; then
                fail "as-inter absent (devrait exister)"
            else
                skip "as-inter absent (pas d'inter-STP)"
            fi
        else
            fail "as-inter → hub : ${inter_state}"
        fi

        # as-rkm (MSC/BSC locaux)
        n_rkm_active=$(echo "$as_out" | grep -cE 'as-rkm.*AS_ACTIVE' || true)
        n_rkm_total=$(echo "$as_out" | grep -cE 'as-rkm' || true)
        if [ "$n_rkm_total" -eq 0 ]; then
            warn "Aucun AS local (MSC/BSC) enregistré"
        elif [ "$n_rkm_active" -eq "$n_rkm_total" ]; then
            ok "AS locaux : ${n_rkm_active}/${n_rkm_total} actifs (MSC+BSC)"
        else
            fail "AS locaux : ${n_rkm_active}/${n_rkm_total} actifs"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$as_out" | grep -E 'as-' | while read -r line; do info "$line"; done

        # ASP
        asp_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 asp")
        n_asp_ok=$(echo "$asp_out" | grep -cE 'ASP_ACTIVE' || true)
        n_asp_total=$(echo "$asp_out" | grep -cE 'asp-' || true)
        if [ "$n_asp_ok" -eq "$n_asp_total" ] && [ "$n_asp_total" -gt 0 ]; then
            ok "ASP : ${n_asp_ok}/${n_asp_total} actifs"
        else
            fail "ASP : ${n_asp_ok}/${n_asp_total} actifs"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$asp_out" | grep -E 'asp-' | while read -r line; do info "$line"; done

        # Routes
        route_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 route")
        n_prohib=$(echo "$route_out" | grep -ciE 'prohib' || true)
        has_default=$(echo "$route_out" | grep -cE '0\.0\.0/0' || true)
        n_routes=$(echo "$route_out" | grep -cE '^\s+[0-9]+\.' || true)

        if [ "$n_prohib" -gt 0 ]; then
            fail "Routes : ${n_prohib} PROHIB"
            echo "$route_out" | grep -iE 'prohib' | while read -r line; do
                echo -e "    ${RED}│ ${line}${NC}"
            done
        else
            ok "Routes : ${n_routes} entrées, 0 PROHIB"
        fi

        if [ "$has_default" -gt 0 ] && [ "$HAS_INTER_STP" -eq 1 ]; then
            ok "Route par défaut → inter-STP présente"
        elif [ "$HAS_INTER_STP" -eq 1 ]; then
            fail "Route par défaut → inter-STP absente"
        fi
        [[ $VERBOSE -eq 1 ]] && echo "$route_out" | grep -E '^\s+[0-9]+\.' | while read -r line; do info "$line"; done
    fi

    # ── MSC (4254) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}MSC :${NC}"
    if ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4254" 2>/dev/null; then
        fail "MSC VTY (4254) inaccessible — osmo-msc DOWN"
    else
        msc_asp=$(vty_cmd "$container" 4254 "show cs7 instance 0 asp")
        msc_active=$(echo "$msc_asp" | grep -cE 'ASP_ACTIVE' || true)
        if [ "$msc_active" -gt 0 ]; then
            ok "MSC→STP : ASP_ACTIVE"
        else
            fail "MSC→STP : pas de ASP actif"
        fi

        # SCCP
        msc_sccp=$(vty_cmd "$container" 4254 "show cs7 instance 0 sccp users")
        if echo "$msc_sccp" | grep -qE 'SSN 254'; then
            ok "SCCP SSN 254 (MSC-A) enregistré"
        else
            fail "SCCP SSN 254 absent"
        fi

        # Subscribers
        msc_stats=$(vty_cmd "$container" 4254 "show cs7 instance 0 as all")
        msc_as_state=$(echo "$msc_stats" | grep -oP 'as-msc\s+\K(AS_\w+)' || echo "?")
        info "AS as-msc : ${msc_as_state}"

        # VLR count
        vlr_out=$(vty_cmd "$container" 4254 "show subscriber count")
        vlr_count=$(echo "$vlr_out" | grep -oP '\d+' | head -1 || echo "?")
        info "Subscribers VLR : ${vlr_count}"
    fi

    # ── BSC (4242) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}BSC :${NC}"
    if ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4242" 2>/dev/null; then
        fail "BSC VTY (4242) inaccessible — osmo-bsc DOWN"
    else
        bsc_asp=$(vty_cmd "$container" 4242 "show cs7 instance 0 asp")
        bsc_active=$(echo "$bsc_asp" | grep -cE 'ASP_ACTIVE' || true)
        if [ "$bsc_active" -gt 0 ]; then
            ok "BSC→STP : ASP_ACTIVE"
        else
            fail "BSC→STP : pas de ASP actif"
        fi

        # SCCP
        bsc_sccp=$(vty_cmd "$container" 4242 "show cs7 instance 0 sccp users")
        if echo "$bsc_sccp" | grep -qE 'SSN 254'; then
            ok "SCCP SSN 254 (BSC) enregistré"
        else
            fail "SCCP SSN 254 absent"
        fi

        # BTS
        bsc_bts=$(vty_cmd "$container" 4242 "show bts 0")
        if echo "$bsc_bts" | grep -qE "Oper 'Enabled'.*Avail 'OK'"; then
            ok "BTS 0 : Enabled / OK"
        elif echo "$bsc_bts" | grep -qE "Oper 'Enabled'"; then
            warn "BTS 0 : Enabled mais Avail != OK"
        else
            fail "BTS 0 : pas Enabled"
        fi

        # OML/RSL
        oml_up=$(echo "$bsc_bts" | grep -cE 'OML Link state: connected' || true)
        rsl_up=$(echo "$bsc_bts" | grep -cE 'RSL State: connected' || true)
        if [ "$oml_up" -gt 0 ]; then
            ok "OML : connecté"
        else
            fail "OML : déconnecté"
        fi
        if [ "$rsl_up" -gt 0 ]; then
            ok "RSL : connecté"
        else
            fail "RSL : déconnecté"
        fi
    fi

    # ── HLR (4258) ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}HLR :${NC}"
    if ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; then
        fail "HLR VTY (4258) inaccessible"
    else
        hlr_gsup=$(vty_cmd "$container" 4258 "show gsup-connections")
        n_gsup=$(echo "$hlr_gsup" | grep -cE "from 127" || true)
        vlr_conn=$(echo "$hlr_gsup" | grep -cE "VLR" || true)
        smsc_conn=$(echo "$hlr_gsup" | grep -cE "SMSC" || true)

        if [ "$vlr_conn" -gt 0 ]; then
            ok "GSUP : VLR connecté"
        else
            fail "GSUP : VLR absent"
        fi
        if [ "$smsc_conn" -gt 0 ]; then
            ok "GSUP : SMSC connecté"
        else
            warn "GSUP : SMSC absent"
        fi
        info "Connexions GSUP totales : ${n_gsup}"
    fi

    # ── MNCC socket ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}Voice path :${NC}"
    if docker exec "$container" test -S /tmp/msc_mncc 2>/dev/null; then
        ok "MNCC socket présent"
    else
        fail "MNCC socket absent (osmo-sip-connector down ?)"
    fi

    # ── SMS relay ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}SMS :${NC}"
    sms_port=$(docker exec "$container" ss -tlnp 2>/dev/null | grep -c ':7890' || true)
    if [ "$sms_port" -gt 0 ]; then
        ok "Relay SMS écoute sur :7890"
    else
        warn "Relay SMS absent (port 7890)"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CHECK 3 : Matrice de connectivité inter-opérateur
# ══════════════════════════════════════════════════════════════════════════════
if [ "$HAS_INTER_STP" -eq 1 ] && [ "$N_OPS" -gt 1 ]; then
    banner "MATRICE INTER-OPÉRATEUR"

    # Header
    printf "  %-8s" ""
    for j in $(seq 1 "$N_OPS"); do printf "  Op%-3s" "$j"; done
    echo ""

    for container in "${OP_CONTAINERS[@]}"; do
        src_id="${container##*-}"
        printf "  Op%-5s" "${src_id}"

        route_out=$(vty_cmd "$container" 4239 "show cs7 instance 0 route")

        for j in $(seq 1 "$N_OPS"); do
            if [ "$j" -eq "$src_id" ]; then
                printf "  ${CYAN}%-5s${NC}" "self"
            else
                # Cherche une route vers le STP de l'opérateur j (1.j.2)
                if echo "$route_out" | grep -qE "${j}\.[0-9]+\.2.*avail"; then
                    printf "  ${GREEN}%-5s${NC}" "ok"
                elif echo "$route_out" | grep -qE "0\.0\.0/0.*avail"; then
                    printf "  ${GREEN}%-5s${NC}" "dflt"
                else
                    printf "  ${RED}%-5s${NC}" "FAIL"
                    FAIL=$((FAIL+1))
                fi
            fi
        done
        echo ""
    done
fi

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "$(printf '═%.0s' {1..60})"
TOTAL=$((PASS+FAIL+WARN+SKIP))

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
