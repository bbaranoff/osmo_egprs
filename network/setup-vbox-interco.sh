#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/setup-vbox-interco.sh — interconnexion WAN entre CETTE machine et des
# VM VirtualBox, sur un seul PC
#
# Le WAN d'osmo_egprs relie des machines par leur IP publique. Pour l'éprouver
# sans louer N serveurs, on remplace les pairs distants par des VM et le lien
# public par un segment host-only : la maquette est la même, les adresses sont
# locales.
#
#   ┌─ cette machine ────────────┐        ┌─ VM osmo-wan-2 ─┐  ┌─ VM osmo-wan-3 ─┐
#   │ lab docker ou natif        │        │ ISO osmo_egprs  │  │ ISO osmo_egprs  │
#   │ noeud 1 · indicatif 11     │        │ noeud 2 · 22    │  │ noeud 3 · 33    │
#   └──────────┬─────────────────┘        └────────┬────────┘  └────────┬────────┘
#              │ vboxnet0 192.168.56.11            │ .12                │ .13
#              └───────────────── segment host-only ───────────────────┘
#
# POURQUOI HOST-ONLY ET PAS « RÉSEAU INTERNE »
# Un réseau interne relie les VM ENTRE ELLES et laisse l'hôte dehors. Or ici
# l'hôte est lui-même un noeud : sans patte sur le segment, son lab ne peut pas
# joindre ses pairs, et rien ne le signale — les trunks restent simplement
# « Unavailable ». Le host-only est le seul mode où l'hôte participe.
#
# LA CONTRAINTE À CONNAÎTRE
# VirtualBox refuse toute plage host-only hors 192.168.56.0/21 tant que
# /etc/vbox/networks.conf ne l'autorise pas. D'où ce préfixe par défaut.
#
# Usage :
#   sudo network/setup-vbox-interco.sh [--nodes N] [--host-node 1]
#                                      [--subnet 192.168.56] [--iso f.iso]
#                                      [--build-iso] [--no-vms] [--indicatifs "11 22"]
#
# Écrit la table dans /etc/osmo-wan.conf, prête pour --wan.
# Appelé automatiquement par : start.sh --virtualbox  /  start-direct.sh --virtualbox
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$DIR/tools/vbox-wan-lab.sh"
# shellcheck source=network/wan-nodes.sh
. "$DIR/network/wan-nodes.sh"

NODES=""
HOST_NODE=1
SUBNET="192.168.56"
ISO=""
BUILD_ISO=0
NO_VMS=0
INDS=""
PASSTHRU=()

while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)       NODES="${2:-}"; shift ;;
        --nodes=*)     NODES="${1#*=}" ;;
        --host-node)   HOST_NODE="${2:-}"; shift ;;
        --host-node=*) HOST_NODE="${1#*=}" ;;
        --subnet)      SUBNET="${2:-}"; shift ;;
        --subnet=*)    SUBNET="${1#*=}" ;;
        --iso)         ISO="${2:-}"; shift ;;
        --iso=*)       ISO="${1#*=}" ;;
        --build-iso)   BUILD_ISO=1 ;;
        --no-vms)      NO_VMS=1 ;;
        --indicatifs)  INDS="${2:-}"; shift ;;
        --indicatifs=*) INDS="${1#*=}" ;;
        --conf)        WAN_CONF_FILE="${2:-}"; shift ;;
        --conf=*)      WAN_CONF_FILE="${1#*=}" ;;
        -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PASSTHRU+=("$1") ;;   # transmis tel quel au banc (--ram, --usb-filter…)
    esac
    shift
done

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   Interconnexion WAN — cette machine + VM VirtualBox             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Garde-fous ───────────────────────────────────────────────────────────────
# Lancé DANS une VM, ce script ne peut rien faire d'utile et ses messages
# d'erreur ne le diraient pas : VBoxManage y est simplement absent.
if command -v systemd-detect-virt >/dev/null 2>&1; then
    _virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    case "$_virt" in
        oracle|kvm|qemu|vmware|microsoft)
            echo -e "${RED}Vous êtes DANS une machine virtuelle (${_virt}).${NC}" >&2
            echo -e "  L'interconnexion VirtualBox se monte depuis l'HÔTE." >&2
            echo -e "  Ici, le WAN se configure normalement : ${CYAN}./start-direct.sh --wan${NC}" >&2
            exit 1 ;;
    esac
fi

VBM="$(command -v VBoxManage || command -v vboxmanage || true)"
if [ -z "$VBM" ]; then
    echo -e "${RED}VBoxManage introuvable — VirtualBox n'est pas installé.${NC}" >&2
    exit 1
fi
if ! grep -q '^vboxdrv ' /proc/modules 2>/dev/null; then
    echo -e "${RED}Le module vboxdrv n'est pas chargé : aucune VM ne démarrera.${NC}" >&2
    echo -e "  ${CYAN}sudo /sbin/vboxconfig${NC}" >&2
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -i enabled >/dev/null; then
        echo -e "  ${YELLOW}Secure Boot actif : le module doit être signé et sa clé enrôlée (MOK).${NC}" >&2
    fi
    exit 1
fi
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis (interface réseau + /etc/osmo-wan.conf).${NC}" >&2; exit 1; }

# ── Combien de noeuds ────────────────────────────────────────────────────────
if [ -z "$NODES" ]; then
    if [ -t 0 ]; then
        # Même question que ./start.sh --wan, même bornes.
        NODES=$(_wan_ask "WAN VirtualBox" "Nombre de noeuds au total, cette machine comprise (1-9) :" "3") || exit 1
    else
        NODES=3
    fi
fi
[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes doit valoir 1 à 9${NC}" >&2; exit 2; }
[[ "$HOST_NODE" =~ ^[1-9]$ ]] && [ "$HOST_NODE" -le "$NODES" ] \
    || { echo -e "${RED}--host-node doit désigner un noeud de 1 à ${NODES}${NC}" >&2; exit 2; }

# ── Plage autorisée ? ────────────────────────────────────────────────────────
if [ "$SUBNET" != "192.168.56" ] && ! grep -q "${SUBNET}" /etc/vbox/networks.conf 2>/dev/null; then
    echo -e "${YELLOW}Attention : VirtualBox n'autorise que 192.168.56.0/21 en host-only.${NC}"
    echo -e "  Pour ouvrir ${SUBNET}.0/24 : ${CYAN}echo '* ${SUBNET}.0/24' | sudo tee -a /etc/vbox/networks.conf${NC}"
    echo ""
fi

# ── Table des noeuds ─────────────────────────────────────────────────────────
declare -a ind_arr=()
[ -n "$INDS" ] && read -r -a ind_arr <<< "$INDS"
WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
for i in $(seq 1 "$NODES"); do
    # Noeud N → .1N, sans exception pour l'hôte : la table se lit d'un coup
    # d'oeil et le numéro de noeud se retrouve dans l'adresse.
    WAN_IP[$i]="${SUBNET}.$((10 + i))"
    WAN_IND[$i]="${ind_arr[$((i-1))]:-$(wan_default_ind "$i")}"
    WAN_NODE_LIST+=("$i")
done
WAN_NODE_COUNT="$NODES"
WAN_NODE_ID="$HOST_NODE"
WAN_OPS="${WAN_OPS:-1}"
wan_nodes_validate || exit 1

echo -e "  Cette machine porte le ${BOLD}noeud ${HOST_NODE}${NC} ; les autres sont des VM."
wan_nodes_summary
echo ""

# ── Le banc de VM fait le reste : réseau host-only, DHCP fixe, matériel ──────
if [ "$NO_VMS" -eq 1 ]; then
    echo -e "  ${YELLOW}--no-vms : ni réseau ni VM créés, seule la table est écrite.${NC}"
else
    [ -x "$LAB" ] || { echo -e "${RED}tools/vbox-wan-lab.sh introuvable${NC}" >&2; exit 1; }
    lab_args=(create --nodes "$NODES" --host-node "$HOST_NODE" --subnet "$SUBNET"
              --indicatifs "$(for i in "${WAN_NODE_LIST[@]}"; do printf '%s ' "${WAN_IND[$i]}"; done)")
    [ -n "$ISO" ]          && lab_args+=(--iso "$ISO")
    [ "$BUILD_ISO" -eq 1 ] && lab_args+=(--build-iso)
    bash "$LAB" "${lab_args[@]}" ${PASSTHRU[@]+"${PASSTHRU[@]}"} || {
        echo -e "${RED}La création du banc a échoué.${NC}" >&2; exit 1; }
fi

# ── Table persistée ──────────────────────────────────────────────────────────
# WAN_AUTO=0 côté hôte : ici c'est start.sh / start-direct.sh qui décide quand
# monter le WAN. Les ISO des VM, elles, sont construites avec WAN_AUTO=1.
WAN_AUTO=0 wan_nodes_save "$WAN_CONF_FILE"
echo -e "  ${GREEN}✓${NC} table écrite dans ${CYAN}${WAN_CONF_FILE}${NC}"
echo ""
echo -e "  ${BOLD}Ensuite, sur cette machine :${NC}"
echo -e "    ${CYAN}sudo ./start.sh --wan${NC}          (le lab docker devient le noeud ${HOST_NODE})"
echo -e "    ${CYAN}tools/vbox-wan-lab.sh start${NC}    (démarre les VM)"
echo ""
