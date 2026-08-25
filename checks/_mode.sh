# =============================================================================
#  checks/_mode.sh — une seule règle de détection docker/natif, pour tous
#                    les scripts de checks/
#  Bibliothèque : à SOURCER, jamais à exécuter dans une boucle de tests.
# =============================================================================
#
#  POURQUOI CE FICHIER EXISTE
#  --------------------------
#  Le lab vit dans deux mondes, et les checks doivent dire la vérité dans les
#  deux :
#
#    docker — un conteneur osmo-operator-N par opérateur sur le réseau
#             gsm-inter (172.20.0.0/24), le hub SS7 est le conteneur
#             osmo-inter-stp (172.20.0.10) ; on atteint tout par « docker exec ».
#    natif  — ISO, VM ou machine nue : un seul opérateur (sauf topologie netns),
#             tout tourne ici, les VTY sont sur 127.0.0.1, les configs dans
#             /etc/osmocom, les démons sont des units systemd ou des processus.
#
#  Les PORTS VTY sont les MÊMES dans les deux mondes — seul l'hôte change :
#      osmo-stp 4239 · osmo-msc 4254 · osmo-bsc 4242 · osmo-hlr 4258
#      osmo-sgsn 4245 · osmo-ggsn 4260 · osmo-mgw 4243 · mobile/BB 4247
#
#  Avant ce fichier, la même détection était recopiée dans cinq scripts, avec
#  cinq variantes : deux d'entre elles employaient « docker ps | grep -q », qui
#  rend 141 sous « set -o pipefail » (grep sort au premier match, le producteur
#  prend un SIGPIPE) — l'inter-STP était alors déclaré absent alors qu'il
#  tournait, de façon intermittente. Une seule règle, écrite une fois, corrigée
#  une fois.
#
#  CONTRAT
#  -------
#   • le fichier ne définit QUE des fonctions et des variables « : = » ;
#     il n'affiche rien, ne pose aucune couleur, ne compte aucun PASS/FAIL :
#     chaque check garde ses ok/fail/warn/skip, donc son format de sortie et
#     son code de retour ;
#   • les sondes rendent 0 = vrai, non-0 = faux ;
#   • sourçable deux fois sans effet de bord (garde OSMO_MODE_LIB_LOADED) ;
#   • aucun « grep -q » en fin de pipeline, aucun « awk … exit » au milieu d'un
#     tube : sous « set -o pipefail » ces deux formes rendent 141 ;
#   • compatible « set -euo pipefail » chez l'appelant.
#
#  DEUX QUESTIONS DIFFÉRENTES — POURQUOI start-direct.sh GARDE SA DÉTECTION
#  ----------------------------------------------------------------------
#  start-direct.sh:159 a sa propre detect_runtime_env(), et elle N'EST PAS un
#  doublon de osmo_mode() : les deux fonctions répondent à deux questions qui
#  n'ont pas la même réponse.
#
#    detect_runtime_env()  « où est-ce que JE tourne ? »  → docker | vm | bare
#        Question de l'INTÉRIEUR du nœud. Elle décide du PLAN D'ADRESSAGE :
#        en docker l'inter-STP est 172.20.0.10 et le nœud a déjà son IP ; en
#        VM/ISO l'inter-STP est une autre machine (192.168.56.1) et l'adresse
#        arrive par DHCP, donc peut manquer au lancement.
#
#    osmo_mode()           « comment j'ATTEINS les nœuds d'ici ? » → docker | native
#        Question de PILOTAGE. Elle décide entre « docker exec » et « exécuter
#        ici ».
#
#  Elles se CONTREDISENT volontairement dans un cas, et c'est la preuve qu'il ne
#  faut pas les fusionner : DANS un conteneur du dépôt, detect_runtime_env rend
#  « docker » (le plan d'adressage est bien celui de docker) alors qu'osmo_mode
#  rend « native » — car « docker exec » vers soi-même n'a aucun sens, même
#  quand le socket est monté. Un script qui prendrait l'une pour l'autre
#  s'enverrait des commandes à lui-même par le démon docker.
#
#  Ce qui EST partagé, en revanche, c'est la convention aval : start-direct.sh
#  transmet « --$NODE_MODE » (--docker / --native) à network/setup-wan-mesh.sh
#  (start-direct.sh:756), et c'est exactement ce que consomme osmo_mode_force().
#  Les deux vocabulaires coïncident ; seules les fonctions restent distinctes.
#
#  DÉSIGNER UN NŒUD — <op>
#  -----------------------
#  Toutes les fonctions d'exécution prennent en premier argument un <op>, qui
#  accepte indifféremment :
#      3                    le numéro d'opérateur (forme normale)
#      osmo-operator-3      l'étiquette (ce que rendent osmo_ops/osmo_node)
#      hub | osmo-inter-stp le hub SS7
#  En docker c'est le nom du conteneur ; en natif c'est cette machine, avec le
#  préfixe « ip netns exec osmo-opN » si et seulement si l'espace de noms
#  existe (topologie multi-opérateur native, run_modules/12-netns.sh).
#
#  L'ÉTIQUETTE osmo-operator-N EST CONSERVÉE EN NATIF. Ce n'est pas une
#  coquetterie : checks/vty-debug-dump.sh écrit « container=osmo-operator-N »
#  dans son dump, et checks/operator_summary.sh y accroche quinze extractions.
#  L'étiquette est une clé de corrélation, pas un objet interrogeable.
#
#  SOURCING (le même bloc partout ; marche depuis le dépôt et depuis /opt) :
#      _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#      for _c in "$_here/_mode.sh" /opt/osmo_egprs/checks/_mode.sh; do
#          [ -r "$_c" ] && { . "$_c"; break; }
#      done
#      command -v osmo_mode >/dev/null || { echo "checks/_mode.sh introuvable" >&2; exit 1; }
# =============================================================================

[ -n "${OSMO_MODE_LIB_LOADED:-}" ] && return 0
OSMO_MODE_LIB_LOADED=1

# Racine du dépôt : ce fichier est dans checks/, la racine est un cran au-dessus.
# Sert à retrouver globals.conf ; surchargeable pour les tests.
_osmo_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OSMO_REPO:=$(dirname "$_osmo_lib_here")}"
unset _osmo_lib_here

# Plan d'adressage de la dorsale inter-opérateurs. La MÊME valeur sert aux deux
# mondes : docker la pose avec « --network gsm-inter --ip », le natif
# multi-opérateur la recrée en netns (BACKBONE_NET, run_modules/12-netns.sh:47).
: "${OSMO_BACKBONE_NET:=172.20.0}"
: "${OSMO_NETNS_PREFIX:=${NETNS_PREFIX:-osmo-op}}"

# Préfixe de racine, mode natif seulement : permet de viser un arbre de test
# (OSMO_NATIVE_ROOT=/tmp/essai) au lieu du /etc de la machine. Vide en
# production. Même rôle que NATIVE_ROOT dans network/setup-wan-mesh.sh.
: "${OSMO_NATIVE_ROOT:=}"

# Mémo « quel client VTY ce nœud possède-t-il ? », pour ne pas relancer un
# « command -v nc » à chaque commande VTY (global_check en passe des dizaines).
# « -g » : la bibliothèque doit rester utilisable même sourcée DEPUIS une
# fonction, où un « declare » nu créerait une variable locale qui disparaîtrait
# au retour.
declare -gA _OSMO_VTY_TOOL 2>/dev/null || declare -A _OSMO_VTY_TOOL

# =============================================================================
#  1. MODE
# =============================================================================

# osmo_in_container — tourne-t-on DANS un conteneur DE CE DÉPÔT ?
# /.dockerenv seul serait vrai dans n'importe quel conteneur ; on exige aussi
# /etc/docker-entrypoint-cmd, déposé par scripts/entrypoint.sh. C'est le couple
# qu'emploient start.sh:20 et start-direct.sh:159.
osmo_in_container() {
    [ -f /.dockerenv ] && [ -f /etc/docker-entrypoint-cmd ]
}

# Détection, du plus explicite au plus déduit.
_osmo_mode_detect() {
    # Dans un conteneur du dépôt, on EST le nœud : « docker exec » vers
    # soi-même n'a pas de sens, même si le socket docker est monté (c'est le cas
    # du conteneur du dashboard). C'est la règle de start-direct.sh:237.
    if osmo_in_container; then printf 'native\n'; return 0; fi

    # OSMO_NATIVE=1 est déjà posé par l'ISO (services/osmo-egprs-web.service).
    if [ "${OSMO_NATIVE:-}" = "1" ]; then printf 'native\n'; return 0; fi

    # LA règle du dépôt (checks/wan_ss7_check.sh:88, network/setup-wan-mesh.sh:122) :
    # on ne se fie pas à la présence du binaire docker — l'hôte du lab l'a, une
    # machine de dev aussi — mais à celle d'un conteneur opérateur EN COURS.
    # On capture la liste AVANT de la filtrer : « docker ps | grep -q » rendrait
    # 141 sous pipefail.
    if command -v docker >/dev/null 2>&1; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        if grep -x 'osmo-operator-1' >/dev/null 2>&1 <<<"$names"; then
            printf 'docker\n'; return 0
        fi
    fi
    printf 'native\n'
}

# osmo_mode — écrit « docker » ou « native ». Mémoïsé dans OSMO_MODE, qui fait
# aussi office d'entrée : « OSMO_MODE=native ./checks/global_check.sh » force.
osmo_mode() {
    case "${OSMO_MODE:-}" in
        docker|native) : ;;
        *) OSMO_MODE="$(_osmo_mode_detect)" ;;
    esac
    printf '%s\n' "$OSMO_MODE"
}

osmo_is_docker() { [ "$(osmo_mode)" = docker ]; }
osmo_is_native() { [ "$(osmo_mode)" = native ]; }

# osmo_mode_force <docker|native|--docker|--native|--mode=X>
# À glisser tel quel dans la boucle « case » d'analyse des options de chaque
# script : l'explicite gagne toujours sur la détection. Rend 2 sur un argument
# qui n'est pas un mode (l'appelant sait alors que l'option ne le concerne pas).
osmo_mode_force() {
    local m="${1:-}"
    case "$m" in
        --mode=*) m="${m#*=}" ;;
        --docker) m=docker ;;
        --native) m=native ;;
    esac
    case "$m" in
        docker|native) OSMO_MODE="$m"; return 0 ;;
        *) return 2 ;;
    esac
}

# =============================================================================
#  2. INVENTAIRE
# =============================================================================

# Lit une clé de globals.conf (« N_OPERATORS=3 »). On lit le fichier avec awk
# directement : pas de tube, donc pas de piège pipefail.
_osmo_globals() {
    local k="${1:-}" f v
    for f in "${OSMO_GLOBALS:-}" "$OSMO_REPO/globals.conf" \
             /opt/osmo_egprs/globals.conf ./globals.conf; do
        [ -n "$f" ] && [ -r "$f" ] || continue
        v="$(awk -F= -v k="$k" '$1 == k { gsub(/[" \r\t]/, "", $2); if ($2 != "") print $2 }' "$f" | tail -1)"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    done
    return 1
}

# osmo_ops — identifiants des opérateurs présents, un par ligne, triés.
#   docker : les conteneurs osmo-operator-N en cours.
#   natif  : $OSMO_OP_IDS (posé par services/osmo-egprs-web.service), puis les
#            netns osmo-opN (multi-opérateur natif), puis N_OPERATORS de
#            globals.conf, sinon 1. Aucun inventaire n'existe en natif : la vie
#            d'un nœud se déduit des démons, pas d'une liste de conteneurs.
osmo_ops() {
    local ids=""
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        ids="$(sed -n 's/^osmo-operator-\([0-9][0-9]*\)$/\1/p' <<<"$names")"
    else
        ids="$(tr ', ' '\n\n' <<<"${OSMO_OP_IDS:-}" | sed -n 's/^\([0-9][0-9]*\)$/\1/p')"
        if [ -z "$ids" ]; then
            ids="$(ip netns list 2>/dev/null | awk '{print $1}' \
                   | sed -n "s/^${OSMO_NETNS_PREFIX}\([0-9][0-9]*\)\$/\1/p")"
        fi
        if [ -z "$ids" ]; then
            local n; n="$(_osmo_globals N_OPERATORS || true)"
            case "$n" in ''|*[!0-9]*) n=1 ;; esac
            [ "$n" -ge 1 ] 2>/dev/null || n=1
            ids="$(seq 1 "$n")"
        fi
    fi
    [ -n "$ids" ] || return 0
    sort -n -u <<<"$ids" | sed '/^$/d'
}

# osmo_op_exists <id> — l'opérateur existe-t-il ?
# Remplace « docker ps | grep osmo-operator-N » de global_check.sh:131, dont le
# motif n'était pas ancré : « --op=1 » y acceptait aussi osmo-operator-10.
osmo_op_exists() {
    local want="${1:-}" id
    case "$want" in ''|*[!0-9]*) return 2 ;; esac
    while read -r id; do
        [ "$id" = "$want" ] && return 0
    done <<<"$(osmo_ops)"
    return 1
}

# osmo_node <op> — étiquette du nœud : « osmo-operator-N » ou « osmo-inter-stp ».
# En docker c'est le nom du conteneur ; en natif c'est un NOM D'AFFICHAGE, et
# c'est ce qui préserve mot pour mot la bannière « OPÉRATEUR 1 (osmo-operator-1) »
# et le champ « container= » du dump.
osmo_node() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf 'osmo-inter-stp\n' ;;
        osmo-operator-*)    printf '%s\n' "$1" ;;
        [0-9]*)             printf 'osmo-operator-%s\n' "$1" ;;
        *)                  printf '%s\n' "${1:-}" ;;
    esac
}

# Numéro d'opérateur d'un <op> ; vide pour le hub ou pour l'inconnu.
_osmo_id() {
    case "${1:-}" in
        hub|osmo-inter-stp) printf '' ;;
        osmo-operator-*)    printf '%s\n' "${1##*-}" ;;
        [0-9]*)             printf '%s\n' "$1" ;;
        *)                  printf '' ;;
    esac
}

# osmo_hub — un inter-STP est-il interrogeable ICI ? Écrit son étiquette si oui.
#   docker : le conteneur osmo-inter-stp tourne.
#   natif  : cette machine EST le hub — OSMO_ROLE=interstp dans /etc/osmo-role
#            (posé par build-iso.sh), ou la sonde de start-interstp.sh:100.
# Sur un nœud opérateur natif le hub est une AUTRE machine : rc 1, et c'est
# osmo_hub_hint qui dit quoi faire. Un « 0 AS actif » fabriqué se lirait comme
# une panne.
osmo_hub() {
    if [ "$(osmo_mode)" = docker ]; then
        local names
        names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        grep -x 'osmo-inter-stp' >/dev/null 2>&1 <<<"$names" || return 1
        printf 'osmo-inter-stp\n'; return 0
    fi
    if [ -r /etc/osmo-role ] \
       && grep -E '^OSMO_ROLE[[:space:]]*=[[:space:]]*interstp' /etc/osmo-role >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    if pgrep -f 'osmo-stp .*osmo-stp-interop\.cfg' >/dev/null 2>&1; then
        printf 'osmo-inter-stp\n'; return 0
    fi
    return 1
}

# osmo_hub_ip — adresse du hub. docker : 172.20.0.10. natif : OSMO_HUB_IP de
# /etc/osmo-role (idiome de wan_ss7_check.sh:193). Rien à dire → rc 1.
osmo_hub_ip() {
    if [ "$(osmo_mode)" = docker ]; then
        printf '%s.10\n' "$OSMO_BACKBONE_NET"; return 0
    fi
    local v=""
    [ -r /etc/osmo-role ] && \
        v="$(awk -F= '/^OSMO_HUB_IP=/ { gsub(/[ \r\t]/, "", $2); print $2 }' /etc/osmo-role 2>/dev/null | tail -1)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# osmo_hub_hint — phrase prête pour skip(), quand le hub existe mais est
# ailleurs. Le VTY Osmocom n'écoute que sur 127.0.0.1 (aucune conf du dépôt ne
# pose de « bind » sous « line vty ») : depuis un nœud opérateur, l'état des AS
# et des ASP du hub n'est PAS observable. La commande citée existe déjà.
osmo_hub_hint() {
    local ip
    ip="$(osmo_hub_ip 2>/dev/null || true)"
    if [ -n "$ip" ]; then
        printf 'hub distant %s : VTY 4239 non joignable depuis ce nœud — lancez ./start-interstp.sh --status sur le hub\n' "$ip"
    else
        printf 'aucun inter-STP local, et pas de OSMO_HUB_IP dans /etc/osmo-role — hub non interrogeable depuis ce nœud\n'
    fi
}

# =============================================================================
#  3. EXÉCUTION SUR UN NŒUD
# =============================================================================

# Préfixe netns du mode natif. Vide en mono-opérateur : la dorsale et les
# espaces de noms ne sont créés que si N_OPERATORS > 1.
_osmo_ns_cmd() {
    local id ns
    id="$(_osmo_id "${1:-}")"
    [ -n "$id" ] || return 0
    ns="${OSMO_NETNS_PREFIX}${id}"
    if [ -e "/run/netns/$ns" ] || [ -e "/var/run/netns/$ns" ]; then
        printf 'ip netns exec %s' "$ns"
    fi
}

# osmo_exec <op> <argv…> — substitution 1:1 de « docker exec "$container" … ».
osmo_exec() {
    local op="${1:-}"; shift || return 2
    [ $# -ge 1 ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        local c; c="$(osmo_node "$op")"
        [ -n "$c" ] || return 2
        docker exec "$c" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns doit être découpé en mots (ip netns exec X)
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# Idem, mais l'entrée standard est transmise au nœud (« docker exec -i »).
# Interne : réservé au dialogue VTY, où le tube est l'entrée de nc/telnet.
_osmo_exec_in() {
    local op="${1:-}"; shift || return 2
    if [ "$(osmo_mode)" = docker ]; then
        docker exec -i "$(osmo_node "$op")" "$@"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086
    if [ -n "$ns" ]; then $ns "$@"; else "$@"; fi
}

# osmo_cat <op> <chemin> — contenu d'un fichier du nœud (conf, marqueur…).
osmo_cat() {
    local op="${1:-}" path="${2:-}"
    [ -n "$path" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        docker exec "$(osmo_node "$op")" cat "$path" 2>/dev/null
    else
        cat "${OSMO_NATIVE_ROOT}${path}" 2>/dev/null
    fi
}

# osmo_ast <op> <commande CLI> — asterisk -rx, identique dans les deux mondes.
osmo_ast() {
    local op="${1:-}" cli="${2:-}"
    [ -n "$cli" ] || return 2
    osmo_exec "$op" asterisk -rx "$cli" 2>/dev/null
}

# osmo_running <op> <démon> — ce démon tourne-t-il sur ce nœud ?
#
# En natif il faut les DEUX formes : sur l'ISO les démons sont des units
# (services/osmo-bts-trx.service…) mais core_svc_start retombe sur un lancement
# détaché quand systemd est absent — auquel cas seul pgrep répond.
#
# Le repli « pgrep -f » n'est pas décoratif : /proc/PID/comm est TRONQUÉ à 15
# caractères, donc « pgrep -x osmo-sip-connector » (18) ne trouve jamais rien,
# quand bien même le démon tourne. On retente alors sur la ligne de commande.
#
# Limite assumée du natif multi-opérateur : « ip netns exec » n'isole pas les
# PID, la réponse porte donc sur la machine, pas sur l'opérateur.
osmo_running() {
    local op="${1:-}" name="${2:-}"
    [ -n "$name" ] || return 2
    if [ "$(osmo_mode)" = docker ]; then
        osmo_exec "$op" pgrep -x "$name" >/dev/null 2>&1 && return 0
        osmo_exec "$op" pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
        return $?
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" 2>/dev/null && return 0
    fi
    pgrep -x "$name" >/dev/null 2>&1 && return 0
    pgrep -f "(^|/)${name}([[:space:]]|\$)" >/dev/null 2>&1
}

# osmo_sock <op> <chemin> — socket UNIX en écoute ?
# L'ORDRE EST OBLIGATOIRE : on interroge ss AVANT le test de fichier. Sous
# PrivateTmp, /tmp/msc_mncc EXISTE sans être visible par « test -S » (constaté,
# run_modules/13-msc.sh:14) ; un « test -S » seul donnerait un « voix
# impossible » mensonger.
# awk lit TOUTE son entrée (pas d'« exit » au milieu du tube) : sous pipefail,
# un awk qui sort tôt ferait mourir ss en SIGPIPE et rendrait 141.
osmo_sock() {
    local op="${1:-}" p="${2:-}" out
    [ -n "$p" ] || return 2
    out="$(osmo_exec "$op" ss -xlH 2>/dev/null || true)"
    awk -v w="$p" '{ for (i = 1; i <= NF; i++) if ($i == w) f = 1 } END { exit !f }' <<<"$out" && return 0
    osmo_exec "$op" test -S "$p" 2>/dev/null
}

# osmo_port <op> <port> [tcp|udp|sctp] — ce port est-il en écoute sur le nœud ?
# Remplace le « ss -tlnp | grep -c ':7890' » de global_check.sh:493 : pas de
# tube fragile, et « :7890 » ne peut plus se confondre avec 17890 ou 78901.
osmo_port() {
    local op="${1:-}" port="${2:-}" proto="${3:-tcp}" out
    local -a opts
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    case "$proto" in
        tcp)  opts=(-H -ltn) ;;
        udp)  opts=(-H -lun) ;;
        sctp) opts=(-H -ln --sctp) ;;
        *)    return 2 ;;
    esac
    out="$(osmo_exec "$op" ss "${opts[@]}" 2>/dev/null || true)"
    # Le 4e champ de ss est « adresse:port » local, pour tcp, udp et sctp.
    awk -v want="$port" '
        { a = $4
          if (a == "" || match(a, /:[0-9]+$/) == 0) next
          if (substr(a, RSTART + 1) == want) f = 1 }
        END { exit !f }' <<<"$out"
}

# osmo_host <op> — l'hôte à joindre pour ce nœud DEPUIS ICI (relais SMS, SIP,
# M3UA…). Ce n'est PAS l'hôte du VTY : celui-ci est toujours 127.0.0.1 vu de
# l'intérieur du nœud, et osmo_vty s'en charge.
#   docker           : l'IP du conteneur sur la dorsale (172.20.0.1N, .10 = hub)
#   natif + netns    : la même dorsale, recréée en netns
#   natif mono-op    : 127.0.0.1 — il n'y a ni pont gsm-inter ni 172.20.0.0/24
#   hub natif        : OSMO_HUB_IP de /etc/osmo-role, sinon 127.0.0.1
osmo_host() {
    local op="${1:-}" id
    case "$op" in
        hub|osmo-inter-stp)
            if [ "$(osmo_mode)" = docker ]; then
                printf '%s.10\n' "$OSMO_BACKBONE_NET"
            else
                local h; h="$(osmo_hub_ip 2>/dev/null || true)"
                printf '%s\n' "${h:-127.0.0.1}"
            fi
            return 0 ;;
    esac
    id="$(_osmo_id "$op")"
    if [ -n "$id" ] && { [ "$(osmo_mode)" = docker ] || [ -n "$(_osmo_ns_cmd "$op")" ]; }; then
        printf '%s.%s\n' "$OSMO_BACKBONE_NET" "$((10 + id))"
    else
        printf '127.0.0.1\n'
    fi
}

# =============================================================================
#  4. VTY
# =============================================================================

# Quel client VTY ce nœud possède-t-il ? nc de préférence, telnet en repli.
# L'ISO installe netcat-openbsd ET telnet (build-iso.sh:693) mais PAS socat :
# ne pas s'appuyer sur socat comme le fait core_vty_ask de run_modules/.
# Le diagnostic est écrit UNE FOIS par nœud, sur stderr, pour ne pas polluer la
# sortie du check ni la répéter à chaque commande.
_osmo_vty_tool() {
    local op="${1:-}" key tool
    key="$(osmo_node "$op")"
    tool="${_OSMO_VTY_TOOL[$key]:-}"
    if [ -z "$tool" ]; then
        if osmo_exec "$op" sh -c 'command -v nc' >/dev/null 2>&1; then
            tool=nc
        elif osmo_exec "$op" sh -c 'command -v telnet' >/dev/null 2>&1; then
            tool=telnet
        else
            tool=none
            printf 'checks/_mode.sh : aucun client VTY sur %s — installez netcat-openbsd ou telnet (apt-get install -y netcat-openbsd telnet)\n' \
                   "$key" >&2
        fi
        _OSMO_VTY_TOOL[$key]="$tool"
    fi
    [ "$tool" = none ] && return 1
    printf '%s\n' "$tool"
}

# osmo_vty_up <op> <port> — le VTY répond-il ?
# Remplace les cinq copies de « docker exec … echo >/dev/tcp/127.0.0.1/PORT ».
# En natif on essaie d'abord la sonde PASSIVE (ss) : elle n'ouvre ni ne referme
# de session VTY. Si elle ne voit rien (ss absent, /proc restreint), on retombe
# sur la sonde active — pas de faux négatif.
osmo_vty_up() {
    local op="${1:-}" port="${2:-}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" != docker ] && command -v ss >/dev/null 2>&1; then
        osmo_port "$op" "$port" tcp && return 0
    fi
    osmo_exec "$op" bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null
}

# osmo_vty <op> <port> <commande>… — envoie les commandes au VTY, rend la
# sortie BRUTE sur stdout (bannière et invite comprises : c'est osmo_vty_clean
# qui filtre, et les scripts n'ont pas tous le même filtre).
#
# Rend 1 SANS RIEN ÉCRIRE si le VTY ne répond pas, ou si le nœud n'a ni nc ni
# telnet : c'est le contrat des vty_cmd() actuelles, que les checks utilisent
# pour distinguer « service muet » de « service sans réponse à cette commande ».
# La sonde préalable est celle d'osmo_vty_up (une connexion TCP ouverte puis
# refermée, comme aujourd'hui).
#
# L'appelant fournit ses propres « enable » / « end » : la bibliothèque
# n'invente aucune commande.
#
# LES TEMPORISATIONS SONT DES PARAMÈTRES, par variables d'environnement, parce
# que chaque script a les siennes et que les changer changerait la QUANTITÉ de
# sortie capturée — donc les « grep -c » qui la comptent :
#     OSMO_VTY_OPEN  attente avant d'écrire (0.5 ; ss7_check : 1)
#     OSMO_VTY_READ  attente de lecture     (2   ; ss7_check : 1.5)
#     OSMO_VTY_Q     nc -q<N>               (1   ; vty-debug-dump : 2)
# Le VTY Osmocom ignore ce qui arrive avant la fin de sa négociation telnet :
# ces sleep cadencent le DIALOGUE, ce ne sont pas des barrières d'attente.
osmo_vty() {
    local op="${1:-}" port="${2:-}"
    [ $# -ge 3 ] || return 2
    shift 2
    case "$port" in ''|*[!0-9]*) return 2 ;; esac

    osmo_vty_up "$op" "$port" || return 1

    local body="" c
    for c in "$@"; do body="${body}${c}"$'\n'; done

    local tool
    tool="$(_osmo_vty_tool "$op")" || return 1

    local open="${OSMO_VTY_OPEN:-0.5}" read_s="${OSMO_VTY_READ:-2}" q="${OSMO_VTY_Q:-1}"

    # nc/telnet ferment souvent avant d'avoir tout lu : le sous-shell producteur
    # prend alors un SIGPIPE et le tube rend 141. « || true » garde la fonction
    # utilisable sous « set -euo pipefail ».
    if [ "$tool" = nc ]; then
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" nc "-q${q}" 127.0.0.1 "$port" 2>/dev/null || true
    else
        { sleep "$open"; printf '%s' "$body"; sleep "$read_s"; } \
            | _osmo_exec_in "$op" telnet 127.0.0.1 "$port" 2>/dev/null || true
    fi
    return 0
}

# osmo_vty_clean [motif supplémentaire] — filtre stdin→stdout : retire bannière,
# invite et lignes vides. Le motif de base et L'ORDRE des filtres sont ceux des
# scripts, au caractère près : y toucher changerait leur sortie.
# global_check.sh et ss7_check.sh filtrent en plus « Free Software lives », que
# vty-debug-dump.sh garde — d'où l'argument optionnel :
#     osmo_vty_clean 'Free Software lives'
osmo_vty_clean() {
    local extra="${1:-}"
    local re="^(Trying|Connected|Escape|Welcome|OsmoSTP|OsmoHLR|OsmoMSC|\
OsmoBSC|OsmoBTS|OsmoMGW|OsmoPCU|OsmoSGSN|OsmoGGSN|OsmoSIP|\
VTY server|Use.*help|Press.*tab|[A-Za-z0-9_-]+[#>] |\
Enter password|% Unknown|% Command incomplete|% Error|\
Connection closed)"
    [ -n "$extra" ] && re="${re%)}|${extra})"
    grep -vE "$re" | sed 's/\r//' | grep -v '^[[:space:]]*$' || true
}

# osmo_vty_interactive <op> <port> [hôte] — ouvre une session VTY INTERACTIVE
# (un humain devant le clavier), là où osmo_vty envoie des commandes et rend la
# sortie. Substitution 1:1 de « docker exec -ti <conteneur> telnet <ip> <port> ».
# L'hôte reste un PARAMÈTRE parce que les groupes Baseband écoutent sur
# 127.0.0.1, 127.0.0.2… (tools/vty-menu.sh:79) : c'est la seule cible VTY du
# dépôt qui ne soit pas 127.0.0.1.
osmo_vty_interactive() {
    local op="${1:-}" port="${2:-}" host="${3:-127.0.0.1}"
    case "$port" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$(osmo_mode)" = docker ]; then
        docker exec -ti "$(osmo_node "$op")" telnet "$host" "$port"
        return $?
    fi
    local ns; ns="$(_osmo_ns_cmd "$op")"
    # shellcheck disable=SC2086  # ns doit être découpé en mots (ip netns exec X)
    if [ -n "$ns" ]; then $ns telnet "$host" "$port"; else telnet "$host" "$port"; fi
}

# osmo_vty_target <op> — « cible » à remettre à un client VTY qui N'EST PAS du
# bash et ne peut donc pas sourcer cette bibliothèque.
#
# Le cas existe et il est unique : tools/vty-connect.exp est écrit en expect. La
# bibliothèque ne l'atteindra jamais ; le mode doit donc être décidé côté bash
# (tools/vty-menu.sh) et lui être passé en ARGUMENT. La convention est :
#     docker → le nom du conteneur, qui devient « docker exec -ti <nom> telnet »
#     natif  → « - », qui devient un « telnet » direct
# « - » plutôt que la chaîne vide : une chaîne vide se perd dans un [lindex]
# expect comme dans un "$@" bash, et l'on ne distingue plus « natif » de
# « argument oublié ».
osmo_vty_target() {
    if [ "$(osmo_mode)" = docker ]; then osmo_node "${1:-}"; else printf -- '-\n'; fi
}

# =============================================================================
#  5. CATÉGORIE A — REFUSER PROPREMENT QUAND DOCKER MANQUE
# =============================================================================
#
#  Certains scripts ne se convertissent pas : ils PILOTENT docker par nature —
#  ils construisent une image, créent un réseau 172.20.N.0/24, lancent un
#  conteneur. En natif il n'y a ni image, ni réseau à créer, ni conteneur : le
#  nœud, c'est la machine. Les convertir reviendrait à réécrire start-direct.sh
#  et start-interstp.sh, qui existent déjà — le dépôt a déjà payé ce prix
#  ailleurs (cf. l'en-tête de start-nitb.sh : 4 copies divergentes de
#  si_bridge.py, 3 de gapk-start.sh).
#
#  Ce qui leur manque, c'est un REFUS. build-iso.sh embarque start.sh,
#  build.sh et launch/osmo-launch.sh sur une ISO où build-iso.sh:707 garantit
#  qu'il n'y a PAS de docker : aujourd'hui ces scripts y meurent en 127 sur
#  « docker: command not found », après avoir déjà touché l'hôte, sans nommer
#  l'alternative qui, elle, est installée juste à côté.

# osmo_docker_ok — docker est-il RÉELLEMENT utilisable depuis ici ?
# Le binaire ne suffit pas : une machine de dev l'a souvent sans démon actif, et
# « docker build » y échoue alors sur un message de socket. On interroge le
# démon. Aucun tube : pas de piège pipefail.
osmo_docker_ok() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

# osmo_require_docker [ligne d'alternative…] — refus propre, puis exit 3.
# Rend 0 (et ne dit rien) si docker est utilisable : s'appelle donc en tête de
# script sans condition.
#
# Le message suit le gabarit de launch/start-oqc.sh:41-51, le meilleur du
# dépôt : dire CE QUI MANQUE, POURQUOI ce script ne peut pas s'en passer, et
# SURTOUT quoi lancer à la place, par son nom exact. Sans les alternatives
# fournies en argument, on cite les deux du dépôt.
#
# Sortie sur stderr, code 3 : distinct de 1 (échec d'exécution) et de 2 (mauvais
# argument), pour qu'un appelant puisse reconnaître « mauvais monde » sans lire
# le texte.
osmo_require_docker() {
    osmo_docker_ok && return 0
    {
        printf '\n%s\n\n' "Docker n'est pas utilisable sur cette machine."
        if command -v docker >/dev/null 2>&1; then
            printf '%s\n' "  Le binaire docker est là, mais le démon ne répond pas."
            printf '%s\n' "  → sudo systemctl start docker, puis relancer ce script."
        else
            printf '%s\n' "  La commande docker est absente — c'est le cas normal sur l'ISO,"
            printf '%s\n' "  en VM et sur une machine nue : la pile y est installée en dur."
        fi
        printf '\n%s\n' "Ce script pilote docker (images, réseaux, conteneurs). Il n'a pas"
        printf '%s\n' "d'équivalent natif à écrire : l'équivalent EXISTE DÉJÀ, et il a un nom."
        printf '%s\n\n' "Lancez plutôt :"
        if [ $# -gt 0 ]; then
            local _l; for _l in "$@"; do printf '  %s\n' "$_l"; done
        else
            printf '  %s\n' "./start-direct.sh     — la pile complète de CE nœud (un opérateur)"
            printf '  %s\n' "./start-interstp.sh   — le hub SS7 inter-opérateurs"
        fi
        printf '\n%s\n' "Sur l'ISO ces deux-là sont déjà dans le PATH : osmo-start-direct."
        printf '%s\n\n' "Pour vérifier l'état sans rien démarrer : ./checks/global_check.sh"
    } >&2
    exit 3
}

# =============================================================================
#  6. DIVERS
# =============================================================================

# osmo_qgrep <args…> — « grep -q » sans le piège.
# « cmd | grep -q motif » : grep sort à la PREMIÈRE correspondance, le
# producteur reçoit un SIGPIPE et meurt en 141 — et sous « set -o pipefail »
# c'est 141 que rend le tube. « trouvé » se lit alors « pas trouvé », de façon
# intermittente, selon que la sortie tenait dans le tampon du tube. Ici grep lit
# toute son entrée et on jette sa sortie. Copie conforme de qgrep()
# (network/setup-wan-mesh.sh:69).
osmo_qgrep() { grep "$@" >/dev/null; }

# =============================================================================
#  Exécuté au lieu d'être sourcé : on ne fait rien de destructeur, on affiche
#  ce que la bibliothèque VOIT. Sert de test rapide, et évite qu'un futur
#  « for f in checks/*.sh; do $f; done » ne tombe dans le vide.
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'mode      : %s\n' "$(osmo_mode)"
    printf 'opérateurs: %s\n' "$(osmo_ops | tr '\n' ' ')"
    if hub="$(osmo_hub)"; then
        printf 'inter-STP : %s (interrogeable ici)\n' "$hub"
    else
        printf 'inter-STP : %s\n' "$(osmo_hub_hint)"
    fi
    printf 'hôte op.1 : %s\n' "$(osmo_host 1)"
    exit 0
fi
