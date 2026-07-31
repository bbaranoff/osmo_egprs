# =============================================================================
#  install_modules/_lib/inst.sh — contrat des modules d'installation
# =============================================================================
#
#  Même principe que run_modules/_lib/mod.sh, mais pour l'installation. La
#  différence tient à la nature des étapes : on n'y « démarre » rien, on
#  transforme la machine — donc on veut savoir, pour chacune, si elle est DÉJÀ
#  faite (idempotence) et si elle a RÉUSSI (vérification).
#
#  Quatre fonctions par module, `run` seule obligatoire :
#     inst_<p>_check    prérequis, LECTURE SEULE          0 ok · 1 manque · 4 sans objet
#     inst_<p>_done     déjà installé ?                   0 oui · 1 non
#     inst_<p>_run      fait le travail                   0 ok · 1 échec · 3 déjà fait
#     inst_<p>_verify   contrôle APRÈS coup               0 ok · 1 échec
#
#  `verify` est le pendant de la barrière `wait` côté exécution : installer
#  n'est pas avoir installé. Un `apt-get` qui rend 0 mais laisse un binaire
#  absent doit être vu ici, pas trois étapes plus loin.
# -----------------------------------------------------------------------------

readonly INST_RC_OK=0
readonly INST_RC_FAIL=1
readonly INST_RC_DONE=3
readonly INST_RC_NA=4

declare -a INST_ORDER=()
declare -A INST_DESC=()      # description affichée
declare -A INST_DEPS=()      # étapes prérequises
declare -A INST_REQUIRED=()  # 1 = un échec arrête tout
declare -A INST_ROOT=()      # 1 = exige les droits root
declare -A INST_TIMEOUT=()   # secondes, pour les étapes longues

INST_REGISTER() {
    local slug="$1" desc="$2"
    INST_ORDER+=("$slug")
    INST_DESC[$slug]="$desc"
    INST_DEPS[$slug]=""
    INST_REQUIRED[$slug]=1
    INST_ROOT[$slug]=1
    INST_TIMEOUT[$slug]=1800
}

inst_prefix() { printf 'inst_%s' "${1//-/_}"; }

# --- protocole de message (identique à run_modules) ---------------------------
_INST_REASON=""
_INST_HINT=""
inst_ok()   { _INST_REASON=""   ; return $INST_RC_OK; }
inst_fail() { _INST_REASON="$*" ; return $INST_RC_FAIL; }
inst_done() { _INST_REASON="$*" ; return $INST_RC_DONE; }
inst_na()   { _INST_REASON="$*" ; return $INST_RC_NA; }
inst_hint() { _INST_HINT="$*"; }
inst_say()  { printf '%s\n' "$*"; }

# --- sondes -------------------------------------------------------------------
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
have_dir()  { [ -d "$1" ]; }
have_file() { [ -f "$1" ]; }
have_pkg()  { dpkg -s "$1" >/dev/null 2>&1; }
have_repo() { [ -d "$1/.git" ]; }
