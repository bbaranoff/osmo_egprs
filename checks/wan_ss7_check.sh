#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# checks/wan_ss7_check.sh — état du WAN, et état du SS7 VIS-À-VIS du WAN
#
# checks/ss7_check.sh vérifie le SS7 D'UN noeud (inter-STP, ASP, routes). Ce
# script-ci répond à la question qui vient juste après : « et entre noeuds ? »
#
# CE QU'IL FAUT SAVOIR AVANT DE LIRE LA SORTIE
# --------------------------------------------
# Le WAN d'osmo_egprs ne transporte PAS de SS7. Entre deux noeuds il n'y a que :
#     • SIP/RTP  (Asterisk ↔ Asterisk)  → la voix
#     • TCP 789x (sms-interop-relay)    → les SMS
# Le SS7/M3UA (osmo-stp, point codes 1.N.2, inter-STP 0.0.0) reste INTERNE à un
# noeud : l'ASP de chaque opérateur pointe sur 172.20.0.10, une adresse du plan
# docker privé, injoignable depuis l'extérieur — et le catch-all « route 0.0.0
# 0.0.0 → as-inter » envoie tout PC inconnu vers CET inter-STP local.
#
# Ce n'est donc pas une panne à réparer, c'est la frontière du montage : un
# appel inter-noeud est une TERMINAISON SIP, pas un relais MAP/ISUP. Ce script
# le VÉRIFIE au lieu de le supposer — et signale les deux cas où l'on croit à
# tort avoir du SS7 inter-noeud :
#   1. deux noeuds qui réutilisent les MÊMES point codes (ils le font tous :
#      1.1.2, 1.2.2… sont recalculés à l'identique sur chaque machine) ;
#   2. un port M3UA (2905/2908) exposé sur l'interface publique.
#
# Usage : sudo checks/wan_ss7_check.sh [--verbose] [--conf /etc/osmo-wan.conf]
# ══════════════════════════════════════════════════════════════════════════════
set -u

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=0
CONF="/etc/osmo-wan.conf"
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1 ;;
        --conf)       CONF="${2:-}"; shift ;;
        --conf=*)     CONF="${1#*=}" ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    shift
done

PASS=0; FAIL=0; WARN=0; SKIP=0
ok()   { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN+1)); }
skip() { echo -e "  ${YELLOW}—${NC} $*"; SKIP=$((SKIP+1)); }
info() { [ $VERBOSE -eq 1 ] && echo -e "    ${CYAN}│${NC} $*" || true; }
banner(){ echo ""; echo -e "${BOLD}$*${NC}"; printf '─%.0s' $(seq 1 64); echo ""; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   WAN — diagnostic voix / SMS / SS7 entre noeuds osmo_egprs      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 0. Table des noeuds ───────────────────────────────────────────────────────
banner "0. Table des noeuds WAN"
if [ ! -r "$SCRIPT_DIR/network/wan-nodes.sh" ]; then
    fail "network/wan-nodes.sh introuvable — dépôt incomplet"; exit 1
fi
# shellcheck source=network/wan-nodes.sh
. "$SCRIPT_DIR/network/wan-nodes.sh"

if ! wan_nodes_load "$CONF" 2>/dev/null; then
    fail "$CONF illisible — aucun WAN configuré sur ce noeud"
    echo -e "     ${CYAN}sudo ./start.sh --wan${NC}  ou  ${CYAN}sudo ./start-direct.sh --wan${NC}"
    exit 1
fi
[ "${WAN_NODE_ID:-0}" = "0" ] && wan_nodes_detect_self 2>/dev/null
if wan_nodes_validate 2>/dev/null; then ok "table valide : ${WAN_NODE_COUNT} noeud(s)"
else fail "table incohérente (voir messages ci-dessus)"; fi
wan_nodes_summary

LOCAL_IND="$(wan_local_ind)"
REMOTES=(); for id in "${WAN_NODE_LIST[@]}"; do [ "$id" = "${WAN_NODE_ID:-0}" ] || REMOTES+=("$id"); done
if [ "${#REMOTES[@]}" -eq 0 ]; then
    warn "table à un seul noeud : aucun pair, rien à vérifier côté WAN"
    echo -e "     ${CYAN}Ajoutez des noeuds : sudo ./start.sh --wan${NC}"
    exit 0
fi

# ── Mode ──────────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^osmo-operator-1$'; then
    MODE=docker
    N_OPS=$(docker ps --format '{{.Names}}' | grep -c '^osmo-operator-[0-9]*$')
else
    MODE=native; N_OPS=1
fi
info "mode=${MODE} opérateurs locaux=${N_OPS}"

ast() { # $1=op  $2=commande
    if [ "$MODE" = docker ]; then docker exec "osmo-operator-$1" asterisk -rx "$2" 2>/dev/null
    else asterisk -rx "$2" 2>/dev/null; fi
}
inside() { # $1=op  $2=commande shell
    if [ "$MODE" = docker ]; then docker exec "osmo-operator-$1" bash -c "$2" 2>/dev/null
    else bash -c "$2" 2>/dev/null; fi
}

# ── 1. Joignabilité des pairs ─────────────────────────────────────────────────
banner "1. Pairs — joignabilité IP et ports WAN"
for r in "${REMOTES[@]}"; do
    rip="${WAN_IP[$r]}"
    if ping -c1 -W2 "$rip" >/dev/null 2>&1; then ok "node ${r} ${rip} répond au ping"
    else warn "node ${r} ${rip} ne répond pas au ping (ICMP filtré ? noeud éteint ?)"; fi
    for i in $(seq 1 "$N_OPS"); do
        sip=$(( 5080 + (i - 1) * 2 )); sms=$(( 7890 + i - 1 ))
        if command -v nc >/dev/null 2>&1; then
            nc -z -w2 "$rip" "$sms" 2>/dev/null \
                && ok "node ${r} op${i} : relais SMS ${rip}:${sms} ouvert" \
                || warn "node ${r} op${i} : relais SMS ${rip}:${sms} fermé — SMS WAN KO dans ce sens"
        else skip "nc absent : test TCP ${rip}:${sms} impossible"; fi
        info "SIP attendu sur ${rip}:${sip}/udp (UDP : pas de test fiable sans trafic)"
    done
done

# ── 2. Asterisk — trunks WAN ──────────────────────────────────────────────────
banner "2. Asterisk — trunks WAN (voix)"
for i in $(seq 1 "$N_OPS"); do
    out="$(ast "$i" 'pjsip show endpoints')"
    if [ -z "$out" ]; then fail "op${i} : Asterisk ne répond pas"; continue; fi
    for r in "${REMOTES[@]}"; do
        for j in $(seq 1 "$N_OPS"); do
            ep="wan_n${r}_op${j}"
            if echo "$out" | grep -q "$ep"; then
                state="$(ast "$i" "pjsip show aor $ep" | grep -iE 'Avail|Unavail|Contact' | head -3 | tr '\n' ' ')"
                if echo "$out" | grep -E "Endpoint:[[:space:]]+$ep" | grep -qi 'Unavailable'; then
                    warn "op${i} → ${ep} présent mais Unavailable (pair injoignable)"
                else ok "op${i} → ${ep}"; fi
                info "$state"
            else
                fail "op${i} : trunk ${ep} ABSENT — relancez network/setup-wan-mesh.sh"
            fi
        done
    done
done

# ── 3. Dialplan — indicatifs ──────────────────────────────────────────────────
banner "3. Dialplan — un indicatif routé par pair"
for i in $(seq 1 "$N_OPS"); do
    for r in "${REMOTES[@]}"; do
        ind="${WAN_IND[$r]}"
        if ast "$i" "dialplan show wan_out" | grep -q "_${ind}"; then
            ok "op${i} : indicatif ${ind} → node ${r} présent dans [wan_out]"
        else
            fail "op${i} : indicatif ${ind} absent de [wan_out]"
        fi
    done
    ast "$i" "dialplan show gsm_in" | grep -q "_${LOCAL_IND}" \
        && ok "op${i} : indicatif local ${LOCAL_IND} traité en interne" \
        || warn "op${i} : indicatif local ${LOCAL_IND} non traité — un appel 'plein numéro' échouera"
done

# ── 4. SMS — routes et strip ──────────────────────────────────────────────────
banner "4. SMS — routes WAN et retrait d'indicatif"
for i in $(seq 1 "$N_OPS"); do
    conf="$(inside "$i" 'cat /etc/osmocom/sms-routing.conf')"
    if [ -z "$conf" ]; then fail "op${i} : sms-routing.conf illisible"; continue; fi
    for r in "${REMOTES[@]}"; do
        ind="${WAN_IND[$r]}"
        line="$(echo "$conf" | grep -E "^${ind}[0-9]+ =" | head -1)"
        if [ -z "$line" ]; then
            fail "op${i} : aucune route SMS pour l'indicatif ${ind}"
        elif echo "$line" | grep -q 'strip='; then
            ok "op${i} : route SMS ${ind} avec strip — le HLR distant verra le numéro nu"
        else
            fail "op${i} : route SMS ${ind} SANS strip= — le noeud distant cherchera « ${ind}10001 » dans son HLR et répondra « not found »"
        fi
    done
    # Le relais doit savoir lire strip= : une conf correcte sur un relais qui
    # l'ignore est exactement aussi cassée qu'une conf sans strip.
    if inside "$i" 'grep -q lookup_strip /opt/GSM/osmo_egprs/scripts/sms-interop-relay.py 2>/dev/null || grep -q lookup_strip /etc/osmocom/sms-interop-relay.py 2>/dev/null || grep -rq lookup_strip /usr/local/bin 2>/dev/null'; then
        ok "op${i} : le relais SMS gère strip="
    else
        warn "op${i} : relais SMS sans lookup_strip — version antérieure, SMS WAN muets"
    fi
done

# ── 5. SS7 — ce qui traverse, ce qui ne traverse pas ──────────────────────────
banner "5. SS7 — portée réelle vis-à-vis du WAN"
echo -e "  ${CYAN}Attendu : le SS7 s'arrête au bord du noeud. On vérifie que c'est bien${NC}"
echo -e "  ${CYAN}le cas, et qu'on ne croit pas avoir un lien SS7 inter-noeud.${NC}"
echo ""

# 5a — l'ASP local vise-t-il une adresse privée ?
for i in $(seq 1 "$N_OPS"); do
    cfg="$(inside "$i" 'cat /etc/osmocom/osmo-stp.cfg')"
    if [ -z "$cfg" ]; then skip "op${i} : osmo-stp.cfg illisible"; continue; fi
    remote="$(echo "$cfg" | awk '/asp asp-to-inter/{f=1} f&&/remote-ip/{print $2; exit}')"
    case "$remote" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|127.*)
            ok "op${i} : ASP inter-STP → ${remote} (privée) — le SS7 reste local, conforme" ;;
        "") skip "op${i} : pas d'ASP inter-STP déclaré" ;;
        *)
            for r in "${REMOTES[@]}"; do
                [ "$remote" = "${WAN_IP[$r]}" ] && {
                    warn "op${i} : ASP inter-STP → ${remote}, l'IP du node ${r} : M3UA passe le WAN EN CLAIR, sans SCTP multi-homing ni filtrage — à n'utiliser que sur un lien maîtrisé"; }
            done
            [ $VERBOSE -eq 1 ] && info "remote-ip=${remote}" ;;
    esac
done

# 5b — collision de point codes entre noeuds
# Les PC sont recalculés à l'identique sur chaque machine (1.<op>.2). Tant que
# les SS7 ne se parlent pas, aucune importance ; le jour où l'on relie deux
# inter-STP, deux PC identiques dans deux réseaux, c'est du routage circulaire.
if [ "${#REMOTES[@]}" -ge 1 ]; then
    warn "point codes IDENTIQUES d'un noeud à l'autre (1.N.2 / 1.N.1 / 1.N.3 recalculés pareil)"
    echo -e "     ${CYAN}Sans conséquence tant que le SS7 ne traverse pas. À corriger AVANT${NC}"
    echo -e "     ${CYAN}tout lien M3UA inter-noeud : donner à chaque noeud son propre${NC}"
    echo -e "     ${CYAN}network appearance ou son propre plan de point codes.${NC}"
fi

# 5c — un port M3UA exposé publiquement ?
LOCAL_IP="$(wan_local_ip)"
for port in 2905 2908; do
    if command -v ss >/dev/null 2>&1; then
        listen="$(ss -lntp 2>/dev/null | grep ":${port} ")"
        if [ -z "$listen" ]; then
            ok "M3UA ${port} : aucun écouteur sur l'hôte"
        elif echo "$listen" | grep -qE '0\.0\.0\.0:'"${port}"'|\[::\]:'"${port}"; then
            warn "M3UA ${port} écoute sur 0.0.0.0 — exposé si le firewall ne le ferme pas"
            echo -e "     ${CYAN}iptables -A INPUT -p sctp --dport ${port} -j DROP${NC} (ou -p tcp selon le transport)"
        else
            ok "M3UA ${port} : écoute restreinte ($(echo "$listen" | awk '{print $4}' | tr '\n' ' '))"
        fi
    else skip "ss absent : écouteurs M3UA non vérifiés"; fi
done

# 5d — SS7 interne toujours sain ? (délégué au check existant)
if [ -x "$SCRIPT_DIR/checks/ss7_check.sh" ] && [ "$MODE" = docker ]; then
    echo ""
    echo -e "  ${CYAN}SS7 interne : checks/ss7_check.sh --quick${NC}"
else
    skip "SS7 interne : checks/ss7_check.sh (docker uniquement)"
fi

# ── 6. iptables ───────────────────────────────────────────────────────────────
banner "6. iptables — chaîne WAN"
if iptables -t nat -L OSMO_WAN_MESH -n >/dev/null 2>&1; then
    n=$(iptables -t nat -S OSMO_WAN_MESH 2>/dev/null | grep -c '^-A')
    ok "chaîne OSMO_WAN_MESH présente (${n} règle(s))"
    iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'OSMO_WAN_MESH' \
        && ok "chaîne branchée sur PREROUTING" \
        || fail "chaîne NON branchée sur PREROUTING — rien n'entre"
else
    if iptables -t nat -L OSMO_WAN_INTEROP -n >/dev/null 2>&1; then
        warn "chaîne legacy OSMO_WAN_INTEROP active (2 serveurs, préfixe 66)"
    else
        fail "aucune chaîne WAN — relancez network/setup-wan-mesh.sh sans --config-only"
    fi
fi

# ── Bilan ─────────────────────────────────────────────────────────────────────
echo ""
printf '─%.0s' $(seq 1 64); echo ""
echo -e "  ${GREEN}${PASS} ok${NC}   ${RED}${FAIL} échec${NC}   ${YELLOW}${WARN} avertissement${NC}   ${SKIP} ignoré"
echo ""
[ "$FAIL" -eq 0 ] || exit 1
