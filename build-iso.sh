#!/bin/bash
# build-iso.sh - Genere une ISO bootable en utilisant build.sh et start.sh
# Aucun docker build direct dans ce script, tout passe par les scripts existants.
set -euo pipefail

# Couleurs definies AVANT tout : sous `set -u`, la premiere ligne coloree d'un
# script qui les declare plus bas echoue sur "variable sans liaison" - et le
# message ne parle ni de couleurs ni de l'endroit fautif.
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

VERSION="${OSMO_ISO_VERSION:-v2}"
OUTPUT="osmo_egprs-${VERSION}.iso"
# Repertoire de travail SUR DISQUE (pas /tmp, souvent un tmpfs en RAM -> "No
# space left on device" car le rootfs est volumineux). Overridable via OSMO_ISO_WORK.
WORK="${OSMO_ISO_WORK:-/var/tmp}/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS_V2"
DIR="$(cd "$(dirname "$0")" && pwd)"

NO_CACHE=""
# ── WAN : jamais par defaut. Avec --wan, l'ISO EST un noeud du WAN ───────────
# La table est figee dans /etc/osmo-wan.conf de l'image ; au demarrage
# start-direct.sh la voit (WAN_AUTO=1) et l'applique sans qu'on repasse --wan.
#
# UNE SEULE ISO pour les N machines : chacune se reconnait a son IP dans la
# table (wan_nodes_detect_self). --wan-id ne sert qu'a forcer un noeud quand
# l'IP ne suffit pas (DHCP non fixe, NAT).
ISO_WAN=0
ISO_WAN_NODES=""
ISO_WAN_ID=""
ISO_WAN_OPS=1

# ── ROLE DE L'IMAGE ──────────────────────────────────────────────────────────
# Une seule chaine de construction, deux produits :
#
#   --role operator --node N   →  osmo-operator-N.iso
#       Un noeud du WAN : coeur GSM complet, ses point codes a lui, son ASP
#       attache au hub. C'est l'image historique, plus l'identite de noeud.
#
#   --role interstp            →  interstp.iso
#       Le hub SS7 : PC 0.0.0, aucun operateur, il ne fait QUE router du M3UA
#       entre les noeuds. C'est ce qui manquait pour que le SS7 traverse le WAN.
#
# Sans --role, rien ne change : on produit l'ISO d'avant, sous son nom d'avant.
ISO_ROLE=""
ISO_ROLE_GIVEN=0
ISO_NODE=""
# Defaut : le hub du banc, en acces par pont. Le host-only VirtualBox
# (192.168.56.1) reste possible, mais via --hub-ip : il n'existe sur aucun
# segment quand les VM sont pontees.
ISO_HUB_IP="192.168.1.49"
ISO_SUBNET="192.168.56"
# ── Table WAN par defaut : le banc ──────────────────────────────────────────
# Format : <noeud>:<IP>:<indicatif>
#   hub 192.168.1.49    noeud 1 .2    noeud 2 .175    noeud 3 .126
# Elle sert quand --wan-nodes n'est pas donne. Sans defaut, une construction
# sans terminal - la CI - s'arretait a l'etape 7b sur une question que personne
# ne lisait : "pas de terminal : renseignez WAN_NODES / WAN_NODE_ID / WAN_OPS".
ISO_WAN_NODES_DEFAULT="1:192.168.1.2:11 2:192.168.1.175:22 3:192.168.1.126:33"
OUTPUT_SET=0
for arg in "$@"; do case "$arg" in
    --output=*)     OUTPUT="${arg#*=}"; OUTPUT_SET=1 ;;
    --no-cache)     NO_CACHE="--no-cache" ;;
    --wan)          ISO_WAN=1 ;;
    --wan-nodes=*)  ISO_WAN=1; ISO_WAN_NODES="${arg#*=}" ;;
    --wan-id=*)     ISO_WAN=1; ISO_WAN_ID="${arg#*=}" ;;
    --wan-ops=*)    ISO_WAN=1; ISO_WAN_OPS="${arg#*=}" ;;
    --role=*)       ISO_ROLE="${arg#*=}"; ISO_ROLE_GIVEN=1 ;;
    --node=*)       ISO_NODE="${arg#*=}" ;;
    --hub-ip=*)     ISO_HUB_IP="${arg#*=}" ;;
    --subnet=*)     ISO_SUBNET="${arg#*=}" ;;
    --kb=*)         OSMO_ISO_KB="${arg#*=}" ;;
esac; done

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# LES QUESTIONS : toutes ici, une seule fois, avant que quoi que ce soit ne parte
# ══════════════════════════════════════════════════════════════════════════════
# Une question posee au milieu d'une construction d'une heure attend un humain
# qui, lui, est parti. Et posee dans l'IMAGE - au premier boot - elle bloque
# chaque machine qui demarre, alors que la reponse est la meme pour toutes.
#
# Tout ce qui se demande se demande donc ICI :
#   - avant la construction, pour ne jamais interrompre une passe en cours ;
#   - une seule fois, meme quand on produit les DEUX images : la reponse part
#     dans l'environnement (export), et les passes filles en heritent ;
#   - jamais en CI : sans terminal, on prend le defaut au lieu d'attendre un
#     EOF qui, sous set -e, ferait echouer la construction.
#
# --kb=XX ou OSMO_ISO_KB=XX court-circuitent la question.
ISO_KB_DEFAULT="fr"
if [ -z "${OSMO_ISO_KB:-}" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}══ Clavier de l'image ══${NC}"
        echo "  1) fr   2) us   3) de   4) es   5) it"
        echo "  6) pt   7) gb   8) be   9) ch   0) autre"
        read -rp "  Choix [1] : " _kb_choice || _kb_choice=""
        case "${_kb_choice:-1}" in
            1|"") OSMO_ISO_KB="fr" ;;
            2) OSMO_ISO_KB="us" ;;  3) OSMO_ISO_KB="de" ;;
            4) OSMO_ISO_KB="es" ;;  5) OSMO_ISO_KB="it" ;;
            6) OSMO_ISO_KB="pt" ;;  7) OSMO_ISO_KB="gb" ;;
            8) OSMO_ISO_KB="be" ;;  9) OSMO_ISO_KB="ch" ;;
            0) read -rp "  Layout (fr, us, ru, ar...) : " OSMO_ISO_KB || OSMO_ISO_KB=""
               OSMO_ISO_KB="${OSMO_ISO_KB:-$ISO_KB_DEFAULT}" ;;
            *) OSMO_ISO_KB="$ISO_KB_DEFAULT" ;;
        esac
    else
        OSMO_ISO_KB="$ISO_KB_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : clavier ${OSMO_ISO_KB} (--kb=XX pour changer)${NC}"
    fi
fi
export OSMO_ISO_KB
echo -e "  ${GREEN}✓${NC} clavier de l'image : ${CYAN}${OSMO_ISO_KB}${NC}"

# ── Sans argument : LES DEUX images ─────────────────────────────────────────
# Un WAN a besoin de deux choses differentes - un hub SS7 et des noeuds - et
# rien ne dit laquelle on veut quand on ne precise rien. On produit donc les
# deux, par deux passes completes.
#
# UNE SEULE image d'operateur suffit pour les neuf noeuds : le numero se choisit
# au demarrage (`start-direct.sh --node N`), qui reecrit les point codes. C'est
# la raison pour laquelle on ne fabrique pas osmo-operator-1..9.
#
# Le hub d'abord : il ne depend ni de build.sh ni de l'image osmocom-run, donc
# un echec de son cote se voit en quelques minutes au lieu d'une heure.
if [ "$ISO_ROLE_GIVEN" = "0" ] && [ "$OUTPUT_SET" = "0" ] && [ -z "$ISO_NODE" ]; then
    echo -e "${CYAN}${BOLD}══ Aucun role demande : construction des DEUX images ══${NC}"
    echo -e "  1. ${CYAN}interstp.iso${NC}       le hub SS7 (PC 0.0.0)"
    echo -e "  2. ${CYAN}osmo-operator.iso${NC}  un noeud - son numero se choisit au demarrage :"
    echo -e "     ${CYAN}./start-direct.sh --node N${NC}   (N de 1 a 9)"
    echo ""
    "$0" --role=interstp "$@" || { echo -e "${RED}Echec de interstp.iso${NC}" >&2; exit 1; }
    "$0" --role=operator --output=osmo-operator.iso "$@" \
        || { echo -e "${RED}Echec de osmo-operator.iso${NC}" >&2; exit 1; }
    echo -e "${GREEN}${BOLD}═══ Les deux images sont pretes ═══${NC}"
    ls -lh "$(pwd)/interstp.iso" "$(pwd)/osmo-operator.iso" 2>/dev/null | sed 's/^/  /'
    exit 0
fi

case "${ISO_ROLE:-operator}" in
    interstp)
        ISO_ROLE="interstp"
        [ "$OUTPUT_SET" = "1" ] || OUTPUT="interstp.iso"
        # Le hub dessert N noeuds : sans table WAN on ne sait pas combien.
        ISO_WAN=1 ;;
    operator|"")
        ISO_ROLE="operator"
        if [ -n "$ISO_NODE" ]; then
            [[ "$ISO_NODE" =~ ^[1-9]$ ]] || { echo "--node : 1 a 9" >&2; exit 2; }
            [ "$OUTPUT_SET" = "1" ] || OUTPUT="osmo-operator-${ISO_NODE}.iso"
            ISO_WAN_ID="${ISO_WAN_ID:-$ISO_NODE}"
            ISO_WAN=1
        fi ;;
    *) echo "--role inconnu : $ISO_ROLE (operator|interstp)" >&2; exit 2 ;;
esac
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac

# ── La table WAN : arretee ICI, pas au milieu de la construction ────────────
# --role=interstp implique le WAN (le hub doit savoir combien de noeuds il
# dessert). L'etape 7b la demandait alors interactivement, une heure apres le
# lancement : de quoi bloquer une construction que l'on croyait autonome, et
# faire echouer la CI, qui n'a pas de terminal pour repondre.
#
# On la fige donc maintenant, avec la table du banc pour defaut. --wan-nodes
# reste prioritaire et n'est pas touche.
# Avec terminal on DEMANDE - un banc n'a pas toujours les adresses du notre.
# Sans terminal (CI, cron) on prend le defaut : rester bloque sur une lecture
# que personne ne verra ne ferait qu'echouer plus tard, et plus obscurement.
if [ "$ISO_WAN" = "1" ] && [ -z "$ISO_WAN_NODES" ]; then
    if [ -t 0 ]; then
        echo -e "${CYAN}${BOLD}== Table WAN de l'image ==${NC}"
        echo -e "  Format : ${CYAN}<noeud>:<IP>:<indicatif>${NC}, separes par des espaces."
        echo -e "  Entree vide = le banc : ${CYAN}${ISO_WAN_NODES_DEFAULT}${NC}"
        read -rp "  Noeuds : " _wan_in || _wan_in=""
        ISO_WAN_NODES="${_wan_in:-$ISO_WAN_NODES_DEFAULT}"
        if [ "$ISO_ROLE" = "interstp" ]; then
            read -rp "  IP du hub [${ISO_HUB_IP}] : " _hub_in || _hub_in=""
            ISO_HUB_IP="${_hub_in:-$ISO_HUB_IP}"
        fi
    else
        ISO_WAN_NODES="$ISO_WAN_NODES_DEFAULT"
        echo -e "  ${YELLOW}Pas de terminal : table WAN par defaut${NC}"
    fi
    echo -e "  ${GREEN}✓${NC} WAN : ${CYAN}${ISO_WAN_NODES}${NC}   hub ${CYAN}${ISO_HUB_IP}${NC}"
fi

# Propage --no-cache aux deux builds Docker : build.sh (image osmocom-nitb) et
# build_run_image (image osmocom-run, via DOCKER_NO_CACHE).
export DOCKER_NO_CACHE="$NO_CACHE"


cleanup() { umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT


# ── Paquets hote requis pour fabriquer l'ISO (squashfs, grub, xorriso...) ──
# Installes ici plutot que dans le workflow CI : `sudo ./build-iso.sh` suffit
# sur une machine Debian/Ubuntu vierge, sans etape "Install host tools" externe.
ISO_HOST_PKGS="squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools debootstrap git isolinux"
if command -v apt-get &>/dev/null; then
    echo -e "${GREEN}[0/9] Installation des paquets hote (apt)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    # Options passees EN LIGNE, pas via /etc/apt : on est sur la machine de
    # l'utilisateur, pas dans un rootfs jetable. On allege ce qui est telecharge
    # (traductions) sans toucher aux garanties d'ecriture de son dpkg.
    HOST_APT_FAST="-o Acquire::Languages=none -o Acquire::Retries=3 -o Acquire::http::Pipeline-Depth=5"
    apt-get update -qq $HOST_APT_FAST || true
    # isolinux est optionnel (isohybrid) : on n'echoue pas s'il manque.
    apt-get install -y $HOST_APT_FAST --no-install-recommends $ISO_HOST_PKGS \
        || apt-get install -y $HOST_APT_FAST --no-install-recommends \
           squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools debootstrap git
else
    echo -e "${YELLOW}apt-get absent : verification seule des outils hote.${NC}"
fi

# Docker n'est pas auto-installe ici (paquet docker-ce hors apt standard).
for t in docker mksquashfs xorriso grub-mkrescue debootstrap git; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo_egprs ISO builder (via build.sh + start.sh) ══${NC}"

# ── Etape 1 : Executer build.sh pour preparer l'hote et construire osmocom-nitb ──
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${GREEN}[1/9] Role inter-STP : build.sh SAUTE${NC}"
    echo -e "  ${CYAN}Le hub route du M3UA. Ni HLR, ni MSC, ni BSC, ni radio, ni Asterisk :${NC}"
    echo -e "  ${CYAN}rien de ce que construit build.sh ne le concerne.${NC}"
else
echo -e "${GREEN}[1/9] Execution de build.sh...${NC}"
if [ -f "$DIR/build.sh" ]; then
    bash "$DIR/build.sh" $NO_CACHE
else
    echo -e "${YELLOW}build.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
    docker build $NO_CACHE -t osmocom-nitb "$DIR"
fi
echo -e "  ${GREEN}✓${NC} image osmocom-nitb prete"
fi

load_start_lib() {
    local src="$DIR/start.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # La lib vit dans $WORK, pas dans le depot : sans ca, la resolution par
    # BASH_SOURCE de start.sh chercherait generate_configs.sh a cote de la copie.
    export OSMO_REPO_DIR="$DIR"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Etape 2 : Construire l'image osmocom-run via start.sh ─────────────────────
# load_start_lib est necessaire dans TOUS les cas : c'est lui qui apporte
# apply_config_templates. C'est build_run_image - deux heures de compilation de
# la pile complete - que le hub n'a aucune raison de payer.
load_start_lib
if [ "$ISO_ROLE" = "interstp" ]; then
    echo -e "${GREEN}[2/9] Construction de l'image ${CYAN}osmocom-stp${NC}${GREEN} (Dockerfile.stp)...${NC}"
    echo -e "  ${CYAN}osmo-stp + libosmocore + libosmo-netif + libosmo-sigtran. Rien d'autre.${NC}"
    docker build $NO_CACHE -f "$DIR/Dockerfile.stp" -t osmocom-stp "$DIR" \
        || { echo -e "${RED}Echec de la construction d'osmocom-stp${NC}"; exit 1; }
    echo -e "  ${GREEN}✓${NC} osmocom-stp construite ($(docker image inspect osmocom-stp --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f Mo", $1/1048576}'))"
else
    echo -e "${GREEN}[2/9] Construction de l'image osmocom-run via start.sh...${NC}"
    build_run_image
    echo -e "  ${GREEN}✓${NC} osmocom-run construite"
fi

echo -e "${GREEN}[2b/9] Preparation de l'image source de l'ISO...${NC}"

ISO_N_MS=2
ISO_OP_ID=1         # operateur unique de l'ISO (PLMN 001-01)
ENCRYPTION="a5 0"   # A5/1 par defaut dans l'ISO (chiffrement bout-en-bout valide)

# L'ISO tourne en NATIF, sans bridge docker. Les 172.20.0.x existaient quand
# meme : 20-dhcp.network (plus bas) les alias sur le NIC par defaut. Mais faire
# ecouter le coeur dessus le rend tributaire de ce NIC - s'il est absent (VM
# sans carte), nomme hors de "en* eth*", ou simplement pas encore configure
# par systemd-networkd quand osmo-ggsn demarre, le bind echoue. La boucle
# locale, elle, est toujours la et prete avant tout service.
# Concerne : osmo-ggsn (gtp bind-ip), osmo-sgsn (ggsn remote-ip), osmo-upf
# (local-addr), osmo-bsc (gprs nsvc remote ip) et le log gsmtap, que l'on
# ramene ainsi sur 127.0.0.1 ou tshark capte deja.
HOST_IP="127.0.0.1"        # ip1 : __CONTAINER_IP__ - ggsn/sgsn/upf/bsc-nsvc
GATEWAY_IP="127.0.0.1"     # gw  : __GATEWAY_IP__  - log gsmtap + dns 0 du ggsn

ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
PHY_MODE="${PHY_MODE:-faketrx}"
# __INTER_STP_IP__ : ASP vers le STP d'un autre operateur. Inerte ici - l'ISO
# n'a qu'un operateur et passe inter_stp_shutdown=shutdown a apply_config_
# templates - mais on ne laisse pas une IP docker morte dans les configs.
INTER_STP_IP="127.0.0.1"   # ip2 : inter-operateur (ASP shutdown sur l'ISO)

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  Inter-STP  : ${CYAN}${INTER_STP_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"
echo -e "  PHY        : ${CYAN}${PHY_MODE}${NC}"

TEMP_CONFIG="$(mktemp -d)"

# ── Point codes et rattachement SS7 ──────────────────────────────────────────
# Hors WAN : le plan historique, 1.<op>.<role>, et l'ASP inter-STP coupe -
# l'ISO n'a qu'un operateur, il n'a personne a qui parler en SS7.
#
# Avec --node N : le noeud entre DANS le point code, 1.<noeud><op>.<role>.
# Sans ca, trois ISO attachees au meme hub y presenteraient trois fois 1.11.2.
# Un point code est une adresse : deux equipements avec la meme, ce n'est pas
# un conflit de nom, c'est du routage faux - et silencieux.
ISO_PC_MSC="1.1.1"; ISO_PC_STP="1.1.2"; ISO_PC_BSC="1.1.3"
ISO_INTER_SHUT="shutdown"
ISO_INTER_IP="$INTER_STP_IP"
if [ -n "$ISO_NODE" ]; then
    ISO_PC_MSC="1.${ISO_NODE}${ISO_OP_ID}.1"
    ISO_PC_STP="1.${ISO_NODE}${ISO_OP_ID}.2"
    ISO_PC_BSC="1.${ISO_NODE}${ISO_OP_ID}.3"
    ISO_INTER_IP="$ISO_HUB_IP"
    ISO_INTER_SHUT="no shutdown"
    # RCTX unique lui aussi : le hub identifie chaque AS par son routing context.
    export RCTX_INTER_OVERRIDE=$(( ISO_NODE * 1000 + ISO_OP_ID * 100 + 50 ))
    # local-ip de l'ASP laissee a 0.0.0.0 : l'adresse du noeud vient du DHCP et
    # n'est pas forcement montee quand osmo-stp demarre. Se lier a une adresse
    # absente echoue au lancement, sans rapport visible avec le reseau.
    export INTER_LOCAL_IP_OVERRIDE="0.0.0.0"
    echo -e "  Noeud WAN  : ${CYAN}${ISO_NODE}${NC}  PC ${CYAN}${ISO_PC_STP}${NC}  hub ${CYAN}${ISO_HUB_IP}${NC}  rctx ${RCTX_INTER_OVERRIDE}"
fi

apply_config_templates "$TEMP_CONFIG" \
    "$HOST_IP" "$GATEWAY_IP" \
    "1" "$ISO_PC_MSC" "$ISO_PC_STP" "$ISO_PC_BSC" \
    "001" "01" "OsmoGSM" \
    "$ISO_INTER_IP" "$ISO_INTER_SHUT" "1"

# ── Role inter-STP : la config du hub, pour N noeuds ────────────────────────
if [ "$ISO_ROLE" = "interstp" ]; then
    _hub_nodes=3
    if [ -n "$ISO_WAN_NODES" ]; then
        _hub_nodes=$(printf '%s' "${ISO_WAN_NODES//,/ }" | wc -w)
    fi
    bash "$DIR/helpers/create_interop.sh" --wan "$_hub_nodes" "${ISO_WAN_OPS:-1}" \
        "$TEMP_CONFIG/osmocom/osmo-stp-interop.cfg" || exit 1
    echo -e "  ${GREEN}✓${NC} hub SS7 pour ${CYAN}${_hub_nodes}${NC} noeud(s) × ${ISO_WAN_OPS:-1} operateur(s)"
fi

# ── Routage SMS ──────────────────────────────────────────────────────────────
# APRES apply_config_templates, et non avant : celui-ci ecrase systematiquement
# sms-routing.conf avec le fallback de lib/gabarits.sh.
#
# Ce fallback ne convient pas a l'ISO sur deux points :
#   - [operators] pointe sur op_backbone_ip (172.20.0.11), une adresse du plan
#     docker ; l'ISO tourne en natif, tout boucle sur HOST_IP.
#   - [routes] enumere des prefixes fixes (i000, i0000, i001..i005) qui ne
#     suivent pas ISO_N_MS : au-dela du 5e MS, "No route for destination".
#
# On reecrit donc la meme structure, mais avec UNE route par MS reellement
# embarque. MSISDN = op * 10000 + ms, la formule du depot (21-abonnes-hlr.sh,
# scripts/sms-routing-setup.sh) - pour ISO_N_MS=2 : 10001 et 10002.
ISO_SMS_SC="1999001${ISO_OP_ID}444"
{
    printf '# sms-routing.conf - Fallback\n\n'
    printf '[local]\noperator_id = %s\nsc_address  = %s\n\n' "$ISO_OP_ID" "$ISO_SMS_SC"
    printf '[operators]\n%s = %s\n\n' "$ISO_OP_ID" "$HOST_IP"
    printf '[routes]\n'
    for ms in $(seq 1 "$ISO_N_MS"); do
        printf '%s = %s\n' "$(( ISO_OP_ID * 10000 + ms ))" "$ISO_OP_ID"
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
} > "$TEMP_CONFIG/osmocom/sms-routing.conf"
echo -e "  ${GREEN}✓${NC} sms-routing.conf : ${CYAN}${ISO_N_MS}${NC} route(s) MS, operateur ${ISO_OP_ID} = ${CYAN}${HOST_IP}${NC}"

if [ "$ISO_ROLE" = "interstp" ]; then
    ISO_RUN_IMAGE="osmocom-stp-iso"
    ISO_SRC_IMAGE="osmocom-stp"
else
    ISO_RUN_IMAGE="osmocom-run-iso-net-host"
    ISO_SRC_IMAGE="osmocom-run"
fi
TMP_CID="$(docker create "$ISO_SRC_IMAGE" /bin/sh)"

docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
# Le hub n'a pas d'Asterisk : lui pousser des configs SIP n'aurait pas de sens,
# et l'image n'a meme pas /etc/asterisk.
[ "$ISO_ROLE" = "interstp" ] || \
    docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prete"

# ── Etape 3 : (SUPPRIME) - ISO NATIF : on n'embarque PAS l'image Docker ────
# L'image osmocom-run ne sert plus que de SOURCE de build (docker cp des binaires
# et configs vers le rootfs a l'etape 6). On ne la save plus dans l'ISO : pas de
# docker au runtime, pas de tar.gz de plusieurs Go embarque.

# ── Etape 4 : Bootstrap rootfs minimal ─────────────────────────────────────
echo -e "${GREEN}[4/9] debootstrap jammy (minimal)...${NC}"
debootstrap --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
    jammy "$ROOTFS" http://archive.ubuntu.com/ubuntu
echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"

# ── Etape 5 : Injection des binaires et libs depuis l'image osmocom-run ───
echo -e "${GREEN}[5/9] Injection stack Osmocom...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
docker cp "$CID:/usr/local/bin/." "$ROOTFS/usr/local/bin/"  2>/dev/null||true
docker cp "$CID:/usr/local/lib/." "$ROOTFS/usr/local/lib/"  2>/dev/null||true
docker cp "$CID:/usr/local/include/." "$ROOTFS/usr/local/include/" 2>/dev/null||true
docker cp "$CID:/opt/GSM"             "$ROOTFS/opt/GSM"     2>/dev/null||true
# venv python (gr-gsm + bridges) attendu par /opt/GSM/qemu-src/start-clean.sh
docker cp "$CID:/root/.env"           "$ROOTFS/root/"       2>/dev/null||true
docker cp "$CID:/etc/osmocom/."       "$ROOTFS/etc/osmocom/" 2>/dev/null||true
docker cp "$CID:/etc/asterisk/."      "$ROOTFS/etc/asterisk/" 2>/dev/null||true
for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
    docker cp "$CID:/lib/systemd/system/${svc}.service" "$ROOTFS/lib/systemd/system/" 2>/dev/null||true
done
docker rm "$CID" &>/dev/null
echo -e "  ${GREEN}✓${NC} binaires + libs + configs injectes"

# ── osmo_egprs : SOURCE a jour depuis GitHub (branche main) ──
# La copie docker cp ci-dessus peut etre perimee ; on recupere la branche main
# du repo (start-direct.sh, run.sh, scripts/, configs/, build-iso.sh...) dans l'ISO.
# ── osmo_egprs : ARBRE a jour depuis GitHub (branche main), sans depot git ──
EGPRS_BRANCH="${OSMO_EGPRS_BRANCH:-main}"
EGPRS_TARBALL="https://codeload.github.com/bbaranoff/osmo_egprs/tar.gz/refs/heads/${EGPRS_BRANCH}"
echo -e "${GREEN}[5d/7] Recuperation osmo_egprs (branche ${EGPRS_BRANCH}, tarball)...${NC}"
stage="$(mktemp -d)"
if wget -qO- "$EGPRS_TARBALL" | tar -xz -C "$stage" --strip-components=1 \
   && [ -s "$stage/start.sh" ]; then
    find "$stage" -name '.git*' -maxdepth 2 -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$ROOTFS/opt/GSM/osmo_egprs"
    mkdir -p "$ROOTFS/opt/GSM"
    cp -a "$stage" "$ROOTFS/opt/GSM/osmo_egprs"
    echo -e "  ${GREEN}✓${NC} osmo_egprs installe (${EGPRS_BRANCH}, arbre nu, sans .git)"
else
    echo -e "  ${YELLOW}⚠ recuperation osmo_egprs echouee (reseau ?) - copie de l'image conservee${NC}"
fi
rm -rf "$stage"

# ── Feed HLR : aligner N_MS sur le nombre de MS embarques ────────────────────
# run_modules/21-abonnes-hlr.sh retombe sur ": "${N_MS:=1}"" : sans ce fichier
# un SEUL abonne etait provisionne alors que l'ISO en declare ISO_N_MS, et les
# MS suivants se voyaient refuser le rattachement ("IMSI unknown in HLR") -
# panne lue a tort comme un defaut radio.
#
# environment/load.env source "coeur.env" s'il existe, et tout le depot suit
# l'idiome ": "${VAR:=...}"" : la ligne de commande (N_MS=2 ./run.sh) garde
# donc la priorite. On ecrit dans les arbres presents : l'ISO native resout
# run.sh depuis osmo_egprs, qemu-src n'y survit que si ses sources sont gardees.
for envdir in "$ROOTFS/opt/GSM/osmo_egprs/environment" \
              "$ROOTFS/opt/GSM/qemu-src/environment"; do
    [ -d "$envdir" ] || continue
    cat > "$envdir/coeur.env" <<COEUR
# coeur.env - genere par build-iso.sh. Aligne le nombre d'abonnes provisionnes
# dans le HLR sur le nombre de MS embarques par l'ISO (ISO_N_MS).
: "\${N_MS:=$ISO_N_MS}"
: "\${OPERATOR_ID:=1}"
COEUR
    echo -e "  ${GREEN}✓${NC} coeur.env : ${CYAN}N_MS=${ISO_N_MS}${NC} (${envdir#$ROOTFS})"
done


# ── qemu-src : checkout LOCAL (branche main, build/qemu-system-arm recompile) ──
# La copie docker cp ($CID:/opt/GSM) peut etre perimee / sur une autre branche. On
# ecrase qemu-src par le checkout local de la VM, deja sur 'main' avec le binaire
# build/ a jour. On retire .git (historique QEMU = lourd, inutile a l'execution).
QEMU_BUILD_LOCAL="${OSMO_QEMU_BUILD:-${OSMO_QEMU_SRC:-/opt/GSM/qemu-src}/build}"
echo -e "${GREEN}[5d/9] Installation QEMU (artefacts seuls, depuis ${QEMU_BUILD_LOCAL})...${NC}"
if [ -x "$QEMU_BUILD_LOCAL/qemu-system-arm" ]; then
    # aucune arborescence source dans l'image
    rm -rf "$ROOTFS/opt/GSM/qemu-src"

    qpfx="$(sed -n 's/^prefix=//p' "$QEMU_BUILD_LOCAL/config-host.mak" 2>/dev/null)"
    qpfx="${qpfx:-/usr/local}"

    if DESTDIR="$ROOTFS" ninja -C "$QEMU_BUILD_LOCAL" install >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} qemu installe dans ${ROOTFS}${qpfx} (ninja install, pas de sources)"
    else
        # repli : binaire + firmwares/keymaps strictement necessaires
        install -Dm755 "$QEMU_BUILD_LOCAL/qemu-system-arm" "$ROOTFS$qpfx/bin/qemu-system-arm"
        install -d "$ROOTFS$qpfx/share/qemu"
        cp -a "$QEMU_BUILD_LOCAL/pc-bios/." "$ROOTFS$qpfx/share/qemu/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} qemu-system-arm + pc-bios copies dans ${ROOTFS}${qpfx} (repli manuel)"
    fi
    strip --strip-unneeded "$ROOTFS$qpfx/bin/qemu-system-arm" 2>/dev/null || true
else
    echo -e "  ${YELLOW}⚠ ${QEMU_BUILD_LOCAL}/qemu-system-arm absent - qemu de l'image conserve${NC}"
fi
echo -e "${GREEN}[5c/9] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5b/9] Patch configs ISO...${NC}"
echo -e "${GREEN}[5b/9] Patch configs ISO...${NC}"

if [ -f "$ROOTFS/etc/osmocom/osmo-sgsn.cfg" ]; then
    sed -i \
        -e 's/^\([[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e 's/^\([[:space:]]*gsup[[:space:]]\+remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e '/^[[:space:]]*bind udp local$/,/^[[:space:]]*!$/ s/^\([[:space:]]*listen[[:space:]]\+\).*/\1127.0.0.2 23000/' \
        "$ROOTFS/etc/osmocom/osmo-sgsn.cfg"
fi

if [ -f "$ROOTFS/etc/osmocom/osmo-msc.cfg" ]; then
    sed -i \
        -e '/^hlr$/,/^!$/ s/^\([[:space:]]*remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        "$ROOTFS/etc/osmocom/osmo-msc.cfg"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + MSC applique"

# run.sh: reduire toute ligne "trxcon options..." a "trxcon"
#         et toute ligne "mobile options..." a "mobile"
if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    sed -i \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?trxcon\([[:space:]].*\)\?$#trxcon#' \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?mobile\([[:space:]].*\)\?$#mobile#' \
        "$ROOTFS/etc/osmocom/run.sh"
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + run.sh applique"
mkdir -p "$ROOTFS/usr/bin"
cp -a "$ROOTFS/usr/local/bin/." "$ROOTFS/usr/bin/" 2>/dev/null || true

mkdir -p "$ROOTFS/root/.osmocom/bb"
if [ -f "$ROOTFS/opt/osmo_egprs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo_egprs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/opt/osmo_egprs/configs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo_egprs/configs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/etc/osmocom/mobile.cfg" ]; then
    cp "$ROOTFS/etc/osmocom/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
fi

if ! chroot "$ROOTFS" getent passwd osmocom >/dev/null 2>&1; then
    chroot "$ROOTFS" useradd -m -s /bin/bash osmocom 2>/dev/null || true
fi

chroot "$ROOTFS" usermod -o -u 0 -g 0 osmocom 2>/dev/null || true

mkdir -p "$ROOTFS/home/osmocom"
chown -R 0:0 "$ROOTFS/home/osmocom" "$ROOTFS/root/.osmocom" 2>/dev/null || true

echo -e "  ${GREEN}✓${NC} user osmocom + /usr/bin + mobile.cfg prets"

chmod +x "$ROOTFS/etc/osmocom/run.sh"

# ── Etape 6 : Injection du dashboard web ───────────────────────────────────
echo -e "${GREEN}[6/9] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
WEB_BRANCH="${OSMO_WEB_BRANCH:-test}"

mkdir -p "$WEB/web"
# Source AUTORITAIRE = le VRAI git bbaranoff/osmo-egprs-web (clone ci-dessous).
# La copie locale /opt/osmo-egprs-web n'est plus utilisee que comme override
# EXPLICITE : OSMO_WEB_LOCAL=/chemin ./build-iso.sh. Sinon -> git.
# Le patch natif plus bas est idempotent (skip si server.js est deja en mode natif).
LOCAL_WEB="${OSMO_WEB_LOCAL:-}"
if [ -n "$LOCAL_WEB" ] && [ -f "$LOCAL_WEB/server.js" ]; then
    cp "$LOCAL_WEB/server.js" "$WEB/server.js"
    [ -f "$LOCAL_WEB/package.json" ] && cp "$LOCAL_WEB/package.json" "$WEB/package.json"
    [ -d "$LOCAL_WEB/web" ]          && cp -r "$LOCAL_WEB/web/."     "$WEB/web/"
    [ -f "$LOCAL_WEB/start-web.sh" ] && cp "$LOCAL_WEB/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$LOCAL_WEB/Dockerfile" ]   && cp "$LOCAL_WEB/Dockerfile"   "$WEB/Dockerfile"
    echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis source LOCALE ($LOCAL_WEB)"
else
    WEB_TMP="$WORK/osmo-egprs-web"
    rm -rf "$WEB_TMP"
    git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2 || true
    # Layout REEL du repo : server.js / package.json / web/ / start-web.sh a la
    # RACINE (fallback sous server/ pour un ancien layout).
    if   [ -f "$WEB_TMP/server.js" ];        then cp "$WEB_TMP/server.js"        "$WEB/server.js"
    elif [ -f "$WEB_TMP/server/server.js" ]; then cp "$WEB_TMP/server/server.js" "$WEB/server.js"; fi
    if   [ -f "$WEB_TMP/package.json" ];        then cp "$WEB_TMP/package.json"        "$WEB/package.json"
    elif [ -f "$WEB_TMP/server/package.json" ]; then cp "$WEB_TMP/server/package.json" "$WEB/package.json"; fi
    [ -d "$WEB_TMP/web" ]          && cp -r "$WEB_TMP/web/."     "$WEB/web/"
    [ -f "$WEB_TMP/start-web.sh" ] && cp "$WEB_TMP/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$WEB_TMP/Dockerfile" ]   && cp "$WEB_TMP/Dockerfile"   "$WEB/Dockerfile"
    rm -rf "$WEB_TMP"
    if [ -f "$WEB/server.js" ]; then
        echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis le git ${CYAN}$WEB_REPO${NC} ($WEB_BRANCH)"
    else
        echo -e "  ${RED}✗ clone osmo-egprs-web sans server.js - dashboard incomplet${NC}"
    fi
fi

# Patch server.js : mode natif (no-docker). VTY en telnet direct sur 127.0.0.1
# (ou ip netns exec) au lieu de docker exec. Idempotent ; n'echoue pas le build.
if [ -f "$WEB/server.js" ] && command -v python3 >/dev/null 2>&1; then
python3 - "$WEB/server.js" <<'PYEOF' || echo -e "  ${YELLOW}[web] patch natif non applique (server.js amont a change ?)${NC}"
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'const NATIVE' in s:
    print('  [web] server.js deja en mode natif - skip'); sys.exit(0)
HELPERS = """
// ─── Native (no-docker) mode ─────────────────────────────────
const NATIVE        = (process.env.OSMO_NATIVE !== '0');
const OP_IDS        = (process.env.OSMO_OP_IDS || '1').split(',')
                        .map(function(s){ return parseInt(s, 10); })
                        .filter(function(n){ return !isNaN(n); });
const NETNS_PREFIX  = process.env.OSMO_NETNS_PREFIX || '';
function vtyProc(container, port, ip, id) {
  if (NATIVE) {
    if (NETNS_PREFIX) return { bin: 'ip', args: ['netns','exec', NETNS_PREFIX + id, 'telnet', ip, String(port)] };
    return { bin: 'telnet', args: [ip, String(port)] };
  }
  return { bin: 'docker', args: ['exec','-i', container, 'telnet', ip, String(port)] };
}
function shCmd(container, id, inner) {
  if (NATIVE) {
    if (NETNS_PREFIX) return 'ip netns exec ' + NETNS_PREFIX + id + ' bash -c "' + inner + '"';
    return 'bash -c "' + inner + '"';
  }
  return 'docker exec ' + container + ' bash -c "' + inner + '"';
}
"""
n = [0]
def sub(pat, rep, flags=0):
    global s
    s, c = re.subn(pat, rep, s, flags=flags); n[0]+=c; return c
sub(r"(const VTY_RETRY_DELAY = 2000;)", r"\1\n" + HELPERS.replace('\\','\\\\'))
sub(r"(function discoverOperators\(\) \{)", r"\1\n  if (NATIVE) return Promise.resolve(OP_IDS.slice());")
sub(r"var proc = spawn\('docker', \[\s*'exec', '-i', container, 'telnet', targetIp, String\(port\)\s*\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(container, port, targetIp, String(container).replace(PREFIX, ''));\n    var proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
sub(r"return execAsync\(\s*'docker inspect.*?\)\.then\(function\(running\) \{",
    "var runningProbe = NATIVE\n    ? execAsync(shCmd(container, id, 'ss -tln 2>/dev/null | grep -q :' + VTY_PORTS.bsc + ' && echo true || echo false'), 3000)\n    : execAsync('docker inspect -f \\'{{.State.Running}}\\' ' + container + ' 2>/dev/null', 3000);\n  return runningProbe.then(function(running) {", re.DOTALL)
sub(r"execAsync\(\s*'docker exec ' \+ container \+ ' bash -c \"ss -tlnp.*?', 3000\s*\)",
    "execAsync(\n        shCmd(container, id, 'ss -tlnp 2>/dev/null | grep :7890 | wc -l'), 3000\n      )", re.DOTALL)
sub(r"log\('VTY open: docker exec.*?\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(this.container, this.port, this.ip, this.opId);\n  log('VTY open: ' + vc.bin + ' ' + vc.args.join(' ') + ' (attempt ' + (this.retries + 1) + ')');\n\n  this.proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
open(p,'w',encoding='utf-8').write(s)
print('  [web] server.js patche mode natif (%d remplacements)' % n[0])
sys.exit(0 if n[0] >= 6 else 2)
PYEOF
fi

# ── Etape 7 : Injection des scripts projet et installation du lanceur start-direct.sh ──
echo -e "${GREEN}[7/9] Scripts projet et adaptation ISO...${NC}"
P="$ROOTFS/opt/osmo_egprs"
# [2026-08-14] `lib` ajoute : scripts/audio-chain.sh source lib/audio.sh.
# Sans ce repertoire l'ISO embarquait un wrapper qui ne pouvait pas se sourcer.
# [2026-08-25] `network` et `tools` AJOUTES a la liste. Sans eux, les `cp
# "$DIR/network/..." "$P/network/..."` de la boucle suivante echouaient - le
# repertoire cible n'existait pas - et comme ils sont dans une chaine `&&`,
# l'echec ne disait rien : l'ISO partait SANS aucun script WAN, et le seul
# symptome etait un "introuvable" au moment d'en avoir besoin.
mkdir -p "$P"/{scripts,configs,checks,helpers,lib,pont,network,tools}
for f in start.sh start-direct.sh start-interstp.sh build.sh network/loopback.sh \
         tools/vty-menu.sh tools/vty-connect.exp \
         network/firewall-wan.sh network/setup-wan-interop.sh network/setup-wan-sms.sh \
         network/wan-nodes.sh network/setup-wan-mesh.sh network/setup-vbox-interco.sh; do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$P/$f" && chmod +x "$P/$f"
done
ln -sf /opt/osmo_egprs/start-direct.sh "$ROOTFS/usr/local/bin/osmo-start-direct" 2>/dev/null || true
# [2026-08-16] `pont` AJOUTE A LA LISTE. Dockerfile.run contient desormais
# `COPY pont/pont.py`, donc sans ce repertoire dans la charge de l'ISO le
# `docker build -f Dockerfile.run .` echoue net au premier demarrage.
for d in scripts configs checks helpers lib pont; do
    [ -d "$DIR/$d" ] && cp -r "$DIR/$d/." "$P/$d/" && find "$P/$d" -name "*.sh" -exec chmod +x {} \;
done
[ -f "$DIR/Dockerfile" ]     && cp "$DIR/Dockerfile"     "$P/"
[ -f "$DIR/Dockerfile.run" ] && cp "$DIR/Dockerfile.run" "$P/"
ln -sf /opt/osmo_egprs/start.sh "$ROOTFS/usr/local/bin/osmo-start-lab"
[ -f "$DIR/launch/osmo-launch.sh" ] && cp "$DIR/launch/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"

# [2026-08-03] start-in-iso.sh a ete supprime : start-direct.sh le remplace.
# L'ancien bloc fabriquait, en son absence, un stub qui refusait de demarrer
# ("Veuillez fournir un script start-in-iso.sh complet") - l'ISO partait donc
# avec un lanceur inutilisable. On embarque le vrai lanceur.
if [ -f "$DIR/start-direct.sh" ]; then
    cp "$DIR/start-direct.sh" "$P/start-direct.sh"
    chmod +x "$P/start-direct.sh"
    echo -e "  ${GREEN}✓${NC} /opt/osmo_egprs/start-direct.sh copie"
else
    echo -e "  ${RED}✗${NC} start-direct.sh introuvable - l'ISO n'aura pas de lanceur" >&2
    exit 1
fi

# ── WAN : table des noeuds figee dans l'image ────────────────────────────────
if [ "$ISO_WAN" = "1" ]; then
    echo -e "${GREEN}[7b/9] WAN - table des noeuds embarquee...${NC}"
    # shellcheck source=network/wan-nodes.sh
    . "$DIR/network/wan-nodes.sh"
    WAN_OPS="$ISO_WAN_OPS"
    if [ -n "$ISO_WAN_NODES" ]; then
        wan_nodes_parse "$ISO_WAN_NODES" || exit 1
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
    else
        # Construction interactive : memes questions que ./start.sh --wan.
        # Le numero du noeud demande ici n'est qu'un defaut : chaque machine
        # qui demarre l'ISO se re-reconnait a son IP.
        WAN_NODE_ID="${ISO_WAN_ID:-0}"
        wan_nodes_prompt || exit 1
    fi
    wan_nodes_validate || exit 1
    WAN_AUTO=1 WAN_CONF_FILE="$ROOTFS/etc/osmo-wan.conf" wan_nodes_save
    wan_nodes_summary
    echo -e "  ${GREEN}✓${NC} /etc/osmo-wan.conf fige dans l'ISO (WAN_AUTO=1)"
    echo -e "  ${CYAN}Au boot :${NC} start-direct.sh applique le WAN tout seul ;"
    echo -e "  ${CYAN}sans --wan a la construction, l'ISO n'a AUCUN WAN.${NC}"
else
    echo -e "  ${CYAN}[7b/9] WAN non embarque (--wan absent) - ISO autonome${NC}"
fi

# ── Etape 8 : (SUPPRIME) - ISO NATIF, plus de Docker au runtime ───────────
# L'ancien load-osmocom-image.service chargeait osmocom-run.tar.gz via 'docker
# load' au boot ; son ExecStartPre 'while ! docker info' bloquait indefiniment la
# file systemd en natif (docker jamais up) → boot fige. Le lab tourne desormais
# en natif (start-direct.sh) : pas d'image Docker a charger, pas de ce service.

# ── Etape 9 : Configuration chroot (paquets) ───────────────────────────────
echo -e "${GREEN}[8/9] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

chroot "$ROOTFS" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"

# ── apt/dpkg rapides ────────────────────────────────────────────────────────
# Ce rootfs est jetable : il est fabrique, empaquete en squashfs, puis efface.
# Les garanties de durabilite que dpkg paie a chaque fichier - un fsync par
# fichier deballe - n ont donc aucune valeur ici, et elles dominent le temps de
# construction. force-unsafe-io les coupe : c est le reglage qu utilisent les
# images Docker officielles, pour la meme raison.
#
# Le reste ne joue pas sur la durabilite mais sur ce qui est TELECHARGE :
#   Languages=none    supprime les traductions de descriptions (inutiles ici)
#   Pipeline-Depth    plusieurs requetes en vol au lieu d une a la fois
#   Retries           un miroir qui bronche ne fait plus echouer la construction
#                     entiere - ce chroot tourne sous set -e
mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/02-unsafe-io
cat > /etc/apt/apt.conf.d/99osmo-fast <<APTFAST
Acquire::Languages "none";
Acquire::Retries "3";
Acquire::http::Pipeline-Depth "5";
Dpkg::Use-Pty "0";
APTFAST

APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

cat > /etc/apt/sources.list <<SOURCES
deb http://archive.ubuntu.com/ubuntu jammy           main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates    main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security   main universe multiverse
SOURCES
apt-get update -qq

# ── Outils de diagnostic : nc, tcpdump, git ────────────────────────────────
# ICI, en premier, et pas plus bas avec les autres : ce chroot tourne sous
# set -e. Place dans un des groupes suivants, le moindre echec en amont - un
# build-dep, un miroir qui bronche - emporterait cette ligne avec lui, et l ISO
# sortirait sans eux sans que rien ne le dise. Juste apres apt-get update, il
# n y a plus rien qui puisse les faire sauter.
#
#   nc       le VTY est la seule source de verite sur l etat SS7 : tout le
#            depot l interroge par "nc 127.0.0.1 4239". Sans nc, les checks ne
#            se plaignent pas - ils affichent un diagnostic VIDE, qui se lit
#            comme "rien n est attache" alors que tout va bien.
#   tcpdump  les captures GSMTAP/M3UA. Sans lui, une capture lancee en arriere
#            plan echoue en silence et le pcap reste vide.
#   git      la synchro du depot depuis la VM (update.sh).
apt-get install -y $APT_OPTS --no-install-recommends netcat-openbsd tcpdump git logrotate

# deb-src + build-dep gnuradio : tire toutes les deps de GNU Radio (boost, fftw,
# gmp, log4cpp, volk...) dont depend le gnuradio/gr-gsm custom de /usr/local.
# Genere les lignes deb-src a partir des deb (tous composants), comme le Dockerfile.
sed -nE "s|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p" \
    /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list
apt-get update -qq
apt-get build-dep -y $APT_OPTS gnuradio || echo "WARN: apt build-dep gnuradio a echoue"

apt-get install -y $APT_OPTS --no-install-recommends \
    linux-image-generic initramfs-tools \
    live-boot live-boot-initramfs-tools

apt-get install -y $APT_OPTS --no-install-recommends \
    libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev libc-ares2 libgnutls30 libgnutls28-dev libmnl-dev \
    libortp-dev libdbi1 libdbd-sqlite3 sqlite3 \
    libfftw3-single3 libusb-1.0-0 \
    libgsm1 libasound2 libasound2-plugins \
    libsofia-sip-ua-glib3 libmnl0 \
    liburing2 libslirp0

apt-get install -y $APT_OPTS --no-install-recommends \
    iproute2 iptables net-tools lksctp-tools \
    tmux telnet expect whiptail \
    lsb-release pulseaudio pulseaudio-utils alsa-utils openssh-server \
    console-setup keyboard-configuration locales \
    binutils-arm-none-eabi psmisc gdb-multiarch

apt-get install -y $APT_OPTS --no-install-recommends \
    python3 python3-scapy \
    tshark wireshark-common \
    asterisk \
    ffmpeg

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

# Docker NON installe dans le ISO (natif) : le lab tourne via start-direct.sh et le
# dashboard web via node natif. Le build sur le HOTE utilise le docker du HOTE pour
# extraire binaires/configs, mais le ISO final nembarque pas docker.

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/osmo-egprs-web/package.json ]; then
    cd /opt/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
'

# ── Etape 8b : Reequilibrage sur build.sh - cloture de dependances ldd ────────
# L'image osmocom-run (produite par build.sh + Dockerfile) est l'environnement
# qui MARCHE. Au lieu de se fier aux versions apt du rootfs (skew -> crash
# logging libosmocore), on copie depuis le conteneur la cloture .so EXACTE de
# tous les binaires osmo + calypso-ipc-device, en ecrasant les libs apt. On
# exclut la famille glibc/loader (identique en jammy, ne pas clobber ld.so).
echo -e "${GREEN}[8b/9] Cloture de dependances COMPLETE depuis ${CYAN}${ISO_RUN_IMAGE}${NC}${GREEN} (toute l'install)...${NC}"
# On ldd TOUS les ELF (executables + toutes les .so) de l'install custom :
# /usr/local/bin (osmo), /opt/GSM (qemu, ipc-device, gr-gsm), /root/.env (venv
# python : bindings gnuradio/gr-gsm + leurs deps boost/log4cpp/volk/fftw...).
# => toutes les deps natives finissent dans l'ISO, plus de "import gsm" qui rate.
docker run --rm --entrypoint bash \
    -e OSMO_LDD_ROOTS="$([ "$ISO_ROLE" = "interstp" ] && echo "/usr/local/bin /usr/local/lib" || echo "/usr/local/bin /opt/GSM /root/.env")" \
    "$ISO_RUN_IMAGE" -c '
    set -e
    find ${OSMO_LDD_ROOTS:-/usr/local/bin /opt/GSM /root/.env} -type f \( -executable -o -name "*.so*" \) 2>/dev/null \
      | while read -r b; do ldd "$b" 2>/dev/null; done \
      | grep -oE "/[^ ]+\.so[^ ]*" | sort -u \
      | grep -vE "/(ld-linux[^/]*|ld|libc|libm|libpthread|libdl|librt|libresolv)\.so" \
      | while read -r f; do realpath "$f" 2>/dev/null; done | sort -u \
      | tar -czf - -T - 2>/dev/null
' > "$WORK/closure.tar.gz" || true
if [ -s "$WORK/closure.tar.gz" ]; then
    tar -xzf "$WORK/closure.tar.gz" -C "$ROOTFS" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} $(tar -tzf "$WORK/closure.tar.gz" 2>/dev/null | wc -l) libs injectees (Docker)"
else
    echo -e "  ${YELLOW}cloture vide - on garde les libs apt${NC}"
fi

# Priorite /usr/local/lib (libosmo* custom) + purge de tout doublon systeme.
# NB: pas de `| grep` ici - sous set -euo pipefail un grep sans correspondance
# (cas normal: aucun doublon) renverrait 1 et tuerait le script avant l'ISO.
echo "/usr/local/lib" > "$ROOTFS/etc/ld.so.conf.d/00-osmocom-local.conf"
find "$ROOTFS/usr/lib" "$ROOTFS/lib" -maxdepth 4 -name 'libosmo*.so*' -delete 2>/dev/null || true
chroot "$ROOTFS" ldconfig 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} /usr/local/lib prioritaire + ldconfig"

# ── Configuration systeme ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
# ── Adresses heritees du plan docker, en /32 ────────────────────────────────
# Elles servent aux configs de l'image qui nomment encore 172.20.x (passerelle
# du backbone, cible gsmtap...) : sans elles, un demon qui s'y lie ne demarre
# pas. On les garde donc - mais sans revendiquer de reseau.
#
# POURQUOI /32 ET PLUS /24
# Un /24 fait croire a la machine que TOUT 172.20.0.0/24 est sur son lien. Elle
# l'ARP alors sur le LAN au lieu de le router. Sur un banc mixte VM + docker,
# les conteneurs de l'hote deviennent injoignables : "ip route add
# 172.20.0.0/24 via <hote>" est refuse d'un "File exists", et le trafic part
# dans le vide. Le /32 garde l'adresse locale sans fermer la porte au routage.
#
# 172.20.0.11 est RETIREE : c'est l'adresse du PREMIER CONTENEUR operateur. Une
# VM qui la porte se repond a elle-meme et ne joint jamais le conteneur - la
# panne la plus deroutante du lot, puisque tout repond en local.
#
# La route /16 disparait pour la meme raison : elle couvrait le plan docker
# entier et primait sur toute route plus fine vers l'hote.
Address=172.20.0.1/32
Address=172.20.1.10/32
EOF
# docker RETIRE de la liste : son service n'existe plus (ISO natif) et 'systemctl
# enable' valide tous les units d'abord → un seul manquant faisait AVORTER l'enable
# de systemd-networkd/resolved → enp3s0 sans IP au boot. On active chaque unit
# separement pour qu'un eventuel echec n'empeche pas les autres.
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null||true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>/dev/null||true

# live-boot ecrit /root/etc/network/interfaces dans la racine montee au boot.
# Sans ifupdown, /etc/network/ n'existe pas -> "/init: can't create
# /root/etc/network/interfaces: nonexistent directory". On cree le dossier + un
# interfaces minimal (loopback). systemd-networkd gere le reseau ; ce fichier
# n'est lu par personne (ifupdown absent), il satisfait juste le hook live-boot.
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# ── Service startup : execute le gist tools/update.sh (bbaranoff) au demarrage ──────
cat > "$ROOTFS/usr/local/sbin/osmo-update.sh" <<'UPD'
#!/bin/bash
# osmo-update.sh - recupere et execute tools/update.sh (repo bbaranoff/osmo_egprs) au boot.
set -u
URL="https://raw.githubusercontent.com/bbaranoff/osmo_egprs/refs/heads/main/update.sh"
LOG=/var/log/osmo-update.log
exec >>"$LOG" 2>&1
echo "===== osmo-update $(date) ====="
for i in 1 2 3 4 5; do
    if curl -fsSL "$URL" -o /tmp/osmo-update.gist.sh; then
        chmod +x /tmp/osmo-update.gist.sh
        echo "--- execution tools/update.sh ---"
        bash /tmp/osmo-update.gist.sh; rc=$?
        echo "tools/update.sh termine (rc=$rc)"
        # ── Normalisation fstab : retire le doublon /tmp re-injecte par tools/update.sh ──
        # tools/update.sh (gist) re-ajoute 'tmpfs /tmp tmpfs nosuid,nodev 0 0' (SANS size=),
        # creant un doublon avec l'entree canonique 'tmpfs /tmp ... size en pourcentage' posee au build.
        # On supprime toute ligne 'tmpfs /tmp tmpfs ...' depourvue de size= (le doublon),
        # en conservant l'entree 2G. Idempotent : sans effet si le doublon est absent.
        if [ -f /etc/fstab ]; then
            sed -i -E '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]+tmpfs[[:space:]]/d' /etc/fstab
            systemctl daemon-reload 2>/dev/null || true
            echo "fstab normalise (/tmp gere par systemd tmp.mount)"
        fi
        exit 0
    fi
    echo "curl echoue (tentative $i/5), retry dans 5s..."; sleep 5
done
echo "impossible de recuperer tools/update.sh apres 5 tentatives (pas de reseau ?)"
exit 0
UPD
chmod +x "$ROOTFS/usr/local/sbin/osmo-update.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-update.service" <<'EOF'
[Unit]
Description=osmo_egprs startup update (gist tools/update.sh)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-update.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-update 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-update (execute le gist tools/update.sh au demarrage)"

# ── Marqueur de role : ce que CETTE image est ───────────────────────────────
# Lu par start-direct.sh et par la banniere. Sans lui, deux ISO issues de la
# meme chaine sont indiscernables une fois demarrees - et on lance le mauvais
# script sur la mauvaise machine.
{
    printf '# /etc/osmo-role - genere par build-iso.sh\n'
    printf 'OSMO_ROLE=%s\n' "$ISO_ROLE"
    [ -n "$ISO_NODE" ] && printf 'OSMO_WAN_NODE=%s\n' "$ISO_NODE"
    printf 'OSMO_HUB_IP=%s\n' "$ISO_HUB_IP"
} > "$ROOTFS/etc/osmo-role"

if [ "$ISO_ROLE" = "interstp" ]; then
    # Le hub, lui, DOIT demarrer seul : les noeuds s'attachent a lui au boot, et
    # un hub qu'il faut lancer a la main transforme un demarrage simultane en
    # course perdue d'avance.
    cat > "$ROOTFS/etc/systemd/system/osmo-interstp.service" <<EOF
[Unit]
Description=osmo_egprs inter-STP - hub SS7 du WAN (PC 0.0.0)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=forking
PIDFile=/run/osmo-interstp.pid
ExecStart=/opt/osmo_egprs/start-interstp.sh --ip ${ISO_HUB_IP}
ExecStop=/opt/osmo_egprs/start-interstp.sh --stop
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    chroot "$ROOTFS" systemctl enable osmo-interstp 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} osmo-interstp.service - hub lance au demarrage sur ${CYAN}${ISO_HUB_IP}${NC}"
fi


# Autologin root
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Service web dashboard
cat > "$ROOTFS/etc/systemd/system/osmo-egprs-web.service" <<'EOF'
[Unit]
Description=osmo_egprs Web Dashboard (native)
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/osmo-egprs-web
ExecStart=/usr/bin/node /opt/osmo-egprs-web/server.js --verbose
Restart=always
RestartSec=5
Environment=HTTP_PORT=8080
# Mode natif (start-direct.sh) : VTY en telnet direct sur 127.0.0.1, pas de docker.
# Pour le mode docker (start.sh + conteneurs), mettre OSMO_NATIVE=0.
Environment=OSMO_NATIVE=1
Environment=OSMO_OP_IDS=1
Environment=CONTAINER_PREFIX=osmo-operator-
[Install]
WantedBy=multi-user.target
EOF
# Le hub n'a ni VTY d'operateur a afficher ni radio a tracer : le tableau de
# bord n'aurait rien a montrer. On ne l'active pas.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# ── Audio : PulseAudio systeme (sink gsm_audio) au boot ────────────────────
# Chaine : osmo-gapk → ALSA gsm_out → sink null gsm_audio → monitor → loopback
# → carte. system.pa autorise l'acces anonyme + prepare le sink ; le service
# lance le demon au boot (ensure_pulse de start-direct.sh devient un no-op).
if [ -f "$ROOTFS/etc/pulse/system.pa" ]; then
    sed -i 's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' \
        "$ROOTFS/etc/pulse/system.pa"
    # [2026-08-14] gsm_mic MANQUAIT ICI. Seul gsm_audio etait declare, alors que
    # lib/audio.sh traite les deux sinks comme SOLIDAIRES (GSM_SINKS) et que
    # configs/asound.conf fait pointer `pcm.gsm_in` sur `gsm_mic.monitor`.
    # Consequence mesuree dans la VM : `pactl list short sources` sans gsm_mic
    # → gapk_io n'initialise pas la capture et ABANDONNE LES DEUX SENS
    #   (pq_alsa.c:168 "Couldn't init ALSA device 'gsm_in'" puis
    #    gapk_io.c:468 "Failed to initialize GAPK I/O")
    # → appel parfaitement etabli et TOTALEMENT MUET. Les deux sinks doivent
    # etre declares ensemble, ici, comme le dit deja lib/audio.sh.
    for _s in "gsm_audio:GSM_Audio" "gsm_mic:GSM_Mic"; do
        _n="${_s%%:*}"; _d="${_s##*:}"
        grep -q "sink_name=${_n}\b" "$ROOTFS/etc/pulse/system.pa" || \
            echo "load-module module-null-sink sink_name=${_n} format=s16le rate=8000 channels=1 sink_properties=device.description=${_d}" \
            >> "$ROOTFS/etc/pulse/system.pa"
    done
fi
# [2026-08-14] /etc/asound.conf N'ETAIT DEPLOYE NULLE PART sur l'ISO. Il l'est
# par ensure_pulse() de lib/audio.sh - mais lib/audio.sh n'est source par
# personne (son appelant annonce, run_modules/25-audio.sh, n'existe pas). Sans
# ce fichier les PCM `gsm_out`/`gsm_in` que `mobile` ouvre n'existent pas, donc
# la voix TCH n'atteint jamais gsm_audio. Verifie absent dans la VM au boot.
if [ -f "$DIR/configs/asound.conf" ]; then
    cp -f "$DIR/configs/asound.conf" "$ROOTFS/etc/asound.conf"
    echo -e "  ${GREEN}✓${NC} /etc/asound.conf (PCM gsm_out/gsm_in → sinks PulseAudio)"
fi
cat > "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh" <<'ACHAIN'
#!/bin/bash
# osmo-audio-chain.sh - ferme la chaine audio locale apres le demarrage de
# PulseAudio. Appele en ExecStartPost par osmo-pulse.service.
#   1. /etc/asound.conf present (PCM gsm_out/gsm_in)
#   2. les DEUX null-sinks gsm_audio + gsm_mic charges
#   3. le module-loopback gsm_audio.monitor → carte son
# Sans (2), gapk_io abandonne LES DEUX SENS ; sans (3), la voix descendante est
# jetee par le null-sink. Toujours exit 0 : l'audio ne doit jamais empecher la
# pile de monter. AUDIO=0 ou AUDIO_LOCAL_LOOPBACK=0 neutralisent.
set -u
for r in /opt/GSM/osmo_egprs /opt/osmo_egprs /etc/osmocom/osmo_egprs; do
    [ -x "$r/scripts/audio-chain.sh" ] && exec "$r/scripts/audio-chain.sh" "${1:-30}"
done
exit 0
ACHAIN
chmod +x "$ROOTFS/usr/local/sbin/osmo-audio-chain.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-pulse.service" <<'EOF'
[Unit]
Description=osmo_egprs PulseAudio system daemon (GSM audio)
After=sound.target
[Service]
Type=forking
ExecStart=/usr/bin/pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 --log-target=file:/var/log/osmocom/pulse-system.log
ExecStartPre=/bin/mkdir -p /var/log/osmocom /var/run/pulse
# [2026-08-14] Sans ceci, gsm_audio (module-null-sink) n'a AUCUN consommateur :
# la voix descendante y est jetee par construction, la sortie ALSA reste
# SUSPENDED et l'appel est muet. Le loopback est le maillon qui manquait - il
# est pose ici, par le demon lui-meme, donc il survit a un restart du service.
# Non fatal (le script sort 0 quoi qu'il arrive) : l'audio ne doit jamais
# empecher la pile de monter. AUDIO_LOCAL_LOOPBACK=0 le neutralise.
# Passe par un wrapper /usr/local/sbin (meme patron que osmo-update.sh) : une
# directive `ExecStartPost=/bin/sh -c "... \" ... \" ..."` avec guillemets
# imbriques est ACCEPTEE par `systemctl cat` mais rejetee par le parseur -
# `systemctl show -p ExecStartPost` revient alors VIDE et rien ne s'execute.
ExecStartPost=/usr/local/sbin/osmo-audio-chain.sh 30
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# Idem pour l'audio : le hub ne porte aucun appel, il route de la signalisation.
[ "$ISO_ROLE" = "interstp" ] || chroot "$ROOTFS" systemctl enable osmo-pulse 2>/dev/null||true

# Modules noyau
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Variables d'environnement
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# bashrc pour root
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
# Active par defaut l'environnement python (gr-gsm + bridges) utilise par
# /opt/GSM/osmo_egprs/start-direct.sh. VIRTUAL_ENV_DISABLE_PROMPT pour garder le PS1.
export VIRTUAL_ENV_DISABLE_PROMPT=1
[ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
alias faketrx='python3 /opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py'
alias osmo-lab='cd /opt/GSM/osmo_egprs && ./start-direct.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/etc/osmocom/status.sh status'
export PATH="$HOME/.local/bin:$PATH"

### calypso-prompt ###
export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️ # '
### end calypso-prompt ###
BASH

# Message du jour - banniere couleur + boite alignee. Contenu de la boite en
# ASCII (pas de ←/e/• multi-octets) + padding printf => bords parfaitement
# alignes. Genere a chaud pour injecter les couleurs ANSI dans /etc/motd.
{
  B=$'\033[1;36m'; T=$'\033[1;37m'; G=$'\033[1;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
  W=58
  printf '\n%b' "$B"
  cat <<'LOGO'
    ___  ___ _ __ ___   ___    ___  __ _ _ __  _ __ ___
   / _ \/ __| '_ ` _ \ / _ \  / _ \/ _` | '_ \| '__/ __|
  | (_) \__ \ | | | | | (_) ||  __/ (_| | |_) | |  \__ \
   \___/|___/_| |_| |_|\___/  \___|\__, | .__/|_|  |___/
                                   |___/|_|
LOGO
  printf '%b' "$N"
  printf "${B}  ╔"; printf '═%.0s' $(seq 1 $W); printf "╗${N}\n"
  printf "${B}  ║${N} ${T}%-*s${N} ${B}║${N}\n" $((W-2)) "GSM / EGPRS  Multi-PLMN  Live System"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "SS7/SIGTRAN  -  Osmocom  -  Calypso/QEMU"
  printf "${B}  ╠"; printf '═%.0s' $(seq 1 $W); printf "╣${N}\n"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "/opt/GSM/osmo_egprs/start-direct.sh"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "    -> lance le lab Calypso/QEMU (A5/1)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "Dashboard web  ->  http://<vm-ip>:8080"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "FFT spectres   ->  http://<vm-ip>:8081"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "Wiki / docs        ->  pl4y.store"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "ssh root@<vm-ip>   -> mot de passe : osmo"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "loadkeys fr   -> changer le clavier (apres boot)"
  printf "${B}  ╚"; printf '═%.0s' $(seq 1 $W); printf "╝${N}\n\n"
} > "$ROOTFS/etc/motd"

# Mot de passe root = "osmo" (autologin console + login SSH). On NE vide PAS le
# mot de passe (sinon sshd refuse le login root).
echo 'root:osmo' | chroot "$ROOTFS" chpasswd 2>/dev/null || true

# ── Espace writable du live : /dev/shm + /tmp, en POURCENTAGE de la RAM ─────
# Le live boote en 'toram' → racine = overlay tmpfs (RAM). Les gros writers de la
# stack sont les cfiles I/Q dans /dev/shm (FFT/record, plusieurs centaines de Mo)
# et /tmp. systemd applique ces entrees au boot.
#
# POURQUOI PLUS 2 Go EN DUR
# Ces caps ne reservent rien, mais ils AUTORISENT : 2 + 2 Go, sur une machine
# ou le squashfs occupe deja ~2,5 Go de RAM et ou la racine elle-meme est un
# tmpfs, c'est plus que ce dont dispose une VM de 8 Go. Deux writers un peu
# gourmands suffisaient alors a saturer la memoire - et le symptome n'est pas
# "tmpfs plein" mais une machine exsangue : "No space left on device" sur la
# racine, puis un sshd qui n'arrive meme plus a envoyer sa banniere.
#
# En pourcentage, le plafond suit la taille de la machine : 20 % + 15 % laissent
# toujours les deux tiers de la RAM au squashfs, a la racine et aux processus.
# Une VM a 16 Go y gagne autant qu'une VM a 8 Go cesse de se noyer.
# Idempotent + anti-doublon : on purge d'abord toute entree tmpfs /tmp ou /dev/shm
# preexistante (y compris la variante 'nosuid,nodev' sans size=) et l'ancien
# commentaire de bloc, PUIS on (re)ecrit le bloc canonique size en pourcentage. Garantit
# exactement une entree /tmp et une entree /dev/shm dans le fstab du squashfs.
touch "$ROOTFS/etc/fstab"
sed -i -E \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]/d' \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/dev\/shm[[:space:]]/d' \
    -e '/^# osmo_egprs live - espace writable/d' \
    "$ROOTFS/etc/fstab"
# /dev/shm : sizing via fstab (sans risque de doublon generateur).
cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
# osmo_egprs live - espace writable (cfiles I/Q FFT)
tmpfs   /dev/shm   tmpfs   defaults,nosuid,nodev,size=20%   0 0
FSTAB
# /tmp : PAS dans fstab. Une entree fstab /tmp entre en collision avec l'unite
# systemd tmp.mount -> "systemd-fstab-generator: tmp.mount already exists,
# Duplicate entry in /etc/fstab" (generateur en exit 1) ; en plus tools/update.sh la
# reinjecte au boot. On gere /tmp en natif systemd via un drop-in size=15% : une
# seule source, zero doublon possible quoi que fasse update.sh.
mkdir -p "$ROOTFS/etc/systemd/system/tmp.mount.d"
cat > "$ROOTFS/etc/systemd/system/tmp.mount.d/size.conf" <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=15%
EOF
chroot "$ROOTFS" systemctl enable tmp.mount 2>/dev/null || true

# ── Ce qui remplit la RAM : les ECRITURES DE LA PILE ────────────────────────
# En 'toram' la racine est un overlay tmpfs : TOUT ce qui s'ecrit a l'execution
# reste en RAM, rien n'atteint un disque. Le squashfs y est deja recopie, /tmp
# et /dev/shm en reservent 2 Go chacun - le reste, quelques Go, est tout ce dont
# dispose la racine.
#
# Trois writers non bornes suffisaient a la remplir, et le symptome n'apparait
# qu'apres des heures : "No space left on device" sur une machine qui n'a
# pourtant aucun disque plein.
#   1. le journal systemd, sans plafond ;
#   2. /var/log/osmocom/*.log - la pile journalise en 'filter all 1', et mobile
#      tourne avec une vingtaine de categories de debug ;
#   3. les captures pcap GSMTAP, ecrites en continu et sans limite de taille.
# On les borne ici, dans l'image : un cap pose au build vaut pour toutes les VM,
# alors qu'un nettoyage manuel est a refaire apres chaque boot.

# 1. Journal : volatile (il est de toute facon perdu au reboot d'un live) et
#    plafonne. Sans RuntimeMaxUse, journald s'autorise 10 % de la RAM.
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
cat > "$ROOTFS/etc/systemd/journald.conf.d/osmo-live.conf" <<'EOF'
# osmo_egprs live : la racine est en RAM, le journal ne doit pas la manger.
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeKeepFree=256M
EOF

# 2. Logs Osmocom : rotation a la TAILLE, pas a la date - une pile bavarde
#    remplit en une heure ce qu'une rotation quotidienne ne verrait jamais.
#    copytruncate : les demons gardent leur descripteur ouvert ; sans lui la
#    rotation leur laisse un fichier supprime, et l'espace n'est pas rendu.
mkdir -p "$ROOTFS/etc/logrotate.d"
cat > "$ROOTFS/etc/logrotate.d/osmocom" <<'EOF'
/var/log/osmocom/*.log {
    size 32M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
# logrotate.timer ne passe qu'une fois par jour : trop tard pour un tmpfs.
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.service" <<'EOF'
[Unit]
Description=osmo_egprs - rotation des journaux Osmocom (racine en RAM)
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/osmocom --state /run/osmo-logrotate.state
EOF
cat > "$ROOTFS/etc/systemd/system/osmo-logrotate.timer" <<'EOF'
[Unit]
Description=osmo_egprs - rotation des journaux Osmocom toutes les 15 min
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
chroot "$ROOTFS" systemctl enable osmo-logrotate.timer 2>/dev/null || true

# 3. Captures pcap : purge de celles de plus d'une heure. La capture GSMTAP
#    tourne en continu ; elle sert a regarder ce qui vient de se passer, pas a
#    constituer un historique - qu'aucun live ne pourrait de toute facon garder.
mkdir -p "$ROOTFS/etc/tmpfiles.d"
cat > "$ROOTFS/etc/tmpfiles.d/osmo-captures.conf" <<'EOF'
# osmo_egprs : les captures vivent en RAM, on ne les garde pas plus d'une heure.
d /run/user/0/osmo-nitb/captures 0755 root root 1h
EOF

# 3bis. Le ring, plutot qu'un fichier qui gonfle
# Purger toutes les heures ne protege de rien : entre deux passages, UNE
# capture continue peut a elle seule remplir la RAM - et sur un lien charge,
# c'est l'affaire de quelques minutes, pas d'une nuit. Un fichier unique en -w
# croit sans limite ; -C <Mo> -W <n> lui substitue un ANNEAU de n fichiers qui
# se recyclent : la capture ne s'arrete jamais, l'empreinte reste bornee.
#
# Par un wrapper plutot qu'en corrigeant les appelants : la capture GSMTAP est
# lancee depuis le dashboard web (autre depot, clone au build) et depuis des
# outils qui ne vivent pas dans ce depot-ci. Un wrapper vaut pour tous, y
# compris ceux qu'on ajoutera. /usr/local/bin precede /usr/bin dans le PATH :
# l'appel "tcpdump" passe par lui sans que rien n'ait a etre reecrit.
#
# Il ne force rien quand l'appelant a deja choisi (-C ou -W presents), et sans
# -w il n'y a rien a borner.
cat > "$ROOTFS/usr/local/bin/tcpdump" <<'TCPDUMPEOF'
#!/bin/sh
# tcpdump - wrapper osmo_egprs : impose un anneau aux captures sur fichier.
#
# La racine du live est un tmpfs : une capture non bornee finit par remplir la
# RAM, et l'erreur ("No space left on device") tombe des heures plus tard, sur
# une machine qui n'a pourtant aucun disque plein.
#
# DEUX PIEGES, DEUX PARADES
#  -Z root : avec -C/-W, tcpdump cree les membres suivants de l'anneau APRES
#            avoir abandonne ses privileges (utilisateur "tcpdump"). Sans -Z il
#            echoue des le premier : "Permission denied" - et aucune capture.
#            Sans -C il ouvrait le fichier AVANT, d'ou un fonctionnement qui ne
#            cassait qu'en ajoutant l'anneau.
#  lien    : avec -C/-W, tcpdump n'ecrit pas le nom demande mais numerote les
#            membres (capture.pcap0, .pcap1...). Le nom exact n'existe jamais,
#            et l'appelant qui l'attend conclut a un echec. On maintient donc
#            <nom exact> -> membre courant : la barriere le suit, qui ouvre le
#            fichier lit la capture en cours, et rien n'a a etre reecrit.
#
# Reglable : OSMO_PCAP_RING_MB (32), OSMO_PCAP_RING_FILES (5).
REAL=/usr/bin/tcpdump
[ -x "$REAL" ] || REAL=/usr/sbin/tcpdump

has_w=0; has_ring=0; has_z=0; wfile=""; next_is_w=0
for a in "$@"; do
    if [ "$next_is_w" = 1 ]; then wfile="$a"; next_is_w=0; continue; fi
    case "$a" in
        -w)            has_w=1; next_is_w=1 ;;
        -w?*)          has_w=1; wfile="${a#-w}" ;;
        -C|-C*|-W|-W*) has_ring=1 ;;
        -Z|-Z*)        has_z=1 ;;
    esac
done

# Rien a borner, ou l'appelant a deja choisi son anneau : on s'efface.
if [ "$has_w" != 1 ] || [ "$has_ring" = 1 ] || [ -z "$wfile" ]; then
    exec "$REAL" "$@"
fi

# Le veilleur du lien. Lance AVANT l'exec : apres, ce processus EST tcpdump.
# $$ reste le meme a travers l'exec, donc il suit exactement sa vie et s'arrete
# avec lui - aucun processus orphelin a nettoyer.
( ppid=$$
  n=0
  while [ "$n" -lt 300 ]; do
      [ -e "${wfile}0" ] && break
      kill -0 "$ppid" 2>/dev/null || exit 0
      sleep 0.2; n=$((n + 1))
  done
  while kill -0 "$ppid" 2>/dev/null; do
      newest=$(ls -t "${wfile}"[0-9]* 2>/dev/null | head -1)
      if [ -n "$newest" ] && [ "$(readlink "$wfile" 2>/dev/null)" != "$newest" ]; then
          ln -sfn "$newest" "$wfile"
      fi
      sleep 2
  done ) >/dev/null 2>&1 &

if [ "$has_z" = 1 ]; then
    exec "$REAL" -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
fi
exec "$REAL" -Z root -C "${OSMO_PCAP_RING_MB:-32}" -W "${OSMO_PCAP_RING_FILES:-5}" "$@"
TCPDUMPEOF
chmod +x "$ROOTFS/usr/local/bin/tcpdump"

# ── Purge complete a chaque relance ─────────────────────────────────────────
# Les caps ci-dessus empechent la derive PENDANT une session ; celui-ci repart
# d'une racine propre A CHAQUE DEMARRAGE. Sur un live c'est sans perte : ces
# fichiers ne survivraient pas au reboot de toute facon. Avec persistance, en
# revanche, ils s'accumuleraient d'un boot a l'autre jusqu'a remplir le medium -
# c'est precisement le cas ou la purge devient indispensable.
#
# Avant la pile (Before=osmo-*.service) : purger APRES le demarrage effacerait
# les journaux de la session en cours, et le premier incident serait invisible.
cat > "$ROOTFS/usr/local/sbin/osmo-purge.sh" <<'PURGEEOF'
#!/bin/bash
# osmo-purge.sh - repart d'une racine propre. Appele au boot par osmo-purge.service.
# Ne touche NI aux configs (/etc/osmocom), NI aux bases (HLR) : seulement ce qui
# se regenere - journaux, captures, fichiers de travail.
set -u

purge_dir() {   # $1=repertoire  $2=motif
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f -name "$2" -delete 2>/dev/null || true
}

# Journaux de la pile
purge_dir /var/log/osmocom '*.log'
purge_dir /var/log/osmocom '*.log.*'
purge_dir /var/log/osmocom '*.gz'

# Captures pcap (GSMTAP et autres)
rm -rf /run/user/0/osmo-nitb/captures/* 2>/dev/null || true
purge_dir /var/log/osmocom '*.pcap'
find /tmp /var/tmp -maxdepth 2 -type f -name '*.pcap*' -delete 2>/dev/null || true

# Fichiers de travail : I/Q FFT (plusieurs centaines de Mo piece)
find /dev/shm -maxdepth 1 -type f \( -name '*.cfile' -o -name '*.raw' \) -delete 2>/dev/null || true

# Repertoire d'execution du live, recree par la pile au demarrage
rm -rf /run/user/0/osmo-nitb/logs/* 2>/dev/null || true

# Journal systemd volatile
command -v journalctl >/dev/null 2>&1 && journalctl --rotate --vacuum-time=1s >/dev/null 2>&1

exit 0
PURGEEOF
chmod +x "$ROOTFS/usr/local/sbin/osmo-purge.sh"
cat > "$ROOTFS/etc/systemd/system/osmo-purge.service" <<'EOF'
[Unit]
Description=osmo_egprs - purge des journaux, captures et fichiers de travail
DefaultDependencies=no
After=local-fs.target
Before=osmo-stp.service osmo-interstp.service osmo-msc.service osmo-bsc.service
Before=osmo-egprs-web.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-purge.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-purge.service 2>/dev/null || true

# SSH : autorise le login root par mot de passe + active le service au boot.
if [ -f "$ROOTFS/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
        "$ROOTFS/etc/ssh/sshd_config"
    grep -q '^PermitRootLogin yes' "$ROOTFS/etc/ssh/sshd_config" || \
        echo 'PermitRootLogin yes' >> "$ROOTFS/etc/ssh/sshd_config"
fi
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# ── Clavier : fige DANS l'image, plus demande au premier boot ───────────────
# Le choix se fait au debut de cette construction (voir "LES QUESTIONS"). Ici on
# ne fait que l'ecrire. L'ancienne version posait la question dans
# /etc/profile.d au premier login : chaque machine du banc s'arretait alors sur
# un menu, et une VM demarree sans console attendait une reponse que personne
# n'allait donner.
cat > "$ROOTFS/etc/default/keyboard" <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${OSMO_ISO_KB}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
chroot "$ROOTFS" setupcon --force 2>/dev/null || true
chroot "$ROOTFS" dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

# Ce qui reste au login : le rappel, qui n'attend rien.
# La commande DEPEND du role : le hub n'a pas de coeur GSM a demarrer, et
# start-direct.sh y chercherait un BSC, un MSC, une BTS qui n'existent pas.
# Lui dicter start-direct.sh, c'est envoyer droit dans une erreur.
if [ "$ISO_ROLE" = "interstp" ]; then
    OSMO_START_HINT='Pour demarrer le hub SS7 : /opt/osmo_egprs/start-interstp.sh'
    OSMO_START_HINT2='  (etat des noeuds attaches : ./start-interstp.sh --status)'
else
    OSMO_START_HINT='Pour demarrer la stack : /opt/osmo_egprs/start-direct.sh --node N'
    OSMO_START_HINT2='  (N de 1 a 9 : il fixe les point codes 1.<N>1.x du noeud)'
fi
cat > "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh" <<KBSCRIPT
#!/bin/bash
[ "\$(id -u)" -ne 0 ] && return 0
[ -n "\${OSMO_DISCLAIMER_SHOWN:-}" ] && return 0
export OSMO_DISCLAIMER_SHOWN=1
echo -e "  \033[1;33mDisclaimer:\033[0m aucun service Osmocom n'est lance automatiquement."
echo -e "  \033[1;33m${OSMO_START_HINT}\033[0m"
echo -e "  \033[0;36m${OSMO_START_HINT2}\033[0m"
echo -e "  clavier : \033[1;32m\$(awk -F\\" '/^XKBLAYOUT/{print \$2}' /etc/default/keyboard 2>/dev/null)\033[0m  \033[0;36m(changer : osmo-keyboard)\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-osmo-disclaimer.sh"
rm -f "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"

# Le choix du clavier reste offert - mais QUAND ON LE DEMANDE. C'est le meme
# menu qu'avant ; ce qui change, c'est qu'il ne s'interpose plus entre le login
# et le shell : une VM sans console ne peut plus rester bloquee dessus.
cat > "$ROOTFS/usr/local/bin/osmo-keyboard" <<'KBCMD'
#!/bin/bash
# osmo-keyboard - change la disposition clavier du systeme, a la demande.
[ "$(id -u)" -ne 0 ] && { echo "Root requis."; exit 1; }

if [ -n "$1" ]; then
    KB_LAYOUT="$1"
else
    echo ""
    echo -e "\033[1;36m== Configuration clavier ==\033[0m"
    echo "  1) fr    2) us    3) de    4) es    5) it"
    echo "  6) pt    7) gb    8) be    9) ch    0) autre"
    echo ""
    read -rp "  Choix [1] : " KB_CHOICE
    case "${KB_CHOICE:-1}" in
        1|"") KB_LAYOUT="fr" ;;
        2) KB_LAYOUT="us" ;;  3) KB_LAYOUT="de" ;;
        4) KB_LAYOUT="es" ;;  5) KB_LAYOUT="it" ;;
        6) KB_LAYOUT="pt" ;;  7) KB_LAYOUT="gb" ;;
        8) KB_LAYOUT="be" ;;  9) KB_LAYOUT="ch" ;;
        0) read -rp "  Layout (fr, us, ru, ar...) : " KB_LAYOUT
           KB_LAYOUT="${KB_LAYOUT:-us}" ;;
        *) KB_LAYOUT="fr" ;;
    esac
fi

loadkeys "$KB_LAYOUT" 2>/dev/null || true
cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF
setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true
echo -e "  \033[1;32mClavier : ${KB_LAYOUT}\033[0m   (sans persistance, revient au reboot)"
KBCMD
chmod +x "$ROOTFS/usr/local/bin/osmo-keyboard"
umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminee"

# ── Creation du squashfs et de l'ISO ───────────────────────────────────────
echo -e "${GREEN}[9/9] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-*|sort -V|tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-*|sort -V|tail -1)
[ -z "$VMLINUZ" ]||[ -z "$INITRD" ] && { echo -e "${RED}Kernel absent${NC}"; exit 1; }
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 1M \
    -e 'boot/vmlinuz-*' -e 'boot/initrd*' \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

cp "$VMLINUZ" "$ISOROOT/boot/vmlinuz"
cp "$INITRD"  "$ISOROOT/boot/initrd.img"

cat > "$ISOROOT/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5
menuentry "osmo_egprs - Live (toram - RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram quiet
    initrd /boot/initrd.img
}
menuentry "osmo_egprs - Live USB sans toram (RAM ~3 Go, lit depuis le medium)" {
    linux  /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}
menuentry "osmo_egprs - Live verbose (toram - RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram
    initrd /boot/initrd.img
}
menuentry "osmo_egprs - Copy to RAM (toram - RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram copytoram quiet
    initrd /boot/initrd.img
}

# ── Persistance ─────────────────────────────────────────────────────────────
# Sans elle, la racine est un overlay tmpfs : tout ce qui s'ecrit vit en RAM et
# meurt au reboot - configs SS7 posees a la main, base HLR, journaux compris.
# C'est aussi ce qui rendait l'espace si vite compte : la pile ecrivait dans la
# memoire, pas sur un disque.
#
# PAS de toram ici, et c'est le point : avec toram le systeme est recopie en RAM
# et l'overlay y reste, ce qui annulerait l'interet. Sans lui, live-boot monte
# l'union sur le volume de persistance et les ecritures atterrissent sur le
# medium.
#
# Cote support, il faut un volume ETIQUETE "persistence" contenant un fichier
# persistence.conf dont la seule ligne utile est "/ union" :
#
#   sudo mkfs.ext4 -L persistence /dev/sdX3
#   sudo mount /dev/sdX3 /mnt && echo "/ union" | sudo tee /mnt/persistence.conf
#
# En VM, un second disque suffit. Sans volume ainsi etiquete, cette entree
# demarre exactement comme un live ordinaire : rien ne casse, rien n'est garde.
menuentry "osmo_egprs - Live PERSISTANT (ecrit sur le medium, pas en RAM)" {
    linux  /boot/vmlinuz boot=live persistence persistence-encryption=none quiet
    initrd /boot/initrd.img
}
menuentry "osmo_egprs - Live PERSISTANT verbose" {
    linux  /boot/vmlinuz boot=live persistence persistence-encryption=none
    initrd /boot/initrd.img
}
GRUB

# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
    --product-name "osmo_egprs $VERSION" -- -volid "$LABEL"
    if command -v isohybrid &>/dev/null; then
    isohybrid --uefi "$OUTPUT"
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}grub-mkrescue a echoue - ISO non creee${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}═══ ISO prete : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
