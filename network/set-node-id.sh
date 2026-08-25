#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# network/set-node-id.sh — donne à CETTE machine son identité de nœud SS7
#
# Une seule ISO pour tous les nœuds : le numéro se choisit au démarrage, pas à
# la construction. Ce script réécrit ce qui, dans les configs Osmocom, désigne
# le nœud — c'est-à-dire ses POINT CODES et ses routing contexts.
#
#   plan local (une machine)   1.<op>.<role>          op×100 + {10,20,30,50}
#   plan WAN   (N machines)    1.<nœud><op>.<role>    nœud×1000 + op×100 + …
#
# Pourquoi ça ne peut pas rester le plan local : la formule se recalcule à
# l'identique sur chaque machine. Trois nœuds attachés au même inter-STP y
# présenteraient trois fois 1.11.2. Un point code est une ADRESSE — deux
# équipements qui partagent la leur, ce n'est pas un doublon de nom, c'est du
# routage faux, et le hub n'a aucun moyen de s'en apercevoir.
#
# Trois fichiers portent cette identité, et ils doivent rester d'accord :
#   osmo-stp.cfg   son propre PC, son routing-key, son ASP vers le hub
#   osmo-msc.cfg   son PC, son routing-key, et le PC du BSC qu'il appelle
#   osmo-bsc.cfg   son PC, son routing-key, et le PC du MSC qu'il appelle
# En rater un donne un cœur qui démarre et des appels qui n'aboutissent pas.
#
# Idempotent : il lit l'état courant et le remplace. Passer --node 2 après
# --node 1 fonctionne, il n'y a pas d'état à nettoyer entre les deux.
#
# Usage :
#   sudo network/set-node-id.sh --node 3 [--op 1] [--hub-ip 192.168.56.1]
#   sudo network/set-node-id.sh --show          état actuel, sans rien modifier
#   sudo network/set-node-id.sh --node 3 --local   plan local (annule le plan WAN)
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

NODE=""
OP=1
HUB_IP=""
MODE=""            # docker | native — l'adressage n'est pas le même
CONF_DIR="${CONF_DIR:-/etc/osmocom}"
SHOW=0
LOCAL_PLAN=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --node)     NODE="${2:-}"; shift ;;
        --node=*)   NODE="${1#*=}" ;;
        --op)       OP="${2:-1}"; shift ;;
        --op=*)     OP="${1#*=}" ;;
        --hub-ip)   HUB_IP="${2:-}"; shift ;;
        --hub-ip=*) HUB_IP="${1#*=}" ;;
        --conf-dir)   CONF_DIR="${2:-}"; shift ;;
        --conf-dir=*) CONF_DIR="${1#*=}" ;;
        --mode)     MODE="${2:-}"; shift ;;
        --mode=*)   MODE="${1#*=}" ;;
        --docker)   MODE="docker" ;;
        --native)   MODE="native" ;;
        --show)     SHOW=1 ;;
        --local)    LOCAL_PLAN=1 ;;
        --dry-run)  DRY=1 ;;
        -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

STP="$CONF_DIR/osmo-stp.cfg"
MSC="$CONF_DIR/osmo-msc.cfg"
BSC="$CONF_DIR/osmo-bsc.cfg"

# ── Lecture de l'identité en place ──────────────────────────────────────────
# Le premier point-code d'un fichier est CELUI DU DÉMON ; ceux qui suivent, à
# l'intérieur d'un bloc « sccp-address », désignent ses pairs. C'est cette
# distinction qui structure toute la réécriture.
own_pc() { awk '/^cs7 instance/{c=1} c && /^ *point-code /{print $2; exit}' "$1" 2>/dev/null; }

show_state() {
    local f n
    printf '  %-16s %-10s %-12s %s\n' FICHIER "POINT CODE" "ROUTING-KEY" "ASP INTER-STP"
    for f in "$STP" "$MSC" "$BSC"; do
        [ -r "$f" ] || { printf '  %-16s %s\n' "$(basename "$f")" "absent"; continue; }
        local pc rk asp
        pc="$(own_pc "$f")"
        rk="$(awk '/^ *routing-key /{print $2; exit}' "$f")"
        asp="$(awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}' "$f")"
        printf '  %-16s %-10s %-12s %s\n' "$(basename "$f")" "${pc:-–}" "${rk:-–}" "${asp:-–}"
    done
}

if [ "$SHOW" = "1" ]; then
    [ -n "$MODE" ] || { [ -f /.dockerenv ] && MODE=docker || MODE=native; }
    echo -e "${BOLD}Identité SS7 de cette machine${NC}  (mode ${CYAN}${MODE}${NC})"
    show_state
    exit 0
fi

[[ "$NODE" =~ ^[1-9]$ ]] || { echo -e "${RED}--node : un chiffre de 1 à 9${NC}" >&2; exit 2; }
[[ "$OP"   =~ ^[1-9]$ ]] || { echo -e "${RED}--op : un chiffre de 1 à 9${NC}" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Root requis (écriture dans ${CONF_DIR}).${NC}" >&2; exit 1; }

for f in "$STP" "$MSC" "$BSC"; do
    [ -w "$f" ] || { echo -e "${RED}$f introuvable ou non modifiable${NC}" >&2; exit 1; }
done

# ── Le nouveau plan ─────────────────────────────────────────────────────────
if [ "$LOCAL_PLAN" = "1" ]; then
    MID="$OP"                       # 1.<op>.<role> — plan d'une machine isolée
    RBASE=$(( OP * 100 ))
else
    MID="${NODE}${OP}"              # 1.<nœud><op>.<role> — plan WAN
    RBASE=$(( NODE * 1000 + OP * 100 ))
fi
PC_MSC="1.${MID}.1"; PC_STP="1.${MID}.2"; PC_BSC="1.${MID}.3"
RCTX_MSC=$(( RBASE + 10 )); RCTX_STP=$(( RBASE + 20 ))
RCTX_BSC=$(( RBASE + 30 )); RCTX_INTER=$(( RBASE + 50 ))

# ── DOCKER OU VM : deux plans d'adressage, et le défaut de l'un est faux dans
# l'autre ──────────────────────────────────────────────────────────────────
#   docker : le hub est le conteneur osmo-inter-stp, 172.20.0.10, sur le réseau
#            gsm-inter. Le nœud y a déjà son IP quand osmo-stp démarre.
#   VM/ISO : le hub est une machine à part, 192.168.56.1 sur le segment
#            host-only. L'adresse du nœud vient du DHCP et n'est pas forcément
#            montée au lancement.
# Se tromper de défaut donne un ASP qui ne s'attache jamais, et le journal ne
# dit que « connection refused » — sans indiquer que l'adresse visée n'existe
# nulle part sur ce réseau-là.
if [ -z "$MODE" ]; then
    if [ -f /.dockerenv ]; then MODE="docker"; else MODE="native"; fi
fi

if [ -z "$HUB_IP" ]; then
    if [ -r /etc/osmo-role ]; then
        HUB_IP="$(awk -F= '/^OSMO_HUB_IP=/{print $2}' /etc/osmo-role)"
    fi
fi
if [ -z "$HUB_IP" ]; then
    case "$MODE" in
        docker) HUB_IP="${INTER_STP_IP:-172.20.0.10}" ;;
        *)      HUB_IP="192.168.56.1" ;;
    esac
fi

# En docker on NE touche PAS au local-ip : le conteneur a son adresse avant que
# le démon ne démarre, et une source explicite évite que SCTP annonce plusieurs
# adresses (multi-homing) à un pair qui n'en attend qu'une.
# En natif c'est l'inverse : l'adresse vient du DHCP, s'y lier trop tôt échoue.
if [ "$MODE" = "docker" ]; then SET_LOCAL_IP=0; else SET_LOCAL_IP=1; fi

echo -e "${BOLD}Nœud ${NODE} — opérateur ${OP}${NC}   (mode ${CYAN}${MODE}${NC})"
echo -e "  STP ${CYAN}${PC_STP}${NC}   MSC ${CYAN}${PC_MSC}${NC}   BSC ${CYAN}${PC_BSC}${NC}"
echo -e "  routing-key : stp ${RCTX_STP} · msc ${RCTX_MSC} · bsc ${RCTX_BSC} · inter ${RCTX_INTER}"
[ "$LOCAL_PLAN" = "1" ] \
    && echo -e "  ${YELLOW}plan LOCAL : cette machine ne peut pas partager un hub avec une autre${NC}" \
    || echo -e "  ASP inter-STP → ${CYAN}${HUB_IP}${NC}$([ "$SET_LOCAL_IP" = "1" ] && echo "  (source 0.0.0.0)" || echo "  (source inchangée)")"
echo ""

# ── Réécriture ──────────────────────────────────────────────────────────────
# `own` = le point code du démon (au niveau cs7 instance).
# `peer` = celui qu'il déclare dans ses blocs sccp-address.
# La distinction se fait sur le bloc courant, pas sur le numéro de ligne : un
# fichier qui gagne une directive ne décale pas la réécriture.
rewrite() {  # $1=fichier  $2=own  $3=peer  $4=rctx  $5=1 si bloc asp inter-STP
    local f="$1" own="$2" peer="$3" rctx="$4" do_asp="$5"
    local tmp; tmp="$(mktemp)"
    awk -v own="$own" -v peer="$peer" -v rctx="$rctx" -v do_asp="$do_asp" -v hub="$HUB_IP" \
        -v set_local="$SET_LOCAL_IP" '
        /^cs7 instance/            { in_cs7=1 }
        /^ *sccp-address /         { sccp=1 }
        /^ *(as|asp|listen|route-table|network-indicator|xua) / { sccp=0 }
        /^!/                       { sccp=0 }
        /^ *asp asp-to-inter/      { in_asp=1; print; next }
        in_asp && /^ *(as|listen|route-table|!)/ { in_asp=0 }

        in_asp && do_asp && /^ *remote-ip /   { sub(/remote-ip .*/, "remote-ip " hub); print; next }
        # local-ip de l ASP : l adresse SOURCE de la SCTP vers le hub. Elle vaut
        # 127.0.0.1 dans l image (tout etait local) ; la laisser ainsi ferait
        # partir la connexion de la boucle locale vers une adresse de segment —
        # elle n aboutirait jamais, et le seul symptome serait un ASP DOWN.
        # 0.0.0.0 : le noyau choisit la source selon la route.
        in_asp && do_asp && set_local && /^ *local-ip / { sub(/local-ip.*/, "local-ip 0.0.0.0"); print; next }
        in_asp && do_asp && /^ *shutdown[ \t]*$/ { sub(/shutdown/, "no shutdown"); print; next }

        /^ *point-code / {
            if (sccp && peer != "") { sub(/point-code .*/, "point-code " peer) }
            else if (in_cs7)        { sub(/point-code .*/, "point-code " own) }
            print; next
        }
        /^ *routing-key / { sub(/routing-key .*/, "routing-key " rctx " " own); print; next }
        { print }
    ' "$f" > "$tmp"

    if [ "$DRY" = "1" ]; then
        echo "  [dry-run] $f"; diff -u "$f" "$tmp" | sed -n '4,30p' | sed 's/^/    /'; rm -f "$tmp"
    else
        # cat plutôt que mv : sur l'ISO comme dans un conteneur, ces fichiers
        # peuvent être des points de montage, et rename() y échoue.
        cat "$tmp" > "$f"; rm -f "$tmp"
        echo -e "  ${GREEN}✓${NC} $(basename "$f")"
    fi
}

rewrite "$STP" "$PC_STP" ""        "$RCTX_INTER" "$([ "$LOCAL_PLAN" = "1" ] && echo 0 || echo 1)"
rewrite "$MSC" "$PC_MSC" "$PC_BSC" "$RCTX_MSC"   0
rewrite "$BSC" "$PC_BSC" "$PC_MSC" "$RCTX_BSC"   0

if [ "$DRY" != "1" ]; then
    echo ""
    show_state
    echo ""
    echo -e "  ${YELLOW}Les démons déjà lancés gardent l'ancienne identité :${NC} relancez la pile."
fi
