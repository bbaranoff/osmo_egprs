# =============================================================================
#  run_modules/_lib/mod.sh — bibliothèque du contrat de module
# =============================================================================
#
#  Sourcé par run.sh AVANT les modules. Fournit :
#    - le registre déclaratif (MOD_REGISTER + tableaux associatifs) ;
#    - les helpers de message (mod_ok / mod_fail / mod_skip / …) ;
#    - les codes de retour normalisés ;
#    - la barrière d'attente wait_until, qui remplace les `sleep` aveugles.
#
#  POURQUOI CE DÉCOUPAGE. L'ancien run.sh enchaînait 20 lancements sans jamais
#  vérifier qu'ils avaient abouti : un service absent ne se voyait nulle part, le
#  script continuait. Séparer `start` (lancer) de `wait` (attendre un critère
#  OBSERVABLE) distingue « n'a pas démarré » de « démarré mais jamais prêt » —
#  c'est le trou de diagnostic qu'on cherchait à combler.
# -----------------------------------------------------------------------------

# --- codes de retour, communs à toutes les fonctions de module ---------------
readonly MOD_RC_OK=0        # succès
readonly MOD_RC_FAIL=1      # échec
readonly MOD_RC_UNKNOWN=2   # indéterminable (status seulement)
readonly MOD_RC_ALREADY=3   # déjà démarré
readonly MOD_RC_SKIP=4      # à ignorer légitimement

# --- registre déclaratif ------------------------------------------------------
declare -a MOD_ORDER=()          # slugs, dans l'ordre de découverte (= ordre des fichiers)
declare -A MOD_DESC=()           # description humaine, affichée à l'écran
declare -A MOD_DEPS=()           # slugs prérequis, séparés par des espaces
declare -A MOD_REQUIRED=()       # 1 = un échec arrête tout ; 0 = WARN et on continue
declare -A MOD_PROFILES=()       # profils qui incluent ce module
declare -A MOD_LOG=()            # chemin de log ("" = $LOGDIR/mod/<slug>.log)
declare -A MOD_JOURNAL=()        # unité systemd, pour afficher son journal en cas d'échec
declare -A MOD_PURE=()           # 1 = aucun effet de bord -> exécuté même en --dry-run
declare -A MOD_ENABLED_IF=()     # expression shell, évaluée juste avant exécution
declare -A MOD_TIMEOUT=()        # secondes, pour la barrière wait

# MOD_REGISTER <slug> <description>
# Pose les valeurs par défaut ; le module n'a à surcharger que ce qui diffère.
MOD_REGISTER() {
    local slug="$1" desc="$2"
    MOD_ORDER+=("$slug")
    MOD_DESC[$slug]="$desc"
    MOD_DEPS[$slug]=""
    MOD_REQUIRED[$slug]=1
    MOD_PROFILES[$slug]="calypso"
    MOD_LOG[$slug]=""
    MOD_JOURNAL[$slug]=""
    MOD_PURE[$slug]=0
    MOD_ENABLED_IF[$slug]='true'
    MOD_TIMEOUT[$slug]=30
}

# Préfixe de fonction : slug avec les tirets remplacés par des underscores.
mod_prefix() { printf 'mod_%s' "${1//-/_}"; }

# --- protocole de message -----------------------------------------------------
# Les modules n'écrivent JAMAIS sur la console : run.sh redirige leur sortie vers
# leur log. Pour parler à l'opérateur, ils posent une raison via ces helpers.
_MOD_REASON=""
_MOD_HINT=""

mod_ok()      { _MOD_REASON=""   ; return $MOD_RC_OK; }
mod_fail()    { _MOD_REASON="$*" ; return $MOD_RC_FAIL; }
mod_already() { _MOD_REASON="$*" ; return $MOD_RC_ALREADY; }
mod_skip()    { _MOD_REASON="$*" ; return $MOD_RC_SKIP; }
mod_hint()    { _MOD_HINT="$*"; }
mod_say()     { printf '%s\n' "$*"; }   # va dans le log du module

# --- barrière d'attente -------------------------------------------------------
# wait_until <timeout_s> <description> <commande...>
# Sonde la commande jusqu'à ce qu'elle réussisse, ou échoue au bout du délai.
# Remplace les `sleep N` : on attend un CRITÈRE, pas une durée.
wait_until() {
    local timeout="$1" what="$2"; shift 2
    local deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        if "$@" >/dev/null 2>&1; then return $MOD_RC_OK; fi
        sleep 0.2
    done
    mod_fail "$what : toujours pas prêt après ${timeout}s"
}

# --- sondes réutilisables par les modules ------------------------------------
have_proc()  { pgrep -f "$1" >/dev/null 2>&1; }
have_port()  { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
have_unix()  { [ -S "$1" ]; }
log_has()    { [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; }
