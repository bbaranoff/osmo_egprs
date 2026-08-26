#!/usr/bin/env bash
# =============================================================================
#  generate_configs.sh - le SEUL endroit ou la configuration du reseau est
#                        decidee, et le seul qui sait substituer les gabarits.
# =============================================================================
#
#  POURQUOI CE FICHIER EXISTE
#  --------------------------
#  La mecanique est inchangee : les fichiers de `configs/` contiennent des
#  marqueurs `__MCC__`, `__ARFCN__`, `__KI__`... qu'une fonction remplace au
#  demarrage. Ce qui change, c'est qu'il n'y a plus DEUX implementations de
#  cette fonction - `start.sh` en portait une copie de 132 lignes et
#  `lib/gabarits.sh` une autre de 70, identiques au formatage pres, qui
#  derivaient donc en silence. Elles vivent ici, une fois.
#
#  Et surtout : les valeurs n'etaient calculees NULLE PART de facon visible.
#  ARFCN, BSIC, IMSI, IMEI, Ki etaient des formules enfouies au milieu de la
#  substitution (`arfcn=$(( 512 + op_id * 2 ))`). Pour changer l'ARFCN il
#  fallait trouver et editer la formule. Desormais ces formules ne sont plus
#  que des DEFAUTS : `globals.conf`, a la racine, les expose toutes et gagne.
#
#  DEUX USAGES
#  -----------
#    ./generate_configs.sh [--force] [--show] [CLE=VALEUR ...]
#         ecrit/complete globals.conf a la racine, puis affiche l'effectif.
#         Sans --force, un globals.conf existant n'est JAMAIS ecrase : c'est
#         ton fichier, on ne reecrit pas par-dessus tes reglages.
#
#    . ./generate_configs.sh
#         charge globals.conf et definit apply_config_templates().
#         C'est ce que font start.sh (hote) et lib/gabarits.sh.
#
#  QUI APPELLE QUOI
#  ----------------
#    start.sh          -> execute ce script (genere globals.conf) puis le source
#    start-direct.sh   -> source globals.conf (docker : la conf est deja la)
#    lib/gabarits.sh   -> source ce script pour apply_config_templates()
#
#  MULTI-OPERATEUR
#  ---------------
#  En mode `virtual` (N_OPERATORS > 1) chaque operateur a besoin de valeurs
#  DISTINCTES. Une valeur posee dans globals.conf s'applique alors a TOUS -
#  ce qui est presque toujours faux pour ARFCN, LAC, IMSI... Laisse-les vides
#  (le defaut) pour garder la derivation par operateur, et ne fixe que ce que
#  tu veux vraiment figer. Le script te previent si tu figes un champ
#  per-operateur avec N_OPERATORS > 1.
#
#  SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================

_GC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GC_FILE="$_GC_HERE/globals.conf"

# ── Les reglages exposes, avec leur defaut historique ────────────────────────
# Format : CLE|VALEUR-PAR-DEFAUT|PER-OP|COMMENTAIRE
#   PER-OP=1 -> la valeur est normalement derivee du numero d'operateur ;
#               la figer n'a de sens qu'avec un seul operateur.
_gc_table() {
cat <<'TABLE'
#SECTION|Identite du reseau
MCC|001|0|Mobile Country Code (3 chiffres)
MNC|01|0|Mobile Network Code (2 chiffres)
OP_NAME|OsmoQEMU|0|Nom court et long du reseau
#SECTION|Securite et carte SIM
ENCRYPTION|a5 1|0|Chiffrement : "a5 1" (defaut), "a5 0" (aucun), "a5 0 1 3"...
SIM_ALGO|comp128|0|Algorithme d'authentification (comp128, xor...)
KI||1|Ki de la SIM, 16 octets hexa espaces
IMSI||1|IMSI du mobile
IMEI||1|IMEI du mobile
#SECTION|Radio
ARFCN||1|Canal radio (a accorder avec BAND)
BAND|DCS1800|0|Bande : GSM900, DCS1800, PCS1900, GSM850
BSIC||1|Base Station Identity Code, 0..63
LAC||1|Location Area Code
CELL_ID||1|Cell identity
IPA_UNIT_ID||1|Identifiant IPA du BTS
MS_MAX_POWER|15|0|Puissance max autorisee au mobile (0..15)
RXLEV_ACCESS_MIN|0|0|Niveau recu minimal pour acceder a la cellule
CELL_RESEL_HYST|4|0|Hysteresis de reselection de cellule (dB)
T3109|5|0|Timer T3109 du BSC (s) - liberation de canal
#SECTION|GPRS
BVCI||1|BSSGP Virtual Connection Id
NSEI||1|Network Service Entity Id
NSVCI||1|NS Virtual Connection Id
APN|internet|0|Nom du point d'acces
#SECTION|Services
SMS_SC||1|Numero du centre SMS
#SECTION|Dimensionnement
MS_COUNT|2|0|Nombre de mobiles simules
N_OPERATORS|1|0|Nombre d'operateurs (mode "virtual")
HOST_IP|127.0.0.1|0|Adresse de l'hote vue par la pile
TABLE
}

# ── Ecriture de globals.conf ─────────────────────────────────────────────────
_gc_write() {
    local force=$1
    if [ -f "$_GC_FILE" ] && [ "$force" != "1" ]; then
        printf '  globals.conf existe deja - conserve (--force pour regenerer)\n'
        return 0
    fi
    {
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#  globals.conf - la configuration du reseau, en un seul endroit.\n'
        printf '# ═══════════════════════════════════════════════════════════════\n'
        printf '#\n'
        printf '#  Edite ce fichier a la main : il ne sera JAMAIS reecrit par un run.\n'
        printf '#  Seul "./generate_configs.sh --force" le regenere.\n'
        printf '#\n'
        printf '#  CE FICHIER FAIT AUTORITE - SUR LES VARIABLES QU'"'"'IL DECLARE, ET SUR\n'
        printf '#  ELLES SEULES. Il est lu en dernier : les %s reglages ci-dessous\n' "$(_gc_table | grep -vc '^#SECTION')"
        printf '#  ecrasent leur homonyme dans l'"'"'environnement. Tout le reste (CALYPSO_*,\n'
        printf '#  LOG_DIR, MODE...) passe au travers, intact. Deux facons de le modifier :\n'
        printf '#      vim globals.conf\n'
        printf '#      ./generate_configs.sh ARFCN=520\n'
        printf '#\n'
        printf '#  Un champ VIDE = valeur calculee automatiquement. Les champs notes\n'
        printf '#  [auto/operateur] se deduisent du numero d'"'"'operateur : ne les fige\n'
        printf '#  que si N_OPERATORS=1, sinon tous les operateurs se marchent dessus.\n'
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
                "$([ "$perop" = 1 ] && printf '  [auto/operateur]')"
            case "$def" in
                *" "*|"") printf '%s="%s"\n' "$key" "$def" ;;
                *)        printf '%s=%s\n'   "$key" "$def" ;;
            esac
        done < <(_gc_table)
    } > "$_GC_FILE"
    printf '  globals.conf ecrit (%s reglages)\n' \
           "$(_gc_table | grep -vc '^#SECTION')"
}

# ── Poser une valeur DANS le fichier, en place, sans casser la mise en forme ──
_gc_set() {
    local key="${1%%=*}" val="${1#*=}"
    _gc_table | grep -q "^${key}|" || {
        printf '  ⚠ reglage inconnu : %s (voir --show)\n' "$key" >&2; return 1; }
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
# Charge globals.conf, puis COMPLETE avec les defauts de la table.
#
# L'ordre compte : le fichier est lu d'abord et fait autorite sur les variables
# qu'il declare ; ensuite, toute cle encore vide recoit son defaut d'usine.
#
# Ce filet n'est pas decoratif. Sans lui, un globals.conf ABSENT - clone frais,
# fichier volontairement gitignore, suppression accidentelle - laissait BAND,
# SIM_ALGO, APN, T3109... vides, et la substitution les ecrivait tels quels dans
# les configs : "band" sans valeur, "ki  <hexa>" sans algorithme. osmo-bsc
# refuse alors de demarrer, et rien dans le journal ne dit pourquoi. Constate
# en vrai le 2026-08-03. Les defauts appartiennent au SCRIPT ; globals.conf
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

# ── La substitution des gabarits - implementation UNIQUE ─────────────────────
#  Signature inchangee, pour rester compatible avec les deux appelants :
#    apply_config_templates DEST CONTAINER_IP GATEWAY_IP OP_ID \
#                           PC_MSC PC_STP PC_BSC MCC MNC OP_NAME \
#                           INTER_STP INTER_STP_SHUTDOWN N_OPERATORS
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3 op_id=$4

    # ── OSMO_NO_REGEN : ne pas refaire ce qui vient d'etre fait ─────────────
    # run.sh rejoue cette fonction au demarrage (qemu-src,
    # run_modules/08-gabarits.sh). Dans un conteneur, c'est une REGRESSION : les
    # configs viennent d'etre generees par start.sh, avec l'identite du noeud,
    # ses point codes et son inter-STP. Les regenerer depuis les gabarits les
    # remplace par les valeurs par defaut - 1.1.2 pour tout le monde, ASP vers
    # le hub docker, en shutdown - et l'interco meurt sans un mot.
    #
    # start-direct.sh pose donc cette variable par defaut, et --regen la leve
    # pour qui veut vraiment repartir des gabarits.
    if [ "${OSMO_NO_REGEN:-0}" = "1" ]; then
        echo "  gabarits : conserves (OSMO_NO_REGEN=1 ; --regen pour regenerer)"
        return 0
    fi
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
    # qui omettait silencieusement tout script ajoute depuis.
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
    # RCTX_INTER_OVERRIDE : pose par build-iso.sh quand l'image est un NOEUD DE
    # WAN. Le routing context identifie l'AS aupres du hub ; la formule locale
    # (op*100+50) donne la meme valeur sur tous les noeuds, donc plusieurs AS
    # indiscernables sur le meme hub. Vide = formule d'origine, rien ne change.
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
    # plan docker mais celle du segment - ou 0.0.0.0 quand elle vient du DHCP.
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

    # ── L'adressage SS7 du noeud : rendu a set-node-id.sh ────────────────────
    # Les gabarits portent les defauts d'une machine SEULE (point-code 1.1.2,
    # ASP vers 127.0.0.1, shutdown). Sur un noeud de WAN ils sont faux - et ils
    # revenaient ici a CHAQUE regeneration : l'adressage pose par set_stp_ip.sh
    # etait efface au demarrage suivant sans que rien ne le signale. L'interco
    # retombait alors que le fichier venait d'etre "regenere proprement".
    #
    # set-node-id.sh (ce que set_stp_ip.sh appelle lui-meme) est le seul endroit
    # qui tienne d'accord les trois fichiers - osmo-stp, osmo-msc, osmo-bsc - et
    # leurs point codes croises. On le rejoue APRES la substitution plutot que
    # de dupliquer ici un sed qui divergerait le jour ou le plan changerait.
    _apply_node_ss7_addressing "$dest"
}

# Rejoue l'adressage SS7 du noeud sur les configs fraichement generees.
#   $1 = repertoire destination (celui qui contient osmocom/)
# Sans effet - et silencieux - quand la machine n'est pas un noeud de WAN, quand
# le script est absent, ou quand OSMO_NO_STP_IP=1 le demande explicitement.
_apply_node_ss7_addressing() {
    local dest="$1"
    local role_file="${ROLE_FILE:-/etc/osmo-role}"
    local here="${GEN_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    [ "${OSMO_NO_STP_IP:-0}" = "1" ] && return 0
    [ -d "$dest/osmocom" ] || return 0

    # ── L'ENVIRONNEMENT D'ABORD, le fichier de role ensuite ─────────────────
    # Cette fonction s'execute AUSSI dans un conteneur : run.sh y rejoue
    # apply_config_templates (qemu-src, run_modules/08-gabarits.sh), ce qui
    # regenere tout /etc/osmocom a partir des gabarits - et efface l'identite
    # SS7 que start.sh venait d'ecrire. Le conteneur repartait alors avec le
    # plan du gabarit : point-code 1.1.2 pour TOUS les operateurs, donc deux
    # equipements a la meme adresse SS7 et aucun ASP attache.
    #
    # Or le conteneur n'a pas de /etc/osmo-role - il a des VARIABLES, que
    # start.sh lui passe (OSMO_WAN_NODE, OSMO_HUB_IP). On les lit en premier :
    # c'est la seule source disponible la ou le probleme se produit.
    local role node hub
    node="${OSMO_WAN_NODE:-${WAN_NODE_ID:-}}"
    hub="${OSMO_HUB_IP:-}"
    role="${OSMO_ROLE:-}"
    if [ -r "$role_file" ]; then
        [ -n "$role" ] || role="$(awk -F= '/^OSMO_ROLE=/{gsub(/[ \r\t]/,"",$2);v=$2}    END{print v}' "$role_file")"
        [ -n "$node" ] || node="$(awk -F= '/^OSMO_WAN_NODE=/{gsub(/[ \r\t]/,"",$2);v=$2} END{print v}' "$role_file")"
        [ -n "$hub"  ] || hub="$(awk  -F= '/^OSMO_HUB_IP=/{gsub(/[ \r\t]/,"",$2);v=$2}  END{print v}' "$role_file")"
    fi
    # UN ROLE EXPLICITE, ET RIEN D'AUTRE.
    # Deduire "operateur" de la simple presence d'un numero de noeud etait faux
    # sur l'hote : start.sh y porte WAN_NODE_ID = le noeud de la MACHINE, alors
    # qu'il genere les configs de CONTENEURS qui sont, eux, d'autres noeuds. Le
    # hook reappliquait donc le noeud de l'hote a chaque operateur : tous se
    # retrouvaient avec le meme point code, et deux equipements a la meme
    # adresse SS7 ne peuvent pas s'attacher tous les deux.
    #
    # Ce rattrapage ne vaut donc QUE pour une machine qui se declare operateur
    # dans /etc/osmo-role (une VM, un noeud natif) ou via OSMO_ROLE. Quand
    # start.sh calcule lui-meme l'identite de chaque conteneur, il n'a besoin
    # de personne.

    [ "$role" = "operator" ] || return 0
    [[ "$node" =~ ^[1-9]$ ]] || return 0

    local setid="$here/network/set-node-id.sh"
    [ -r "$setid" ] || return 0

    # Le hub, quelle qu'en soit la source. Sans lui, set-node-id.sh DEMANDE -
    # et comme il est appele ici depuis une boucle de demarrage, il attendait
    # une reponse que personne ne venait donner : le lancement se figeait juste
    # apres la creation du reseau de l'operateur, sans un mot.
    [ -n "$hub" ] || hub="${WAN_STP_TARGET:-${INTER_STP_IP:-}}"

    local args=(--node "$node" --op "${OPS_PER_NODE:-1}" --native --conf-dir "$dest/osmocom")
    [ -n "$hub" ] && args+=(--hub-ip "$hub")

    # </dev/null : cette reecriture est automatique, elle ne pose JAMAIS de
    # question. Si une valeur manque, on prefere un echec signale a un blocage.
    if bash "$setid" "${args[@]}" </dev/null >/dev/null 2>&1; then
        echo "  ✓ adressage SS7 du noeud ${node} reapplique (set-node-id.sh)"
    else
        echo "  ⚠ adressage SS7 du noeud ${node} NON reapplique - l'ASP inter-STP" >&2
        echo "    gardera les defauts du gabarit (127.0.0.1, shutdown)." >&2
    fi
}

# ── Affichage de l'effectif ──────────────────────────────────────────────────
_gc_show() {
    local key def perop comment val src
    printf '\n  %-13s %-26s %s\n' "REGLAGE" "VALEUR EFFECTIVE" "ORIGINE"
    printf '  %-13s %-26s %s\n' "-------" "----------------" "-------"
    while IFS='|' read -r key def perop comment; do
        [ -n "$key" ] && [ "$key" != "#SECTION" ] || continue
        val="${!key:-}"
        if [ -n "$val" ]; then src="globals.conf / env"
        elif [ "$perop" = 1 ]; then src="derive de l'operateur"; val="(auto)"
        else src="defaut"; val="$def"; fi
        printf '  %-13s %-26s %s\n' "$key" "$val" "$src"
    done < <(_gc_table)
    printf '\n'
}

# ── Garde-fou multi-operateur ────────────────────────────────────────────────
_gc_warn_perop() {
    [ "${N_OPERATORS:-1}" -gt 1 ] 2>/dev/null || return 0
    local key def perop comment figes=""
    while IFS='|' read -r key def perop comment; do
        [ "$key" != "#SECTION" ] && [ "$perop" = 1 ] && [ -n "${!key:-}" ] && figes="$figes $key"
    done < <(_gc_table)
    [ -n "$figes" ] || return 0
    printf '\n  ⚠ N_OPERATORS=%s mais ces champs par-operateur sont FIGES :%s\n' \
           "$N_OPERATORS" "$figes"
    printf '    Tous les operateurs partageront la meme valeur - collision garantie\n'
    printf '    sur la radio et/ou les identites. Videz-les dans globals.conf.\n\n'
}

# ── Mode execute ─────────────────────────────────────────────────────────────
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

# ── Mode source ──────────────────────────────────────────────────────────────
gc_load
