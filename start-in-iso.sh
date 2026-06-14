#!/bin/bash
# start-in-iso.sh — lancement NATIF (hors docker) du lab osmo_egprs sur l'ISO.
#
#   1) IP1 = IPv4 DHCP de l'interface de la route par defaut
#      IP2 = IP1 avec le 3e octet +1, ajoutee en alias sur le meme NIC
#   2) Injection des configs au RUN via apply_config_templates (logique start.sh),
#      avec notre IP en exception : 127.0.0.1 -> IP1, 127.0.0.2 -> IP2
#   3) exec /etc/osmocom/run.sh  -> osmo-start.sh (core via systemctl) +
#      PHY (faketrx/virtphy) + mobile + asterisk + smsc (tmux)
#
# Tout est natif : aucun conteneur Docker n'est lance.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"   # /opt/osmo_egprs
cd "$DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${CYAN}[start-in-iso]${NC} $*"; }

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1) Logique IP : IP1 = DHCP, IP2 = IP1 (3e octet +1) en alias
# ─────────────────────────────────────────────────────────────────────────────
NIC="${OSMO_NIC:-}"
[ -z "$NIC" ] && NIC=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
[ -z "$NIC" ] && NIC=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')

IP1=""; PREFIX=""
for _ in $(seq 1 45); do
    line=$(ip -4 -o addr show dev "$NIC" scope global 2>/dev/null | awk '{print $4; exit}')
    IP1="${line%%/*}"; PREFIX="${line##*/}"
    [ -n "$IP1" ] && break
    sleep 1
done
if [ -z "$IP1" ]; then
    echo -e "${YELLOW}Pas d'IPv4 DHCP sur ${NIC} — repli sur loopback (127.0.0.1/127.0.0.2).${NC}"
    IP1="127.0.0.1"; IP2="127.0.0.2"; PREFIX=8
else
    [ -z "$PREFIX" ] && PREFIX=24
    IFS=. read -r o1 o2 o3 o4 <<<"$IP1"
    o3p=$((o3 + 1)); [ "$o3p" -gt 255 ] && o3p=$((o3 - 1))
    IP2="$o1.$o2.$o3p.$o4"
    if ip -4 -o addr show dev "$NIC" | grep -qw "$IP2"; then
        log "IP2 ${IP2} deja presente sur ${NIC}"
    else
        ip addr add "$IP2/$PREFIX" dev "$NIC" 2>/dev/null \
            && log "IP2 ${IP2}/${PREFIX} ajoutee sur ${NIC}" \
            || echo -e "${YELLOW}echec ajout IP2 ${IP2} (continue)${NC}"
    fi
fi
log "IP1=${CYAN}${IP1}${NC}  IP2=${CYAN}${IP2}${NC}  (NIC=${NIC})"

# ─────────────────────────────────────────────────────────────────────────────
# 2) Injection des configs via apply_config_templates (lib de start.sh)
# ─────────────────────────────────────────────────────────────────────────────
# Globals attendus par apply_config_templates
export ENCRYPTION="${ENCRYPTION:-a5 0}"
export HOST_IP="$IP1"
export ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
export ALSA_INPUT="${ALSA_INPUT:-default}"
export PHY_MODE="${PHY_MODE:-faketrx}"

# Charge UNIQUEMENT la bibliotheque de fonctions de start.sh (apply_config_templates
# + helpers op_*/linphone_*/generate_*), sans executer l'orchestration docker.
# Memes marqueurs de coupe que build-iso.sh:load_start_lib.
LIB="$(mktemp)"
awk '
    /^banner[[:space:]]*$/                    { exit }
    /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
    /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
    /^choose_network_mode[[:space:]]*$/       { exit }
    /^\.\//                                   { exit }
    /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
    { print }
' "$DIR/start.sh" > "$LIB"
# shellcheck disable=SC1090
source "$LIB"

if ! declare -f apply_config_templates >/dev/null 2>&1; then
    echo -e "${RED}apply_config_templates introuvable dans start.sh — abort.${NC}"; exit 1
fi

TMP="$(mktemp -d)"
# IP1 pour container/gateway/host/inter-stp ; op 1, MCC 001 MNC 01.
apply_config_templates "$TMP" \
    "$IP1" "$IP1" \
    "1" "1.1.1" "1.1.2" "1.1.3" \
    "001" "01" "OsmoGSM" \
    "$IP1" "shutdown" "1"

# Deploiement : on copie les CONFIGS uniquement (pas les scripts, pour ne pas
# ecraser le run.sh/osmo-start.sh deja en place et patches dans l'ISO).
mkdir -p /etc/osmocom /etc/asterisk /root/.osmocom/bb
cp -f "$TMP"/osmocom/*.cfg  /etc/osmocom/        2>/dev/null || true
cp -f "$TMP"/asterisk/*.conf /etc/asterisk/      2>/dev/null || true
cp -f "$TMP"/bb/*.cfg       /root/.osmocom/bb/   2>/dev/null || true

# Exception IP : remap des adresses loopback restantes (litterales + __HLR_IP__
# code en dur a 127.0.0.2 dans apply_config_templates) vers IP1/IP2.
for f in /etc/osmocom/*.cfg /etc/asterisk/*.conf /root/.osmocom/bb/*.cfg; do
    [ -f "$f" ] || continue
    sed -i -e "s/\b127\.0\.0\.2\b/$IP2/g" -e "s/\b127\.0\.0\.1\b/$IP1/g" "$f"
done
rm -rf "$TMP" "$LIB"
log "configs injectees dans /etc/osmocom + /etc/asterisk (IP1/IP2 appliquees)"

# ─────────────────────────────────────────────────────────────────────────────
# 3) Lancement natif de la stack (core systemctl + PHY/mobile/asterisk tmux)
# ─────────────────────────────────────────────────────────────────────────────
export OPERATOR_ID="${OPERATOR_ID:-1}"
RUN="/etc/osmocom/run.sh"; [ -x "$RUN" ] || RUN="$DIR/scripts/run.sh"
log "lancement natif via ${RUN} (PHY=${PHY_MODE})"
exec "$RUN"
