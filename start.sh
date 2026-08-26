#!/bin/bash
# start.sh - Lance la stack Osmocom GSM multi-operateurs
#
# Modes : net-host (1 operateur, SDR physique) | bridge (N operateurs SS7 inter-op)
set -eu

# ── Ce script est le lanceur de l'HOTE. Refus net s'il tourne DANS le conteneur ──
# [2026-08-12] start.sh pilote docker (build, reseaux, `docker run`, volumes) ;
# start-direct.sh, lui, prepare l'environnement Calypso et lance run.sh A
# L'INTERIEUR. Les confondre ne donne pas une erreur lisible : `docker` n'existe
# pas dans l'image, donc on part sur une cascade de "command not found" apres
# avoir deja cree des fichiers et touche des configs. Mieux vaut s'arreter avant
# d'avoir rien fait, et nommer le script a utiliser.
#
# Discriminant verifie dans LES DEUX SENS le 12/08 : `/.dockerenv` et
# `/etc/docker-entrypoint-cmd` (pose par scripts/entrypoint.sh) sont presents
# dans le conteneur et absents sur l'hote. On exige les DEUX : `/.dockerenv`
# seul serait vrai dans n'importe quel conteneur, y compris un ou ce script
# aurait legitimement sa place.
if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then
    printf '\033[1;31mVous etes dans le docker ! Utilisez start-direct.sh\033[0m\n' >&2
    printf '\n  \033[0;36m/opt/GSM/osmo_egprs/start-direct.sh\033[0m   (ou ./start-direct.sh depuis le depot)\n' >&2
    printf '\n  start.sh est le lanceur de l'"'"'HOTE : il construit l'"'"'image, cree les\n' >&2
    printf '  reseaux et fait le "docker run". Rien de tout ca n'"'"'a de sens ici.\n' >&2
    exit 1
fi

DEBUG=
if [[ -n "$DEBUG" ]]; then
    set -x
    PS4='[DEBUG] + ${BASH_SOURCE}:${LINENO}: '
    echo "=== MODE DEBUG ACTIVE ==="
fi

IMAGE_BASE="osmocom-nitb"
# [2026-08-12] Surchargeable depuis l'environnement - c'est ce que fait
# start-nitb.sh, qui relance exactement ce script avec IMAGE_RUN=osmocom-nitb.
# Idiome `:=` du projet : une valeur posee explicitement en amont gagne, le
# defaut ne s'applique qu'a vide. NE PAS remettre en dur : start-nitb.sh
# deviendrait silencieusement un alias de start.sh, ce qui est indiscernable
# d'un lanceur qui marche.
IMAGE_RUN="${IMAGE_RUN:-osmocom-run}"

INTER_NET="gsm-inter"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

# Quel noeud du WAN heberge le hub SS7. UN SEUL doit le faire : deux hubs, c'est
# deux reseaux SS7 separes qui s'ignorent, et rien ne le signale.
WAN_HUB_NODE="${WAN_HUB_NODE:-1}"
# --hub-ip : l'inter-STP designe par son ADRESSE, pas par un numero de noeud.
# --hub-node oblige a le faire figurer dans la table WAN ; sur un banc ou le hub
# est une machine a part - une VM dediee, sans operateur - cela forcait a
# inventer un noeud pour lui, qui apparaissait ensuite dans les indicatifs et le
# routage voix/SMS comme s'il portait des abonnes. Avec --hub-ip la table ne
# contient que de vrais noeuds.
WAN_HUB_IP="${WAN_HUB_IP:-}"
# --node-per-op : chaque conteneur est un NOEUD, pas un operateur de la machine.
# A n'utiliser que quand les conteneurs ont une adresse joignable de l'exterieur
# (backbone route vers le LAN) : sinon les autres noeuds ne peuvent pas les
# appeler, et un noeud injoignable vaut moins qu'un operateur bien range.
WAN_NODE_PER_OP="${WAN_NODE_PER_OP:-0}"
# --operator IP:PREFIXE : declarer un operateur du WAN, ou qu'il soit.
# La table WAN se saisissait jusqu'ici par --wan-nodes "id:ip:ind", une forme
# exacte mais qui suppose qu'on connaisse deja les numeros de noeud. Declarer
# "une machine a cette adresse, joignable par ce prefixe" est plus proche de ce
# qu'on a sous les yeux - une VM, un conteneur - et les numeros suivent l'ordre
# de declaration.
OPERATOR_DECLS=()
OPERATOR_COUNT_HINT=""
IMAGE_STP="${IMAGE_STP:-osmocom-stp}"
INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── SMS Routing ────────────────────────────────────────────────────────────────
SMS_ROUTING_SCRIPT="$(dirname "$0")/scripts/sms-routing-setup.sh"
if [ -f "$SMS_ROUTING_SCRIPT" ]; then
    source "$SMS_ROUTING_SCRIPT"
fi
SMS_ROUTING_DIR=""

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
# Deux WAN coexistent ici, et ils ne font PAS la meme chose :
#
#   WAN_ENABLED (legacy, --pas d'option, question whiptail) : DEUX serveurs,
#     prefixe unique 66, network/setup-wan-interop.sh. Conserve tel quel.
#
#   WAN_MESH (option --wan) : N noeuds (1 a 9), UN INDICATIF PAR NOEUD,
#     network/setup-wan-mesh.sh. C'est le seul qui tienne au-dela de deux
#     serveurs - le legacy reecrit son bloc de conf a chaque appel, donc
#     l'enchainer sur trois pairs ne laisse que le dernier.
#
# Les deux sont EXCLUSIFS et aucun n'est actif par defaut.
WAN_MESH=0
# --virtualbox : les pairs du WAN sont des VM VirtualBox sur CETTE machine, et
# cette machine est elle-meme un noeud. Voir network/setup-vbox-interco.sh.
VBOX_INTERCO=0
VBOX_NODES=""
VBOX_HOST_NODE=1
BUILD_STP=0
# shellcheck source=network/wan-nodes.sh
. "$(dirname "$0")/network/wan-nodes.sh"

WAN_ENABLED="false"
WAN_LOCAL_IP=""
WAN_REMOTE_IP=""
WAN_N_REMOTE=""
WAN_PREFIX="66"
WAN_SIP_BASE=5080
WAN_RTP_BASE=20000
WAN_RTP_PER_OP=500
PHY_MODE="faketrx"   # faketrx | virtphy
# Choix passes au start-direct.sh DANS le conteneur via le handoff (NO_MENU=1),
# pour eviter les menus whiptail laggy en docker exec -ti. Fixes sur l'HOTE.
# Retenu AVANT le defaut : "l'appelant a-t-il impose le mode ?". C'est ce qui
# permet a --wan de basculer en hybride sans ecraser un HANDOFF_MODE=... explicite.
HANDOFF_MODE_FROM_ENV="${HANDOFF_MODE:+1}"
HANDOFF_MODE="${HANDOFF_MODE:-qemu}"               # qemu | faketrx-qemu (combine)
HANDOFF_QEMU_CHOICE="${HANDOFF_QEMU_CHOICE:-full-grgsm}"

# ── Helpers ────────────────────────────────────────────────────────────────────
# ── Les deux plans d'adressage d'un operateur ───────────────────────────────
# backbone  172.20.0.<10+op>  le segment que TOUS partagent avec l'inter-STP
#                             (.10). C'est par la que passe le SS7, et c'est ce
#                             reseau que network/setup-docker-lan-route.sh rend
#                             joignable depuis le LAN des VM.
# prive     192.168.<op+1>.x  un segment par operateur : son BTS, son PCU, son
#                             GGSN. Rien n'y entre de l'exterieur.
#
# POURQUOI <op+1> ET PAS <op>
# Le LAN du banc est 192.168.1.0/24 - celui des VM et du hub SS7 en .49. Un
# operateur 1 en 192.168.1.0/24 entrerait en collision avec lui : deux routes
# pour le meme reseau sur l'hote, et un conteneur qui ne peut plus joindre le
# hub. Le decalage d'un rang laisse le .1 au LAN et commence les operateurs a
# 192.168.2.0/24.
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
op_private_ip()   { echo "192.168.$(($1 + 1)).10"; }
op_private_gw()   { echo "192.168.$(($1 + 1)).1"; }
op_private_net()  { echo "192.168.$(($1 + 1)).0/24"; }
op_container()    { echo "osmo-operator-$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }

# WAN helpers
wan_sip_port()    { echo $(( WAN_SIP_BASE + ($1 - 1) * 2 )); }
wan_rtp_start()   { echo $(( WAN_RTP_BASE + ($1 - 1) * WAN_RTP_PER_OP )); }
wan_rtp_end()     { echo $(( WAN_RTP_BASE + $1 * WAN_RTP_PER_OP - 1 )); }

wan_sms_port()    { echo $(( 7890 + $1 - 1 )); }
# Un WAN est actif - legacy OU mesh. Sert partout ou la question est "faut-il
# ouvrir les ports WAN", independamment du mecanisme choisi.
wan_active()      { [ "$WAN_ENABLED" = "true" ] || [ "${WAN_MESH:-0}" = "1" ]; }

# Linphone helpers - port SIP/RTP expose sur le host
linphone_sip_port()  { echo $(( 5060 + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }

# Global - detecte avant la boucle operateurs
HOST_IP="127.0.0.1"
ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
HOST_AUDIO_RELAY=""
WSLG_TCP_PORT="${WSLG_TCP_PORT:-4713}"

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Osmocom GSM/EGPRS Virtual Network            ║"
    echo "║        Multi-Operator SS7 + osmo-gapk Audio          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Whiptail helpers ────────────────────────────────────────────────────────
WT_BACKTITLE="Osmocom GSM/EGPRS Virtual Network"
WT_WIDTH=72

check_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        echo -e "${RED}whiptail introuvable.${NC} Installez-le :" >&2
        echo -e "  ${CYAN}apt-get install -y whiptail${NC}  (Debian/Ubuntu)" >&2
        echo -e "  ${CYAN}dnf install -y newt${NC}          (Fedora/RHEL)" >&2
        exit 1
    fi
}

wt_input() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" \
        --inputbox "$2" 10 "$WT_WIDTH" "$3" 3>&1 1>&2 2>&3
}

wt_yesno() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" \
        --defaultno --yesno "$2" 11 "$WT_WIDTH" 3>&1 1>&2 2>&3
}

wt_menu() {
    local title="$1" prompt="$2"; shift 2
    local nitems=$(( $# / 2 ))
    whiptail --backtitle "$WT_BACKTITLE" --title "$title" \
        --menu "$prompt" 20 "$WT_WIDTH" "$nitems" "$@" 3>&1 1>&2 2>&3
}

wt_msg() {
    whiptail --backtitle "$WT_BACKTITLE" --msgbox "$1" 10 "$WT_WIDTH"
}

# ── Loopback audio cote session utilisateur ───────────────────────────────
# ── Session audio de l'hote : QUI, et OU ────────────────────────────────────
# [2026-08-12] Ces deux fonctions codaient "nirvana" en dur et cherchaient
# /home/<user>/osmo_egprs/loopback.sh - un chemin QUI N'EXISTE PAS (le script
# est network/loopback.sh). Resultat : enable_user_loopback echouait sur toute
# machine sans utilisateur nirvana, et disable_user_loopback (appele a l'arret)
# etait deja du code mort ICI. On resout les deux a l'execution.
#
# Le critere du bon utilisateur n'est pas son nom mais la PRESENCE de son socket
# pulse : c'est la seule chose qui distingue une session graphique vivante d'un
# compte qui existe. Meme logique que session_user() de wslg-audio-bridge.sh,
# etendue au balayage de /run/user/*.
session_pulse_user() {
    local u uid sock
    for u in "${HOST_PULSE_USER:-}" "${SUDO_USER:-}" "$(logname 2>/dev/null || true)" "${USER:-}"; do
        [ -n "$u" ] || continue
        uid="$(id -u "$u" 2>/dev/null)" || continue
        [ -S "/run/user/${uid}/pulse/native" ] && { echo "$u"; return 0; }
    done
    # Dernier recours : proprietaire du premier socket pulse trouve. Couvre le
    # `sudo -i` (SUDO_USER perdu) et les sessions sans logname (cron, service).
    for sock in /run/user/*/pulse/native; do
        [ -S "$sock" ] || continue
        uid="${sock#/run/user/}"; uid="${uid%%/*}"
        u="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)"
        [ -n "$u" ] && { echo "$u"; return 0; }
    done
    return 1
}

# Le script de loopback vit dans le depot, pas dans un $HOME.
find_loopback_script() {
    local d c
    d="$(cd "$(dirname "$0")" && pwd)"
    for c in "$d/network/loopback.sh" "$d/loopback.sh"; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

enable_user_loopback() {
    local target_user target_uid target_runtime loopback_script
    target_user="$(session_pulse_user)" || {
        echo -e "  ${YELLOW}[audio] aucune session PulseAudio utilisateur - loopback ignore${NC}"
        return 0
    }
    loopback_script="$(find_loopback_script)" || {
        echo -e "  ${YELLOW}[audio] network/loopback.sh introuvable - loopback ignore${NC}"
        return 0
    }
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    echo -e "${GREEN}=== [audio] Loopback user session ===${NC}"
    echo -e "  user    : ${CYAN}${target_user}${NC}"
    echo -e "  runtime : ${CYAN}${target_runtime}${NC}"
    echo -e "  script  : ${CYAN}${loopback_script}${NC}"
    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" enable >/dev/null 2>&1 || {
            echo -e "  ${RED}[FAIL]${NC} enable loopback"
            return 1
        }
    echo -e "[ OK ]${NC} loopback active"
}

disable_user_loopback() {
    local target_user target_uid target_runtime loopback_script
    target_user="$(session_pulse_user)"       || return 0
    loopback_script="$(find_loopback_script)" || return 0
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" disable || true
}

build_alsa_args() {
    local alsa_args=""
    local src_asound="$(dirname "$0")/configs/asound.conf"
    local host_asound="/tmp/osmocom-alsa/asound.conf"
    mkdir -p /tmp/osmocom-alsa
    if [ -d /dev/snd ]; then
        alsa_args="${alsa_args} --device /dev/snd"
        if getent group audio >/dev/null 2>&1; then
            alsa_args="${alsa_args} --group-add $(getent group audio | cut -d: -f3)"
        fi
    fi
    local has_pulse="true"
    alsa_args="${alsa_args} -e PULSE_SERVER=unix:/run/pulse/native"
    if [ -f "$src_asound" ]; then
        cp "$src_asound" "$host_asound"
        alsa_args="${alsa_args} -v ${host_asound}:/etc/asound.conf:rw"
        alsa_args="${alsa_args} -e ALSA_OUTPUT=gsm_out -e ALSA_INPUT=gsm_in"
        alsa_args="${alsa_args} -e ALSA_CARD=gsm_out -e GAPK_ALSA_DEV=gsm_out"
        if [ "$has_pulse" = "true" ]; then
            echo -e "  ${GREEN}Audio : PulseAudio + asound.conf${NC}" >&2
        else
            echo -e "  ${YELLOW}Audio : asound.conf sans PulseAudio${NC}" >&2
        fi
    else
        alsa_args="${alsa_args} -e ALSA_OUTPUT=default -e ALSA_INPUT=default"
        alsa_args="${alsa_args} -e ALSA_CARD=default -e GAPK_ALSA_DEV=default"
        echo -e "  ${YELLOW}Audio : configs/asound.conf absent, fallback default${NC}" >&2
    fi
    echo "$alsa_args"
}

# ── Audio hote : expose le pulse de l'hote en TCP ──────────────────────────
ensure_host_audio_relay() {
    [ -n "${HOST_AUDIO_RELAY_DONE:-}" ] && return 0
    HOST_AUDIO_RELAY_DONE=1
    local bridge="$(dirname "$0")/scripts/wslg-audio-bridge.sh"
    [ -x "$bridge" ] || { echo -e "  ${YELLOW}[host-audio] $bridge introuvable${NC}" >&2; return 0; }
    if "$bridge" host-relay; then
        HOST_AUDIO_RELAY="tcp:${INTER_NET_GATEWAY}:${WSLG_TCP_PORT:-4713}"
        echo -e "  ${GREEN}[host-audio] relai pret → ${HOST_AUDIO_RELAY}${NC}"
    else
        HOST_AUDIO_RELAY=""
        echo -e "  ${YELLOW}[host-audio] relai non ouvert - fallback carte locale dans le conteneur${NC}"
    fi

    # [2026-08-12] Sens MONTANT (micro). Le relai ci-dessus ne couvre que la
    # descente (gsm_audio.monitor → HP de l'hote). Le micro, lui, vient du
    # navigateur, qui capture la source PAR DEFAUT de l'hote - laquelle peut
    # tres bien etre une entree fantome qui ne sort que du zero (vecu ici :
    # defaut non mute a 93 % et pourtant silence total, cf. host_mic()).
    # On choisit donc la source a l'oreille, pas au nom. Non fatal.
    "$bridge" host-mic || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Build
# ══════════════════════════════════════════════════════════════════════════════
QUICK="${OSMO_QUICK:-0}"
QUICK_EXPLICIT=0; [ -n "${OSMO_QUICK:-}" ] && QUICK_EXPLICIT=1

build_run_image() {
    if [ "${QUICK:-0}" = "1" ]; then
        echo -e "${GREEN}Build de l'image run...${NC} ${YELLOW}(quick - cache docker reutilise)${NC}"
        docker build --build-arg QEMU_CACHE_BUST=$(date +%s) -f Dockerfile.run -t "$IMAGE_RUN" .
    else
        echo -e "${GREEN}Build de l'image run...${NC} ${CYAN}(normal - --no-cache)${NC}"
        docker build --no-cache --build-arg QEMU_CACHE_BUST=$(date +%s) -f Dockerfile.run -t "$IMAGE_RUN" .
    fi
    echo -e "${GREEN}Image '$IMAGE_RUN' prete.${NC}"
}

check_image() {
    if ! docker image inspect "$IMAGE_RUN" &>/dev/null; then
        echo -e "${RED}Image '$IMAGE_RUN' introuvable - build en cours...${NC}"
        build_run_image
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Generation dynamique - pjsip interop trunks
# ══════════════════════════════════════════════════════════════════════════════
generate_pjsip_interop_trunks() {
    local op_id=$1
    local n_operators=$2
    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        local remote_ip
        remote_ip=$(op_backbone_ip "$remote_op")
        cat <<EOF

[interop-identify-op${remote_op}]
type=identify
endpoint=interop_trunk_op${remote_op}
match=${remote_ip}

[interop_trunk_op${remote_op}]
type=endpoint
transport=transport-udp
context=interop_in
disallow=all
allow=gsm
allow=ulaw
aors=interop_trunk_op${remote_op}
direct_media=no
rtp_symmetric=yes
force_rport=yes
media_encryption=no

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}

generate_extensions_interop_out() {
    local op_id=$1
    local n_operators=$2
    cat <<'EOF'
[interop_out]

EOF
    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${remote_op}XXXX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

exten => _${remote_op}XXXXX,1,NoOp(=== INTEROP OUT Op${remote_op} 5d: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done
    cat <<'EOF'
exten => _X.,1,NoOp(=== INTEROP OUT: inconnu ${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# SMS routing fallback
# ══════════════════════════════════════════════════════════════════════════════
_generate_sms_routing_conf_fallback() {
    # 'local i' n'est PAS cosmetique. Cette fonction est appelee, via
    # apply_config_templates, DEPUIS la boucle "for i in ..." qui demarre les
    # operateurs. Sans local, sa propre boucle ecrase la variable de l'appelant
    # et la laisse a n_operators : tous les conteneurs suivants calculaient
    # alors leurs ports avec le MEME indice, d'ou
    #     Bind for 0.0.0.0:5082 failed: port is already allocated
    # au deuxieme conteneur - et, avant l'erreur, deux operateurs annonces sur
    # les memes SIP/RTP/SMS.
    local i
    local op_id=$1 n_operators=$2
    printf '# sms-routing.conf - Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    for i in $(seq 1 "$n_operators"); do
        printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"
    done
    printf '\n[routes]\n'
    for i in $(seq 1 "$n_operators"); do
        for ms in 1 2; do printf '%s = %s\n' "$(( i * 10000 + ms ))" "$i"; done   # MSISDN exacts op*10000+ms (10001,10002,...) - PAS de concatenation
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}

# ══════════════════════════════════════════════════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────
# Configuration du reseau - deleguee a ./generate_configs.sh
#
# [2026-08-03] Ce fichier portait ici une copie de 132 lignes de
# apply_config_templates(), jumelle de celle de lib/gabarits.sh (70 lignes).
# Deux implementations de la meme chose, qui divergeaient en silence : celle-ci
# copiait tout scripts/, l'autre une liste blanche perimee. Elles vivent
# desormais dans generate_configs.sh, une seule fois.
#
# generate_configs.sh cree globals.conf a la racine s'il n'existe pas - et ne
# l'ecrase JAMAIS ensuite. Tes reglages survivent donc a tous les runs. Pour
# repartir des valeurs d'usine : ./generate_configs.sh --force
# ─────────────────────────────────────────────────────────────────────────────
# start.sh n'a pas de variable de repertoire (il travaille en chemins relatifs
# depuis la racine du depot) : on resout ici, sans rien supposer.
#
# BASH_SOURCE ne suffit pas : build-iso.sh extrait ce fichier en bibliotheque
# ($WORK/start.lib.sh) puis la source, et BASH_SOURCE designe alors la COPIE,
# dans un repertoire de travail ou generate_configs.sh n'existe pas.
# OSMO_REPO_DIR laisse l'appelant nommer la vraie racine du depot.
_GC_SH="${OSMO_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/generate_configs.sh"
"$_GC_SH" >/dev/null || true
. "$_GC_SH"


# ── Mise a jour forcee des trois arbres, AVANT run.sh ─────────────────────────
# [2026-08-12] Les trois depots sont clones et `git pull`-es DANS LE Dockerfile,
# donc a l'etat du BUILD. Entre deux builds d'image (11,5 Go, plusieurs dizaines
# de minutes) un `git push` n'atteignait jamais un conteneur neuf : on lancait un
# run sur du code perime sans le voir. On les rafraichit donc a chaque demarrage,
# avant que run.sh ne lise quoi que ce soit.
#
# ORDRE : cette fonction DOIT etre appelee apres `docker run` et AVANT le
# `docker exec ... run.sh`. Apres, run.sh aurait deja lu l'ancien code.
#
# `--ff-only`, PAS de `reset --hard` : le depot qemu-src du conteneur recoit des
# commits faits a la main pendant une session (c'est le mode de travail : on
# corrige, on compile, on commite dans le conteneur). Un reset dur les
# effacerait sans le dire. En avance-rapide seule, une divergence s'ARRETE et se
# VOIT au lieu d'etre ecrasee en silence.
#
# qemu-src est RECOMPILE apres le pull : mettre la source a jour sans relier le
# binaire ne change rien a ce qui tourne - et c'est indiscernable d'un pull qui
# aurait echoue. Le juge d'un binaire a jour reste `stat -L /proc/<pid>/exe`.
#
# Non bloquant (reseau absent = on continue), mais BRUYANT : un pull rate doit
# se lire dans la sortie du lanceur, pas se deviner.
force_update_trees() {
    local c=$1
    echo -e "  ${GREEN}[*] Mise a jour forcee des depots (avant run.sh)...${NC}"
    for repo in /opt/GSM/qemu-src /opt/GSM/osmo_egprs /opt/osmo-egprs-web; do
        if ! docker exec "$c" test -d "$repo/.git" 2>/dev/null; then
            echo -e "    ${YELLOW}$repo : pas un depot git - ignore${NC}"
            continue
        fi
        local before after
        before=$(docker exec "$c" git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')
        if docker exec "$c" git -C "$repo" pull --ff-only 2>&1 | tail -2 | sed 's/^/    /'; then
            after=$(docker exec "$c" git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')
            if [ "$before" = "$after" ]; then
                echo -e "    ${CYAN}$repo${NC} : deja a jour ($after)"
            else
                echo -e "    ${GREEN}$repo${NC} : $before -> $after"
            fi
        else
            echo -e "    ${RED}$repo : pull KO (divergence ou reseau) - le run part sur $before${NC}"
        fi
    done
    # Recompilation de QEMU : sans elle le pull ci-dessus ne change RIEN au
    # binaire qui tourne. ninja ne reconstruit que ce qui a bouge.
    echo -e "  ${GREEN}[*] Recompilation QEMU (ninja)...${NC}"
    if docker exec "$c" bash -c 'cd /opt/GSM/qemu-src/build && ninja' >/dev/null 2>&1; then
        echo -e "    ${GREEN}qemu-system-arm relie${NC} ($(docker exec "$c" stat -L -c %y /opt/GSM/qemu-src/build/qemu-system-arm 2>/dev/null | cut -c1-19))"
    else
        echo -e "    ${RED}ninja KO - le run utilisera le binaire de l'image${NC}"
        docker exec "$c" bash -c 'cd /opt/GSM/qemu-src/build && ninja 2>&1 | tail -15' | sed 's/^/      /'
    fi
}

build_vol_args() {
    local tmpdir=$1
    local vol_args=""
    [ -d "$tmpdir/osmocom" ] && vol_args="$vol_args -v $tmpdir/osmocom:/etc/osmocom"
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/asterisk/$(basename "$f")"
    done
    if [ -f "$tmpdir/bb/mobile.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile.cfg:/root/.osmocom/bb/mobile.cfg"
    fi
    if [ -f "$tmpdir/bb/mobile_group1.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile_group1.cfg:/root/.osmocom/bb/mobile_group1.cfg"
    fi
    echo "$vol_args"
}

# ══════════════════════════════════════════════════════════════════════════════
# TUN hote
# ══════════════════════════════════════════════════════════════════════════════
prepare_host_tun() {
    echo -e "${GREEN}[*] Configuration TUN sur l'hote...${NC}"
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    if [ ! -c /dev/net/tun ]; then
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi
    ip link del apn0 2>/dev/null || true
    ip tuntap add dev apn0 mode tun
    ip addr add 176.16.32.0/24 dev apn0
    ip link set apn0 up
}

# ══════════════════════════════════════════════════════════════════════════════
# Inter-STP
# ══════════════════════════════════════════════════════════════════════════════
start_inter_stp() {
    local n_operators=$1
    local tmpdir
    tmpdir=$(mktemp -d)
    local inter_cfg="${tmpdir}/osmo-stp-interop.cfg"
    if [ "${WAN_MESH:-0}" = "1" ]; then
        # Plan WAN : un AS par couple (noeud, operateur), point codes
        # 1.<noeud><op>.<role>. Le hub doit connaitre TOUS les noeuds, pas
        # seulement les operateurs locaux - sinon les ASP distants s'attachent
        # a un AS qui n'existe pas et sont rejetes sans explication.
        echo -e "${GREEN}Generation config inter-STP WAN (${WAN_NODE_COUNT} noeuds × ${n_operators})...${NC}"
        bash ./helpers/create_interop.sh --wan "$WAN_NODE_COUNT" "$n_operators" "$inter_cfg" > /dev/null
    else
        echo -e "${GREEN}Generation config inter-STP (${n_operators} operateurs)...${NC}"
        bash ./helpers/create_interop.sh "$n_operators" "$inter_cfg" > /dev/null
    fi
    if [ ! -f "$inter_cfg" ]; then
        echo -e "${RED}Echec generation config inter-STP${NC}"; exit 1
    fi
    # Le hub ne fait que router du M3UA : l'image osmocom-stp (Dockerfile.stp)
    # lui suffit et pese une fraction d'osmocom-run. On ne la CONSTRUIT pas ici
    # a l'insu de l'appelant - si elle manque, on reste sur l'image complete,
    # qui contient aussi osmo-stp.
    local stp_image="$IMAGE_RUN"
    if [ "${BUILD_STP:-0}" = "1" ] && ! docker image inspect "$IMAGE_STP" >/dev/null 2>&1; then
        echo -e "  ${GREEN}Construction de ${IMAGE_STP} (Dockerfile.stp)...${NC}"
        docker build -f "$(dirname "$0")/Dockerfile.stp" -t "$IMAGE_STP" "$(dirname "$0")" \
            || echo -e "  ${YELLOW}⚠ echec - on restera sur ${IMAGE_RUN}${NC}"
    fi
    if docker image inspect "$IMAGE_STP" >/dev/null 2>&1; then
        stp_image="$IMAGE_STP"
        echo -e "  ${CYAN}image ${IMAGE_STP} (STP seul)${NC}"
    elif [ "${WAN_MESH:-0}" = "1" ]; then
        echo -e "  ${YELLOW}image ${IMAGE_STP} absente - on utilise ${IMAGE_RUN}.${NC}"
        echo -e "  ${CYAN}Pour la construire : docker build -f Dockerfile.stp -t ${IMAGE_STP} .${NC}"
    fi

    echo -e "${GREEN}Lancement inter-STP @ ${INTER_STP_IP}:2908 (PC 0.0.0)...${NC}"
    docker rm -f "$INTER_STP_CONTAINER" &>/dev/null || true
    docker run -d \
        --rm \
        --name "$INTER_STP_CONTAINER" \
        --hostname "$INTER_STP_CONTAINER" \
        --network "$INTER_NET" \
        --ip "$INTER_STP_IP" \
        --cap-add NET_ADMIN \
        -v "${inter_cfg}:/etc/osmocom/osmo-stp-interop.cfg" \
        --entrypoint bash \
        "$stp_image" \
        -c "sleep infinity" > /dev/null
    # tmux si l'image en a un, sinon un simple processus detache.
    #
    # osmocom-stp est l'image "STP seul" : elle ne porte que osmo-stp et ses
    # bibliotheques - c'est tout son interet, 877 Mo contre 11 Go. tmux n'y est
    # pas, et l'exec echouait alors sur "tmux: executable file not found in
    # $PATH". Le conteneur tournait pourtant (sleep infinity) : un hub bien
    # demarre, mais SANS osmo-stp dedans - il n'ecoutait rien, et les noeuds ne
    # s'attachaient a personne.
    #
    # tmux n'apportait ici que le confort de s'attacher a la session. La
    # barriere qui suit ne lit que /tmp/osmo-stp.log : un processus detache qui
    # redirige vers ce meme fichier remplit le contrat, et l'image complete
    # garde son tmux quand elle en a un.
    if docker exec "$INTER_STP_CONTAINER" sh -c 'command -v tmux >/dev/null 2>&1'; then
        docker exec "$INTER_STP_CONTAINER" \
            tmux new-session -d -s stp \
            "osmo-stp -c /etc/osmocom/osmo-stp-interop.cfg 2>&1 | tee /tmp/osmo-stp.log"
    else
        docker exec -d "$INTER_STP_CONTAINER" \
            sh -c 'exec osmo-stp -c /etc/osmocom/osmo-stp-interop.cfg > /tmp/osmo-stp.log 2>&1'
    fi
    echo -ne "${GREEN}[*] Attente demarrage inter-STP"
    local retries=25
    while [ $retries -gt 0 ]; do
        if docker exec "$INTER_STP_CONTAINER" \
            grep -qE "listening|m3ua.*[Ss]erver|bound" /tmp/osmo-stp.log 2>/dev/null; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$INTER_STP_CONTAINER" 2>/dev/null)" != "true" ]; then
            echo -e " ${RED}CRASH${NC}"
            docker logs "$INTER_STP_CONTAINER"
            exit 1
        fi
        echo -n "."
        sleep 1
        ((retries--)) || true
    done
    echo -e " ${YELLOW}(timeout log, on continue)${NC}"
}

wait_inter_stp_ready() {
    local n_operators=$1
    echo -ne "${GREEN}[*] Verification stabilisation inter-STP (routes SS7)${NC}"
    for i in {1..15}; do sleep 1; echo -n "."; done
    echo -e " ${GREEN}✓${NC}"
    return 0
}

wait_bb_vty() {
    local container="$1"
    local timeout=120
    local elapsed=0
    echo -ne "  Attente BB VTY 4247 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4247" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

wait_stp_vty() {
    local container="$1"
    local timeout=60
    local elapsed=0
    echo -ne "  Attente STP VTY 4239 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4239" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
setup_wan_interop() {
    local n_local=$1
    local n_remote=$2
    local script_path
    script_path="$(dirname "$0")/setup-wan-interop.sh"
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[WAN] network/setup-wan-interop.sh introuvable${NC}"
        return 1
    fi
    chmod +x "$script_path"
    bash "$script_path" "$WAN_LOCAL_IP" "$WAN_REMOTE_IP" "$n_local" "$n_remote"
}

# ══════════════════════════════════════════════════════════════════════════════
# WAN mesh (--wan)
# ══════════════════════════════════════════════════════════════════════════════
# Renseigne la table des noeuds : sans interaction si WAN_NODES est deja pose
# (option --wan-nodes ou variable d'environnement), par questions sinon.
wan_mesh_configure() {
    local n_operators=$1
    WAN_OPS="$n_operators"

    # Le point code WAN vaut 1.<noeud><op>.<role> : le champ central du format
    # ITU 3-8-3 tient sur 8 bits, soit 255. Avec 12 operateurs, le noeud 9
    # donnerait "912" - un point code invalide, refuse par osmo-stp au
    # demarrage avec une erreur de parsing qui ne dit rien du nombre
    # d'operateurs. On arrete ici, en nommant la cause.
    if [ "$n_operators" -gt 9 ]; then
        echo -e "${RED}[WAN] ${n_operators} operateurs : le plan de point codes WAN${NC}" >&2
        echo -e "${RED}      (1.<noeud><op>.<role>) n'en admet que 9 par noeud.${NC}" >&2
        echo -e "${CYAN}      Repartissez-les sur plusieurs noeuds, ou lancez sans --wan.${NC}" >&2
        exit 1
    fi

    # --virtualbox : le segment, les VM et la table sont fabriques AVANT tout le
    # reste, puis relus comme n'importe quelle table. Le WAN qui suit ne sait
    # pas - et n'a pas a savoir - que ses pairs sont des VM.
    if [ "${VBOX_INTERCO:-0}" = "1" ] && [ -z "${WAN_NODES:-}" ]; then
        local _vb=("$(dirname "$0")/network/setup-vbox-interco.sh"
                   --host-node "$VBOX_HOST_NODE" --conf "$WAN_CONF_FILE")
        [ -n "${VBOX_NODES:-}" ] && _vb+=(--nodes "$VBOX_NODES")
        bash "${_vb[@]}" || { echo -e "${RED}[WAN] interconnexion VirtualBox echouee${NC}" >&2; exit 1; }
        wan_nodes_load "$WAN_CONF_FILE" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        WAN_NODE_ID="$VBOX_HOST_NODE"
    fi

    wan_menu_table

    if [ -n "${WAN_NODES:-}" ]; then
        wan_nodes_parse "$WAN_NODES" || exit 1
        if [ "${WAN_NODE_ID:-0}" = "0" ]; then
            # La detection par IP echoue par construction quand les premiers
            # noeuds sont des CONTENEURS : leurs adresses (172.20.0.11, .12)
            # appartiennent au backbone docker, pas a l'hote. L'hote n'est donc
            # dans la table sous aucune de ses adresses - et il n'a pas a y
            # etre : il porte des noeuds, il n'en est pas un.
            #
            # Son numero est celui de son PREMIER conteneur, c'est-a-dire 1
            # dans le modele "conteneur i = noeud i". On ne s'arrete donc plus :
            # on le pose, et on ne demande --wan-id que si la table ne contient
            # meme pas ce noeud-la.
            if wan_nodes_detect_self 2>/dev/null; then
                :
            elif [ -n "${WAN_IP[1]:-}" ]; then
                WAN_NODE_ID=1
                echo -e "  ${CYAN}[WAN] cette machine porte les conteneurs : noeud de base 1${NC}"
            else
                echo -e "${RED}[WAN] table vide ou sans noeud 1 : passez --wan-id N${NC}" >&2
                exit 1
            fi
        fi
        wan_nodes_validate || exit 1
    else
        # Une table deja posee sur cette machine sert de valeurs par defaut :
        # relancer le lab ne redemande donc pas tout, il propose l'existant.
        wan_nodes_load "$WAN_CONF_FILE" 2>/dev/null || true
        wan_nodes_prompt || exit 1
    fi

    # ── Ce que la table WAN ne dit pas, et qu'il faut pourtant savoir ───────
    # Elle donne les noeuds et leurs adresses. Elle ne dit ni ou est le hub SS7,
    # ni si les conteneurs de CETTE machine sont ses operateurs ou des noeuds a
    # part entiere. Sans ces reponses, --wan partait sur ses defauts - hub
    # local, conteneurs = operateurs - et sur un banc ou le hub est une VM
    # dediee, cela donnait un second hub inutile et des ASP attaches au mauvais.
    wan_menu_complements

    WAN_ENABLED="false"          # exclusif du WAN legacy
    WAN_LOCAL_IP="$(wan_local_ip)"
    echo ""
    wan_nodes_summary
    if [ -n "${WAN_HUB_IP:-}" ]; then
        echo -e "  inter-STP : ${CYAN}${WAN_HUB_IP}${NC}  (hors table : ce n'est pas un noeud)"
    else
        echo -e "  inter-STP : porte par le noeud ${CYAN}${WAN_HUB_NODE}${NC}"
    fi
    [ "${WAN_NODE_PER_OP:-0}" = "1" ] \
        && echo -e "  conteneurs: ${CYAN}un noeud chacun${NC}, a partir du noeud ${CYAN}${WAN_NODE_ID}${NC}"
    # Qui tourne ICI, et qui est seulement DECLARE. La distinction n'a rien de
    # cosmetique : un noeud declare doit deja tourner ailleurs, sinon ses
    # abonnes figurent dans les tables SMS et le dialplan sans que personne ne
    # reponde - un appel qui sonne dans le vide se diagnostique mal.
    for _nid in ${WAN_NODE_LIST[@]+"${WAN_NODE_LIST[@]}"}; do
        if [ "$_nid" = "${WAN_NODE_ID:-0}" ] || \
           { [ "${WAN_NODE_PER_OP:-0}" = "1" ] && [ "$_nid" -gt "${WAN_NODE_ID:-0}" ]; }; then
            printf '    noeud %-2s %-16s %s\n' "$_nid" "${WAN_IP[$_nid]}" "conteneur lance ici"
        else
            printf '    noeud %-2s %-16s %s\n' "$_nid" "${WAN_IP[$_nid]}" "declare (doit tourner ailleurs)"
        fi
    done
    echo ""
}

# ── La table WAN, batie dans l'ordre ou on la pense ─────────────────────────
# D'abord COMBIEN d'operateurs en tout, puis combien tournent ICI en conteneur,
# puis les autres un par un. Les conteneurs prennent les premiers rangs -
# osmo-operator-1 est le noeud 1, -2 le noeud 2 - de sorte que le nom du
# conteneur donne son numero de noeud, sans table a consulter. Les operateurs
# distants (une VM deja demarree) prennent les rangs suivants : on ne demande
# que ce qu'on ne peut pas deduire, leur adresse et leur indicatif.
wan_menu_table() {
    command -v whiptail >/dev/null 2>&1 || return 0
    [ -t 0 ] || return 0
    [ -n "${WAN_NODES:-}" ] && return 0            # deja donne en CLI
    [ "${#OPERATOR_DECLS[@]}" -gt 0 ] && return 0  # deja declare par --operator

    local total cont k ip ind spec=""
    total=$(wt_input "WAN" "Nombre d'operateurs du WAN, tous sites confondus (1-9) :" "3") || return 0
    [[ "$total" =~ ^[1-9]$ ]] || { wt_msg "Nombre invalide : $total"; return 0; }

    cont=$(wt_input "WAN" "Combien tournent ICI, en conteneur ? (0-${total})" "$(( total > 1 ? total - 1 : total ))") || return 0
    [[ "$cont" =~ ^[0-9]$ ]] && [ "$cont" -le "$total" ] \
        || { wt_msg "Entre 0 et ${total}."; return 0; }

    # Les conteneurs : adresse du backbone, indicatif du rang. Rien a demander.
    for k in $(seq 1 "$cont"); do
        spec="${spec}${spec:+ }${k}:$(op_backbone_ip "$k"):$(( k * 11 ))"
    done
    # Les autres : eux seuls ont besoin d'une reponse.
    for k in $(seq $(( cont + 1 )) "$total"); do
        # Defaut : la VM du banc, seul noeud distant du montage courant.
        _defip=""; [ "$k" = 3 ] && _defip="192.168.1.2"
        ip=$(wt_input "Operateur distant ${k}/${total}" \
             "Adresse du noeud ${k} (une VM, une autre machine) :" "$_defip") || return 0
        [ -n "$ip" ] || { wt_msg "Adresse vide : noeud ${k} ignore."; continue; }
        ind=$(wt_input "Operateur distant ${k}/${total}" \
              "Indicatif (prefixe d'appel) du noeud ${k} :" "$(( k * 11 ))") || return 0
        spec="${spec}${spec:+ }${k}:${ip}:${ind:-$(( k * 11 ))}"
    done

    WAN_NODES="$spec"
    OPERATOR_COUNT_HINT="$cont"
    WAN_NODE_ID="${WAN_NODE_ID:-1}"
    [ "$cont" -ge 1 ] && WAN_NODE_PER_OP=1 && WAN_NODE_PER_OP_GIVEN=1
    echo -e "  ${CYAN}Table WAN :${NC} $WAN_NODES"
}

# ── Les questions WAN que la table ne porte pas ──────────────────────────────
# Chacune se saute des que l'option correspondante a ete donnee en ligne de
# commande : une invocation scriptee reste muette, une invocation a la main est
# guidee. Sans terminal (CI, cron), on garde les defauts plutot que d'attendre
# une reponse que personne ne donnera.
wan_menu_complements() {
    command -v whiptail >/dev/null 2>&1 || return 0
    [ -t 0 ] || return 0

    if [ -z "${WAN_HUB_IP:-}" ] && [ "${WAN_HUB_NODE_GIVEN:-0}" != "1" ]; then
        local _c
        _c=$(wt_menu "Inter-STP" "Ou se trouve le hub SS7 (PC 0.0.0) ?" \
            "ip"    "sur une machine dediee, hors table (une VM par exemple)" \
            "ici"   "sur CETTE machine - un conteneur inter-STP sera lance" \
            "noeud" "sur un autre noeud de la table WAN") || return 0
        case "$_c" in
            ip)
                local _ip
                _ip=$(wt_input "Inter-STP" "Adresse du hub (ex: 192.168.1.49) :" "${WAN_HUB_IP:-}") || return 0
                if [ -n "$_ip" ]; then WAN_HUB_IP="$_ip"
                else wt_msg "Adresse vide : le hub restera local."; fi ;;
            noeud)
                local _n
                _n=$(wt_input "Inter-STP" "Numero du noeud qui porte le hub :" "${WAN_HUB_NODE:-1}") || return 0
                [ -n "$_n" ] && WAN_HUB_NODE="$_n" ;;
            *)  WAN_HUB_NODE="$WAN_NODE_ID" ;;
        esac
    fi

    if [ "${WAN_NODE_PER_OP_GIVEN:-0}" != "1" ]; then
        if wt_yesno "Conteneurs" \
"Chaque conteneur doit-il etre un NOEUD a part entiere ?

Oui : conteneur 1 -> noeud ${WAN_NODE_ID}, conteneur 2 -> noeud $((WAN_NODE_ID + 1))...
      (leurs adresses backbone doivent etre joignables des autres noeuds)
Non : ce sont les operateurs du noeud ${WAN_NODE_ID}."; then
            WAN_NODE_PER_OP=1
        fi
    fi
}

# Applique la table (Asterisk, iptables, SMS) une fois les containers debout.
wan_mesh_apply() {
    local n_operators=$1
    local script_path="$(dirname "$0")/network/setup-wan-mesh.sh"
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[WAN] network/setup-wan-mesh.sh introuvable${NC}"; return 1
    fi
    if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
        # UN SEUL passage, avec --op-is-node : le script associe alors
        # l'operateur i au noeud i et recalcule SES pairs. Un passage par noeud,
        # comme on le faisait, ecrivait dans TOUS les conteneurs a chaque fois :
        # le dernier gagnait, l'un d'eux se routait vers lui-meme et l'autre
        # n'avait aucun maillage.
        bash "$script_path" --docker --op-is-node \
            --nodes "$(wan_nodes_spec)" --id 1 --ops "$n_operators" \
            || echo -e "${RED}[WAN] setup-wan-mesh.sh a echoue${NC}"
    else
        bash "$script_path" --docker \
            --nodes "$(wan_nodes_spec)" --id "$WAN_NODE_ID" --ops "$n_operators" \
            || echo -e "${RED}[WAN] setup-wan-mesh.sh a echoue${NC}"
    fi

}

# ── Rendre au trafic sortant son adresse d'origine ───────────────────────────
# Docker masque tout ce qui quitte un bridge : vues du LAN, les associations des
# conteneurs semblent toutes venir de l'hote. Or l'inter-STP identifie ses ASP
# par leur ADRESSE SOURCE - trois operateurs derriere une seule IP sont
# indiscernables, et il les rattache au mauvais AS ou les refuse.
# network/setup-docker-lan-route.sh pose donc un RETURN en tete de POSTROUTING.
#
# POURQUOI LE REJOUER ICI
# Docker REINSERE ses MASQUERADE en tete a chaque reseau cree - et start.sh en
# cree un par operateur. Le RETURN se retrouve alors DERRIERE eux et ne sert
# plus a rien : "iptables -L" le montre toujours, et pourtant le hub revoit
# l'adresse de l'hote. On le remet donc en premiere position une fois TOUS les
# reseaux crees.
reassert_docker_lan_return() {
    command -v iptables >/dev/null 2>&1 || return 0
    [ "$(id -u)" -eq 0 ] || return 0

    local lan_ip lan_net
    lan_ip="$(ip route show default 2>/dev/null | awk '/^default/{print $9; exit}')"
    [ -n "$lan_ip" ] || lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$lan_ip" ] || return 0
    lan_net="${lan_ip%.*}.0/24"

    # Si LAN et backbone se recouvrent, la regle porterait sur du trafic interne
    # au bridge : on s'abstient plutot que de deviner.
    [ "${lan_net%%/*}" = "${INTER_NET_SUBNET%%/*}" ] && return 0

    iptables -t nat -D POSTROUTING -s "$INTER_NET_SUBNET" -d "$lan_net" -j RETURN 2>/dev/null
    if iptables -t nat -I POSTROUTING 1 -s "$INTER_NET_SUBNET" -d "$lan_net" -j RETURN 2>/dev/null; then
        echo -e "  ${CYAN}[WAN] adresse source preservee vers ${lan_net} (RETURN en tete de POSTROUTING)${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# PoC QEMU - entree par defaut du premier menu
# ══════════════════════════════════════════════════════════════════════════════
start_qemu_poc() {
    echo -e "${GREEN}PoC QEMU Calypso - bring-up minimal + qemu-src/run.sh...${NC}"
    QEMU_POC=1
    start_bridge_mode
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode virtual (multi-operateurs SS7 - ex-bridge)
# ══════════════════════════════════════════════════════════════════════════════
start_bridge_mode() {
    local n_operators
    declare -A OP_MCC OP_MNC OP_NAME OP_MS

    if [ "${QEMU_POC:-0}" = "1" ]; then
        # ── PoC QEMU ──────────────────────────────────────────────────────────
        n_operators=1
        OP_MCC[1]="001"; OP_MNC[1]="01"; OP_NAME[1]="OsmoQEMU"; OP_MS[1]=2
        WAN_ENABLED="false"
        # --wan reste valable en PoC QEMU : un noeud = un operateur, c'est
        # exactement la maquette "N machines qui s'appellent".
        [ "${WAN_MESH:-0}" = "1" ] && wan_mesh_configure 1
        PHY_MODE="faketrx"; BRIDGE_NO_PROCESS=1; BRIDGE_QEMU=1
        ENCRYPTION="a5 0"
        echo -e "  ${CYAN}[PoC QEMU] 1 operateur · no-process + qemu-src/run.sh · A5/1${NC}"
    else
        # ── Mode interactif ──────────────────────────────────────────────────
        # Deja repondu dans le menu WAN (« combien tournent ICI ») : on ne
        # repose pas la question, deux reponses divergentes donneraient une
        # table et un nombre de conteneurs qui ne se correspondent plus.
        if [ -n "${OPERATOR_COUNT_HINT:-}" ]; then
            n_operators="$OPERATOR_COUNT_HINT"
            echo -e "  ${CYAN}Conteneurs a lancer : ${n_operators} (choisis dans le menu WAN)${NC}"
        else
            # 3 par defaut : c'est la taille du banc (deux conteneurs et une
            # VM). Un defaut qui correspond au montage courant evite la moitie
            # des saisies, et surtout evite qu'un oubli produise une table plus
            # courte que la realite - un noeud absent de la table n'existe pour
            # personne, et son absence ne se voit qu'a l'appel qui n'aboutit pas.
            n_operators=$(wt_input "Operateurs" "Nombre d'operateurs (1-36) :" "3") || exit 1
        fi
        n_operators=${n_operators:-2}
        if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 36 ]; then
            wt_msg "Nombre invalide (1-36)."; exit 1
        fi

        local use_defaults="N"
        wt_yesno "Valeurs par defaut" "Valeurs par defaut pour tous (MCC=001, MNC=01/02/...) ?" && use_defaults="O"

        local same_ms_all="N"
        if [ "$use_defaults" != "O" ]; then
            wt_yesno "MS" "Meme nombre de MS pour tous les operateurs ?" && same_ms_all="O"
        fi

        declare -A OP_MCC OP_MNC OP_NAME OP_MS

        if [ "$use_defaults" = "O" ]; then
            local common_ms
            common_ms=$(wt_input "MS" "MS par operateur (1-64) :" "8") || exit 1
            common_ms=${common_ms:-8}
            if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
            for i in $(seq 1 "$n_operators"); do
                OP_MCC[$i]="001"; OP_MNC[$i]=$(printf '%02d' "$i")
                OP_NAME[$i]="OsmoOP${i}"; OP_MS[$i]=$common_ms
            done
        else
            if [ "$same_ms_all" = "O" ]; then
                local common_ms
                common_ms=$(wt_input "MS" "MS par operateur (1-64) :" "8") || exit 1
                common_ms=${common_ms:-8}
                if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
                for i in $(seq 1 "$n_operators"); do
                    local mcc mnc name dmnc; dmnc=$(printf '%02d' "$i")
                    mcc=$(wt_input "Operateur ${i}" "MCC :" "001") || exit 1; OP_MCC[$i]=${mcc:-001}
                    mnc=$(wt_input "Operateur ${i}" "MNC :" "$dmnc") || exit 1; OP_MNC[$i]=${mnc:-$dmnc}
                    name=$(wt_input "Operateur ${i}" "Nom :" "OsmoOP${i}") || exit 1; OP_NAME[$i]=${name:-"OsmoOP${i}"}
                    OP_MS[$i]=$common_ms
                done
            else
                for i in $(seq 1 "$n_operators"); do
                    local mcc mnc name n_ms dmnc; dmnc=$(printf '%02d' "$i")
                    mcc=$(wt_input "Operateur ${i}" "MCC :" "001") || exit 1; OP_MCC[$i]=${mcc:-001}
                    mnc=$(wt_input "Operateur ${i}" "MNC :" "$dmnc") || exit 1; OP_MNC[$i]=${mnc:-$dmnc}
                    name=$(wt_input "Operateur ${i}" "Nom :" "OsmoOP${i}") || exit 1; OP_NAME[$i]=${name:-"OsmoOP${i}"}
                    n_ms=$(wt_input "Operateur ${i}" "Nombre de MS (1-64) :" "1") || exit 1; OP_MS[$i]=${n_ms:-1}
                    if ! [[ "${OP_MS[$i]}" =~ ^[0-9]+$ ]] || [ "${OP_MS[$i]}" -lt 1 ] || [ "${OP_MS[$i]}" -gt 64 ]; then OP_MS[$i]=1; fi
                done
            fi
        fi

        # ── WAN ──────────────────────────────────────────────────────────────
        if [ "${WAN_MESH:-0}" = "1" ]; then
            wan_mesh_configure "$n_operators"
        elif wt_yesno "WAN Interop" "Activer WAN vers un serveur distant (2 serveurs, prefixe 66) ?"; then
            WAN_ENABLED="true"
            local auto_ip=""
            auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
            [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
            local wan_local wan_remote wan_nremote wan_pfx
            wan_local=$(wt_input "WAN" "IP publique locale :" "$auto_ip") || exit 1
            WAN_LOCAL_IP="${wan_local:-$auto_ip}"
            [ -z "$WAN_LOCAL_IP" ] && WAN_ENABLED="false"
            if [ "$WAN_ENABLED" = "true" ]; then
                wan_remote=$(wt_input "WAN" "IP publique distante :" "") || exit 1
                WAN_REMOTE_IP="$wan_remote"
                [ -z "$WAN_REMOTE_IP" ] && WAN_ENABLED="false"
            fi
            if [ "$WAN_ENABLED" = "true" ]; then
                wan_nremote=$(wt_input "WAN" "Nb operateurs distants :" "$n_operators") || exit 1
                WAN_N_REMOTE="${wan_nremote:-$n_operators}"
                wan_pfx=$(wt_input "WAN" "Prefixe WAN :" "$WAN_PREFIX") || exit 1
                WAN_PREFIX="${wan_pfx:-$WAN_PREFIX}"
                echo -e "  ${GREEN}WAN: ${WAN_LOCAL_IP} ↔ ${WAN_REMOTE_IP} (local=${n_operators} remote=${WAN_N_REMOTE} prefix=${WAN_PREFIX})${NC}"
            fi
        fi

        # ── RAN / Encryption ─────────────────────────────────────────────────
        PHY_MODE="faketrx"; BRIDGE_NO_PROCESS=1; BRIDGE_QEMU=1
        ENCRYPTION="${ENCRYPTION:-a5 0}"
        if [ "${WAN_MESH:-0}" = "1" ] && [ -z "$HANDOFF_MODE_FROM_ENV" ]; then
            # Un noeud de WAN est une maquette complete : il lui faut une radio
            # des DEUX types pour que l'appel inter-noeud soit vraiment porte de
            # bout en bout. D'ou l'hybride par defaut - un faketrx + un QEMU
            # Calypso - au lieu du menu. HANDOFF_MODE=... en prefixe le change.
            HANDOFF_MODE="faketrx-qemu"; HANDOFF_QEMU_CHOICE="faketrx-qemu"
            echo -e "  ${GREEN}[RAN] WAN → hybride par defaut : ${CYAN}1 faketrx + 1 QEMU Calypso${NC}"
        else
            choose_ran_host
        fi
    fi

    # ── Detection IP hote ────────────────────────────────────────────────────
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    HOST_IP="${HOST_IP:-127.0.0.1}"
    REAL_UID=$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}")
    echo -e "${GREEN}IP hote : ${CYAN}${HOST_IP}${NC}  (Linphone)${NC}"
    echo ""

    # ── Ou joindre le hub SS7, vu d'ici ──────────────────────────────────────
    # Le hub est UNIQUE pour tout le WAN. Deux cas, et le mauvais donne un ASP
    # qui ne s'attache jamais :
    #   ce noeud heberge le hub  → les conteneurs le joignent en interne (172.20.0.10)
    #   un autre noeud l'heberge → ils sortent sur le WAN, vers SON adresse
    WAN_STP_TARGET="$INTER_STP_IP"
    HUB_IS_LOCAL=1
    if [ -n "${WAN_HUB_IP:-}" ]; then
        # Hub designe par son adresse : il n'est pas un noeud, et rien ne se
        # lance ici. C'est le cas d'une VM inter-STP dediee.
        WAN_STP_TARGET="$WAN_HUB_IP"; HUB_IS_LOCAL=0
    elif [ "${WAN_MESH:-0}" = "1" ] && [ "${WAN_NODE_ID}" != "${WAN_HUB_NODE}" ]; then
        WAN_STP_TARGET="${WAN_IP[$WAN_HUB_NODE]:-}"; HUB_IS_LOCAL=0
        if [ -z "$WAN_STP_TARGET" ]; then
            echo -e "${RED}[SS7] le noeud ${WAN_HUB_NODE} (hub) n'est pas dans la table WAN${NC}" >&2
            echo -e "${RED}      (ou designez-le par son adresse : --hub-ip ADRESSE)${NC}" >&2
            exit 1
        fi
    fi

    # ── Reseau backbone ──────────────────────────────────────────────────────
    if docker network inspect "$INTER_NET" &>/dev/null; then
        echo -e "  ${CYAN}Reseau backbone ${INTER_NET} deja present${NC}"
    elif docker network create --subnet="$INTER_NET_SUBNET" --gateway="$INTER_NET_GATEWAY" "$INTER_NET" &>/dev/null; then
        echo -e "  ${GREEN}✓ Reseau backbone ${INTER_NET} (${INTER_NET_SUBNET}) cree${NC}"
    else
        echo -e "  ${RED}✗ Echec creation reseau backbone ${INTER_NET} (${INTER_NET_SUBNET})${NC}"; exit 1
    fi

    # ── SMS Routing ──────────────────────────────────────────────────────────
    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate_all > /dev/null 2>&1; then
        local _ms_counts=()
        for i in $(seq 1 "$n_operators"); do _ms_counts+=("${OP_MS[$i]}"); done
        sms_routing_generate_all "$n_operators" "$SMS_ROUTING_DIR" "${_ms_counts[@]}"
        sms_routing_summary "$n_operators" "${_ms_counts[@]}"
    fi

    # ── Inter-STP ────────────────────────────────────────────────────────────
    if [ "$HUB_IS_LOCAL" = "1" ]; then
        start_inter_stp "$n_operators"
        wait_inter_stp_ready "$n_operators"
    else
        echo -e "${CYAN}[SS7] hub porte par le noeud ${WAN_HUB_NODE} (${WAN_STP_TARGET}) - pas de hub ici.${NC}"
        echo -e "${CYAN}      Les ASP de ce noeud s'y attacheront en M3UA/SCTP 2908.${NC}"
    fi

    # ── HLR subscribers ──────────────────────────────────────────────────────
    local all_subscribers_file
    all_subscribers_file=$(mktemp)
    echo "# op_id:ms_idx:imsi:msisdn:ki" > "$all_subscribers_file"
    for op_id in $(seq 1 "$n_operators"); do
        local mcc="${OP_MCC[$op_id]}" mnc="${OP_MNC[$op_id]}" n_ms="${OP_MS[$op_id]}"
        for ms_idx in $(seq 1 "$n_ms"); do
            local msin; msin=$(printf '%04d%06d' "${op_id}" "${ms_idx}")
            local imsi="${mcc}${mnc}${msin}"
            local msisdn=$(( op_id * 10000 + ms_idx ))
            local ki; ki=$(printf '00112233445566778899aabbccdd%02x%02x' "${ms_idx}" "${op_id}")
            echo "${op_id}:${ms_idx}:${imsi}:${msisdn}:${ki}" >> "$all_subscribers_file"
        done
    done
    local total_subs; total_subs=$(( $(wc -l < "$all_subscribers_file") - 1 ))
    echo -e "${GREEN}Abonnes total : ${total_subs}${NC}"
    echo ""

    # ── Table rase sur la serie d'operateurs ────────────────────────────────
    # Le "docker rm -f" plus bas ne vise que le conteneur de MEME NOM. Un
    # reliquat d'un lancement precedent - trois operateurs hier, deux
    # aujourd'hui, ou une serie interrompue en cours de route - garde ses
    # publications de ports et fait echouer la creation du suivant :
    #     Bind for 0.0.0.0:5082 failed: port is already allocated
    # Le message nomme le port, jamais le conteneur qui le tient : on cherche
    # longtemps. Cette fonction RECREE toute la serie, on efface donc d'abord.
    local _stale
    _stale="$(docker ps -aq --filter "name=^osmo-operator-" 2>/dev/null)"
    if [ -n "$_stale" ]; then
        echo -e "  ${CYAN}Nettoyage : $(echo "$_stale" | wc -l) conteneur(s) operateur d'un lancement precedent${NC}"
        # shellcheck disable=SC2086
        docker rm -f $_stale >/dev/null 2>&1 || true
    fi

    # ── Demarrage sequentiel des operateurs ──────────────────────────────────
    for i in $(seq 1 "$n_operators"); do
        local container_name net_name subnet gateway container_ip inter_local_ip rctx_inter
        local n_groups last_group_ip

        container_name=$(op_container "$i")
        net_name="gsm-net-op${i}"
        subnet=$(op_private_net "$i")
        gateway=$(op_private_gw "$i")
        container_ip=$(op_private_ip "$i")
        inter_local_ip=$(op_backbone_ip "$i")
        rctx_inter=$(op_rctx_inter "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        last_group_ip="127.0.0.${n_groups}"

        echo -e "${CYAN}── Operateur ${i} : ${OP_NAME[$i]} (MCC=${OP_MCC[$i]} MNC=${OP_MNC[$i]}) ──${NC}"
        echo -e "  Backbone   : ${CYAN}${inter_local_ip}${NC}  Prive : ${CYAN}${container_ip}${NC}"
        local _node_i="$WAN_NODE_ID" _op_i="$i"
        if [ "${WAN_NODE_PER_OP:-0}" = "1" ]; then
            _node_i=$(( WAN_NODE_ID + i - 1 ))
            _op_i=1
        fi
        local _pc_mid="$i" _rctx_inter=""
        if [ "${WAN_MESH:-0}" = "1" ]; then
            _pc_mid="${_node_i}${_op_i}"
            _rctx_inter=$(( _node_i * 1000 + _op_i * 100 + 50 ))
        fi

        # L'identite AFFICHEE est celle qui sera ECRITE. Cette ligne montrait
        # "1.<op>.2" en dur et le routing context du plan local : elle annoncait
        # donc 1.1.2/150 alors que la config recevait 1.21.2/2150. On cherche
        # longtemps une panne quand le journal dit le contraire du fichier.
        echo -e "  STP PC     : 1.${_pc_mid}.2  RCTX : ${_rctx_inter:-$rctx_inter}  MS : ${CYAN}${OP_MS[$i]}${NC}"

        if docker network inspect "$net_name" &>/dev/null; then
            echo -e "  Reseau     : ${CYAN}${net_name}${NC} (deja present)"
        elif docker network create --subnet="$subnet" --gateway="$gateway" "$net_name" &>/dev/null; then
            echo -e "  Reseau     : ${GREEN}✓ ${net_name} (${subnet}) cree${NC}"
        else
            echo -e "  ${RED}✗ Echec creation reseau ${net_name} (${subnet})${NC}"; exit 1
        fi

        local tmpdir
        tmpdir=$(mktemp -d)
        # Plan de point codes. Hors WAN : 1.<op>.<role>, comme toujours. En WAN :
        # le numero de noeud entre dedans, sans quoi deux machines presentent au
        # hub des adresses SS7 identiques - routage faux, et silencieux.
        # Seul RCTX_INTER est surcharge : c'est le seul routing context que le
        # hub voit. Ceux du MSC et du BSC restent internes au conteneur.
        #
        # UN NOEUD PAR CONTENEUR (--node-per-op)
        # Par defaut, la machine EST le noeud et ses conteneurs en sont les
        # operateurs : 1.<noeud><op>.<role>. C'est juste quand une machine
        # heberge un operateur complet.
        #
        # Mais des que les conteneurs sont joignables chacun a SON adresse
        # (172.20.0.11, .12... routees depuis le LAN), ce ne sont plus des
        # operateurs d'un meme site : ce sont des noeuds a part entiere, au meme
        # titre qu'une VM. Les traiter en operateurs obligeait alors a inscrire
        # la MACHINE dans la table WAN - une entree qui ne correspond a aucun
        # equipement, et qui recevait pourtant un indicatif et des routes.
        #
        # Avec --node-per-op, le conteneur i devient le noeud (base + i - 1),
        # porte l'operateur 1 de ce noeud, et son point code suit : 1.<n>1.<role>.
        RCTX_INTER_OVERRIDE="$_rctx_inter" \
        apply_config_templates "$tmpdir" \
            "$container_ip" "$gateway" \
            "$i" "1.${_pc_mid}.1" "1.${_pc_mid}.2" "1.${_pc_mid}.3" \
            "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}" \
            "$WAN_STP_TARGET" "no shutdown" \
            "$n_operators"

        local vol_args alsa_args
        vol_args=$(build_vol_args "$tmpdir")
        alsa_args=$(build_alsa_args)

        # [2026-08-12] Le chown est OBLIGATOIRE, pas cosmetique. Ce repertoire est
        # monte sur /var/log/osmocom et les demons tournent en osmocom (999:1000
        # dans l'image). Cree en root:root, osmo-hlr ne peut pas creer son fichier
        # de log → "% Unable to create file '/var/log/osmocom/osmo-hlr.log'" →
        # echec du parse de sa config → boucle de restart systemd → osmo-start.sh
        # `exit 1` ("HLR indispensable") → run.sh meurt (set -e) et n'atteint
        # aucun de ses etages suivants. Un simple probleme de droits fait donc
        # tomber tout le pipeline, audio compris.
        mkdir -p /tmp/osmocom-logs/op${i}
        chown 999:1000 /tmp/osmocom-logs/op${i} 2>/dev/null || true

        # ── Ports a exposer ──────────────────────────────────────────────────
        local port_args=""

        # Linphone SIP/RTP - toujours expose
        local lsip_port lrtp_s lrtp_e
        lsip_port=$(linphone_sip_port "$i")
        lrtp_s=$(linphone_rtp_start "$i")
        lrtp_e=$(linphone_rtp_end "$i")
        port_args="-p ${lsip_port}:5060/udp -p ${lrtp_s}-${lrtp_e}:${lrtp_s}-${lrtp_e}/udp"
        echo -e "  Linphone   : ${CYAN}${HOST_IP}:${lsip_port}${NC}  RTP ${lrtp_s}-${lrtp_e}"

        # WAN en plus si active (legacy ou mesh)
        if wan_active; then
            local sip_port rtp_start rtp_end sms_port
            sip_port=$(wan_sip_port "$i")
            rtp_start=$(wan_rtp_start "$i")
            rtp_end=$(wan_rtp_end "$i")
            port_args="${port_args} -p ${sip_port}:5060/udp -p ${sip_port}:5060/tcp -p ${rtp_start}-${rtp_end}:${rtp_start}-${rtp_end}/udp"
            echo -e "  WAN        : SIP ${sip_port} RTP ${rtp_start}-${rtp_end}"
            if [ "${WAN_MESH:-0}" = "1" ]; then
                # Un port SMS PAR operateur : le relais distant doit joindre le
                # container du BON operateur, or son injection MT passe par le
                # HLR local a son container. Un port unique livrerait tous les
                # SMS au premier operateur, qui ne connait pas les abonnes des
                # autres - "MSISDN not found in HLR", sans autre trace.
                sms_port=$(wan_sms_port "$i")
                port_args="${port_args} -p ${sms_port}:7890/tcp"
                echo -e "  WAN SMS    : ${sms_port} → relay 7890"
            fi
        fi

        docker rm -f "$container_name" 2>/dev/null || true
        ensure_host_audio_relay

        # shellcheck disable=SC2086
        docker run -d \
            --rm \
            --name "$container_name" \
            --hostname "$container_name" \
            --network "$INTER_NET" \
            --ip "$inter_local_ip" \
            --cap-add NET_ADMIN \
            --cap-add SYS_ADMIN \
            --cap-add NET_RAW \
            --ulimit rtprio=18 \
            --shm-size=8g \
            --cgroupns host \
            --device /dev/net/tun:/dev/net/tun \
            $alsa_args \
            $port_args \
            -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            -v /tmp/osmocom-logs/op${i}:/var/log/osmocom \
            --tmpfs /tmp:exec,rw,mode=1777,size=2g \
            --tmpfs /run:exec,size=64m \
            --tmpfs /run/lock \
            -e OPERATOR_ID="$i" \
            -e N_MS="${OP_MS[$i]}" \
            -e CONTAINER_IP="$container_ip" \
            -e GATEWAY_IP="$gateway" \
            -e INTER_STP_IP="${WAN_STP_TARGET:-$INTER_STP_IP}" \
            -e OSMO_HUB_IP="${WAN_STP_TARGET:-$INTER_STP_IP}" \
            -e WAN_NODE_ID="${_node_i}" \
            -e OSMO_WAN_NODE="${_node_i}" \
            -e HOST_IP="${HOST_IP}" \
            -e SIP_HOST_PORT="${lsip_port}" \
            -e PHY_MODE="${PHY_MODE}" \
            -e HOST_AUDIO_RELAY="${HOST_AUDIO_RELAY}" \
            $vol_args \
            "$IMAGE_RUN" \
            sleep infinity

        docker network connect --ip "$container_ip" "$net_name" "$container_name"

        force_update_trees "$container_name"

        # run.sh selon le mode no-process choisi
        local run_cmd="RUN_NO_PROCESS=${BRIDGE_NO_PROCESS:-0} /etc/osmocom/run.sh"
        echo -e "  ${GREEN}[*] Lancement run.sh...${NC}"
        # DANS UN TMUX, pas en simple processus detache.
        #
        # Le terminal courant est reserve a osmo-operator-1 (handoff QEMU plus
        # bas) : c'est celui qu'on regarde. Les autres tournaient en
        # "docker exec -d", c'est-a-dire sans session a laquelle se rattacher -
        # on ne pouvait plus que LIRE leur journal, jamais reprendre la main sur
        # la pile qui tourne.
        #
        # Une session nommee "osmo" rend chaque operateur joignable a la
        # demande, sans rien afficher tant qu'on ne le demande pas :
        #     docker exec -ti osmo-operator-2 tmux attach -t osmo
        # (ou par tools/vty-menu.sh, qui liste les conteneurs)
        #
        # tee : le journal reste ecrit meme quand personne n'est attache, sinon
        # un incident survenu hors session serait perdu. Repli sans tmux pour
        # une image qui n'en aurait pas - le comportement d'avant, a l'identique.
        if docker exec "$container_name" sh -c 'command -v tmux >/dev/null 2>&1'; then
            docker exec -d "$container_name" bash -c \
                "mkdir -p /var/log/osmocom && tmux new-session -d -s osmo \
                 '{ ${run_cmd}; } 2>&1 | tee /var/log/osmocom/run.sh.log'"
            echo -e "     ${CYAN}tmux 'osmo' : docker exec -ti ${container_name} tmux attach -t osmo${NC}"
        else
            docker exec -d "$container_name" bash -c "mkdir -p /var/log/osmocom && { ${run_cmd}; } > /var/log/osmocom/run.sh.log 2>&1"
        fi

        # Attente HLR
        echo -ne "  ${GREEN}[*] Attente HLR (4258)${NC}"
        local retry=0
        while ! docker exec "$container_name" bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
            sleep 2; echo -n "."; retry=$((retry + 1))
            if [ $retry -ge 45 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
        done
        echo -e " ${GREEN}✓${NC}"

        # Feed HLR
        echo -e "  ${GREEN}[*] Alimentation HLR Op${i} (${total_subs} abonnes)...${NC}"
        {
            echo "#!/bin/bash"
            echo "cat > /tmp/hlr_feed.vty << 'VTYCMDS'"
            echo "enable"
            while IFS=: read -r feed_op feed_ms feed_imsi feed_msisdn feed_ki; do
                [[ "$feed_op" =~ ^#.*$ ]] && continue
                echo "subscriber imsi ${feed_imsi} create"
                echo "subscriber imsi ${feed_imsi} update msisdn ${feed_msisdn}"
                echo "subscriber imsi ${feed_imsi} update aud2g comp128v1 ki ${feed_ki}"
            done < "$all_subscribers_file"
            echo "end"
            echo "VTYCMDS"
        } | docker exec -i "$container_name" bash

        docker exec "$container_name" bash -c '
            if command -v nc >/dev/null 2>&1; then
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 2) | nc -q2 127.0.0.1 4258 2>/dev/null | grep -cE "^%" || true
            else
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 3) | telnet 127.0.0.1 4258 2>/dev/null | grep -cE "^%" || true
            fi
            rm -f /tmp/hlr_feed.vty
        '
        echo -e "  ${GREEN}✓ HLR Op${i} alimente${NC}"

        # Attente dernier groupe - sautee en no-process
        if [ "${BRIDGE_NO_PROCESS:-0}" = "1" ]; then
            echo -e "  ${YELLOW}[no-process] mobile non lance - attente 4247 sautee${NC}"
        else
            echo -ne "  ${GREEN}[*] Attente groupe (${last_group_ip}:4247)${NC}"
            retry=0
            while ! docker exec "$container_name" bash -c "echo >/dev/tcp/${last_group_ip}/4247" 2>/dev/null; do
                sleep 2; echo -n "."; retry=$((retry + 1))
                if [ $retry -ge 90 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
            done
            echo -e " ${GREEN}OK${NC}"
            sleep 3
        fi
        echo -e "  ${GREEN}✓${NC} ${container_name} pret"
        echo ""
    done

    rm -f "$all_subscribers_file"

    # ── Attente relays SMS ────────────────────────────────────────────────────
    if [ "${BRIDGE_NO_PROCESS:-0}" != "1" ] && declare -f sms_routing_wait_ready > /dev/null 2>&1; then
        for i in $(seq 1 "$n_operators"); do
            sms_routing_wait_ready "$(op_container "$i")" 90 || true
        done
    fi

    # ── WAN ────────────────────────────────────────────────────────────────────
    if [ "${WAN_MESH:-0}" = "1" ]; then
        wan_mesh_apply "$n_operators"
    elif [ "$WAN_ENABLED" = "true" ]; then
        setup_wan_interop "$n_operators" "$WAN_N_REMOTE"
    fi

    # ── Resume ─────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-operateurs demarree !${NC}"
    echo ""
    echo -e "  Inter-STP @ ${CYAN}${INTER_STP_IP}:2908${NC}  PC=0.0.0"
    for i in $(seq 1 "$n_operators"); do
        local rctx bb_ip n_groups
        rctx=$(op_rctx_inter "$i"); bb_ip=$(op_backbone_ip "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        echo -e "  Op${i} ${OP_NAME[$i]}  STP 1.${i}.2 @ ${bb_ip}  RCTX ${rctx}  [${OP_MS[$i]} MS]"
    done

    echo ""
    echo -e "  ${BOLD}Linphone (depuis l'hote) :${NC}"
    for i in $(seq 1 "$n_operators"); do
        local lsip bb_ip
        lsip=$(linphone_sip_port "$i"); bb_ip=$(op_backbone_ip "$i")
        echo -e "    Op${i}: ${CYAN}${HOST_IP}:${lsip}${NC}  (ou direct ${bb_ip}:5060)"
    done
    echo -e "    linphone_A / tester → 100  |  linphone_B / testerB → 200"

    if [ "${WAN_MESH:-0}" = "1" ]; then
        echo ""
        echo -e "  ${BOLD}WAN mesh :${NC} noeud ${CYAN}${WAN_NODE_ID}${NC}/${WAN_NODE_COUNT} - indicatif ${CYAN}$(wan_local_ind)${NC}"
        for _r in "${WAN_NODE_LIST[@]}"; do
            [ "$_r" = "$WAN_NODE_ID" ] && continue
            echo -e "    ${CYAN}${WAN_IND[$_r]}${NC}10001 → MS 10001 op1 du noeud ${_r} (${WAN_IP[$_r]})"
        done
    elif [ "$WAN_ENABLED" = "true" ]; then
        echo ""
        echo -e "  ${BOLD}WAN :${NC} ${CYAN}${WAN_LOCAL_IP}${NC} (${n_operators} ops) ↔ ${CYAN}${WAN_REMOTE_IP}${NC} (${WAN_N_REMOTE} ops)  prefix=${WAN_PREFIX}"
    fi
    echo ""

    # --virtualbox : le "set" ne se limite pas a cette machine. Les VM sont
    # creees avant (setup-vbox-interco.sh) ; on les demarre ici, une fois que le
    # hub et les operateurs locaux sont debout - un noeud qui monte avant le hub
    # voit sa SCTP refusee.
    if [ "${VBOX_INTERCO:-0}" = "1" ]; then
        local _lab="$(dirname "$0")/tools/vbox-wan-lab.sh"
        if [ -x "$_lab" ] || [ -r "$_lab" ]; then
            echo ""
            echo -e "${GREEN}[*] Demarrage des VM du WAN...${NC}"
            bash "$_lab" start || echo -e "  ${YELLOW}⚠ demarrage des VM incomplet${NC}"
        fi
    fi

    # ICI, et pas plus tot : docker reinsere ses MASQUERADE en tete de
    # POSTROUTING a CHAQUE reseau cree, et il y en a un par operateur. Rejouee
    # depuis l'application du WAN, la regle se retrouvait derriere eux - donc
    # inerte, alors qu'"iptables -L" la montrait toujours. A cet endroit, tous
    # les reseaux existent : plus rien ne passera devant.
    reassert_docker_lan_return

    echo -e "\n${GREEN}${BOLD}Stack prete !${NC}"

    # ── Mode QEMU : handoff vers start-direct.sh ──────────────────────────────
    if [ "${BRIDGE_QEMU:-0}" = "1" ]; then
        local _qemu_container; _qemu_container=$(op_container 1)
        echo -e "  ${CYAN}[*] run.sh calypso → ${_qemu_container} (terminal courant)${NC}"
        echo -e "  ${CYAN}[*] mode=${HANDOFF_MODE} pipeline=${HANDOFF_QEMU_CHOICE} chiffrement='${ENCRYPTION}' (choisis sur l'hote, NO_MENU)${NC}"

        # Le start-direct lance DANS le conteneur doit connaitre son noeud : il
        # reverifie (et corrige) l'identite SS7 avant de demarrer la pile, au
        # lieu de dependre de ce que start.sh a ecrit dans les configs.
        local _node_args=""
        if [ "${WAN_MESH:-0}" = "1" ]; then
            # --node-per-op : le conteneur 1 est le noeud de base lui-meme,
            # donc WAN_NODE_ID convient ici. Les suivants recoivent le leur
            # dans la boucle de demarrage (voir _node_i).
            _node_args="--node ${WAN_NODE_ID} --op 1 --hub-ip ${WAN_STP_TARGET}"
        fi

        local _wan_env=""
        if [ "${WAN_MESH:-0}" = "1" ]; then
            _wan_env="WAN_NODES='$(wan_nodes_spec)' WAN_NODE_ID='${WAN_NODE_ID}' WAN_OPS='${n_operators}'"
            echo -e "  ${CYAN}[*] WAN mesh transmis au conteneur (noeud ${WAN_NODE_ID}, indicatif $(wan_local_ind))${NC}"
        elif [ "$WAN_ENABLED" = "true" ]; then
            _wan_env="WAN_REMOTE_IP='${WAN_REMOTE_IP}' WAN_PREFIX='${WAN_PREFIX}' WAN_N_REMOTE='${WAN_N_REMOTE:-$n_operators}'"
            echo -e "  ${CYAN}[*] SMS inter-WAN → ${WAN_REMOTE_IP} (prefixe ${WAN_PREFIX})${NC}"
        fi

        # Correction : on execute directement start-direct.sh avec les bonnes variables
        # pour que CALYPSO_MODE soit correctement passe et reconnu
        exec docker exec -ti "$_qemu_container" bash -c \
            "cd /opt/GSM/osmo_egprs && \
             ./start-direct.sh --stop && \
             NO_MENU=1 \
             MODE='${HANDOFF_MODE}' \
             QEMU_CHOICE='${HANDOFF_QEMU_CHOICE}' \
             ENCRYPTION='a5 1' \
             CALYPSO_BRIDGE='pont' \
             CALYPSO_MODE='shunt_legit' \
             ${_wan_env} \
             ./start-direct.sh ${_node_args} --force"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode net-host
# ══════════════════════════════════════════════════════════════════════════════
start_host_mode() {
    echo -e "${GREEN}Demarrage en mode net-host (1 operateur)...${NC}"
    local src_ip gw_ip
    gw_ip=$(ip route get 1 | awk '{print $3; exit}')
    src_ip=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$src_ip" ] && { echo -e "${RED}Impossible de detecter l'IP hote.${NC}"; exit 1; }
    HOST_IP="$src_ip"

    local n_ms
    n_ms=$(wt_input "net-host" "Nombre de MS :" "1") || exit 1
    n_ms=${n_ms:-1}

    prepare_host_tun
    docker rm -f egprs &>/dev/null || true

    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate > /dev/null 2>&1; then
        sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$n_ms"
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$src_ip" "$gw_ip" \
        "1" "1.1.1" "1.1.2" "1.1.3" \
        "001" "01" "OsmoGSM" \
        "127.0.0.1" "shutdown" "1"

    local vol_args alsa_args
    vol_args=$(build_vol_args "$tmpdir")
    alsa_args=$(build_alsa_args)

    ensure_host_audio_relay
    local nethost_relay=""
    [ -n "$HOST_AUDIO_RELAY" ] && nethost_relay="tcp:127.0.0.1:${WSLG_TCP_PORT}"

    # shellcheck disable=SC2086
    docker run -d --rm --name egprs --net host \
        --cap-add NET_ADMIN --cap-add SYS_ADMIN --cap-add NET_RAW \
        --shm-size=8g \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        $alsa_args \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,rw,mode=1777,size=2g \
        -e CONTAINER_IP="$src_ip" -e GATEWAY_IP="$gw_ip" \
        -e OPERATOR_ID="1" -e N_MS="$n_ms" \
        -e INTER_STP_IP="127.0.0.1" \
        -e HOST_IP="${HOST_IP}" -e SIP_HOST_PORT="5060" \
        -e ALSA_OUTPUT="${ALSA_OUTPUT}" -e ALSA_INPUT="${ALSA_INPUT}" \
        -e HOST_AUDIO_RELAY="${nethost_relay}" \
        $vol_args \
        "$IMAGE_RUN" /root/run.sh

    wait_bb_vty "egprs"
    sleep 3

    local _du="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    local _duid; _duid=$(id -u "$_du" 2>/dev/null)
    local _disp="${DISPLAY:-:0}"
    local _xauth="${XAUTHORITY:-/home/$_du/.Xauthority}"
    local _hscript="/tmp/osmo-gnome-host.sh"
    cat > "$_hscript" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;net-host - egprs\007'
echo "=== net-host - egprs run.sh ==="
exec sudo docker exec -ti egprs /bin/bash -c "/root/run.sh; exec bash"
EOF
    chmod +x "$_hscript"
    echo -e "  ${CYAN}[*] run.sh → gnome-terminal${NC}"
    sudo -u "$_du" \
        DISPLAY="$_disp" XAUTHORITY="$_xauth" \
        XDG_RUNTIME_DIR="/run/user/${_duid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_duid}/bus" \
        gnome-terminal -- bash "$_hscript" &
    sleep 0.3
}

# ══════════════════════════════════════════════════════════════════════════════
stop_all() {
    echo -e "${YELLOW}Arret de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    for _chain in OSMO_WAN_INTEROP OSMO_WAN_MESH; do
        iptables -t nat -D PREROUTING -j "$_chain" 2>/dev/null || true
        iptables -t nat -F "$_chain" 2>/dev/null || true
        iptables -t nat -X "$_chain" 2>/dev/null || true
    done
    echo -e "${GREEN}Arrete.${NC}"
    disable_user_loopback
}

# ══════════════════════════════════════════════════════════════════════════════
# Menus
# ══════════════════════════════════════════════════════════════════════════════
choose_build_mode() {
    [ "${QUICK_EXPLICIT:-0}" = "1" ] && return 0
    local choice
    choice=$(wt_menu "Build de l'image" "Comment (re)construire l'image run ?" \
        "quick"  "Quick - reutilise le cache docker (rapide)" \
        "normal" "Normal - docker build --no-cache (image a neuf)") \
        || { echo "Annule."; exit 1; }
    case "$choice" in
        quick)  QUICK=1 ;;
        normal) QUICK=0 ;;
    esac
}

choose_ran_host() {
    local r
    r=$(wt_menu "RAN - Pipeline QEMU Calypso" \
        "Pipeline radio (conteneur de l'operateur) :" \
        "full-grgsm"   "gr-gsm = le DSP (defaut, valide)" \
        "start-clean"  "Pipeline historique (start-clean.sh)" \
        "full"         "full radio + vrai c54x (WIP)" \
        "shunt"        "DSP shunt canned (bissection FBSB)" \
        "bare"         "QEMU + osmocon only" \
        "faketrx-qemu" "COMBINE : fake_trx vivant + Calypso QEMU" \
        "free"         "menu complet run.sh (--menu)") || exit 1

    if [ "$r" = "faketrx-qemu" ]; then
        HANDOFF_MODE="faketrx-qemu"; HANDOFF_QEMU_CHOICE="faketrx-qemu"
    else
        HANDOFF_MODE="qemu";         HANDOFF_QEMU_CHOICE="$r"
    fi

    local e
    e=$(wt_menu "Chiffrement A5" "Chiffrement :" \
        "1" "A5/1 - chiffrement legacy (defaut)" \
        "0" "A5/0 - pas de chiffrement" \
        "2" "A5/2 - (casse, usage test)") || exit 1
    case "$e" in 0) ENCRYPTION="a5 0" ;; 2) ENCRYPTION="a5 2" ;; *) ENCRYPTION="a5 0" ;; esac
    echo -e "  ${GREEN}[RAN] mode=${CYAN}${HANDOFF_MODE}${NC}${GREEN} pipeline=${CYAN}${HANDOFF_QEMU_CHOICE}${NC}${GREEN} chiffrement=${CYAN}${ENCRYPTION}${NC}"
}

choose_network_mode() {
    local choice
    choice=$(wt_menu "Que lancer ?" "Premier choix :" \
        "qemu"    "PoC QEMU Calypso - qemu-src/run.sh (defaut)" \
        "virtual" "Reseau VIRTUEL multi-operateurs SS7 (config niveau 2)" \
        "hw"      "SDR physique (net-host) - hw (in dev)") || { echo "Annule."; exit 1; }
    case "$choice" in
        qemu)    NETWORK_MODE="qemu" ;;
        virtual) NETWORK_MODE="bridge" ;;
        hw)      NETWORK_MODE="host" ;;
        *) echo -e "${RED}Choix invalide.${NC}"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
# ── Options longues, extraites AVANT le mode positionnel ──────────────────────
# start.sh a toujours pris son mode en $1 (qemu|virtual|hw|stop) et son build en
# quick|normal. On garde ca intact : la pre-passe ne retire que les --wan* et
# rend la main avec les positionnels d'origine.
usage_wan() {
    cat <<'USAGE'
Usage : sudo ./start.sh [quick|normal] [--wan ...] [qemu|virtual|hw|stop]

  --wan                   active le WAN a N noeuds (1 a 9) et pose les questions :
                            • nombre de noeuds
                            • IP publique de chaque noeud
                            • indicatif de chaque noeud (prefixe d'appel)
                            • numero du noeud construit par CE lancement
  --wan-nodes "1:IP:IND ..."  meme chose sans question (scriptable)
  --wan-id N              numero du noeud local (sinon deduit des IP locales)
  --wan-conf FICHIER      table a lire/ecrire (defaut /etc/osmo-wan.conf)

  --virtualbox[=N]        monte le WAN entre CETTE machine et des VM VirtualBox
                          (implique --wan). Cette machine devient un noeud, les
                          autres sont des VM sur un segment host-only.
  --vbox-node N           numero de noeud porte par cette machine (defaut 1)
  --hub-node N            noeud qui heberge l'inter-STP, le hub SS7 (defaut 1).
  --hub-ip ADRESSE        inter-STP a une adresse a lui, hors table WAN. Le hub
                          n'est alors PAS un noeud : aucun indicatif, aucun
                          abonne, et rien n'est lance localement.
  --node-per-op           chaque conteneur est un NOEUD (base = --wan-id) et non
                          un operateur de la machine : conteneur 1 -> noeud N,
                          conteneur 2 -> noeud N+1... Point codes 1.<n>1.<role>.
  --operator IP:PREFIXE   declare un operateur du WAN par son adresse et son
                          prefixe d'appel. Repetable ; l'ordre donne les numeros
                          de noeud. Il DECLARE seulement : aucun conteneur n'est
                          lance pour lui - c'est ainsi qu'une VM deja demarree
                          entre dans la table SMS et le dialplan. Les conteneurs
                          restent gouvernes par le nombre d'operateurs demande.
                            --operator 192.168.1.2:11   (la VM, deja lancee)
                            --operator 172.20.0.11:22   (un conteneur d'ici)
                          UN SEUL noeud du WAN doit le porter.
  --build-stp             construit l'image legere osmocom-stp (Dockerfile.stp)
                          pour le hub. Sans elle, le hub tourne sur l'image
                          complete, qui contient aussi osmo-stp.

  Sans --wan, rien ne change : aucun WAN n'est monte.
  Avec --wan, la radio passe en HYBRIDE par defaut (1 faketrx + 1 QEMU Calypso).

  Composer <indicatif><numero> joint ce numero sur le noeud correspondant.
    ex. noeud 1 = indicatif 11, noeud 2 = 22 → depuis 2, "1110001" appelle
    le MS 10001 de l'operateur 1 du noeud 1.
USAGE
}

_pos_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --wan)          WAN_MESH=1 ;;
        --wan=*)        WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-nodes)    WAN_MESH=1; WAN_NODES="${2:-}"; shift ;;
        --wan-nodes=*)  WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-id)       WAN_MESH=1; WAN_NODE_ID="${2:-}"; shift ;;
        --wan-id=*)     WAN_MESH=1; WAN_NODE_ID="${1#*=}" ;;
        --wan-conf)     WAN_CONF_FILE="${2:-}"; shift ;;
        --wan-conf=*)   WAN_CONF_FILE="${1#*=}" ;;
        --build-stp)      BUILD_STP=1 ;;
        --hub-node)       WAN_HUB_NODE="${2:-1}"; WAN_HUB_NODE_GIVEN=1; shift ;;
        --hub-ip)         WAN_HUB_IP="${2:-}"; shift ;;
        --node-per-op)    WAN_NODE_PER_OP=1; WAN_NODE_PER_OP_GIVEN=1 ;;
        --operators)      OPERATOR_COUNT_HINT="${2:-}"; shift ;;
        --operators=*)    OPERATOR_COUNT_HINT="${1#*=}" ;;
        --operator)       OPERATOR_DECLS+=("${2:-}"); WAN_MESH=1; shift ;;
        --operator=*)     OPERATOR_DECLS+=("${1#*=}"); WAN_MESH=1 ;;
        --hub-ip=*)       WAN_HUB_IP="${1#*=}" ;;
        --hub-node=*)     WAN_HUB_NODE="${1#*=}" ;;
        --virtualbox)     WAN_MESH=1; VBOX_INTERCO=1 ;;
        --virtualbox=*)   WAN_MESH=1; VBOX_INTERCO=1; VBOX_NODES="${1#*=}" ;;
        --vbox-node)      VBOX_HOST_NODE="${2:-1}"; shift ;;
        --vbox-node=*)    VBOX_HOST_NODE="${1#*=}" ;;
        -h|--help)      usage_wan; exit 0 ;;
        *)              _pos_args+=("$1") ;;
    esac
    shift
done

# ── --operator : de la declaration a la table WAN ───────────────────────────
# "IP:PREFIXE" est ce qu'on a sous les yeux ; "id:ip:ind" est ce que le reste du
# code attend. La conversion se fait ici, une fois, plutot que de demander a
# l'utilisateur de tenir lui-meme la numerotation des noeuds.
if [ "${#OPERATOR_DECLS[@]}" -gt 0 ]; then
    if [ -n "${WAN_NODES:-}" ]; then
        echo -e "\033[0;31m--operator et --wan-nodes sont exclusifs : choisissez l'un des deux.\033[0m" >&2
        exit 2
    fi
    # LES CONTENEURS D'ABORD, dans l'ordre : osmo-operator-1 est le noeud 1,
    # -2 le noeud 2... Leur adresse est celle du backbone, leur indicatif le
    # defaut du rang. Les operateurs declares en CLI prennent les rangs
    # suivants. Numerotation lisible : le nom du conteneur donne son noeud.
    _n=0; _spec=""
    _ncont="${OPERATOR_COUNT_HINT:-0}"
    while [ "$_n" -lt "$_ncont" ]; do
        _n=$(( _n + 1 ))
        _spec="${_spec}${_spec:+ }${_n}:172.20.0.$(( 10 + _n )):$(( _n * 11 ))"
    done
    for _d in "${OPERATOR_DECLS[@]}"; do
        _ip="${_d%%:*}"; _ind="${_d##*:}"
        if [ -z "$_ip" ] || [ "$_ip" = "$_d" ] || [ -z "$_ind" ]; then
            echo -e "\033[0;31m--operator : attendu IP:PREFIXE (ex: 192.168.1.2:11), recu '$_d'\033[0m" >&2
            exit 2
        fi
        _n=$(( _n + 1 ))
        _spec="${_spec}${_spec:+ }${_n}:${_ip}:${_ind}"
    done
    WAN_NODES="$_spec"
    echo -e "\033[0;36m  Operateurs declares :\033[0m $WAN_NODES"
fi

set -- ${_pos_args[@]+"${_pos_args[@]}"}

banner
[ "${1:-}" = "stop" ] && { stop_all; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis${NC}"; exit 1; }

case "${1:-}" in
    quick)  QUICK=1; QUICK_EXPLICIT=1; shift ;;
    normal) QUICK=0; QUICK_EXPLICIT=1; shift ;;
esac

docker rm -f $(docker ps -aq --filter "name=osmo-") 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=egprs") 2>/dev/null || true
docker network ls --filter "name=gsm-" -q | xargs -r docker network rm 2>/dev/null || true

# Selection du mode
case "${1:-}" in
    qemu)    NETWORK_MODE="qemu" ;;
    virtual) NETWORK_MODE="bridge" ;;
    hw)      NETWORK_MODE="host" ;;
    "")
        if [ "${WAN_MESH:-0}" = "1" ]; then
            # --wan sans mode : on ne redemande pas "que lancer ?". Un WAN se
            # monte sur des operateurs, donc mode virtuel, et le menu de build
            # reste pose (quick/normal) s'il n'a pas ete tranche en ligne.
            NETWORK_MODE="bridge"
            [ "${QUICK_EXPLICIT:-0}" = "1" ] || { check_whiptail; choose_build_mode; }
        elif [ "${OSMO_MULTI:-0}" = "1" ]; then
            NETWORK_MODE="bridge"
        elif [ "${OSMO_MENU:-1}" = "0" ]; then
            NETWORK_MODE="qemu"
        else
            check_whiptail
            choose_build_mode
            choose_network_mode
        fi
        ;;
    *) echo -e "${RED}Mode inconnu : '$1' (attendu : qemu|virtual|hw|stop)${NC}"; exit 1 ;;
esac

[ "$NETWORK_MODE" = "bridge" ] && check_whiptail
echo -e "${GREEN}Mode : ${CYAN}${NETWORK_MODE}${NC}  ${GREEN}Build : ${CYAN}$([ "${QUICK:-0}" = "1" ] && echo "quick (cache)" || echo "normal (--no-cache)")${NC}"

./helpers/prepare_host.sh
build_run_image
check_image

case "$NETWORK_MODE" in
    qemu)   start_qemu_poc ;;
    host)   start_host_mode ;;
    bridge) start_bridge_mode ;;
esac
