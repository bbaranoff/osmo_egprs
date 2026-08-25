#!/bin/bash
# =============================================================================
# start-direct.sh — Prépare l'environnement Calypso puis lance run.sh
# =============================================================================
#
# Ce script ne démarre aucun démon.
#
# Il :
#   1. charge l'environnement ;
#   2. détecte le matériel / les binaires ;
#   3. choisit le mode (profil) ;
#   4. génère les fichiers mobile_*.cfg ;
#   5. exporte les variables nécessaires ;
#   6. exécute run.sh.
#
# Toute la logique GSM vit ensuite dans run.sh (et run_modules/).
#
# CHAÎNE DE CONFIGURATION — NE PAS LA CASSER
#     VAR=x ./start-direct.sh   ← la ligne de commande gagne toujours
#       -> environment/load.env
#          -> paths / modes / domaines
#     puis exec run.sh avec le profil choisi.
# -----------------------------------------------------------------------------
set -uo pipefail

# ── [2026-08-14] GARDE « on doit être dans Docker » RETIRÉE ───────────────────
# Elle exigeait /.dockerenv ET /etc/docker-entrypoint-cmd, et sortait en exit 1
# quand l'un manquait. Sur l'ISO il n'y a pas de Docker : les deux fichiers sont
# absents, la garde bloquait donc le seul lanceur utilisable là-bas. Retirée sur
# demande explicite — c'est le cas d'usage ISO qui prime.
#
# CE QU'ON PERD, et c'était sa raison d'être (constat du 12/08) : lancé par
# erreur sur un HÔTE qui a Docker, ce script repart sur un environnement à
# moitié construit — /opt/GSM/qemu-src n'y existe pas, mais /tmp/osmo-nitb/logs,
# lui, se crée tout seul — et meurt sur un « run.sh introuvable » qui ne désigne
# pas la vraie cause. Si ce symptôme réapparaît sur une machine avec Docker,
# c'est ça : là-bas le lanceur est ./start.sh (ou ./start-nitb.sh), pas celui-ci.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# --- options ------------------------------------------------------------------
DRY=0 VERBOSE=0 ACTION=start PROFILE="${CALYPSO_PROFILE:-faketrx-qemu}" FORCE=0
# WAN : jamais par défaut. --wan (ou WAN_AUTO=1 dans /etc/osmo-wan.conf, ce que
# pose une ISO construite avec --wan) le monte avant de passer la main à run.sh.
WAN_MESH=0
# --virtualbox : monte le segment et les VM avant le WAN. Refusé si l'on tourne
# DANS une VM — c'est l'hôte qui pilote VirtualBox (le script le vérifie).
VBOX_INTERCO=0
VBOX_NODES=""
VBOX_HOST_NODE=1
# --node : le numéro de CE nœud, choisi au lancement et pas à la construction.
# C'est ce qui permet une ISO unique pour les neuf nœuds.
NODE_ID=""
NODE_OP=1
HUB_IP=""
usage() {
    cat <<'USAGE'
Usage : ./start-direct.sh [options] [mode]
  Modes (profils) :
    faketrx-qemu   cœur + BTS#0 QEMU + BTS#1 faketrx (défaut)
    faketrx        cœur + fake_trx + trxcon + mobile
    qemu           pipeline Calypso QEMU seul
    virtphy        cœur + osmo-bts-virtual + virtphy
    noproc         cœur seul (no-process)
    core           alias noproc
    hybrid         alias faketrx-qemu
    hw             SDR physique
  Options :
    --list              affiche le plan (délègue à run.sh --list)
    --dry-run           déroule sans effet de bord
    --profile <nom>     force le profil
    --stop              arrête la pile (délègue à run.sh --stop)
    --status            interroge l'état (délègue à run.sh --status)
    --force             relance même les modules déjà démarrés
    --verbose           montre la sortie des modules
    --check-paths       vérifie les dépendances déclarées
    --wan               monte le WAN à N noeuds (1 à 9) AVANT run.sh et demande :
                          nombre de noeuds, IP de chaque noeud, indicatif de
                          chaque noeud, numéro du noeud construit par ce lancement
    --wan-nodes "1:IP:IND …"   même chose sans question (scriptable)
    --wan-id N          numéro du noeud local (sinon déduit des IP locales)
    --wan-conf FICHIER  table à lire/écrire (défaut /etc/osmo-wan.conf)
    --node N            numéro de CE nœud, 1 à 9. Réécrit son identité SS7
                        (point codes 1.<nœud><op>.<rôle>, routing contexts) et
                        pointe son ASP sur l'inter-STP. Une seule ISO suffit
                        alors pour les neuf nœuds — le numéro se choisit ici.
    --op N              opérateur porté par ce nœud (défaut 1)
    --hub-ip ADRESSE    inter-STP à joindre (défaut : selon docker ou VM)
    --virtualbox[=N]    WAN entre CETTE machine et N-1 VM VirtualBox (implique
                        --wan). À lancer depuis l'hôte, pas depuis une VM.
    --vbox-node N       numéro de noeud porté par cette machine (défaut 1)
    -h, --help          cette aide

  Sans --wan : aucun WAN. Avec --wan le profil reste faketrx-qemu (hybride,
  1 faketrx + 1 QEMU Calypso), qui est déjà le défaut de ce script.
  Composer <indicatif><numéro> joint ce numéro sur le noeud correspondant.
Toute variable CALYPSO_* passée en préfixe est transmise à run.sh / QEMU :
  CALYPSO_MODE=native ./start-direct.sh
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION=list ;;
        --dry-run)     DRY=1 ;;
        --profile)     if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                           printf '%s\n\n' "--profile attend un nom de profil" >&2
                           usage >&2; exit 2
                       fi
                       PROFILE="$2"; shift ;;
        --stop)        ACTION=stop ;;
        --status)      ACTION=status ;;
        --force)       FORCE=1 ;;
        --verbose)     VERBOSE=1 ;;
        --check-paths) ACTION=checkpaths ;;
        --wan)         WAN_MESH=1 ;;
        --wan=*)       WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-nodes)   WAN_MESH=1; WAN_NODES="${2:-}"; shift ;;
        --wan-nodes=*) WAN_MESH=1; WAN_NODES="${1#*=}" ;;
        --wan-id)      WAN_MESH=1; WAN_NODE_ID="${2:-}"; shift ;;
        --wan-id=*)    WAN_MESH=1; WAN_NODE_ID="${1#*=}" ;;
        --wan-conf)    WAN_CONF_FILE="${2:-}"; shift ;;
        --wan-conf=*)  WAN_CONF_FILE="${1#*=}" ;;
        --virtualbox)   WAN_MESH=1; VBOX_INTERCO=1 ;;
        --virtualbox=*) WAN_MESH=1; VBOX_INTERCO=1; VBOX_NODES="${1#*=}" ;;
        --vbox-node)    VBOX_HOST_NODE="${2:-1}"; shift ;;
        --vbox-node=*)  VBOX_HOST_NODE="${1#*=}" ;;
        --node)         NODE_ID="${2:-}"; shift ;;
        --node=*)       NODE_ID="${1#*=}" ;;
        --op)           NODE_OP="${2:-1}"; shift ;;
        --op=*)         NODE_OP="${1#*=}" ;;
        --hub-ip)       HUB_IP="${2:-}"; shift ;;
        --hub-ip=*)     HUB_IP="${1#*=}" ;;
        -h|--help)     usage; exit 0 ;;
        faketrx-qemu|faketrx|qemu|virtphy|noproc|core|hybrid|hw)
            PROFILE="$1"
            [ "$PROFILE" = "hybrid" ] && PROFILE=faketrx-qemu
            [ "$PROFILE" = "core" ]   && PROFILE=noproc
            ;;
        *) printf 'option inconnue : %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
# --- où tourne-t-on ? ---------------------------------------------------------
# La question n'est pas cosmétique : le plan d'adressage EN DÉPEND.
#   docker  → l'inter-STP est le conteneur osmo-inter-stp (172.20.0.10), le
#             nœud a déjà son IP quand les démons démarrent.
#   VM/ISO  → l'inter-STP est une machine à part (192.168.56.1), et l'adresse
#             du nœud vient du DHCP : elle peut manquer au lancement.
# Prendre l'un pour l'autre donne un ASP qui ne s'attache jamais, avec pour
# seule trace un « connection refused » vers une adresse inexistante ici.
#
# /.dockerenv seul ne suffit pas — il est vrai dans n'importe quel conteneur.
# On exige aussi /etc/docker-entrypoint-cmd, que scripts/entrypoint.sh dépose :
# c'est ce couple qui identifie un conteneur DE CE DÉPÔT.
detect_runtime_env() {
    if [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]; then
        echo docker; return
    fi
    if [ -f /.dockerenv ] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
        echo docker; return
    fi
    # systemd-detect-virt SORT EN CODE 1 quand il ne trouve rien. Un
    # « $(cmd || echo none) » produit alors DEUX lignes — la sortie « none » du
    # programme, plus celle du repli — et aucun motif ne correspond : une
    # machine physique se retrouvait classée « vm ». On ignore le code de
    # sortie et on ne garde que la première ligne.
    local v
    v="$(systemd-detect-virt 2>/dev/null | head -1)" || true
    v="${v:-none}"
    case "$v" in
        oracle|kvm|qemu|vmware|microsoft|xen|bochs|parallels) echo vm ;;
        none|"") echo bare ;;
        *) echo vm ;;
    esac
}
RUNTIME_ENV="${RUNTIME_ENV:-$(detect_runtime_env)}"
# Pour les scripts qui ne connaissent que deux mondes : docker, ou tout le reste.
case "$RUNTIME_ENV" in docker) NODE_MODE=docker ;; *) NODE_MODE=native ;; esac

# --- affichage (identique à run.sh) -------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_Z=$'\033[0m'
else
    TTY=0
    C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_CYAN=""; C_BOLD=""; C_Z=""
fi
say_begin() {
    if [ $TTY -eq 1 ]; then
        printf '[ %s.. %s] %s' "$C_DIM" "$C_Z" "$1"
    else
        printf '[ .. ] %s\n' "$1"
    fi
}
say_end() { # $1=tag $2=couleur $3=libellé $4=détail
    if [ $TTY -eq 1 ]; then printf '\r\033[K'; fi
    printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
    [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"
    printf '\n'
}
banner() {
    echo -e "${C_CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Calypso GSM — bootstrap → run.sh                   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${C_Z}"
}
# --- 1. configuration ---------------------------------------------------------
# [2026-08-03] globals.conf — les reglages reseau (MCC/MNC/ARFCN/KI/IMSI/A5...).
# Genere par ./generate_configs.sh cote hote ; ici on se contente de le lire.
# L'idiome « := » qu'il utilise laisse gagner toute variable deja posee, donc
#     ARFCN=520 ./start-direct.sh
# surcharge sans toucher au fichier.
[ -r "$HERE/globals.conf" ] && { set -a; . "$HERE/globals.conf"; set +a; }

say_begin "Chargement de l'environnement"
if [ -f "$HERE/environment/load.env" ]; then
    set -a; . "$HERE/environment/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "environment/load.env"
elif [ -f "$HERE/env/load.env" ]; then
    set -a; . "$HERE/env/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "env/load.env"
else
    # Fallback minimal (chemins typiques du dépôt)
    : "${GSM_ROOT:=/opt/GSM}"
    : "${NITB_TREE:=$HERE}"
    if [ -x "$HERE/run.sh" ]; then
        : "${OQC_ROOT:=$HERE}"
    elif [ -x "$HERE/../qemu-src/run.sh" ]; then
        : "${OQC_ROOT:=$(cd "$HERE/../qemu-src" && pwd)}"
    else
        : "${OQC_ROOT:=$GSM_ROOT/qemu-src}"
    fi
    say_end " OK " "$C_OK" "Chargement de l'environnement" "fallback minimal"
fi
: "${RUN_DIR:=/run/osmo-direct}"
# Repli si load.env est absent. Les journaux restent sous RUN_DIR (tmpfs) :
# le défilement tmux en dépend — cf. environment/paths.env.
: "${LOG_DIR:=$RUN_DIR/logs}"
: "${ENCRYPTION:=a5 0}"
: "${MS_COUNT:=2}"
: "${HOST_IP:=127.0.0.1}"
mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb 2>/dev/null || true
# --- 2. détection des chemins / binaires --------------------------------------
say_begin "Résolution de run.sh"
# [2026-08-08] Le chemin etait cable en dur ICI, ce qui rendait MORTE toute la
# resolution de OQC_ROOT faite plus haut (trois candidats testes pour rien) et
# contredisait le contrat annonce en tete de fichier (« la ligne de commande
# gagne toujours ») : RUN_SH etait la seule variable non surchargeable.
# Ordre : RUN_SH explicite > OQC_ROOT resolu > chemin historique.
: "${RUN_SH:=${OQC_ROOT:+$OQC_ROOT/run.sh}}"
: "${RUN_SH:=/opt/GSM/qemu-src/run.sh}"
if [ ! -x "$RUN_SH" ]; then
    say_end "FAIL" "$C_KO" "Résolution de run.sh" "$RUN_SH introuvable ou non exécutable"
    printf '       %s→ Vérifiez que /opt/GSM/qemu-src/run.sh existe et est exécutable%s\n' "$C_DIM" "$C_Z"
    exit 1
fi
say_end " OK " "$C_OK" "Résolution de run.sh" "$RUN_SH"
RUN_ROOT="$(dirname "$RUN_SH")"
# Profil → mapping vers les profils attendus par run.sh
case "$PROFILE" in
    faketrx-qemu|hybrid) CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu ;;
    faketrx)             CALYPSO_PROFILE=faketrx;  MODE=faketrx ;;
    qemu)                CALYPSO_PROFILE=calypso;  MODE=qemu ;;
    virtphy)             CALYPSO_PROFILE=faketrx;  MODE=virtphy; PHY_MODE=virtphy ;;
    noproc|core)         CALYPSO_PROFILE=core;     MODE=noproc; RUN_NO_PROCESS=1 ;;
    hw)                  CALYPSO_PROFILE=faketrx;  MODE=hw; PHY_MODE=trx ;;
    *)                   CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu; PROFILE=faketrx-qemu ;;
esac
export CALYPSO_PROFILE MODE
export PHY_MODE="${PHY_MODE:-faketrx}"
export RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
export ENCRYPTION MS_COUNT HOST_IP
export LOG_DIR RUN_DIR
# --- 3. validation des chemins critiques --------------------------------------
say_begin "Validation des chemins"
path_ok=1
_check() {
    local name="$1" val="${!1:-}"
    if [ -z "$val" ]; then
        printf '\n       %s%s non défini%s\n' "$C_DIM" "$name" "$C_Z"
        path_ok=0
    elif [ -e "$val" ]; then
        :
    else
        printf '\n       %s%s introuvable : %s%s\n' "$C_DIM" "$name" "$val" "$C_Z"
        path_ok=0
    fi
}
# Variables optionnelles selon le profil ; on ne bloque que si présentes et cassées
for v in QEMU_BIN FIRMWARE_ELF DSP_PROM0 OSMOCON; do
    # `[ -n x ] && _check || true` avalait le verdict : _check pouvait poser
    # path_ok=0 sans que la boucle ne le laisse remonter. Forme explicite.
    if [ -n "${!v:-}" ]; then _check "$v"; fi
done
if [ $path_ok -eq 1 ]; then
    say_end " OK " "$C_OK" "Validation des chemins"
else
    say_end "WARN" "$C_SK" "Validation des chemins" "certains chemins manquent (run.sh vérifiera)"
fi
# --- 4. génération des configs mobile -----------------------------------------
# MS#1 (QEMU / mobile principal) et MS#2 (faketrx side-car) pour le profil hybrid.
BB_DIR="/root/.osmocom/bb"
mkdir -p "$BB_DIR"
# Sources possibles pour le template mobile
MS_TEMPLATE=""
for t in \
    "${OQC_ROOT:-}/cfgs/mobile_group1.cfg" \
    "$RUN_ROOT/cfgs/mobile_group1.cfg" \
    "$HERE/configs/mobile.cfg.template" \
    "$HERE/configs/mobile.cfg" \
    "$BB_DIR/mobile_group1.cfg" \
    "$BB_DIR/mobile.cfg"
do
    if [ -f "$t" ]; then MS_TEMPLATE="$t"; break; fi
done
generate_mobile_cfg() {
    local dest="$1" vty_port="$2" l2sock="$3" sapsock="$4" arfcn="$5" imsi="$6" ki="$7"
    # [2026-08-08] Peripheriques ALSA PAR MOBILE. Le template porte
    # gsm_out/gsm_in pour tout le monde ; laisser ca remettrait les deux
    # mobiles sur le meme sink et la meme source, c'est-a-dire la boucle
    # audio qu'on vient d'ouvrir (cf /etc/asound.conf).
    local aout="${8:-gsm_out}" ain="${9:-gsm_in}"
    # [2026-08-08] GARDE-FOU : la liste de templates contient $BB_DIR/mobile.cfg,
    # qui est aussi une DESTINATION. Si c'est lui qui est retenu, `sed "$tpl" >
    # "$dest"` avec tpl == dest fait tronquer le fichier par le shell AVANT que
    # sed ne le lise : on produit un mobile.cfg VIDE et le mobile ne demarre plus.
    # On bascule alors sur le template de secours plutot que de se detruire.
    local tpl="$MS_TEMPLATE"
    if [ -n "$tpl" ] && [ "$tpl" -ef "$dest" ] 2>/dev/null; then
        printf '\n       %sMS_TEMPLATE == destination (%s) : template de secours%s\n' \
            "$C_DIM" "$dest" "$C_Z"
        tpl=""
    fi
    if [ -n "$tpl" ]; then
        sed \
            -e "s|bind 127.0.0.1 424[0-9]|bind 127.0.0.1 ${vty_port}|" \
            -e "s|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket ${l2sock}|" \
            -e "s|sap-socket /tmp/osmocom_sap[_0-9]*|sap-socket ${sapsock}|" \
            -e "s|stick [0-9]*|stick ${arfcn}|" \
            -e "s|imsi [0-9]*|imsi ${imsi}|" \
            -e "s|ki comp128 [0-9a-f ]*|ki comp128 ${ki}|" \
            -e "s|alsa-output-dev .*|alsa-output-dev ${aout}|" \
            -e "s|alsa-input-dev .*|alsa-input-dev ${ain}|" \
            "$tpl" > "$dest"
    else
        # Template minimal de secours
        cat > "$dest" <<EOF
!
! mobile.cfg généré par start-direct.sh (secours)
!
log stderr
 logging color 1
 logging print category 1
 logging timestamp 0
!
line vty
 no login
 bind 127.0.0.1 ${vty_port}
!
ms 1
 layer2-socket ${l2sock}
 sap-socket ${sapsock}
 sim reader
 imsi ${imsi}
 ki comp128 ${ki}
 network-selection-mode auto
 stick ${arfcn}
!
EOF
    fi
}
# ⚠️ [2026-08-08] CE FICHIER N'EST PEUT-ETRE PAS CELUI QUE LE RUN UTILISE.
# Constate sur le deploiement conteneurise : le mobile Calypso tourne avec
#     mobile -c /root/.osmocom/bb/mobile_group1.cfg
# alors qu'on genere ici mobile.cfg. Les deux sont des MONTAGES BIND fournis par
# docker (compose), donc il y a DEUX sources de verite, et elles divergent :
# mobile.cfg porte IMSI 001010000000001, mobile_group1.cfg 001010001000001.
# Tant que le lanceur du conteneur designe mobile_group1.cfg, ce qu'on ecrit ici
# est inerte. Verifier avant de croire un reglage pose ici :
#     pgrep -a mobile
say_begin "Génération mobile MS#1"
MS1_CFG="${MOBILE_CFG_MS1_PATH:-$BB_DIR/mobile.cfg}"
generate_mobile_cfg "$MS1_CFG" \
    4247 \
    /tmp/osmocom_l2 \
    /tmp/osmocom_sap_1 \
    514 \
    "001010001000001" \
    "00 11 22 33 44 55 66 77 88 99 aa bb cc dd 01 01"
say_end " OK " "$C_OK" "Génération mobile MS#1" "$MS1_CFG"
say_begin "Génération mobile MS#2 (faketrx)"
MS2_CFG="$BB_DIR/mobile_faketrx_bts1.cfg"
generate_mobile_cfg "$MS2_CFG" \
    4248 \
    /tmp/ms2_l2 \
    /tmp/ms2_sap \
    516 \
    "001010001000002" \
    "00 11 22 33 44 55 66 77 88 99 aa bb cc dd 02 01" \
    gsm_out gsm_in
say_end " OK " "$C_OK" "Génération mobile MS#2 (faketrx)" "$MS2_CFG"
# Export pour que les modules run.sh / hybrid puissent les retrouver
export MOBILE_CFG_MS1="$MS1_CFG"
export MOBILE_CFG_MS2="$MS2_CFG"
export CALYPSO_MS2_CFG="$MS2_CFG"

# --- Mode PONT TRX (CALYPSO_BRIDGE=pont) : le pont maison REMPLACE la chaine IQ --
# Le pont (/opt/GSM/pont/pont.py) se presente comme transceiver TRX-UDP a osmo-bts-trx
# (5700/5701/5702), decode les bursts DL en L2 -> GSMTAP 4730/4731 (shunt in-QEMU ->
# a_cd), et encode l'UL depuis les sidebands /dev/shm/calypso_* -> TRXD -> BTS.
# Il REND REDONDANTS et on ETEINT : osmo-trx-ipc (transceiver), calypso-ipc-device
# (pont IQ), si_bridge (decode DL), demod-bridge. On GARDE QEMU (Calypso+shunt) et
# osmo-bts-trx. Reversible : ne pas passer CALYPSO_BRIDGE=pont.
if [ "${CALYPSO_BRIDGE:-}" = pont ]; then
    export CALYPSO_BRIDGE
    export CALYPSO_SKIP_TRX_IPC=1        # plus d'osmo-trx-ipc (le pont est le transceiver)
    export CALYPSO_SKIP_IPC_DEVICE=1     # plus de calypso-ipc-device (plus d'IQ)
    export CALYPSO_SKIP_BRIDGE_PY=1      # plus de si_bridge (le pont decode)
    export CALYPSO_SKIP_DEMOD_BRIDGE=1   # plus de demod-bridge
    # Le pont a BESOIN d'osmo-bts-trx en face (c'est son interlocuteur TRX-UDP).
    # On l'impose explicitement : un SKIP_BTS herite d'un run precedent (env
    # fossilise) laisserait le pont sans personne au bout du fil.
    export CALYPSO_SKIP_BTS=0
    # FB (FCCH) : en mode pont il n'y a plus de chaine gr-gsm/IQ, donc plus de
    # detection FB REELLE (calypso_dsp_shunt_real_fb_read). Sans FB, la FBSB de
    # l'ARM echoue -> "Channel sync error" -> le mobile ne campe jamais, meme
    # avec des SI. On laisse donc le shunt FABRIQUER le FB (canned), tandis que
    # le SCH, lui, reste REEL : le pont le decode et le publie sur 4731.
    export CALYPSO_SHUNT_REAL_FB=0
    export CALYPSO_SHUNT_NO_CANNED=0
    # 65-record-drain / 66-grgsm-decode sont rallumes par ce forceur meme hors
    # full-grgsm : on le neutralise (aucune IQ a drainer ni a decoder ici).
    export CALYPSO_FORCE_DEMOD_BRIDGE=0
    # Preset EXISTANT "bridge" = pont Python a la place d'ipc/trx-ipc : c'est
    # exactement notre cas. Il pose SKIP_IPC_DEVICE=1 / SKIP_TRX_IPC=1, et
    # comme il n'est pas full-grgsm il DESACTIVE aussi 65-record-drain et
    # 66-grgsm-decode (MOD_ENABLED_IF) — le pont fournit lui-meme le GSMTAP.
    export CALYPSO_PIPELINE=bridge
    _PONT="${PONT_PY:-/opt/GSM/pont/pont.py}"
    # [2026-08-16] N'ARMER LE LANCEUR QUE SUR UN VRAI DEMARRAGE.
    # Ce bloc s'execute AVANT le `case "$ACTION"` plus bas. Sur `--stop` (comme
    # sur --list/--status/--check-paths) on armait donc quand meme le lanceur
    # differe, que `run.sh --stop` tuait aussitot — d'ou le « line 450: Killed »
    # crache par bash en plein arret propre. Un arret qui programme un demarrage
    # n'a aucun sens, et le message faisait croire a une panne.
    # Le pont DEJA VIVANT, lui, est bien arrete : le teardown le connait
    # desormais (`f:pont/pont.py` dans _td_patterns) et mod_teardown_stop
    # l'applique aussi.
    if [ "$ACTION" != start ]; then
        printf '  %spont TRX%s : non arme (action=%s, pas un demarrage)\n' \
               "${C_DIM:-}" "${C_Z:-}" "$ACTION"
    elif [ -r "$_PONT" ]; then
        # SINGLETON : tuer un pont precedent, sinon il tient 5700-5702 et le
        # teardown de run.sh echoue ("restes du run precedent : port:5700...").
        pkill -f "$_PONT" 2>/dev/null || true
        # [2026-08-16] KILLALL DEMANDE PAR L'OPERATEUR, et assume.
        # Le motif nominatif ci-dessus rate tout pont lance sous un autre chemin
        # (PONT_PY surcharge, une sauvegarde .bak), et c'est ce qui faisait
        # echouer le teardown sur « port:5700 port:5701 port:5702 ».
        # ⚠️ CE QUE CA EMPORTE, en plus du pont : fake_trx.py (le transceiver de
        # MS#2), sms-interop-relay.py (routage SMS inter-operateurs, HORS pile
        # run.sh donc non relance automatiquement), gsm_sniff.py et les scripts
        # des panes tmux. C'est acceptable ICI parce qu'on est sur le chemin d'un
        # DEMARRAGE (ACTION=start) : le teardown de run.sh va de toute facon tout
        # arreter deux secondes plus tard. Ne PAS reprendre ce geste dans un
        # module de run.sh, ou il tuerait le filtre d'horodatage du run en cours.
        # CALYPSO_NO_KILLALL=1 pour s'en passer.
        if [ "${CALYPSO_NO_KILLALL:-0}" != "1" ]; then
            printf '  %spont TRX%s : killall -9 python3 (demande ; emporte aussi fake_trx / sms-interop-relay)\n' "${C_DIM:-}" "${C_Z:-}"
            killall -9 python3 2>/dev/null || true
        fi
        sleep 1
        printf '  %spont TRX%s : REMPLACE osmo-trx-ipc + calypso-ipc-device + si_bridge (SHUNT_LEGIT burst-direct)\n' "${C_DIM:-}" "${C_Z:-}"
        # LANCEMENT DIFFERE : run.sh fait d'abord son teardown (qui verifie que
        # 5700-5702 sont LIBRES). On ne binde donc qu'apres, sinon on se
        # bloque nous-memes. 25 s = teardown + demarrage des modules.
        # LOG HORS LOG_DIR : run.sh archive/efface LOG_DIR pendant son teardown ;
        # un pont.log ouvert avant se retrouve sur un inode SUPPRIME (sortie
        # invisible, "(deleted)" dans /proc/<pid>/fd/1). /dev/shm survit.
        # setsid : le pont doit survivre a la fin du shell de start-direct.
        # [2026-08-16] LE `sleep 25` ETAIT UNE COURSE, PAS UNE BARRIERE.
        # 25 s etait un pari sur la duree du teardown de run.sh. Des que
        # celui-ci archive de gros journaux (mesure : 62 Mo -> ~40 s), le pont
        # se rebindait sur 5700-5702 EN PLEIN teardown, qui echouait alors sur
        # « restes du run precedent : port:5700 port:5701 port:5702 » et
        # abandonnait toute la sequence. Le symptome se deplacait avec la
        # taille des journaux, ce qui le faisait passer pour intermittent.
        # On attend maintenant un EVENEMENT et non une duree : osmo-bts-trx,
        # qui est l'interlocuteur TRX-UDP du pont et ne demarre qu'APRES le
        # teardown. Sa presence prouve donc que les ports sont a nous.
        ( _n=0
          while [ "$_n" -lt 180 ] && ! pgrep -x osmo-bts-trx >/dev/null 2>&1; do
              _n=$((_n + 1)); sleep 1
          done
          if [ "$_n" -ge 180 ]; then
              echo "[pont] osmo-bts-trx jamais vu apres 180 s — demarrage quand meme"
          else
              echo "[pont] osmo-bts-trx detecte apres ${_n} s — la pile est debout, on binde"
          fi
          sleep 1
          pkill -f "$_PONT" 2>/dev/null; sleep 1
          exec setsid python3 -u "$_PONT" ) >/dev/shm/pont.log 2>&1 &
        printf '  %spont: journal%s /dev/shm/pont.log (hors LOG_DIR, efface par le teardown)\n' "${C_DIM:-}" "${C_Z:-}"
    else
        printf '  pont introuvable (%s)\n' "$_PONT"
    fi
fi

# --- Mode BRIDGE IPC-MS (CALYPSO_BRIDGE=ipc) : MS#1 servi par osmo-trx-ms-ipc ----
# Le firmware qemu/osmocon de MS#1 est SKIP (gates dans 40-qemu.sh/50-osmocon.sh).
# osmo-trx-ms-ipc lit le DL fc32 relaye par l'IPC (UDP CALYPSO_TRX_IQ_RX_PORT=5810),
# emet l'UL fc32 sur 5811 (relay_init le lit deja), et sert L1CTL sur /tmp/osmocom_l2.
if [ "${CALYPSO_BRIDGE:-}" = ipc ]; then
    export CALYPSO_BRIDGE
    export CALYPSO_IPC_RELAY=1
    : "${CALYPSO_TRX_IQ_HOST:=127.0.0.1}";   export CALYPSO_TRX_IQ_HOST
    : "${CALYPSO_TRX_IQ_RX_PORT:=5810}";     export CALYPSO_TRX_IQ_RX_PORT
    : "${CALYPSO_TRX_IQ_TX_PORT:=5811}";     export CALYPSO_TRX_IQ_TX_PORT
    _MSIPC="$(command -v osmo-trx-ms-ipc || echo /opt/GSM/osmo-trx/Transceiver52M/osmo-trx-ms-ipc)"
    if [ -x "$_MSIPC" ]; then
        printf '  %sMS#1 = osmo-trx-ms-ipc%s  (DL<-udp %s:%s, UL->%s, L1CTL /tmp/osmocom_l2)\n' \
            "${C_DIM:-}" "${C_Z:-}" "$CALYPSO_TRX_IQ_HOST" "$CALYPSO_TRX_IQ_RX_PORT" "$CALYPSO_TRX_IQ_TX_PORT"
        ( sleep 6; "$_MSIPC" >"${LOG_DIR:-/tmp/osmo-nitb/logs}/osmo-trx-ms-ipc.log" 2>&1 ) &
    else
        printf '  osmo-trx-ms-ipc PAS COMPILE (%s) — build requis\n' "$_MSIPC"
    fi
fi


# --- 5. exports supplémentaires pour le profil hybrid -------------------------
if [ "$MODE" = "faketrx-qemu" ] || [ "$CALYPSO_PROFILE" = "hybrid" ]; then
    export QEMU_ATTACH_TRX="${QEMU_ATTACH_TRX:-0}"
    export NO_LOCAL_BTS="${NO_LOCAL_BTS:-0}"
    export NO_LOCAL_TRX="${NO_LOCAL_TRX:-0}"
    export TRX_BASE_PORT="${TRX_BASE_PORT:-6700}"
    export TRX_BIND="${TRX_BIND:-127.0.0.1}"
    export BTS1_UNIT_ID=6002
    export BTS1_ARFCN=516
    export BTS0_ARFCN=514
fi
# --- 6. résumé ----------------------------------------------------------------
banner
printf '  %sprofil%s     %s (%s)\n' "$C_DIM" "$C_Z" "$CALYPSO_PROFILE" "$MODE"
printf '  %senviron.%s   %s\n' "$C_DIM" "$C_Z" \
    "$(case "$RUNTIME_ENV" in docker) echo "conteneur docker" ;; vm) echo "machine virtuelle" ;; *) echo "machine physique" ;; esac)"
printf '  %srun.sh%s     %s\n' "$C_DIM" "$C_Z" "$RUN_SH"
printf '  %sMS#1%s       %s  IMSI 001010001000001  ARFCN 514  VTY 4247\n' "$C_DIM" "$C_Z" "$MS1_CFG"
printf '  %sMS#2%s       %s  IMSI 001010001000002  ARFCN 516  VTY 4248\n' "$C_DIM" "$C_Z" "$MS2_CFG"
printf '  %sjournaux%s   %s\n' "$C_DIM" "$C_Z" "$LOG_DIR"
printf '  %schiffrement%s %s\n' "$C_DIM" "$C_Z" "$ENCRYPTION"
printf '\n'
# --- 7. actions déléguées à run.sh --------------------------------------------
RUN_ARGS=()
[ "$DRY" -eq 1 ]     && RUN_ARGS+=(--dry-run)
[ "$FORCE" -eq 1 ]   && RUN_ARGS+=(--force)
[ "$VERBOSE" -eq 1 ] && RUN_ARGS+=(--verbose)
RUN_ARGS+=(--profile "$CALYPSO_PROFILE")
# [2026-08-08] --restart etait ajoute DIRECTEMENT sur la ligne exec, hors de
# RUN_ARGS. Consequence : `--dry-run` affichait une commande SANS --restart puis
# le vrai lancement en ajoutait un. Une simulation qui ne decrit pas ce qui va
# se passer est pire qu'absente. Il entre donc dans RUN_ARGS, ou il est visible.
# CALYPSO_NO_RESTART=1 pour demarrer sans reinitialiser (l'ancien comportement
# n'etait pas atteignable du tout).
[ "${CALYPSO_NO_RESTART:-0}" = "1" ] || RUN_ARGS+=(--restart)
case "$ACTION" in
    list)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --list "${RUN_ARGS[@]}"
        ;;
    stop)
        say_begin "Arrêt de la pile via run.sh"
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE"
        say_end " OK " "$C_OK" "Arrêt de la pile via run.sh"
        exit 0
        ;;
    status)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --status --profile "$CALYPSO_PROFILE"
        ;;
    checkpaths)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --check-paths
        ;;
esac
# --- 7ter. Identité de nœud (--node) -------------------------------------------
# AVANT le WAN et avant run.sh : les point codes sont lus par osmo-stp, osmo-msc
# et osmo-bsc à leur démarrage. Les changer après ne servirait à rien.
if [ -n "$NODE_ID" ]; then
    if ! [[ "$NODE_ID" =~ ^[1-9]$ ]]; then
        say_end " KO " "$C_KO" "--node" "un chiffre de 1 à 9"; exit 2
    fi
    SETID="$HERE/network/set-node-id.sh"
    if [ ! -r "$SETID" ]; then
        say_end " KO " "$C_KO" "--node" "network/set-node-id.sh absent"; exit 1
    fi
    say_begin "Identité SS7 du nœud $NODE_ID"
    setid_args=(--node "$NODE_ID" --op "$NODE_OP" --mode "$NODE_MODE")
    [ -n "$HUB_IP" ] && setid_args+=(--hub-ip "$HUB_IP")
    if [ "$DRY" -eq 1 ]; then
        say_end " -- " "$C_DIM" "Identité SS7 du nœud $NODE_ID" "dry-run"
        bash "$SETID" "${setid_args[@]}" --dry-run 2>&1 | sed 's/^/  /'
    elif bash "$SETID" "${setid_args[@]}" > "${LOG_DIR:-/tmp}/set-node-id.log" 2>&1; then
        say_end " OK " "$C_OK" "Identité SS7" "nœud $NODE_ID · PC 1.${NODE_ID}${NODE_OP}.x · mode $NODE_MODE"
    else
        say_end " KO " "$C_KO" "Identité SS7" "voir ${LOG_DIR:-/tmp}/set-node-id.log"
        exit 1
    fi
    # Le numéro de nœud vaut aussi pour la voix et les SMS : c'est le même nœud.
    WAN_NODE_ID="$NODE_ID"
fi

# --- 7bis. WAN à N noeuds ------------------------------------------------------
# ICI et pas après : ce processus va devenir run.sh (exec), il n'y a pas d'après.
# Asterisk n'est pas encore lancé — setup-wan-mesh.sh le voit, écrit la conf et
# ne redémarre rien ; run.sh démarrera Asterisk avec le WAN déjà en place.
#
# Sûr vis-à-vis des gabarits : en natif rien ne réinstalle /etc/asterisk au
# démarrage (install_configs_native n'a aucun appelant, run_modules/08-gabarits.sh
# n'existe pas), donc le bloc WAN écrit ici survit à run.sh. Si un module de
# gabarits revient un jour, il faudra rejouer le WAN APRÈS lui.
if [ -r "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" ] && [ "$WAN_MESH" -eq 0 ]; then
    # Table figée dans l'image (ISO construite avec --wan) : WAN_AUTO=1 dit
    # « ce système EST un noeud », on n'oblige pas à retaper l'option.
    if grep -q '^WAN_AUTO=1' "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null; then
        WAN_MESH=1
        printf '  %sWAN%s        table figée dans %s (WAN_AUTO=1)\n' \
            "$C_DIM" "$C_Z" "${WAN_CONF_FILE:-/etc/osmo-wan.conf}"
    fi
fi

if [ "$WAN_MESH" -eq 1 ] && [ "$ACTION" = "start" ]; then
    WAN_LIB="$HERE/network/wan-nodes.sh"
    WAN_MESH_SH="$HERE/network/setup-wan-mesh.sh"
    if [ ! -r "$WAN_LIB" ] || [ ! -r "$WAN_MESH_SH" ]; then
        say_end " KO " "$C_KO" "WAN" "network/wan-nodes.sh ou setup-wan-mesh.sh absent"
        exit 1
    fi
    # shellcheck source=network/wan-nodes.sh
    . "$WAN_LIB"
    # --virtualbox : segment host-only + VM + table, avant tout le reste.
    if [ "$VBOX_INTERCO" -eq 1 ] && [ -z "${WAN_NODES:-}" ]; then
        VB="$HERE/network/setup-vbox-interco.sh"
        [ -r "$VB" ] || { say_end " KO " "$C_KO" "WAN" "network/setup-vbox-interco.sh absent"; exit 1; }
        vb_args=(--host-node "$VBOX_HOST_NODE" --conf "${WAN_CONF_FILE:-/etc/osmo-wan.conf}")
        [ -n "$VBOX_NODES" ] && vb_args+=(--nodes "$VBOX_NODES")
        bash "$VB" "${vb_args[@]}" || exit 1
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" || exit 1
        WAN_NODES="$(wan_nodes_spec)"
        WAN_NODE_ID="$VBOX_HOST_NODE"
    fi

    if [ -n "${WAN_NODES:-}" ]; then
        wan_nodes_parse "$WAN_NODES" || exit 1
        [ "${WAN_NODE_ID:-0}" != "0" ] || wan_nodes_detect_self || {
            printf '  %sWAN%s : aucune IP locale dans la table — passez --wan-id N\n' "$C_KO" "$C_Z"
            exit 1; }
    else
        wan_nodes_load "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" 2>/dev/null || true
        # Une ISO diffusée sur N machines porte la MÊME table : chaque machine
        # se reconnaît à son IP plutôt que d'exiger une image par noeud.
        wan_nodes_detect_self 2>/dev/null || true
        if [ "${WAN_NODE_COUNT:-0}" -lt 1 ] || [ "${WAN_NODE_ID:-0}" = "0" ]; then
            wan_nodes_prompt || exit 1
        fi
    fi
    wan_nodes_validate || exit 1
    printf '\n'
    wan_nodes_summary
    printf '\n'
    if [ "$DRY" -eq 1 ]; then
        printf '  [dry-run] %s --native --id %s\n' "$WAN_MESH_SH" "$WAN_NODE_ID"
    else
        say_begin "WAN — application de la table"
        # --native / --docker : même distinction que pour les point codes.
        if WAN_AUTO=1 bash "$WAN_MESH_SH" "--$NODE_MODE" --id "$WAN_NODE_ID" \
                --nodes "$(wan_nodes_spec)" --ops 1 \
                --config "${WAN_CONF_FILE:-/etc/osmo-wan.conf}" > "${LOG_DIR:-/tmp}/wan-mesh.log" 2>&1; then
            say_end " OK " "$C_OK" "WAN — noeud $WAN_NODE_ID, indicatif $(wan_local_ind)"
        else
            say_end " KO " "$C_KO" "WAN" "voir ${LOG_DIR:-/tmp}/wan-mesh.log"
        fi
    fi
fi

# --- 8. lancement : exec run.sh -----------------------------------------------
say_begin "Transmission à run.sh"
if [ $DRY -eq 1 ]; then
    say_end " -- " "$C_DIM" "Transmission à run.sh" "dry-run"
    printf '  commande : CALYPSO_PROFILE=%s bash %s %s\n' \
        "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
    exit 0
fi
say_end " OK " "$C_OK" "Transmission à run.sh" "profil=$CALYPSO_PROFILE"
# Hand-off total : ce processus devient run.sh
exec bash "$RUN_SH" "${RUN_ARGS[@]}"
