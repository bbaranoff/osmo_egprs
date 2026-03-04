#!/bin/bash
# osmo-start.sh — Démarrage synchronisé des services Osmocom (systemd)
#
# Utilisé par systemd pour lancer les services Osmocom dans un ordre cohérent
# avec dépendances explicites et vérifications d'état.
#
# Appelé par : run.sh (après boot systemd via entrypoint.sh)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_DIR="/var/log/osmocom"
mkdir -p "$LOG_DIR"

OPERATOR_ID="${OPERATOR_ID:-1}"
N_MS="${N_MS:-1}"

# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

vty_check() {
    local port=$1 name=$2 timeout=${3:-30}
    local elapsed=0
    echo -ne "  ${YELLOW}…${NC} VTY ${CYAN}:${port}${NC} (${name})"
    while [ $elapsed -lt $timeout ]; do
        if timeout 2 bash -c "echo 'help' | telnet 127.0.0.1 $port &>/dev/null"; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        echo -ne "."
    done
    echo -e " ${YELLOW}[timeout]${NC}"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Démarrage des services
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}Démarrage services Osmocom — Op${OPERATOR_ID}${NC}"
echo ""

# ─ OsmoBTS ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}1. OsmoBTS-TRX${NC}"
systemctl start osmo-bts-trx || {
    echo -e "  ${RED}✗ Démarrage échoué${NC}"; 
    journalctl -u osmo-bts-trx -n 20 >&2
    exit 1
}
vty_check 4241 "OsmoBTS" 30 || {
    echo -e "  ${YELLOW}[WARN]${NC} VTY non accessible après 30s, on continue..." >&2
}

# ─ OsmoBSC ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}2. OsmoBSC${NC}"
systemctl start osmo-bsc || {
    echo -e "  ${RED}✗ Démarrage échoué${NC}";
    journalctl -u osmo-bsc -n 20 >&2
    exit 1
}
vty_check 4242 "OsmoBSC" 30 || {
    echo -e "  ${YELLOW}[WARN]${NC} VTY non accessible après 30s, on continue..." >&2
}

# ─ OsmoMSC ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}3. OsmoMSC${NC}"
systemctl start osmo-msc || {
    echo -e "  ${RED}✗ Démarrage échoué${NC}";
    journalctl -u osmo-msc -n 20 >&2
    exit 1
}
vty_check 4254 "OsmoMSC" 30 || {
    echo -e "  ${YELLOW}[WARN]${NC} VTY non accessible après 30s, on continue..." >&2
}

# ─ OsmoHLR ───────────────────────────────────────────────────────────────────
# En mode bridge, le HLR est centralisé (127.0.0.2)
# En mode net-host (INTER_STP_IP = 127.0.0.1), lancer une instance locale
if [ "${INTER_STP_IP:-127.0.0.1}" = "127.0.0.1" ]; then
    echo -e "${CYAN}4. OsmoHLR${NC}"
    systemctl start osmo-hlr || {
        echo -e "  ${RED}✗ Démarrage échoué${NC}";
        journalctl -u osmo-hlr -n 20 >&2
        exit 1
    }
    vty_check 4258 "OsmoHLR" 30 || {
        echo -e "  ${YELLOW}[WARN]${NC} VTY non accessible après 30s, on continue..." >&2
    }
else
    echo -e "${CYAN}4. OsmoHLR${NC}"
    echo -e "  ${YELLOW}[*]${NC} Mode bridge → HLR centralisé @ 127.0.0.2 (skip local)"
fi

# ─ Asterisk (VoIP/SIP) ───────────────────────────────────────────────────────
echo -e "${CYAN}5. Asterisk (VoIP/SIP)${NC}"
if systemctl is-enabled asterisk &>/dev/null; then
    systemctl start asterisk || {
        echo -e "  ${YELLOW}[WARN]${NC} Astérisk non disponible ou échoué" >&2
    }
else
    echo -e "  ${YELLOW}[*]${NC} Astérisk désactivé"
fi

# ─ gapk-alsa (Audio GSM) ─────────────────────────────────────────────────────
echo -e "${CYAN}6. osmo-gapk (Audio GSM)${NC}"
if systemctl is-enabled gapk-alsa &>/dev/null; then
    systemctl start gapk-alsa || {
        echo -e "  ${YELLOW}[WARN]${NC} gapk-alsa non disponible ou échoué" >&2
    }
else
    echo -e "  ${YELLOW}[*]${NC} gapk-alsa désactivé (mode sans audio)"
fi

# ── SMS Relay ─────────────────────────────────────────────────────────────────
echo -e "${CYAN}7. SMS Relay${NC}"
if [ -f /etc/osmocom/sms-routing.conf ]; then
    systemctl start sms-relay || {
        echo -e "  ${YELLOW}[WARN]${NC} sms-relay non disponible" >&2
    }
else
    echo -e "  ${YELLOW}[*]${NC} sms-routing.conf absent"
fi

echo ""
echo -e "${GREEN}[✓] Services Osmocom démarrés — Op${OPERATOR_ID}${NC}"
echo ""
echo "  VTY Status :"
for svc in BTS BSC MSC HLR; do
    case "$svc" in
        BTS) port=4241 ;;
        BSC) port=4242 ;;
        MSC) port=4254 ;;
        HLR) port=4258 ;;
    esac
    if timeout 2 bash -c "echo 'help' | telnet 127.0.0.1 $port &>/dev/null"; then
        echo -e "    ${GREEN}✓${NC} ${svc} (telnet 127.0.0.1:$port)"
    else
        echo -e "    ${YELLOW}○${NC} ${svc} (démarrage en cours...)"
    fi
done

echo ""
echo "  Logs → ${LOG_DIR}/"
