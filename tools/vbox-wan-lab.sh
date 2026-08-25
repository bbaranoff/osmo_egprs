#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# tools/vbox-wan-lab.sh — N machines VirtualBox, un noeud de WAN chacune
#
# Monte un WAN complet sur une seule machine : N VM (1 à 9, 3 par défaut)
# bootent la MÊME ISO osmo_egprs, sur un réseau interne commun, et chacune se
# reconnaît comme le noeud dont l'IP est la sienne. Depuis un MS de la VM 2,
# composer <indicatif de la VM 1> + le numéro joint un MS de la VM 1.
#
# POURQUOI UNE SEULE ISO POUR N VM
# Le numéro du noeud n'est PAS figé dans l'image : la table l'est, et
# wan_nodes_detect_self compare les IP locales à cette table au démarrage.
# Une image par VM coûterait N builds d'une heure pour une ligne de conf.
#
# C'est le DHCP de VirtualBox qui rend l'IP prévisible : une adresse fixe par
# (VM, NIC), donc l'ISO retrouve toujours le même numéro de noeud. Sans ça, une
# VM changerait d'identité au gré des baux.
#
# Usage :
#   tools/vbox-wan-lab.sh create   [--nodes 3] [--iso chemin.iso] [--build-iso]
#   tools/vbox-wan-lab.sh start | stop | status | destroy
#   tools/vbox-wan-lab.sh table                 # imprime la table sans rien créer
#
# Options de create :
#   --nodes N        nombre de VM/noeuds, 1 à 9 (défaut 3)
#   --iso FICHIER    ISO à démarrer (défaut : le plus récent du dépôt)
#   --build-iso      construit l'ISO avec la table déjà dedans (sudo, long)
#   --subnet 10.66.0 préfixe /24 du réseau interne (défaut 10.66.0)
#   --ram Mo         mémoire par VM (défaut 4096)
#   --cpus N         vCPU par VM (défaut 2)
#   --indicatifs "11 22 33"   indicatifs, un par noeud (défaut 11 22 33 …)
#   --no-nat         supprime la 2e carte (NAT) — pas d'accès Internet dans les VM
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=network/wan-nodes.sh
. "$DIR/network/wan-nodes.sh"

NODES=3
SUBNET="10.66.0"
RAM=4096
CPUS=2
ISO=""
BUILD_ISO=0
WITH_NAT=1
INDS=""
NETNAME="osmowan"
VM_PREFIX="osmo-wan-"

ACTION="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --nodes)       NODES="${2:-3}"; shift ;;
        --nodes=*)     NODES="${1#*=}" ;;
        --iso)         ISO="${2:-}"; shift ;;
        --iso=*)       ISO="${1#*=}" ;;
        --build-iso)   BUILD_ISO=1 ;;
        --subnet)      SUBNET="${2:-}"; shift ;;
        --subnet=*)    SUBNET="${1#*=}" ;;
        --ram)         RAM="${2:-}"; shift ;;
        --ram=*)       RAM="${1#*=}" ;;
        --cpus)        CPUS="${2:-}"; shift ;;
        --cpus=*)      CPUS="${1#*=}" ;;
        --indicatifs)  INDS="${2:-}"; shift ;;
        --indicatifs=*) INDS="${1#*=}" ;;
        --no-nat)      WITH_NAT=0 ;;
        --net)         NETNAME="${2:-}"; shift ;;
        --net=*)       NETNAME="${1#*=}" ;;
        -h|--help)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

[[ "$NODES" =~ ^[1-9]$ ]] || { echo -e "${RED}--nodes doit valoir 1 à 9${NC}" >&2; exit 2; }

VBM="$(command -v VBoxManage || command -v vboxmanage || true)"
[ -n "$VBM" ] || { echo -e "${RED}VBoxManage introuvable — installez VirtualBox.${NC}" >&2; exit 1; }
vbm() { "$VBM" "$@" 2>&1 | grep -v 'vboxdrv\|vboxconfig\|recompile the kernel\|You will not be able\|available for the current kernel\|load. Please\|^$' || true; }

vm_name() { echo "${VM_PREFIX}$1"; }
node_ip()  { echo "${SUBNET}.$((10 + $1))"; }

# ── Table des noeuds ─────────────────────────────────────────────────────────
build_table() {
    local i ind
    local -a ind_arr=()
    [ -n "$INDS" ] && read -r -a ind_arr <<< "$INDS"
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
    for i in $(seq 1 "$NODES"); do
        ind="${ind_arr[$((i-1))]:-$(wan_default_ind "$i")}"
        WAN_IP[$i]="$(node_ip "$i")"; WAN_IND[$i]="$ind"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$NODES"; WAN_NODE_ID=1
    wan_nodes_validate || exit 1
}

find_iso() {
    local latest
    latest="$(ls -t "$DIR"/osmo_egprs-*.iso 2>/dev/null | head -1)"
    [ -n "$latest" ] && { echo "$latest"; return 0; }
    return 1
}

# ── create ───────────────────────────────────────────────────────────────────
do_create() {
    build_table
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    printf "║   Banc WAN VirtualBox — %d noeud(s), réseau interne « %-8s ║\n" "$NODES" "${NETNAME} »"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    wan_nodes_summary
    echo ""

    if [ "$BUILD_ISO" -eq 1 ]; then
        echo -e "${GREEN}[1/4] Construction de l'ISO avec la table embarquée...${NC}"
        echo -e "  ${CYAN}sudo $DIR/build-iso.sh --wan --wan-nodes \"$(wan_nodes_spec)\"${NC}"
        sudo "$DIR/build-iso.sh" --wan --wan-nodes "$(wan_nodes_spec)" \
            || { echo -e "${RED}build-iso.sh a échoué${NC}"; exit 1; }
        ISO="$(find_iso)" || { echo -e "${RED}ISO introuvable après build${NC}"; exit 1; }
    elif [ -z "$ISO" ]; then
        ISO="$(find_iso)" || {
            echo -e "${RED}Aucune ISO. Passez --iso chemin.iso, ou --build-iso.${NC}" >&2; exit 1; }
        echo -e "${GREEN}[1/4] ISO : ${CYAN}${ISO}${NC}"
        echo -e "  ${YELLOW}Vérifiez qu'elle a été construite avec --wan et CETTE table,${NC}"
        echo -e "  ${YELLOW}sinon les VM démarreront sans WAN (start-direct.sh --wan à la main).${NC}"
    else
        echo -e "${GREEN}[1/4] ISO : ${CYAN}${ISO}${NC}"
    fi
    [ -r "$ISO" ] || { echo -e "${RED}ISO illisible : $ISO${NC}" >&2; exit 1; }

    # ── Réseau interne + DHCP à adresses fixes ──────────────────────────────
    echo -e "${GREEN}[2/4] Réseau interne « ${NETNAME} » + DHCP...${NC}"
    if "$VBM" list dhcpservers 2>/dev/null | grep -q "NetworkName:.*${NETNAME}"; then
        vbm dhcpserver modify --network="$NETNAME" \
            --server-ip="${SUBNET}.1" --netmask=255.255.255.0 \
            --lower-ip="${SUBNET}.100" --upper-ip="${SUBNET}.200" --enable
    else
        vbm dhcpserver add --network="$NETNAME" \
            --server-ip="${SUBNET}.1" --netmask=255.255.255.0 \
            --lower-ip="${SUBNET}.100" --upper-ip="${SUBNET}.200" --enable
    fi
    echo -e "  ${GREEN}✓${NC} DHCP ${SUBNET}.1 sur ${NETNAME}"

    # ── VM ──────────────────────────────────────────────────────────────────
    echo -e "${GREEN}[3/4] Création des ${NODES} VM...${NC}"
    for i in $(seq 1 "$NODES"); do
        local vm; vm="$(vm_name "$i")"
        if "$VBM" list vms 2>/dev/null | grep -q "\"${vm}\""; then
            echo -e "  ${YELLOW}⚠${NC} ${vm} existe déjà — ignorée (destroy pour repartir à neuf)"
            continue
        fi
        vbm createvm --name "$vm" --ostype Ubuntu_64 --register
        vbm modifyvm "$vm" --memory "$RAM" --cpus "$CPUS" --ioapic on \
            --boot1 dvd --boot2 disk --boot3 none --boot4 none \
            --audio-driver none --graphicscontroller vmsvga --vram 32 \
            --nested-hw-virt on
        # NIC1 = le WAN. C'est CETTE carte que la table adresse.
        vbm modifyvm "$vm" --nic1 intnet --intnet1 "$NETNAME" --nictype1 virtio
        if [ "$WITH_NAT" -eq 1 ]; then
            # NIC2 = NAT : sortie Internet (apt, osmo-update) et redirection SSH
            # depuis l'hôte. Elle ne porte AUCUN trafic WAN — son 10.0.2.15
            # n'est pas dans la table, donc la détection de noeud ne s'y trompe pas.
            vbm modifyvm "$vm" --nic2 nat --nictype2 virtio
            vbm modifyvm "$vm" --natpf2 "ssh${i},tcp,127.0.0.1,$((2220 + i)),,22"
        fi
        vbm storagectl "$vm" --name IDE --add ide
        vbm storageattach "$vm" --storagectl IDE --port 0 --device 0 --type dvddrive --medium "$ISO"
        # Adresse fixe : c'est elle qui donne son IDENTITÉ au noeud.
        vbm dhcpserver modify --network="$NETNAME" --vm="$vm" --nic=1 \
            --fixed-address="$(node_ip "$i")" \
            || echo -e "  ${YELLOW}⚠${NC} adresse fixe refusée pour ${vm} — VirtualBox < 6.1 ?"
        echo -e "  ${GREEN}✓${NC} ${vm}  ${CYAN}$(node_ip "$i")${NC}  indicatif ${CYAN}${WAN_IND[$i]}${NC}$([ "$WITH_NAT" -eq 1 ] && echo "  ssh 127.0.0.1:$((2220 + i))")"
    done

    echo -e "${GREEN}[4/4] Prêt.${NC}"
    if ! lsmod 2>/dev/null | grep -q '^vboxdrv'; then
        echo ""
        echo -e "  ${YELLOW}vboxdrv n'est pas chargé : les VM sont créées mais ne démarreront pas.${NC}"
        echo -e "  ${CYAN}sudo /sbin/vboxconfig${NC}  (recompile le module pour le noyau courant)"
    fi
    do_hint
}

do_hint() {
    build_table
    echo ""
    echo -e "  ${BOLD}Démarrer :${NC} ${CYAN}$0 start${NC}"
    echo ""
    echo -e "  ${BOLD}Dans chaque VM (autologin root) :${NC}"
    echo -e "    ${CYAN}/opt/osmo_egprs/start-direct.sh${NC}"
    echo -e "    → la table WAN figée dans l'ISO est appliquée toute seule (WAN_AUTO=1)."
    echo -e "    → sans ISO --wan : ${CYAN}/opt/osmo_egprs/start-direct.sh --wan${NC}"
    echo ""
    echo -e "  ${BOLD}Appeler d'un noeud à l'autre :${NC}"
    local a b
    a="${WAN_NODE_LIST[0]}"; b="${WAN_NODE_LIST[$(( ${#WAN_NODE_LIST[@]} > 1 ? 1 : 0 ))]}"
    echo -e "    depuis un MS du noeud ${a} : ${CYAN}${WAN_IND[$b]}10001${NC} → MS 10001 du noeud ${b}"
    echo -e "    SMS : même numérotation (${CYAN}${WAN_IND[$b]}10001${NC})"
    echo ""
    echo -e "  ${BOLD}Diagnostic dans une VM :${NC} ${CYAN}/opt/osmo_egprs/checks/wan_ss7_check.sh${NC}"
    echo ""
}

do_each() {  # $1 = commande vboxmanage sur chaque VM existante
    local i vm found=0
    for i in $(seq 1 9); do
        vm="$(vm_name "$i")"
        "$VBM" list vms 2>/dev/null | grep -q "\"${vm}\"" || continue
        found=1
        case "$1" in
            start)   vbm startvm "$vm" --type headless && echo -e "  ${GREEN}▶${NC} ${vm}" ;;
            stop)    vbm controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || true
                     echo -e "  ${YELLOW}■${NC} ${vm}" ;;
            destroy) vbm controlvm "$vm" poweroff >/dev/null 2>&1 || true
                     sleep 1
                     vbm unregistervm "$vm" --delete >/dev/null 2>&1 || true
                     echo -e "  ${RED}✗${NC} ${vm} supprimée" ;;
            status)
                    local st; st="$("$VBM" showvminfo "$vm" --machinereadable 2>/dev/null | awk -F'"' '/^VMState=/{print $2}')"
                    printf '  %-14s %-10s %s\n' "$vm" "${st:-?}" "$(node_ip "$i")" ;;
        esac
    done
    [ "$found" = "1" ] || echo -e "  ${YELLOW}aucune VM ${VM_PREFIX}* — lancez « $0 create »${NC}"
}

case "$ACTION" in
    create)  do_create ;;
    start)   echo -e "${GREEN}Démarrage...${NC}"; do_each start ;;
    stop)    echo -e "${YELLOW}Arrêt...${NC}";    do_each stop ;;
    destroy) echo -e "${RED}Suppression...${NC}"; do_each destroy
             vbm dhcpserver remove --network="$NETNAME" >/dev/null 2>&1 || true ;;
    status)  echo -e "${BOLD}VM du banc WAN :${NC}"; do_each status ;;
    table)   build_table; wan_nodes_summary
             echo ""; echo "  --wan-nodes \"$(wan_nodes_spec)\"" ;;
    ""|-h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo -e "${RED}action inconnue : $ACTION${NC}" >&2; exit 2 ;;
esac
