#!/bin/bash
# osmo-start.sh — Démarrage séquencé du Core Osmocom
#
# Ordre de dépendance :
#   STP (4239) → HLR (4258) → MGW (4243)
#                    ↓
#               MSC (4254) → BSC (4242)
#                    ↓
#          GGSN (4260) → SGSN (4245) → PCU (4239 bts)
#
# Chaque service attend le VTY du précédent avant de démarrer.
# BTS-TRX et SIP-connector sont gérés par run.sh (dépendent de fake_trx / Asterisk).
#
# Appelé par : run.sh (étape 3)

set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

OPERATOR_ID="${OPERATOR_ID:-1}"

# ── Helper : attendre qu'un port TCP soit ouvert ──────────────────────────────
wait_port() {
    local host="$1" port="$2" label="$3" timeout="${4:-30}"
    local elapsed=0
    echo -ne "  Attente ${label} (${host}:${port})"
    while ! bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ── Helper : démarrer un service et vérifier ──────────────────────────────────
start_svc() {
    local svc="$1" vty_port="$2" label="$3" timeout="${4:-30}"

    echo -e "  ${CYAN}${label}${NC}"
    systemctl start "$svc" || {
        echo -e "    ${RED}✗ systemctl start ${svc} échoué${NC}"
        journalctl -u "$svc" -n 20 --no-pager >&2
        return 1
    }

    if [ -n "$vty_port" ]; then
        wait_port 127.0.0.1 "$vty_port" "$label VTY" "$timeout" || {
            echo -e "    ${YELLOW}[WARN] VTY :${vty_port} non accessible après ${timeout}s${NC}" >&2
            journalctl -u "$svc" -n 10 --no-pager >&2
            return 1
        }
    fi
}

# ══════════════════════════════════════════════════════════════════════════════

echo -e "${GREEN}=== Core Osmocom — Op${OPERATOR_ID} ===${NC}"
echo ""

# ── 1. Réseau TUN (APN0 pour GGSN) ───────────────────────────────────────────
echo -e "${CYAN}[1/4] Interface TUN${NC}"
if ip link show apn0 > /dev/null 2>&1; then
    ip link del dev apn0
fi
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set dev apn0 up
echo -e "  ${GREEN}✓${NC} apn0 up"

# ── 2. Signalisation (STP → HLR → MGW) ───────────────────────────────────────
#
# STP doit être prêt en premier : tout le SS7 passe par lui.
# HLR doit être prêt avant MSC : MSC se connecte au HLR au démarrage.
# MGW doit être prêt avant MSC : MSC ouvre un MGCP vers MGW.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}[2/4] Signalisation (STP → HLR → MGW)${NC}"

start_svc osmo-stp  4239 "OsmoSTP"  30 || true
start_svc osmo-hlr  4258 "OsmoHLR"  30 || {
    echo -e "  ${RED}[ERR] HLR indispensable pour MSC — abandon${NC}"
    exit 1
}
start_svc osmo-mgw  4243 "OsmoMGW"  20 || true

# ── 3. Core Network (MSC → BSC) ──────────────────────────────────────────────
#
# MSC doit être prêt avant BSC : BSC se connecte au MSC via A-interface.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}[3/4] Core Network (MSC → BSC)${NC}"

start_svc osmo-msc  4254 "OsmoMSC"  30 || true
start_svc osmo-bsc  4242 "OsmoBSC"  30 || true

# ── 4. Data (GGSN → SGSN → PCU) ──────────────────────────────────────────────
echo ""
echo -e "${CYAN}[4/4] Data (GGSN → SGSN → PCU)${NC}"

start_svc osmo-ggsn 4260 "OsmoGGSN" 20 || true
start_svc osmo-sgsn 4245 "OsmoSGSN" 20 || true
start_svc osmo-pcu  ""   "OsmoPCU"  0  || true
start_svc osmo-sip-connector  ""   "OsmoSIPConnector"  0  || true
sleep 0.5
chmod 777 /tmp/pcu_bts 2>/dev/null || true

# NOTE : osmo-bts-trx et osmo-sip-connector sont intentionnellement
# absents ici. run.sh les démarre dans l'ordre correct :
#   fake_trx → wait_udp 5700 → osmo-bts-trx  (évite la race condition TRX)
#   Asterisk → osmo-sip-connector             (évite le MNCC connect avant SIP UP)

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=== Vérification ===${NC}"
SERVICES="osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu"
for svc in $SERVICES; do
    if systemctl is-active --quiet "$svc"; then
        echo -e "  ${GREEN}✓${NC} ${svc}"
    else
        echo -e "  ${RED}✗${NC} ${svc}"
    fi
done

echo ""
echo -e "${GREEN}Core Osmocom prêt. BTS et SIP connector gérés par run.sh.${NC}"
