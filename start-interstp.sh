#!/bin/bash
# =============================================================================
# start-interstp.sh — lance le NŒUD INTER-STP : le hub SS7 commun au WAN
# =============================================================================
#
# Dans un lab à une seule machine, l'inter-STP est un conteneur parmi d'autres,
# à 172.20.0.10, et il ne dessert que les opérateurs de CETTE machine. Dès qu'on
# répartit les opérateurs sur plusieurs nœuds, il devient ce qu'il est vraiment :
# un équipement à part, avec sa propre adresse, auquel tous les nœuds
# s'attachent. C'est lui — et lui seul — qui fait traverser le SS7 au WAN.
#
#   noeud 1 (1.11.2) ─┐
#   noeud 2 (1.21.2) ─┼─ M3UA/SCTP 2908 ─► inter-STP 192.168.56.1  PC 0.0.0
#   noeud 3 (1.31.2) ─┘
#
# LE PLAN DE POINT CODES, ET POURQUOI IL CHANGE
# Sur une machine isolée, chaque opérateur N porte 1.N.2 — et cette formule se
# recalcule à l'identique partout. Trois nœuds attachés au même hub y
# présenteraient donc trois fois le même point code. Un point code est une
# ADRESSE : deux équipements qui partagent la leur, ce n'est pas un conflit de
# nom, c'est du routage faux. Le plan WAN encode donc le nœud dedans :
#
#     PC   = 1.<noeud><op>.<role>     role 1=MSC 2=STP 3=BSC
#     RCTX = noeud*1000 + op*100 + 50
#
# Usage :
#   sudo ./start-interstp.sh [--nodes 3] [--ops 1] [--ip 192.168.56.1]
#   sudo ./start-interstp.sh --status | --stop
#
#   --nodes N     nombre de nœuds desservis (1-9, défaut : lu dans /etc/osmo-wan.conf)
#   --ops K       opérateurs par nœud (1-9, défaut 1)
#   --ip ADRESSE  adresse du hub ; posée sur l'interface si elle manque
#   --iface NOM   interface où poser l'adresse (défaut : détectée)
#   --port N      port M3UA (défaut 2908)
#   --no-ip       ne touche pas à la configuration réseau
#   --foreground  reste au premier plan (journal à l'écran)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
CFG="${CONF_DIR}/osmo-stp-interop.cfg"
LOG="${LOG:-/var/log/osmocom/osmo-stp-interop.log}"
PIDFILE="/run/osmo-interstp.pid"

NODES=""
OPS=1
HUB_IP="192.168.56.1"
IFACE=""
PORT=2908
SET_IP=1
FOREGROUND=0
ACTION=start

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)      NODES="${2:-}"; shift ;;
        --nodes=*)    NODES="${1#*=}" ;;
        --ops)        OPS="${2:-1}"; shift ;;
        --ops=*)      OPS="${1#*=}" ;;
        --ip)         HUB_IP="${2:-}"; shift ;;
        --ip=*)       HUB_IP="${1#*=}" ;;
        --iface)      IFACE="${2:-}"; shift ;;
        --iface=*)    IFACE="${1#*=}" ;;
        --port)       PORT="${2:-2908}"; shift ;;
        --port=*)     PORT="${1#*=}" ;;
        --no-ip)      SET_IP=0 ;;
        --foreground) FOREGROUND=1 ;;
        --status)     ACTION=status ;;
        --stop)       ACTION=stop ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   Inter-STP — hub SS7 du WAN osmo_egprs   ·   PC 0.0.0           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

stp_pid() {
    if [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        cat "$PIDFILE"; return 0
    fi
    pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' | head -1
}

# ── status ───────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    banner
    pid="$(stp_pid)"
    if [ -z "$pid" ]; then
        echo -e "  ${RED}✗${NC} inter-STP arrêté"; exit 1
    fi
    echo -e "  ${GREEN}✓${NC} inter-STP actif (pid ${pid})"
    echo -e "  Écoute : $(ss -lna 2>/dev/null | grep -E "[:.]${PORT}\b" | head -3 | tr -s ' ' | cut -d' ' -f1,5 | tr '\n' ' ')"
    echo ""
    # Le VTY est la seule source de vérité sur QUI est attaché : un ASP peut
    # avoir ouvert sa SCTP sans jamais passer ASP-ACTIVE, et rien d'autre ne le
    # montre. Le port ouvert, lui, ne prouve que l'écoute.
    if command -v nc >/dev/null 2>&1; then
        echo -e "  ${BOLD}ASP attachés :${NC}"
        printf 'enable\nshow cs7 instance 0 asp\nshow cs7 instance 0 as all\nexit\n' \
            | nc -q2 127.0.0.1 4239 2>/dev/null | sed 's/^/    /' | grep -vE '^\s*$' | head -40 \
            || echo -e "    ${YELLOW}VTY 4239 muet${NC}"
    else
        echo -e "  ${YELLOW}nc absent : ${CYAN}telnet 127.0.0.1 4239${NC} puis « show cs7 instance 0 asp »"
    fi
    exit 0
fi

# ── stop ─────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "stop" ]; then
    pid="$(stp_pid)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null; sleep 1
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo -e "${GREEN}Inter-STP arrêté.${NC}"
    else
        echo -e "${YELLOW}Inter-STP déjà arrêté.${NC}"
    fi
    exit 0
fi

banner
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }
command -v osmo-stp >/dev/null 2>&1 || {
    echo -e "${RED}osmo-stp introuvable.${NC} Ce nœud doit porter la pile Osmocom." >&2; exit 1; }

# ── Combien de nœuds ? La table du WAN fait foi si elle existe ───────────────
if [ -z "$NODES" ]; then
    if [ -r "/etc/osmo-wan.conf" ]; then
        # shellcheck disable=SC1091
        . /etc/osmo-wan.conf
        NODES="${WAN_NODE_COUNT:-}"
        OPS="${WAN_OPS:-$OPS}"
        [ -n "$NODES" ] && echo -e "  Table WAN lue dans ${CYAN}/etc/osmo-wan.conf${NC} : ${NODES} nœud(s)"
    fi
    [ -z "$NODES" ] && NODES=3
fi
[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes : 1 à 9${NC}" >&2; exit 2; }
[[ "$OPS"   =~ ^[1-9]$ ]] || { echo -e "${RED}--ops : 1 à 9${NC}" >&2; exit 2; }

# ── L'adresse du hub ─────────────────────────────────────────────────────────
# Elle est écrite en dur dans la config de CHAQUE nœud : si elle manque au
# démarrage, tous les ASP échouent à s'attacher et le seul symptôme est un
# « connection refused » côté nœuds, jamais côté hub.
if [ "$SET_IP" = "1" ]; then
    if ip -4 addr show 2>/dev/null | grep -q "inet ${HUB_IP}/"; then
        echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}${NC} déjà présente sur cette machine"
    else
        if [ -z "$IFACE" ]; then
            # L'interface qui porte déjà le même /24 : c'est le segment du WAN.
            IFACE="$(ip -4 -o addr show scope global 2>/dev/null \
                | awk -v pfx="${HUB_IP%.*}." '$4 ~ "^"pfx {print $2; exit}')"
            [ -z "$IFACE" ] && IFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
        fi
        if [ -n "$IFACE" ] && ip addr add "${HUB_IP}/24" dev "$IFACE" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${CYAN}${HUB_IP}/24${NC} posée sur ${IFACE}"
        else
            echo -e "  ${YELLOW}⚠${NC} impossible de poser ${HUB_IP} (interface ${IFACE:-?})"
            echo -e "     Les nœuds ne pourront pas s'attacher tant qu'elle manque."
        fi
    fi
fi

# ── Config du hub ────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR" "$(dirname "$LOG")"
if [ ! -x "$HERE/helpers/create_interop.sh" ] && [ ! -r "$HERE/helpers/create_interop.sh" ]; then
    echo -e "${RED}helpers/create_interop.sh introuvable${NC}" >&2; exit 1
fi
bash "$HERE/helpers/create_interop.sh" --wan "$NODES" "$OPS" "$CFG" || exit 1
[ "$PORT" = "2908" ] || sed -i "s/^ listen m3ua 2908/ listen m3ua ${PORT}/" "$CFG"
echo ""

# ── Lancement ────────────────────────────────────────────────────────────────
if pid="$(stp_pid)" && [ -n "$pid" ]; then
    echo -e "  ${YELLOW}Un inter-STP tourne déjà (pid ${pid}) — arrêt puis relance.${NC}"
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
fi

echo -e "  ${BOLD}Nœuds desservis :${NC} ${NODES} × ${OPS} opérateur(s)"
for n in $(seq 1 "$NODES"); do
    for o in $(seq 1 "$OPS"); do
        printf '    noeud %s op %s → STP %s  MSC %s  BSC %s  (rctx %s)\n' \
            "$n" "$o" "1.${n}${o}.2" "1.${n}${o}.1" "1.${n}${o}.3" "$(( n*1000 + o*100 + 50 ))"
    done
done
echo ""

if [ "$FOREGROUND" = "1" ]; then
    echo -e "  ${GREEN}osmo-stp au premier plan — Ctrl-C pour arrêter${NC}"
    exec osmo-stp -c "$CFG"
fi

osmo-stp -c "$CFG" >> "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 2
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo -e "  ${GREEN}✓ inter-STP lancé${NC} — M3UA ${CYAN}${HUB_IP}:${PORT}${NC}, VTY 4239"
    echo -e "  Journal : ${CYAN}${LOG}${NC}"
    echo ""
    echo -e "  ${BOLD}Côté nœuds :${NC} leur osmo-stp doit viser ${CYAN}${HUB_IP}${NC}"
    echo -e "    ISO construite avec ${CYAN}--role operator --node N${NC} : déjà fait."
    echo -e "  ${BOLD}Vérifier qui est attaché :${NC} ${CYAN}./start-interstp.sh --status${NC}"
else
    echo -e "  ${RED}✗ osmo-stp n'a pas démarré${NC} — ${CYAN}tail -30 ${LOG}${NC}"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
    exit 1
fi
