#!/bin/bash
# =============================================================================
# network/set_ip_vm.sh - rend une VM capable de joindre les conteneurs docker
#
# Le probleme, en une ligne : l'ISO pose sur le NIC des adresses du plan docker
# (172.20.0.1/24, 172.20.0.11/24, 172.20.1.10/24) heritees du temps ou tout
# tournait sur une seule machine. Sur un banc ou les conteneurs vivent sur un
# HOTE a part, ces adresses mentent :
#
#   1. le /24 fait croire que 172.20.0.0/24 est sur le lien local. La VM l'ARP
#      donc sur le LAN au lieu de le router, et
#          ip route add 172.20.0.0/24 via <hote>
#      est refuse d'un "RTNETLINK answers: File exists".
#   2. 172.20.0.11 est l'adresse du PREMIER CONTENEUR operateur. La VM se
#      repond a elle-meme : la panne la plus deroutante du lot, puisque tout
#      "fonctionne" en local et que rien n'arrive jamais au conteneur.
#
# Ce script retire ce qui ment, garde ce qui sert, et pose la route. Tout est
# deduit a l'execution - interface, adresses presentes, reseaux - rien n'est
# ecrit en dur : la meme commande vaut sur les trois VM du banc.
#
# CE QU'IL NE FAIT PAS : casser une pile qui tourne. Une adresse sur laquelle un
# demon ecoute est signalee et CONSERVEE, sauf --force. Mieux vaut un routage
# incomplet qu'un osmo-stp qui ne redemarre plus.
#
# Usage :
#   sudo network/set_ip_vm.sh --via 192.168.1.101      l'hote qui porte docker
#   sudo network/set_ip_vm.sh                          --via demande, ou relu
#   sudo network/set_ip_vm.sh --status                 etat, sans rien changer
#   sudo network/set_ip_vm.sh --undo                   retire la route posee
#
#   --via ADRESSE      hote docker (routeur vers le backbone)
#   --docker-net CIDR  backbone des conteneurs (defaut 172.20.0.0/24)
#   --iface NOM        interface (defaut : celle de la route par defaut)
#   --keep ADRESSE     adresse a NE PAS retirer (repetable)
#   --force            retire meme les adresses sur lesquelles un demon ecoute
#   --persist          rejoue au boot (unite systemd)
#   --dry-run          montre, n'applique pas
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOCKER_NET="172.20.0.0/24"
VIA=""
IFACE=""
FORCE=0
DRY=0
PERSIST=0
ACTION="apply"
KEEP=()
STATE=/etc/osmo-docker-host          # memoire du --via, pour ne le taper qu'une fois

while [ $# -gt 0 ]; do
    case "$1" in
        --via)          VIA="${2:-}"; shift ;;
        --via=*)        VIA="${1#*=}" ;;
        --docker-net)   DOCKER_NET="${2:-}"; shift ;;
        --docker-net=*) DOCKER_NET="${1#*=}" ;;
        --iface)        IFACE="${2:-}"; shift ;;
        --iface=*)      IFACE="${1#*=}" ;;
        --keep)         KEEP+=("${2:-}"); shift ;;
        --keep=*)       KEEP+=("${1#*=}") ;;
        --force)        FORCE=1 ;;
        --persist)      PERSIST=1 ;;
        --dry-run)      DRY=1 ;;
        --status)       ACTION="status" ;;
        --undo)         ACTION="undo" ;;
        -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo -e "${RED}option inconnue : $1${NC}" >&2; exit 2 ;;
    esac
    shift
done

run() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }

# ── L'interface : celle qui porte la route par defaut ───────────────────────
[ -n "$IFACE" ] || IFACE="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')"
[ -n "$IFACE" ] || { echo -e "${RED}Aucune interface par defaut - precisez --iface${NC}" >&2; exit 1; }

LAN_IP="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | grep -vE '^172\.20\.' | head -1)"

# Le prefixe du plan docker, pour reconnaitre les adresses a retirer :
# 172.20.0.0/24 -> "172.20." (on ratisse le /16, car l'ISO pose aussi 172.20.1.x)
DOCKER_PREFIX="$(echo "$DOCKER_NET" | cut -d. -f1-2)."

echo -e "${CYAN}${BOLD}== Adressage VM vers les conteneurs docker ==${NC}"
echo -e "  interface : ${CYAN}${IFACE}${NC}   adresse LAN : ${CYAN}${LAN_IP:-?}${NC}"
echo -e "  backbone  : ${CYAN}${DOCKER_NET}${NC}"

# ── Ce qui traine ───────────────────────────────────────────────────────────
mapfile -t STALE_ADDRS < <(ip -4 -o addr show dev "$IFACE" 2>/dev/null \
    | awk '{print $4}' | grep "^${DOCKER_PREFIX}" || true)
mapfile -t STALE_ROUTES < <(ip -4 route show dev "$IFACE" 2>/dev/null \
    | awk '$1 ~ /^'"${DOCKER_PREFIX//./\\.}"'/ && /scope link/ {print $1}' || true)

# ── --status ────────────────────────────────────────────────────────────────
if [ "$ACTION" = "status" ]; then
    echo ""
    if [ "${#STALE_ADDRS[@]}" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} aucune adresse ${DOCKER_PREFIX}x sur ${IFACE}"
    else
        echo -e "  ${YELLOW}adresses du plan docker encore posees :${NC}"
        for a in "${STALE_ADDRS[@]}"; do echo "    $a"; done
    fi
    cur="$(ip -4 route show "$DOCKER_NET" 2>/dev/null | head -1)"
    if echo "$cur" | grep -q " via "; then
        echo -e "  ${GREEN}✓${NC} route : ${cur}"
    elif [ -n "$cur" ]; then
        echo -e "  ${RED}✗${NC} route CONNECTEE (pas de via) : ${cur}"
        echo -e "     tant qu'elle existe, les conteneurs sont injoignables."
    else
        echo -e "  ${YELLOW}–${NC} aucune route vers ${DOCKER_NET}"
    fi
    exit 0
fi

[ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] \
    || { echo -e "${RED}Root requis.${NC}" >&2; exit 1; }

# ── --undo ──────────────────────────────────────────────────────────────────
if [ "$ACTION" = "undo" ]; then
    run ip route del "$DOCKER_NET" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route retiree" \
        || echo -e "  ${YELLOW}–${NC} pas de route a retirer"
    rm -f /etc/systemd/system/osmo-docker-route.service 2>/dev/null && \
        systemctl disable osmo-docker-route.service >/dev/null 2>&1
    exit 0
fi

# ── L'hote docker ───────────────────────────────────────────────────────────
# Memorise : on ne le tape qu'une fois par machine. Sans terminal et sans
# memoire, on s'arrete plutot que d'inventer une passerelle.
[ -n "$VIA" ] || VIA="$(awk -F= '/^OSMO_DOCKER_HOST=/{print $2}' "$STATE" 2>/dev/null | tr -d ' \r')"
if [ -z "$VIA" ] && [ -t 0 ]; then
    def=""
    [ -n "$LAN_IP" ] && def="${LAN_IP%.*}.101"
    printf '  Adresse de l hote qui porte docker [%s] : ' "${def:-?}"
    read -r VIA || VIA=""
    [ -n "$VIA" ] || VIA="$def"
fi
if [ -z "$VIA" ]; then
    echo -e "  ${RED}✗ --via manquant : j'ignore par ou joindre ${DOCKER_NET}${NC}" >&2
    exit 2
fi
if ! [[ "$VIA" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo -e "  ${RED}✗ '${VIA}' n'est pas une IPv4${NC}" >&2; exit 2
fi
echo -e "  hote docker : ${CYAN}${VIA}${NC}"

# ── Ce script est pour les VM. Pas pour l'hote qui porte docker ─────────────
# Lance sur l'hote, il pose une route vers LUI-MEME et prend le pas sur la route
# connectee du bridge docker. Resultat immediat : "Destination Host Unreachable"
# vers ses propres conteneurs - alors qu'ils tournent tres bien.
#
# Deux signes le trahissent, et un seul suffit :
#   - --via est une adresse locale ;
#   - un bridge porte deja le reseau des conteneurs.
#
# Attention a ne pas confondre les deux facons de "porter" ce reseau :
#   un BRIDGE docker (br-xxxx, docker0)  -> c'est l'hote, on s'arrete ;
#   une carte ordinaire (enp0s3...)      -> ce sont justement les alias perimes
#                                           de l'ISO, et c'est notre travail.
# Un premier jet refusait les deux et bloquait donc sur la VM qu'il devait
# reparer.
_self=0
ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -qx "$VIA" && _self=1
_dev="$(ip -4 -o route show "$DOCKER_NET" 2>/dev/null | awk '/proto kernel/{print $3; exit}')"
_bridge=""
case "$_dev" in br-*|docker*|virbr*) _bridge="$_dev" ;; esac
if [ "$_self" = 1 ] || [ -n "$_bridge" ]; then
    echo ""
    echo -e "  ${RED}✗ Cette machine EST l'hote docker - rien a faire ici.${NC}" >&2
    [ "$_self" = 1 ] && echo -e "     ${VIA} est une de ses propres adresses." >&2
    [ -n "$_bridge" ] && echo -e "     ${DOCKER_NET} est deja porte par ${_bridge}." >&2
    echo -e "  ${YELLOW}Ce script se lance SUR LES VM${NC}, pour leur apprendre le chemin" >&2
    echo -e "  vers les conteneurs. Cote hote, c'est l'autre script :" >&2
    echo -e "     ${CYAN}sudo network/setup-docker-lan-route.sh --push \"<ip des VM>\"${NC}" >&2
    exit 2
fi
echo ""

# ── 1. Retirer ce qui ment ──────────────────────────────────────────────────
# Une adresse sur laquelle un demon ECOUTE n'est pas retiree : la supprimer
# ferait tomber le service qui s'y est lie, et le probleme deviendrait pire que
# celui qu'on corrige.
for a in ${STALE_ADDRS[@]+"${STALE_ADDRS[@]}"}; do
    ip_only="${a%%/*}"
    skip=0
    for k in ${KEEP[@]+"${KEEP[@]}"}; do [ "$k" = "$ip_only" ] && skip=1; done
    if [ "$skip" = 1 ]; then
        echo -e "  ${CYAN}–${NC} ${a} conservee (--keep)"; continue
    fi
    if [ "$FORCE" != 1 ] && ss -Hlnp 2>/dev/null | grep -q "[^0-9]${ip_only}:"; then
        echo -e "  ${YELLOW}⚠${NC} ${a} CONSERVEE : un demon y ecoute"
        echo -e "     (relancez la pile puis --force, ou --keep pour l'assumer)"
        continue
    fi
    run ip addr del "$a" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} ${a} retiree" \
        || echo -e "  ${YELLOW}–${NC} ${a} deja absente"
done

for r in ${STALE_ROUTES[@]+"${STALE_ROUTES[@]}"}; do
    run ip route del "$r" dev "$IFACE" 2>/dev/null \
        && echo -e "  ${GREEN}✓${NC} route connectee ${r} retiree"
done

# ── 2. Poser la route ───────────────────────────────────────────────────────
# 'replace' plutot que 'add' : idempotent, et il ne bute pas sur un reste.
if run ip route replace "$DOCKER_NET" via "$VIA" dev "$IFACE"; then
    echo -e "  ${GREEN}✓${NC} ${DOCKER_NET} via ${CYAN}${VIA}${NC}"
else
    echo -e "  ${RED}✗${NC} route refusee - une adresse du plan docker subsiste ?"
    echo -e "     ${CYAN}ip -4 addr show dev ${IFACE} | grep ${DOCKER_PREFIX}${NC}"
    exit 1
fi

[ "$DRY" = 1 ] || printf 'OSMO_DOCKER_HOST=%s\n' "$VIA" > "$STATE" 2>/dev/null || true

# ── 3. Au boot, si demande ──────────────────────────────────────────────────
# Un live sans persistance repart de l'ISO a chaque demarrage : sans unite, tout
# est a refaire. Elle rejoue simplement ce script, qui est idempotent.
if [ "$PERSIST" = 1 ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ "$DRY" = 1 ]; then
        echo "    [dry-run] unite osmo-docker-route.service"
    else
        cat > /etc/systemd/system/osmo-docker-route.service <<EOF
[Unit]
Description=osmo_egprs - route vers les conteneurs docker (${DOCKER_NET})
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${here}/set_ip_vm.sh --via ${VIA} --docker-net ${DOCKER_NET}
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable osmo-docker-route.service >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓${NC} rejoue au boot (osmo-docker-route.service)"
    fi
fi

# ── 4. Le controle qui compte ───────────────────────────────────────────────
echo ""
first="$(echo "$DOCKER_NET" | cut -d. -f1-3).11"
echo -e "  ${BOLD}Verifier :${NC} ${CYAN}ip route get ${first}${NC}   doit indiquer via ${VIA}"
if [ "$DRY" != 1 ]; then
    got="$(ip route get "$first" 2>/dev/null | head -1)"
    if echo "$got" | grep -q "via ${VIA}"; then
        echo -e "  ${GREEN}✓${NC} ${got}"
    else
        echo -e "  ${YELLOW}⚠${NC} ${got:-aucune reponse}"
    fi
fi
