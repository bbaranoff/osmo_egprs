#!/bin/bash
# hlr-feed-subscribers.sh
#
# Injecte les abonnés de TOUS les opérateurs dans le HLR de CHAQUE opérateur.

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MCC="${MCC:-001}"

# ── Détection des containers opérateurs ──────────────────────────────────────
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
echo -e "${GREEN}=== HLR Feed — ${N_OPS} opérateur(s) ===${NC}"

# ── N_MS et MNC par opérateur ────────────────────────────────────────────────
declare -A OP_MS OP_MNC
for i in $(seq 1 "${N_OPS}"); do
    cname="osmo-operator-${i}"
    n=$(docker exec "$cname" bash -c 'echo "${N_MS:-1}"' 2>/dev/null || echo 1)
    mnc=$(docker exec "$cname" bash -c '
        if [ -n "${MNC:-}" ]; then echo "$MNC"; exit 0; fi
        for f in /root/.osmocom/bb/mobile_ms1.cfg \
                 /root/.osmocom/bb/mobile.cfg; do
            [ -f "$f" ] || continue
            mnc=$(grep -E "^\s+rplmn " "$f" \
                  | awk "{print \$3}" | head -1)
            [ -n "$mnc" ] && echo "$mnc" && exit 0
        done
        echo "01"
    ' 2>/dev/null || echo "01")
    OP_MS[$i]="$n"
    OP_MNC[$i]="$mnc"
    echo -e "  Op${i} (${cname}) : ${n} MS  MNC=${mnc}"
done
echo ""

# ── Liste globale des abonnés ─────────────────────────────────────────────────
SUBSCRIBERS=()
for op_id in $(seq 1 "${N_OPS}"); do
    mnc="${OP_MNC[$op_id]}"
    n_ms="${OP_MS[$op_id]}"
    for ms_idx in $(seq 1 "${n_ms}"); do
        msin=$(printf '%04d%06d' "${op_id}" "${ms_idx}")
        imsi="${MCC}${mnc}${msin}"
        msisdn=$(( op_id * 10000 + ms_idx ))
        # KI sans espaces : octet 15=ms_idx, octet 16=op_id
        ki=$(printf '00112233445566778899aabbccdd%02x%02x' "${ms_idx}" "${op_id}")
        SUBSCRIBERS+=("${op_id}:${ms_idx}:${imsi}:${msisdn}:${ki}")
    done
done

total=${#SUBSCRIBERS[@]}
echo -e "${GREEN}${total} abonnés à injecter dans chaque HLR :${NC}"
for s in "${SUBSCRIBERS[@]}"; do
    IFS=':' read -r op ms imsi msisdn ki <<< "$s"
    ki_display=$(echo "$ki" | sed 's/../& /g' | sed 's/[[:space:]]*$//')
    echo -e "  Op${op}/MS${ms}  IMSI=${imsi}  MSISDN=${msisdn}  KI=${ki_display}"
done
echo ""

wait_hlr_vty() {
    local container="$1"
    local timeout=60
    local elapsed=0

    echo -ne "  Attente HLR VTY 127.0.0.1:4258 "

    while ! docker exec "$container" bash -c \
        "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            return 1
        fi
    done
    echo -e " ${GREEN}OK${NC}"
    return 0
}

inject_to_hlr() {
    local container="$1"

    echo -e "${CYAN}=== ${container} ===${NC}"

    if ! wait_hlr_vty "$container"; then
        echo -e "${RED}  HLR VTY indisponible — skip${NC}"
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${YELLOW}  [DRY-RUN] commandes VTY :${NC}"
        for s in "${SUBSCRIBERS[@]}"; do
            IFS=':' read -r _ _ imsi msisdn ki <<< "$s"
            printf "    subscriber imsi %s create\n" "$imsi"
            printf "    subscriber imsi %s update msisdn %s\n" "$imsi" "$msisdn"
            printf "    subscriber imsi %s update aud2g comp128v1 ki %s\n" "$imsi" "$ki"
        done
        return 0
    fi

    # Écrire le script VTY dans le container via stdin
    {
        echo "#!/bin/bash"
        echo "cat > /tmp/hlr_feed.vty << 'VTYCMDS'"
        echo "enable"
        for s in "${SUBSCRIBERS[@]}"; do
            IFS=':' read -r _ _ imsi msisdn ki <<< "$s"
            echo "subscriber imsi ${imsi} create"
            echo "subscriber imsi ${imsi} update msisdn ${msisdn}"
            echo "subscriber imsi ${imsi} update aud2g comp128v1 ki ${ki}"
        done
        echo "end"
        echo "VTYCMDS"
    } | docker exec -i "$container" bash

    # Envoyer le script VTY via netcat
    docker exec "$container" bash -c '
        if command -v nc >/dev/null 2>&1; then
            (sleep 1; cat /tmp/hlr_feed.vty; sleep 1) \
                | nc -q2 127.0.0.1 4258 2>/dev/null \
                | grep -vE "^(OsmoHLR|Welcome|VTY|\s*$)" \
                | sed "s/^/  /" || true
        else
            (sleep 1; cat /tmp/hlr_feed.vty; sleep 2) \
                | telnet 127.0.0.1 4258 2>/dev/null \
                | grep -vE "^(Trying|Connected|Escape|OsmoHLR|Welcome)" \
                | sed "s/^/  /" || true
        fi
        rm -f /tmp/hlr_feed.vty
    '

    echo -e "  ${GREEN}✓ ${total} abonnés injectés${NC}"
}

# ── Boucle ────────────────────────────────────────────────────────────────────
FAIL=0
for i in $(seq 1 "${N_OPS}"); do
    inject_to_hlr "osmo-operator-${i}" || FAIL=$(( FAIL + 1 ))
    echo ""
done

# ── Résumé ────────────────────────────────────────────────────────────────────
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  HLR Feed complet — ${total} abonnés × ${N_OPS} HLR${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Vérifier :"
    echo -e "  ${CYAN}docker exec osmo-operator-1 bash -c \\"
    echo -e "    'echo -e \"enable\\\\nshow subscriber all\\\\nend\" | nc -q2 127.0.0.1 4258 2>/dev/null'${NC}"
else
    echo -e "${RED}${FAIL} HLR(s) en échec. Relancer : sudo bash hlr-feed-subscribers.sh${NC}"
    exit 1
fi
