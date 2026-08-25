#!/usr/bin/env bash
# =============================================================================
#  generate_configs.sh — le SEUL endroit où la configuration du réseau est
#                        décidée, et le seul qui sait substituer les gabarits.
# =============================================================================
#
#  POURQUOI CE FICHIER EXISTE
#  --------------------------
#  La mécanique est inchangée : les fichiers de `configs/` contiennent des
#  marqueurs `__MCC__`, `__ARFCN__`, `__KI__`… qu'une fonction remplace au
#  démarrage. Ce qui change, c'est qu'il n'y a plus DEUX implémentations de
#  cette fonction — `start.sh` en portait une copie de 132 lignes et
#  `lib/gabarits.sh` une autre de 70, identiques au formatage près, qui
#  dérivaient donc en silence. Elles vivent ici, une fois.
#
#  Et surtout : les valeurs n'étaient calculées NULLE PART de façon visible.
#  ARFCN, BSIC, IMSI, IMEI, Ki étaient des formules enfouies au milieu de la
#  substitution (`arfcn=$(( 512 + op_id * 2 ))`). Pour changer l'ARFCN il
#  fallait trouver et éditer la formule. Désormais ces formules ne sont plus
#  que des DÉFAUTS : `globals.conf`, à la racine, les expose toutes et gagne.
#
#  DEUX USAGES
#  -----------
#    ./generate_configs.sh [--force] [--show] [CLE=VALEUR ...]
#         écrit/complète globals.conf à la racine, puis affiche l'effectif.
#         Sans --force, un globals.conf existant n'est JAMAIS écrasé : c'est
#         ton fichier, on ne réécrit pas par-dessus tes réglages.
#
#    . ./generate_configs.sh
#         charge globals.conf et définit apply_config_templates().
#         C'est ce que font start.sh (hôte) et lib/gabarits.sh.
#
#  QUI APPELLE QUOI
#  ----------------
#    start.sh          -> exécute ce script (génère globals.conf) puis le source
#    start-direct.sh   -> source globals.conf (docker : la conf est déjà là)
#    lib/gabarits.sh   -> source ce script pour apply_config_templates()
#
#  MULTI-OPÉRATEUR
#  ---------------
#  En mode `virtual` (N_OPERATORS > 1) chaque opérateur a besoin de valeurs
#  DISTINCTES. Une valeur posée dans globals.conf s'applique alors à TOUS —
#  ce qui est presque toujours faux pour ARFCN, LAC, IMSI… Laisse-les vides
#  (le défaut) pour garder la dérivation par opérateur, et ne fixe que ce que
#  tu veux vraiment figer. Le script te prévient si tu figes un champ
#  per-opérateur avec N_OPERATORS > 1.
#
#  SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================

_GC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GC_FILE="$_GC_HERE/globals.conf"

# ── Les réglages exposés, avec leur défaut historique ────────────────────────
# Format : CLE|VALEUR-PAR-DEFAUT|PER-OP|COMMENTAIRE
#   PER-OP=1 -> la valeur est normalement dérivée du numéro d'opérateur ;
#               la figer n'a de sens qu'avec un seul opérateur.
_gc_table() {
cat <<'TABLE'
#SECTION|Identité du réseau
MCC|001|0|Mobile Country Code (3 chiffres)
MNC|01|0|Mobile Network Code (2 chiffres)
OP_NAME|OsmoQEMU|0|Nom court et long du réseau
#SECTION|Sécurité et carte SIM
ENCRYPTION|a5 0|0|Chiffrement : « a5 0 » (aucun), « a5 1 », « a5 0 1 3 »…
SIM_ALGO|comp128|0|Algorithme d'authentification (comp128, xor…)
KI||1|Ki de la SIM, 16 octets hexa espacés
IMSI||1|IMSI du mobile
IMEI||1|IMEI du mobile
#SECTION|Radio
ARFCN||1|Canal radio (à accorder avec BAND)
BAND|DCS1800|0|Bande : GSM900, DCS1800, PCS1900, GSM850
BSIC||1|Base Station Identity Code, 0..63
LAC||1|Location Area Code
CELL_ID||1|Cell identity
IPA_UNIT_ID||1|Identifiant IPA du BTS
MS_MAX_POWER|15|0|Puissance max autorisée au mobile (0..15)
RXLEV_ACCESS_MIN|0|0|Niveau reçu minimal pour accéder à la cellule
CELL_RESEL_HYST|4|0|Hystérésis de resélection de cellule (dB)
T3109|5|0|Timer T3109 du BSC (s) — libération de canal
#SECTION|GPRS
BVCI||1|BSSGP Virtual Connection Id
NSEI||1|Network Service Entity Id
NSVCI||1|NS Virtual Connection Id
APN|internet|0|Nom du point d'accès
#SECTION|Services
SMS_SC||1|Numéro du centre SMS
#SECTION|Dimensionnement
MS_COUNT|2|0|Nombre de mobiles simulés
N_OPERATORS|1|0|Nombre d'opérateurs (mode « virtual »)
HOST_IP|127.0.0.1|0|Adresse de l'hôte vue par la pile
TABLE
}

# ── Écriture de globals.conf ─────────────────────────────────────────────────
_gc_write() {
    local force=$1
    if [ -f "$_GC_FILE" ] && [ "$force" != "1" ]; then
        printf '  globals.conf existe déjà — conservé (--force pour régénérer)\n'
        return 0
    fi
    {
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#  globals.conf — la configuration du réseau, en un seul endroit.\n'
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#\n'
        printf '#  Édite ce fichier à la main : il ne sera JAMAIS réécrit par un run.\n'
        printf '#  Seul « ./generate_configs.sh --force » le régénère.\n'
        printf '#\n'
        printf '#  CE FICHIER FAIT AUTORITÉ — SUR LES VARIABLES QU'"'"'IL DÉCLARE, ET SUR\n'
        printf '#  ELLES SEULES. Il est lu en dernier : les %s réglages ci-dessous\n' "$(_gc_table | grep -vc '^#SECTION')"
        printf '#  écrasent leur homonyme dans l'"'"'environnement. Tout le reste (CALYPSO_*,\n'
        printf '#  LOG_DIR, MODE…) passe au travers, intact. Deux façons de le modifier :\n'
        printf '#      vim globals.conf\n'
        printf '#      ./generate_configs.sh ARFCN=520\n'
        printf '#\n'
        printf '#  Un champ VIDE = valeur calculée automatiquement. Les champs notés\n'
        printf '#  [auto/opérateur] se déduisent du numéro d'"'"'opérateur : ne les fige\n'
        printf '#  que si N_OPERATORS=1, sinon tous les opérateurs se marchent dessus.\n'
        printf '# ═══════════════════════════════════════════════════════════════\n'
        local key def perop comment
        while IFS='|' read -r key def perop comment; do
            [ -n "$key" ] || continue
            if [ "$key" = "#SECTION" ]; then
                printf '\n# ── %s %s\n\n' "$def" \
                    "$(printf '%.0s─' $(seq 1 $((56 - ${#def}))))"
                continue
            fi
            printf '# %s%s\n' "$comment" \
                "$([ "$perop" = 1 ] && printf '  [auto/opérateur]')"
            case "$def" in
                *" "*|"") printf '%s="%s"\n' "$key" "$def" ;;
                *)        printf '%s=%s\n'   "$key" "$def" ;;
            esac
        done < <(_gc_table)
    } > "$_GC_FILE"
    printf '  globals.conf écrit (%s réglages)\n' \
           "$(_gc_table | grep -vc '^#SECTION')"
}

# ── Poser une valeur DANS le fichier, en place, sans casser la mise en forme ──
_gc_set() {
    local key="${1%%=*}" val="${1#*=}"
    _gc_table | grep -q "^${key}|" || {
        printf '  ⚠ réglage inconnu : %s (voir --show)\n' "$key" >&2; return 1; }
    [ -f "$_GC_FILE" ] || _gc_write 1 >/dev/null
    local q; case "$val" in *" "*|"") q="\"$val\"" ;; *) q="$val" ;; esac
    if grep -qE "^${key}=" "$_GC_FILE"; then
        sed -i "s|^${key}=.*|${key}=${q}|" "$_GC_FILE"
    else
        printf '%s=%s\n' "$key" "$q" >> "$_GC_FILE"
    fi
    printf '  %s = %s\n' "$key" "${val:-(auto)}"
}

# ── Chargement ───────────────────────────────────────────────────────────────
# Charge globals.conf, puis COMPLÈTE avec les défauts de la table.
#
# L'ordre compte : le fichier est lu d'abord et fait autorité sur les variables
# qu'il déclare ; ensuite, toute clé encore vide reçoit son défaut d'usine.
#
# Ce filet n'est pas décoratif. Sans lui, un globals.conf ABSENT — clone frais,
# fichier volontairement gitignoré, suppression accidentelle — laissait BAND,
# SIM_ALGO, APN, T3109… vides, et la substitution les écrivait tels quels dans
# les configs : « band » sans valeur, « ki  <hexa> » sans algorithme. osmo-bsc
# refuse alors de démarrer, et rien dans le journal ne dit pourquoi. Constaté
# en vrai le 2026-08-03. Les défauts appartiennent au SCRIPT ; globals.conf
# n'est qu'une couche de surcharge par-dessus.
gc_load() {
    [ -f "$_GC_FILE" ] && . "$_GC_FILE"
    local key def perop comment
    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        [ -n "${!key:-}" ] || printf -v "$key" '%s' "$def"
    done < <(_gc_table)
    return 0
}

# ── La substitution des gabarits — implémentation UNIQUE ─────────────────────
#  Signature inchangée, pour rester compatible avec les deux appelants :
#    apply_config_templates DEST CONTAINER_IP GATEWAY_IP OP_ID \
#                           PC_MSC PC_STP PC_BSC MCC MNC OP_NAME \
#                           INTER_STP INTER_STP_SHUTDOWN N_OPERATORS
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3 op_id=$4
    local pc_msc=$5 pc_stp=$6 pc_bsc=$7 mcc=$8 mnc=$9 op_name=${10}
    local inter_stp=${11} inter_stp_shutdown=${12} n_operators=${13}

    mkdir -p "$dest/osmocom" "$dest/asterisk" "$dest/bb"
    local f bn

    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done
    [ -f "configs/osmo-bts-virtual.cfg" ] && cp "configs/osmo-bts-virtual.cfg" "$dest/osmocom/"
    for f in configs/*.conf; do
        bn=$(basename "$f"); [ "$bn" = "sms-routing.conf" ] && continue
        cp "$f" "$dest/asterisk/"
    done
    # scripts/ en entier : c'est le comportement de start.sh, le plus permissif
    # des deux qui coexistaient. lib/gabarits.sh en copiait une liste blanche,
    # qui omettait silencieusement tout script ajouté depuis.
    cp scripts/* "$dest/osmocom/" 2>/dev/null || true
    chmod +x "$dest/osmocom"/*.sh 2>/dev/null || true

    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg.template" "$dest/bb/mobile_group1.cfg"
    elif [ -f "configs/mobile.cfg" ]; then
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg" "$dest/bb/mobile_group1.cfg"
    fi

    local rctx_msc rctx_stp rctx_bsc rctx_inter
    rctx_msc=$(op_rctx_msc "$op_id");   rctx_stp=$(op_rctx_stp "$op_id")
    rctx_bsc=$(op_rctx_bsc "$op_id")
    # RCTX_INTER_OVERRIDE : posé par build-iso.sh quand l'image est un NOEUD DE
    # WAN. Le routing context identifie l'AS auprès du hub ; la formule locale
    # (op*100+50) donne la même valeur sur tous les noeuds, donc plusieurs AS
    # indiscernables sur le même hub. Vide = formule d'origine, rien ne change.
    rctx_inter="${RCTX_INTER_OVERRIDE:-$(op_rctx_inter "$op_id")}"

    # ── Les valeurs. globals.conf gagne ; sinon, la formule historique. ──────
    local arfcn="${ARFCN:-$(( 512 + op_id * 2 ))}"
    local bsic="${BSIC:-$(( (op_id * 7) % 64 ))}"
    local lac="${LAC:-0x000${op_id}}"
    local cell_id="${CELL_ID:-$(( 6000 + op_id ))}"
    local ipa_unit_id="${IPA_UNIT_ID:-$(( 6000 + op_id ))}"
    local bvci="${BVCI:-$(( op_id * 10 + 2 ))}"
    local nsei="${NSEI:-$(( op_id * 10 ))}"
    local nsvci="${NSVCI:-$(( op_id * 10 ))}"
    local imsi="${IMSI:-${mcc}${mnc}$(printf '%010d' "$op_id")}"
    local imei="${IMEI:-3589250059$(printf '%04d' "$op_id")0}"
    local ki="${KI:-00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x' "$op_id") ff}"
    local sms_sc="${SMS_SC:-+336661234$(printf '%04d' "$op_id")}"

    local inter_local_ip rtp_start rtp_end sip_host_port
    # Idem : sur un noeud de WAN, l'adresse source de l'ASP n'est pas une IP du
    # plan docker mais celle du segment — ou 0.0.0.0 quand elle vient du DHCP.
    inter_local_ip="${INTER_LOCAL_IP_OVERRIDE:-$(op_backbone_ip "$op_id")}"
    rtp_start=$(linphone_rtp_start "$op_id"); rtp_end=$(linphone_rtp_end "$op_id")
    sip_host_port=$(linphone_sip_port "$op_id")

    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        sed -i \
            -e "s|__ENCRYPTION__|${ENCRYPTION}|g" \
            -e "s|__INTER_NET_GATEWAY__|172.20.0.1|g" \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__INTER_STP_SHUTDOWN__|${inter_stp_shutdown}|g" \
            -e "s|__INTER_LOCAL_IP__|${inter_local_ip}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" -e "s|__PC_STP__|${pc_stp}|g" -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__RCTX_MSC__|${rctx_msc}|g" -e "s|__RCTX_STP__|${rctx_stp}|g" \
            -e "s|__RCTX_BSC__|${rctx_bsc}|g" -e "s|__RCTX_INTER__|${rctx_inter}|g" \
            -e "s|__MCC__|${mcc}|g" -e "s|__MNC__|${mnc}|g" -e "s|__OP_NAME__|${op_name}|g" \
            -e "s|__ARFCN__|${arfcn}|g" -e "s|__IPA_UNIT_ID__|${ipa_unit_id}|g" \
            -e "s|__CELL_ID__|${cell_id}|g" -e "s|__BSIC__|${bsic}|g" -e "s|__LAC__|${lac}|g" \
            -e "s|__BVCI__|${bvci}|g" -e "s|__NSEI__|${nsei}|g" -e "s|__NSVCI__|${nsvci}|g" \
            -e "s|__IMSI__|${imsi}|g" -e "s|__IMEI__|${imei}|g" -e "s|__KI__|${ki}|g" \
            -e "s|__SMS_SC__|${sms_sc}|g" -e "s|__HOST_IP__|${HOST_IP}|g" \
            -e "s|__BAND__|${BAND}|g" -e "s|__SIM_ALGO__|${SIM_ALGO}|g" \
            -e "s|__MS_MAX_POWER__|${MS_MAX_POWER}|g" \
            -e "s|__RXLEV_ACCESS_MIN__|${RXLEV_ACCESS_MIN}|g" \
            -e "s|__CELL_RESEL_HYST__|${CELL_RESEL_HYST}|g" \
            -e "s|__T3109__|${T3109}|g" -e "s|__APN__|${APN}|g" \
            -e "s|__SIP_HOST_PORT__|${sip_host_port}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT}|g" -e "s|__ALSA_INPUT__|${ALSA_INPUT}|g" \
            -e "s|__RTP_START__|${rtp_start}|g" -e "s|__RTP_END__|${rtp_end}|g" \
            "$f"
    done

    generate_pjsip_interop_trunks     "$op_id" "$n_operators" >> "$dest/asterisk/pjsip.conf"
    generate_extensions_interop_out   "$op_id" "$n_operators" >> "$dest/asterisk/extensions.conf"
    # Routes SMS (fallback = generateur par defaut). Condition d'echec : les
    # MSISDN reels (op*10000+1, +2) absents OU route parasite (op0000/op000).
    # Si non remplie -> regen.
    _src="$dest/osmocom/sms-routing.conf"
    _generate_sms_routing_conf_fallback "$op_id" "$n_operators" >  "$_src"
    if ! grep -q "^$(( op_id * 10000 + 1 )) = " "$_src" 2>/dev/null \
       || grep -qE "^${op_id}0000? = " "$_src" 2>/dev/null; then
        _generate_sms_routing_conf_fallback "$op_id" "$n_operators" >  "$_src"
    fi
}

# ── Affichage de l'effectif ──────────────────────────────────────────────────
_gc_show() {
    local key def perop comment val src
    printf '\n  %-13s %-26s %s\n' "RÉGLAGE" "VALEUR EFFECTIVE" "ORIGINE"
    printf '  %-13s %-26s %s\n' "-------" "----------------" "-------"
    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        val="${!key:-}"
        if [ -n "$val" ]; then src="globals.conf / env"
        elif [ "$perop" = 1 ]; then src="dérivé de l'opérateur"; val="(auto)"
        else src="défaut"; val="$def"; fi
        printf '  %-13s %-26s %s\n' "$key" "$val" "$src"
    done < <(_gc_table)
    printf '\n'
}

# ── Garde-fou multi-opérateur ────────────────────────────────────────────────
_gc_warn_perop() {
    [ "${N_OPERATORS:-1}" -gt 1 ] 2>/dev/null || return 0
    local key def perop comment figes=""
    while IFS='|' read -r key def perop comment; do
        [ "$key" != "#SECTION" ] && [ "$perop" = 1 ] && [ -n "${!key:-}" ] && figes="$figes $key"
    done < <(_gc_table)
    [ -n "$figes" ] || return 0
    printf '\n  ⚠ N_OPERATORS=%s mais ces champs par-opérateur sont FIGÉS :%s\n' \
           "$N_OPERATORS" "$figes"
    printf '    Tous les opérateurs partageront la même valeur — collision garantie\n'
    printf '    sur la radio et/ou les identités. Videz-les dans globals.conf.\n\n'
}

# ── Mode exécuté ─────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    force=0; show=0; _gc_sets=()
    for a in "$@"; do
        case "$a" in
            --force) force=1 ;;
            --show)  show=1 ;;
            -h|--help)
                sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
            *=*)     _gc_sets+=("$a") ;;
            *) printf 'option inconnue : %s (voir --help)\n' "$a" >&2; exit 2 ;;
        esac
    done
    _gc_write "$force"
    for kv in "${_gc_sets[@]}"; do _gc_set "$kv"; done
    gc_load
    _gc_warn_perop
    [ "$show" = 1 ] && _gc_show
    exit 0
fi

# ── Mode sourcé ──────────────────────────────────────────────────────────────
gc_load
