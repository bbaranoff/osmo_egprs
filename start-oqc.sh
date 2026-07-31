#!/bin/bash
# =============================================================================
#  start-oqc.sh — lance qemu-src depuis osmo_egprs
# =============================================================================
#
#  « oqc » = qemu-src, l'émulation Calypso (ARM7 + DSP TMS320C54x).
#  Ce fichier est le raccourci depuis osmo_egprs : il trouve le dépôt et lui
#  passe la main. Toute la logique de lancement vit là-bas, dans run_modules/.
#
#      ./start-oqc.sh                  profil calypso (défaut)
#      ./start-oqc.sh --list           le plan, sans rien lancer
#      ./start-oqc.sh --dry-run        déroule sans effet de bord
#      ./start-oqc.sh --status         où en est chaque étape
#      ./start-oqc.sh --stop           arrête, en ordre inverse
#      ./start-oqc.sh --check-paths    vérifie les dépendances de la machine
#
#  Les variables CALYPSO_* passées en préfixe traversent jusqu'à QEMU :
#      CALYPSO_MODE=native ./start-oqc.sh
#
#  Où est le dépôt : OQC_ROOT, sinon les emplacements habituels sont essayés.
#      OQC_ROOT=~/src/qemu-src ./start-oqc.sh
#
#  À ne pas confondre avec start-direct.sh, qui orchestre TOUTE la pile
#  (cœur Osmocom + radio) et dont le mode « qemu » aboutit également ici.
# -----------------------------------------------------------------------------
set -euo pipefail

_find_oqc() {
    [ -n "${OQC_ROOT:-}" ] && { printf '%s\n' "$OQC_ROOT"; return 0; }
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local c
    for c in "$here/../qemu-src" \
             "${GSM_ROOT:-/opt/GSM}/qemu-src" \
             "$HOME/qemu-src"; do
        [ -x "$c/run.sh" ] && { (cd "$c" && pwd); return 0; }
    done
    return 1
}

if ! OQC="$(_find_oqc)"; then
    cat >&2 <<'ERR'
qemu-src introuvable.

Cherché dans : ../qemu-src, $GSM_ROOT/qemu-src, ~/qemu-src

Indiquez son emplacement :
    OQC_ROOT=/chemin/vers/qemu-src ./start-oqc.sh
ou récupérez-le :
    git clone https://github.com/bbaranoff/qemu qemu-src
ERR
    exit 2
fi

exec "$OQC/run.sh" "$@"
