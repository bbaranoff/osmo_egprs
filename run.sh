#!/bin/bash
# =============================================================================
#  run.sh — point d'entrée unique de la pile GSM (Calypso QEMU + Osmocom)
# =============================================================================
#
#  CE FICHIER EST COURT, ET C'EST VOULU.
#  L'ancien run.sh (2426 lignes, conservé en run.sh.legacy) mélangeait le menu,
#  la résolution de configuration, le lancement de vingt processus et la mise en
#  page tmux. Un échec au milieu — osmocon absent, BTS sans horloge, mobile
#  jamais démarré — n'apparaissait nulle part : le script continuait.
#
#  Ici run.sh ne fait plus que quatre choses :
#    1. lire les options ;
#    2. charger la configuration (environnement/load.env) ;
#    3. construire un PLAN à partir de run_modules/ ;
#    4. l'exécuter en affichant un état par étape, et rendre un code de sortie.
#
#  Toute la logique métier vit dans run_modules/NN-<slug>.sh, un module par
#  étape, tous conformes au contrat décrit dans run_modules/_lib/mod.sh.
#
#  CHAÎNE DE CONFIGURATION — NE PAS LA CASSER
#      VAR=x ./run.sh          ← la ligne de commande gagne toujours
#        -> environnement/load.env  (sourcé `set -a`, donc exporté vers QEMU)
#           -> paths / modes / domaines / debug / fixes / crutches / hérité
#  Vérifier ce qui s'applique réellement : grep "calypso-manifest" sur le log.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODDIR="$HERE/run_modules"

# --- options ------------------------------------------------------------------
DRY=0 ONLY="" SKIP="" VERBOSE=0 ACTION=start PROFILE="${CALYPSO_PROFILE:-calypso}" FORCE=0

usage() {
    cat <<'USAGE'
Usage : ./run.sh [options]

  --list              affiche le plan et sort, sans rien lancer
  --dry-run           déroule le plan sans effet de bord
  --only  <slugs>     ne joue que ces modules (séparés par des virgules)
  --skip  <slugs>     saute ces modules
  --profile <nom>     calypso (défaut) | faketrx | hybrid | core
  --stop              arrête la pile (plan en ordre inverse)
  --status            interroge l'état de chaque module
  --force             relance même les modules déjà démarrés
  --verbose           montre la sortie des modules
  --check-paths       vérifie que les dépendances déclarées existent
  -h, --help          cette aide

Toute variable CALYPSO_* passée en préfixe est transmise à QEMU :
  CALYPSO_MODE=native ./run.sh
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION=list ;;
        --dry-run)     DRY=1 ;;
        --only)        ONLY="${2:-}"; shift ;;
        --skip)        SKIP="${2:-}"; shift ;;
        --profile)     PROFILE="${2:-}"; shift ;;
        --stop)        ACTION=stop ;;
        --status)      ACTION=status ;;
        --force)       FORCE=1 ;;
        --verbose)     VERBOSE=1 ;;
        --check-paths) ACTION=checkpaths ;;
        -h|--help)     usage; exit 0 ;;
        *) printf 'option inconnue : %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- configuration ------------------------------------------------------------
if [ -f "$HERE/environnement/load.env" ]; then
    set -a; . "$HERE/environnement/load.env"; set +a
else
    printf 'configuration introuvable : %s\n' "$HERE/environnement/load.env" >&2
    exit 2
fi
LOGDIR="${LOG_DIR:-/root/calypso/logs}"
mkdir -p "$LOGDIR/mod" 2>/dev/null || true

# --- affichage ----------------------------------------------------------------
# En TTY on réécrit la ligne « [ .. ] » en place ; sinon on imprime deux lignes,
# pour qu'un fichier de log ou un pipe reste lisible (pas de \r parasite).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1; C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'; C_DIM=$'\033[2m'; C_Z=$'\033[0m'
else
    TTY=0; C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_Z=""
fi

say_begin() { if [ $TTY -eq 1 ]; then printf '[ %s.. %s] %s' "$C_DIM" "$C_Z" "$1"; else printf '[ .. ] %s\n' "$1"; fi; }
say_end()   { # $1=tag $2=couleur $3=libellé $4=détail
    if [ $TTY -eq 1 ]; then printf '\r\033[K'; fi
    printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
    [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"
    printf '\n'
}

# --- découverte des modules ---------------------------------------------------
. "$MODDIR/_lib/mod.sh"
shopt -s nullglob
for f in "$MODDIR"/[0-9][0-9]-*.sh; do . "$f"; done
shopt -u nullglob

if [ ${#MOD_ORDER[@]} -eq 0 ]; then
    printf 'aucun module dans %s — rien à faire\n' "$MODDIR" >&2
    exit 2
fi

# --- sélection ----------------------------------------------------------------
in_csv() { case ",$1," in *",$2,"*) return 0;; esac; return 1; }
selected=()
for m in "${MOD_ORDER[@]}"; do
    [ -n "$ONLY" ] && { in_csv "$ONLY" "$m" || continue; }
    [ -n "$SKIP" ] && { in_csv "$SKIP" "$m" && continue; }
    case " ${MOD_PROFILES[$m]} " in *" $PROFILE "*) ;; *) continue;; esac
    selected+=("$m")
done

# --- actions simples ----------------------------------------------------------
if [ "$ACTION" = list ]; then
    printf 'Plan — profil %s, %d modules\n\n' "$PROFILE" "${#selected[@]}"
    for m in "${selected[@]}"; do
        printf '  %-18s %-42s %s%s\n' "$m" "${MOD_DESC[$m]}" \
            "$([ "${MOD_REQUIRED[$m]}" = 1 ] && echo obligatoire || echo optionnel)" \
            "$([ -n "${MOD_DEPS[$m]}" ] && echo "  après: ${MOD_DEPS[$m]}")"
    done
    exit 0
fi

if [ "$ACTION" = checkpaths ]; then
    rc=0
    for v in QEMU_BIN FIRMWARE_ELF DSP_PROM0 OSMOCON OSMOCOM_CFG; do
        p="${!v:-}"
        if [ -z "$p" ];      then say_end FAIL "$C_KO" "$v" "non défini"; rc=1
        elif [ -e "$p" ];    then say_end " OK " "$C_OK" "$v" "$p"
        else                      say_end FAIL "$C_KO" "$v" "introuvable : $p"; rc=1; fi
    done
    exit $rc
fi

# --- exécution ----------------------------------------------------------------
declare -A STATE=()
nb_ok=0 nb_fail=0 nb_skip=0 nb_warn=0
[ "$ACTION" = stop ] && { tmp=(); for ((i=${#selected[@]}-1;i>=0;i--)); do tmp+=("${selected[$i]}"); done; selected=("${tmp[@]}"); }

for m in "${selected[@]}"; do
    p="$(mod_prefix "$m")"
    log="${MOD_LOG[$m]:-$LOGDIR/mod/$m.log}"
    _MOD_REASON=""; _MOD_HINT=""

    if [ "$ACTION" = stop ]; then
        say_begin "Arrêt de ${MOD_DESC[$m]}"
        declare -F "${p}_stop" >/dev/null && "${p}_stop" >>"$log" 2>&1
        say_end " OK " "$C_OK" "Arrêt de ${MOD_DESC[$m]}"
        continue
    fi

    if [ "$ACTION" = status ]; then
        if declare -F "${p}_status" >/dev/null && "${p}_status" >>"$log" 2>&1; then
            say_end " UP " "$C_OK" "${MOD_DESC[$m]}"
        else
            say_end "DOWN" "$C_SK" "${MOD_DESC[$m]}"
        fi
        continue
    fi

    # 1. porte d'activation
    if ! eval "${MOD_ENABLED_IF[$m]}" 2>/dev/null; then
        say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "désactivé par ${MOD_ENABLED_IF[$m]}"
        STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue
    fi

    # 2. dépendances
    dep_ko=""
    for d in ${MOD_DEPS[$m]}; do
        case "${STATE[$d]:-absent}" in ok|skip) ;; *) dep_ko="$d"; break;; esac
    done
    if [ -n "$dep_ko" ]; then
        say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "dépendance non satisfaite : $dep_ko"
        STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue
    fi

    say_begin "${MOD_DESC[$m]}"

    # 3. déjà démarré ?
    if [ $FORCE -eq 0 ] && declare -F "${p}_status" >/dev/null && "${p}_status" >>"$log" 2>&1; then
        say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "déjà démarré"
        STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue
    fi

    # 4. prérequis
    if declare -F "${p}_check" >/dev/null; then
        "${p}_check" >>"$log" 2>&1; rc=$?
        if [ $rc -eq $MOD_RC_FAIL ]; then
            say_end "FAIL" "$C_KO" "${MOD_DESC[$m]}" "${_MOD_REASON:-raison non fournie par le module}"
            [ -n "$_MOD_HINT" ] && printf '       %s→ %s%s\n' "$C_DIM" "$_MOD_HINT" "$C_Z"
            printf '       %slog : %s%s\n' "$C_DIM" "$log" "$C_Z"
            STATE[$m]=fail; nb_fail=$((nb_fail+1))
            [ "${MOD_REQUIRED[$m]}" = 1 ] && { printf '\nséquence interrompue (module obligatoire)\n'; exit 1; }
            nb_warn=$((nb_warn+1)); continue
        elif [ $rc -eq $MOD_RC_SKIP ]; then
            say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "${_MOD_REASON:-}"
            STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue
        fi
    fi

    # 5. simulation
    if [ $DRY -eq 1 ] && [ "${MOD_PURE[$m]}" != 1 ]; then
        say_end " -- " "$C_DIM" "${MOD_DESC[$m]}" "simulé"
        STATE[$m]=ok; continue
    fi

    # 6. lancement
    "${p}_start" >>"$log" 2>&1; rc=$?
    case $rc in
        $MOD_RC_ALREADY) say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "${_MOD_REASON:-déjà démarré}"
                         STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue ;;
        $MOD_RC_SKIP)    say_end "SKIP" "$C_SK" "${MOD_DESC[$m]}" "${_MOD_REASON:-}"
                         STATE[$m]=skip; nb_skip=$((nb_skip+1)); continue ;;
        $MOD_RC_FAIL)    say_end "FAIL" "$C_KO" "${MOD_DESC[$m]}" "${_MOD_REASON:-raison non fournie par le module}"
                         [ -n "$_MOD_HINT" ] && printf '       %s→ %s%s\n' "$C_DIM" "$_MOD_HINT" "$C_Z"
                         printf '       %slog : %s%s\n' "$C_DIM" "$log" "$C_Z"
                         STATE[$m]=fail; nb_fail=$((nb_fail+1))
                         [ "${MOD_REQUIRED[$m]}" = 1 ] && { printf '\nséquence interrompue (module obligatoire)\n'; exit 1; }
                         nb_warn=$((nb_warn+1)); continue ;;
    esac

    # 7. barrière : démarré, mais prêt ?
    if declare -F "${p}_wait" >/dev/null; then
        if ! "${p}_wait" >>"$log" 2>&1; then
            say_end "FAIL" "$C_KO" "${MOD_DESC[$m]}" "démarré mais jamais prêt : ${_MOD_REASON:-délai dépassé}"
            printf '       %slog : %s%s\n' "$C_DIM" "$log" "$C_Z"
            STATE[$m]=fail; nb_fail=$((nb_fail+1))
            [ "${MOD_REQUIRED[$m]}" = 1 ] && { printf '\nséquence interrompue (module obligatoire)\n'; exit 1; }
            nb_warn=$((nb_warn+1)); continue
        fi
    fi

    say_end " OK " "$C_OK" "${MOD_DESC[$m]}"
    STATE[$m]=ok; nb_ok=$((nb_ok+1))
done

printf '\n%d ok · %d ignorés · %d échecs\n' "$nb_ok" "$nb_skip" "$nb_fail"

# --- épilogue : où est passée la pile, et comment la reprendre en main ---------
# Le moteur rend la main au lieu de s'attacher lui-même à tmux : on peut donc
# l'utiliser dans un script ou une CI. Mais il faut dire à l'opérateur où aller.
if [ "$ACTION" = start ] && [ $DRY -eq 0 ] && [ $nb_fail -eq 0 ]; then
    _sess="${TMUX_SESSION:-calypso}"
    printf '\n'
    if tmux has-session -t "$_sess" 2>/dev/null; then
        printf '  %sse connecter%s   tmux attach -t %s\n' "$C_OK" "$C_Z" "$_sess"
    else
        printf '  %sse connecter%s   (aucune session tmux « %s » — la pile tourne en arrière-plan)\n' \
               "$C_DIM" "$C_Z" "$_sess"
    fi
    printf '  %sjournaux%s       %s\n'        "$C_DIM" "$C_Z" "$LOGDIR"
    printf '  %sétat%s           ./run.sh --status\n' "$C_DIM" "$C_Z"
    printf '  %sarrêter%s        ./run.sh --stop\n'   "$C_DIM" "$C_Z"
    printf '\n'
fi

[ $nb_fail -gt 0 ] && exit 1
exit 0
