#!/bin/bash
# =============================================================================
# network/wan-nodes.sh — la TABLE DES NOEUDS WAN, partagée par les 3 lanceurs
# =============================================================================
#
# Ce fichier ne définit que des fonctions et des variables : il est SOURCÉ par
#   start.sh          (hôte docker, N opérateurs par noeud)
#   start-direct.sh   (natif / ISO, 1 opérateur par noeud)
#   build-iso.sh      (fige la table dans l'ISO)
#   network/setup-wan-mesh.sh  (l'applique à Asterisk / iptables / SMS)
#
# ── MODÈLE ───────────────────────────────────────────────────────────────────
# Un WAN = N noeuds. Un noeud = (id, ip publique, indicatif).
#
# L'INDICATIF est le préfixe téléphonique du noeud, exactement comme un
# indicatif pays : depuis n'importe quel noeud, composer
#       <indicatif_cible><numéro>
# joint <numéro> sur le noeud qui porte cet indicatif. Le noeud émetteur
# retire l'indicatif avant de sortir sur le WAN ; le noeud d'arrivée reçoit
# donc le numéro nu, celui que son HLR et son dialplan connaissent déjà.
#
# WAN_NODE_ID dit QUI est le noeud local. C'est la seule chose qui distingue
# « ce numéro est chez moi » de « ce numéro part sur le WAN » : sans lui, un
# noeud se renvoie ses propres appels à l'infini.
#
# ── POURQUOI UNE TABLE ET PAS UN COUPLE local/remote ─────────────────────────
# network/setup-wan-interop.sh (l'existant) ne connaît QUE deux serveurs :
# LOCAL_IP et REMOTE_IP. Il réécrit à chaque appel le bloc « WAN INTEROP » de
# pjsip.conf/extensions.conf et remet à zéro sa chaîne iptables — le lancer en
# boucle sur trois pairs ne laisse donc que le DERNIER. D'où cette table : on
# génère UN bloc qui contient tous les pairs, en un seul passage.
# -----------------------------------------------------------------------------

# Table : WAN_IP[id] / WAN_IND[id], plus la liste ordonnée des ids.
declare -A WAN_IP  2>/dev/null || true
declare -A WAN_IND 2>/dev/null || true
WAN_NODE_LIST=()
: "${WAN_NODE_COUNT:=0}"
: "${WAN_NODE_ID:=0}"
: "${WAN_OPS:=1}"          # opérateurs (PLMN) portés par CE noeud
: "${WAN_CONF_FILE:=/etc/osmo-wan.conf}"

_wanc() { [ -t 1 ] && printf '\033[0;36m%s\033[0m' "$1" || printf '%s' "$1"; }
_wan_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
_wan_err()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; }

# ── Indicatifs par défaut ────────────────────────────────────────────────────
# 11/22/…/99 : un doublet par noeud, aucun n'est préfixe d'un autre (condition
# dure, cf. wan_nodes_validate) et il y en a exactement neuf — la borne des
# noeuds. Le doublet se lit aussi comme le numéro du noeud, ce qui rend un
# journal d'appel déchiffrable sans la table sous les yeux.
_WAN_DEFAULT_IND=(11 22 33 44 55 66 77 88 99)
wan_default_ind() {
    local i=$1
    if [ "$i" -ge 1 ] && [ "$i" -le "${#_WAN_DEFAULT_IND[@]}" ]; then
        echo "${_WAN_DEFAULT_IND[$((i-1))]}"
    else
        echo $(( 100 + i ))
    fi
}

# ── Sérialisation « id:ip:indicatif id:ip:indicatif … » ──────────────────────
wan_nodes_spec() {
    local id out=""
    for id in "${WAN_NODE_LIST[@]}"; do
        out="${out}${out:+ }${id}:${WAN_IP[$id]}:${WAN_IND[$id]}"
    done
    printf '%s' "$out"
}

wan_nodes_parse() {
    local spec="${1:-}" entry id rest ip ind
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()
    spec="${spec//,/ }"
    for entry in $spec; do
        [ -n "$entry" ] || continue
        case "$entry" in
            *:*:*) ;;
            *) _wan_err "entrée noeud invalide : '$entry' (attendu id:ip:indicatif)"; return 1 ;;
        esac
        id="${entry%%:*}"; rest="${entry#*:}"
        ip="${rest%%:*}";  ind="${rest#*:}"
        ind="${ind%%:*}"
        WAN_IP[$id]="$ip"; WAN_IND[$id]="$ind"
        WAN_NODE_LIST+=("$id")
    done
    WAN_NODE_COUNT=${#WAN_NODE_LIST[@]}
    [ "$WAN_NODE_COUNT" -gt 0 ] || { _wan_err "table de noeuds vide"; return 1; }
    return 0
}

# ── Validation ───────────────────────────────────────────────────────────────
# Refuse ce qui produirait un routage silencieusement faux, pas seulement ce
# qui est mal écrit.
wan_nodes_validate() {
    local id other rc=0
    [ "${#WAN_NODE_LIST[@]}" -ge 1 ] || { _wan_err "table de noeuds vide"; return 1; }
    for id in "${WAN_NODE_LIST[@]}"; do
        # 1..9 : un chiffre. C'est ce qui garde <indicatif><opérateur><MSISDN>
        # lisible et les patterns Asterisk sans ambiguïté de longueur.
        [[ "$id" =~ ^[1-9]$ ]] \
            || { _wan_err "numéro de noeud invalide : '$id' (1 à 9)"; rc=1; }
        [[ "${WAN_IP[$id]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { _wan_err "noeud $id : '${WAN_IP[$id]}' n'est pas une IPv4"; rc=1; }
        # ── L'INDICATIF NE DOIT PAS MORDRE SUR LE PLAN DE NUMÉROTATION LOCAL ──
        # Les MSISDN du dépôt valent op×10000 + ms (10001, 20001, …) : cinq
        # chiffres dont les deux premiers sont « <op>0 ». Un indicatif « 10 »
        # produirait donc « exten => _10. » dans [gsm_in], qui avalerait 10001
        # — l'abonné local deviendrait injoignable et l'appel partirait sur le
        # WAN. Un indicatif d'UN chiffre a le même défaut, en pire.
        # Les défauts 11/22/…/99 passent tous cette règle.
        if ! [[ "${WAN_IND[$id]}" =~ ^[0-9]{2,4}$ ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' — 2 à 4 chiffres (1 chiffre entrerait en conflit avec les MSISDN locaux)"; rc=1
        elif [[ "${WAN_IND[$id]}" =~ ^[1-9]0 ]]; then
            _wan_err "noeud $id : indicatif '${WAN_IND[$id]}' commence comme un MSISDN local (op×10000+ms → 10001, 20001…) — il capterait les appels locaux ; prenez ${WAN_IND[$id]:0:1}${WAN_IND[$id]:0:1} par exemple"; rc=1
        fi
    done
    # Indicatifs : uniques ET aucun préfixe d'un autre. Un indicatif 3 qui
    # préfixe un indicatif 33 rend les patterns Asterisk (_3. vs _33.) et le
    # longest-prefix du relais SMS dépendants de l'ordre — donc imprévisibles.
    for id in "${WAN_NODE_LIST[@]}"; do
        for other in "${WAN_NODE_LIST[@]}"; do
            [ "$id" = "$other" ] && continue
            if [ "${WAN_IND[$id]}" = "${WAN_IND[$other]}" ]; then
                _wan_err "noeuds $id et $other partagent l'indicatif ${WAN_IND[$id]}"; rc=1
            elif [ "${WAN_IND[$other]#${WAN_IND[$id]}}" != "${WAN_IND[$other]}" ]; then
                _wan_err "indicatif ${WAN_IND[$id]} (noeud $id) est un préfixe de ${WAN_IND[$other]} (noeud $other)"; rc=1
            fi
            if [ "${WAN_IP[$id]}" = "${WAN_IP[$other]}" ]; then
                _wan_err "noeuds $id et $other partagent l'IP ${WAN_IP[$id]}"; rc=1
            fi
        done
    done
    if [ -n "${WAN_NODE_ID:-}" ] && [ "${WAN_NODE_ID:-0}" != "0" ]; then
        [ -n "${WAN_IP[$WAN_NODE_ID]:-}" ] \
            || { _wan_err "le noeud local ($WAN_NODE_ID) n'est pas dans la table"; rc=1; }
    fi
    return $rc
}

# ── Détection du noeud local par ses adresses ────────────────────────────────
# Une SEULE ISO peut alors servir les N machines : chacune se reconnaît à son
# IP. Sans ça il faudrait fabriquer une image par noeud.
wan_nodes_detect_self() {
    local id addrs
    addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    [ -n "$addrs" ] || return 1
    for id in "${WAN_NODE_LIST[@]}"; do
        if printf '%s\n' $addrs | grep -qx "${WAN_IP[$id]}"; then
            WAN_NODE_ID="$id"; return 0
        fi
    done
    return 1
}

wan_local_ip()  { printf '%s' "${WAN_IP[${WAN_NODE_ID}]:-}"; }
wan_local_ind() { printf '%s' "${WAN_IND[${WAN_NODE_ID}]:-}"; }

# ── Saisie ───────────────────────────────────────────────────────────────────
# whiptail quand on en a un ET un terminal ; sinon `read`. Le mode « ni l'un ni
# l'autre » (cron, CI, docker exec -d) n'invente rien : il échoue en nommant
# les variables à poser.
_wan_ask() {   # titre  question  défaut
    local title="$1" q="$2" def="${3:-}" ans
    if [ -t 0 ] && [ -t 2 ] && command -v whiptail >/dev/null 2>&1 && [ -z "${WAN_NO_WHIPTAIL:-}" ]; then
        ans=$(whiptail --backtitle "osmo_egprs — WAN" --title "$title" \
                --inputbox "$q" 10 72 "$def" 3>&1 1>&2 2>&3) || return 1
    elif [ -t 0 ]; then
        printf '  %s [%s] : ' "$q" "$def" >&2
        read -r ans || return 1
    else
        _wan_err "pas de terminal : renseignez WAN_NODES / WAN_NODE_ID / WAN_OPS"
        return 1
    fi
    printf '%s' "${ans:-$def}"
}

# wan_nodes_prompt [nb_ops_local]
#   1. combien de noeuds
#   2. pour CHAQUE noeud : son IP publique, puis son indicatif
#   3. quel numéro porte le noeud construit par ce lancement
wan_nodes_prompt() {
    local n i ip ind me auto_ip def_n
    def_n="${WAN_NODE_COUNT:-0}"; [ "$def_n" -lt 1 ] && def_n=3

    n=$(_wan_ask "WAN — noeuds" "Nombre de noeuds du WAN (1-9) :" "$def_n") || return 1
    [[ "$n" =~ ^[1-9]$ ]] \
        || { _wan_err "nombre de noeuds invalide : '$n' (1 à 9)"; return 1; }

    auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # ${x[@]+"${x[@]}"} : sous `set -u`, un tableau VIDE développé sans cette
    # garde est une erreur fatale sur bash < 4.4 — et la première saisie part
    # justement d'une table vide.
    local -a old_list=(${WAN_NODE_LIST[@]+"${WAN_NODE_LIST[@]}"})
    local -A old_ip old_ind
    for i in "${old_list[@]}"; do old_ip[$i]="${WAN_IP[$i]}"; old_ind[$i]="${WAN_IND[$i]}"; done
    WAN_IP=(); WAN_IND=(); WAN_NODE_LIST=()

    for i in $(seq 1 "$n"); do
        ip=$(_wan_ask "WAN — noeud $i/$n" "IP publique du noeud $i :" "${old_ip[$i]:-}") || return 1
        ind=$(_wan_ask "WAN — noeud $i/$n" "Indicatif du noeud $i (préfixe d'appel) :" \
                       "${old_ind[$i]:-$(wan_default_ind "$i")}") || return 1
        WAN_IP[$i]="$ip"; WAN_IND[$i]="$ind"; WAN_NODE_LIST+=("$i")
    done
    WAN_NODE_COUNT="$n"

    # Numéro du noeud LOCAL. On propose celui dont l'IP est la nôtre.
    me="${WAN_NODE_ID:-0}"
    if [ "$me" = "0" ] && [ -n "$auto_ip" ]; then
        for i in "${WAN_NODE_LIST[@]}"; do [ "${WAN_IP[$i]}" = "$auto_ip" ] && me="$i"; done
    fi
    [ "$me" = "0" ] && me=1
    me=$(_wan_ask "WAN — ce noeud" "Numéro du noeud construit par ce lancement (1-$n) :" "$me") || return 1
    [[ "$me" =~ ^[0-9]+$ ]] && [ -n "${WAN_IP[$me]:-}" ] \
        || { _wan_err "noeud local '$me' hors table"; return 1; }
    WAN_NODE_ID="$me"

    wan_nodes_validate || return 1
    return 0
}

# ── Persistance ──────────────────────────────────────────────────────────────
wan_nodes_save() {
    local f="${1:-$WAN_CONF_FILE}"
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<EOF
# /etc/osmo-wan.conf — table des noeuds WAN (généré par network/wan-nodes.sh)
# Format : WAN_NODES="id:ip:indicatif ..."
WAN_NODES="$(wan_nodes_spec)"
WAN_NODE_COUNT=${WAN_NODE_COUNT}
WAN_NODE_ID=${WAN_NODE_ID}
WAN_OPS=${WAN_OPS}
# WAN_AUTO=1 : les lanceurs appliquent le WAN sans qu'on repasse --wan.
WAN_AUTO=${WAN_AUTO:-0}
EOF
}

wan_nodes_load() {
    local f="${1:-$WAN_CONF_FILE}"
    [ -r "$f" ] || return 1
    # shellcheck disable=SC1090
    . "$f"
    wan_nodes_parse "${WAN_NODES:-}" || return 1
    return 0
}

wan_nodes_summary() {
    local id tag
    printf '  Noeuds WAN : %s   (ce noeud : %s)\n' "$WAN_NODE_COUNT" "$(_wanc "${WAN_NODE_ID}")"
    for id in "${WAN_NODE_LIST[@]}"; do
        tag="   "; [ "$id" = "${WAN_NODE_ID}" ] && tag="◀ ce noeud"
        printf '    node %-2s  %-15s  indicatif %-4s %s\n' "$id" "${WAN_IP[$id]}" "${WAN_IND[$id]}" "$tag"
    done
    printf '    Composer %s + numéro pour joindre le noeud correspondant.\n' \
        "$(_wanc "<indicatif>")"
}
