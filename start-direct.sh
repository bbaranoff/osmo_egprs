#!/bin/bash
# =============================================================================
# start-direct.sh — Prépare l'environnement Calypso puis lance run.sh
# =============================================================================
#
# Ce script ne démarre aucun démon.
#
# Il :
#   1. charge l'environnement ;
#   2. détecte le matériel / les binaires ;
#   3. choisit le mode (profil) ;
#   4. génère les fichiers mobile_*.cfg ;
#   5. exporte les variables nécessaires ;
#   6. exécute run.sh.
#
# Toute la logique GSM vit ensuite dans run.sh (et run_modules/).
#
# CHAÎNE DE CONFIGURATION — NE PAS LA CASSER
#     VAR=x ./start-direct.sh   ← la ligne de commande gagne toujours
#       -> environment/load.env
#          -> paths / modes / domaines
#     puis exec run.sh avec le profil choisi.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
# --- options ------------------------------------------------------------------
DRY=0 VERBOSE=0 ACTION=start PROFILE="${CALYPSO_PROFILE:-faketrx-qemu}" FORCE=0
LIST=0
usage() {
    cat <<'USAGE'
Usage : ./start-direct.sh [options] [mode]
  Modes (profils) :
    faketrx-qemu   cœur + BTS#0 QEMU + BTS#1 faketrx (défaut)
    faketrx        cœur + fake_trx + trxcon + mobile
    qemu           pipeline Calypso QEMU seul
    virtphy        cœur + osmo-bts-virtual + virtphy
    noproc         cœur seul (no-process)
    core           alias noproc
    hybrid         alias faketrx-qemu
    hw             SDR physique
  Options :
    --list              affiche le plan (délègue à run.sh --list)
    --dry-run           déroule sans effet de bord
    --profile <nom>     force le profil
    --stop              arrête la pile (délègue à run.sh --stop)
    --status            interroge l'état (délègue à run.sh --status)
    --force             relance même les modules déjà démarrés
    --verbose           montre la sortie des modules
    --check-paths       vérifie les dépendances déclarées
    -h, --help          cette aide
Toute variable CALYPSO_* passée en préfixe est transmise à run.sh / QEMU :
  CALYPSO_MODE=native ./start-direct.sh
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --list)        ACTION=list ;;
        --dry-run)     DRY=1 ;;
        --profile)     PROFILE="${2:-}"; shift ;;
        --stop)        ACTION=stop ;;
        --status)      ACTION=status ;;
        --force)       FORCE=1 ;;
        --verbose)     VERBOSE=1 ;;
        --check-paths) ACTION=checkpaths ;;
        -h|--help)     usage; exit 0 ;;
        faketrx-qemu|faketrx|qemu|virtphy|noproc|core|hybrid|hw)
            PROFILE="$1"
            [ "$PROFILE" = "hybrid" ] && PROFILE=faketrx-qemu
            [ "$PROFILE" = "core" ]   && PROFILE=noproc
            ;;
        *) printf 'option inconnue : %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
# --- affichage (identique à run.sh) -------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    TTY=1
    C_OK=$'\033[32m'; C_KO=$'\033[31m'; C_SK=$'\033[33m'
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_Z=$'\033[0m'
else
    TTY=0
    C_OK=""; C_KO=""; C_SK=""; C_DIM=""; C_CYAN=""; C_BOLD=""; C_Z=""
fi
say_begin() {
    if [ $TTY -eq 1 ]; then
        printf '[ %s.. %s] %s' "$C_DIM" "$C_Z" "$1"
    else
        printf '[ .. ] %s\n' "$1"
    fi
}
say_end() { # $1=tag $2=couleur $3=libellé $4=détail
    if [ $TTY -eq 1 ]; then printf '\r\033[K'; fi
    printf '[%s%s%s] %s' "$2" "$1" "$C_Z" "$3"
    [ -n "${4:-}" ] && printf ' %s(%s)%s' "$C_DIM" "$4" "$C_Z"
    printf '\n'
}
banner() {
    echo -e "${C_CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Calypso GSM — bootstrap → run.sh (natif, no-docker) ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${C_Z}"
}
# --- 1. configuration ---------------------------------------------------------
# [2026-08-03] globals.conf — les reglages reseau (MCC/MNC/ARFCN/KI/IMSI/A5...).
# Genere par ./generate_configs.sh cote hote ; ici on se contente de le lire.
# L'idiome « := » qu'il utilise laisse gagner toute variable deja posee, donc
#     ARFCN=520 ./start-direct.sh
# surcharge sans toucher au fichier.
[ -r "$HERE/globals.conf" ] && { set -a; . "$HERE/globals.conf"; set +a; }

say_begin "Chargement de l'environnement"
if [ -f "$HERE/environment/load.env" ]; then
    set -a; . "$HERE/environment/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "environment/load.env"
elif [ -f "$HERE/env/load.env" ]; then
    set -a; . "$HERE/env/load.env"; set +a
    say_end " OK " "$C_OK" "Chargement de l'environnement" "env/load.env"
else
    # Fallback minimal (chemins typiques du dépôt)
    : "${GSM_ROOT:=/opt/GSM}"
    : "${NITB_TREE:=$HERE}"
    if [ -x "$HERE/run.sh" ]; then
        : "${OQC_ROOT:=$HERE}"
    elif [ -x "$HERE/../qemu-src/run.sh" ]; then
        : "${OQC_ROOT:=$(cd "$HERE/../qemu-src" && pwd)}"
    else
        : "${OQC_ROOT:=$GSM_ROOT/qemu-src}"
    fi
    say_end " OK " "$C_OK" "Chargement de l'environnement" "fallback minimal"
fi
: "${RUN_DIR:=/run/osmo-direct}"
# Repli si load.env est absent. Les journaux restent sous RUN_DIR (tmpfs) :
# le défilement tmux en dépend — cf. environment/paths.env.
: "${LOG_DIR:=$RUN_DIR/logs}"
: "${ENCRYPTION:=a5 0}"
: "${MS_COUNT:=2}"
: "${HOST_IP:=127.0.0.1}"
mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb 2>/dev/null || true
# --- 2. détection des chemins / binaires --------------------------------------
say_begin "Résolution de run.sh"
# Forcer explicitement le chemin demandé
RUN_SH="/opt/GSM/qemu-src/run.sh"
# Vérifier que le fichier existe et est exécutable
if [ ! -x "$RUN_SH" ]; then
    say_end "FAIL" "$C_KO" "Résolution de run.sh" "$RUN_SH introuvable ou non exécutable"
    printf '       %s→ Vérifiez que /opt/GSM/qemu-src/run.sh existe et est exécutable%s\n' "$C_DIM" "$C_Z"
    exit 1
fi
say_end " OK " "$C_OK" "Résolution de run.sh" "$RUN_SH"
RUN_ROOT="$(dirname "$RUN_SH")"
# Profil → mapping vers les profils attendus par run.sh
case "$PROFILE" in
    faketrx-qemu|hybrid) CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu ;;
    faketrx)             CALYPSO_PROFILE=faketrx;  MODE=faketrx ;;
    qemu)                CALYPSO_PROFILE=calypso;  MODE=qemu ;;
    virtphy)             CALYPSO_PROFILE=faketrx;  MODE=virtphy; PHY_MODE=virtphy ;;
    noproc|core)         CALYPSO_PROFILE=core;     MODE=noproc; RUN_NO_PROCESS=1 ;;
    hw)                  CALYPSO_PROFILE=faketrx;  MODE=hw; PHY_MODE=trx ;;
    *)                   CALYPSO_PROFILE=hybrid;   MODE=faketrx-qemu; PROFILE=faketrx-qemu ;;
esac
export CALYPSO_PROFILE MODE
export PHY_MODE="${PHY_MODE:-faketrx}"
export RUN_NO_PROCESS="${RUN_NO_PROCESS:-0}"
export ENCRYPTION MS_COUNT HOST_IP
export LOG_DIR RUN_DIR
# --- 3. validation des chemins critiques --------------------------------------
say_begin "Validation des chemins"
path_ok=1
_check() {
    local name="$1" val="${!1:-}"
    if [ -z "$val" ]; then
        printf '\n       %s%s non défini%s\n' "$C_DIM" "$name" "$C_Z"
        path_ok=0
    elif [ -e "$val" ]; then
        :
    else
        printf '\n       %s%s introuvable : %s%s\n' "$C_DIM" "$name" "$val" "$C_Z"
        path_ok=0
    fi
}
# Variables optionnelles selon le profil ; on ne bloque que si présentes et cassées
for v in QEMU_BIN FIRMWARE_ELF DSP_PROM0 OSMOCON; do
    [ -n "${!v:-}" ] && _check "$v" || true
done
if [ $path_ok -eq 1 ]; then
    say_end " OK " "$C_OK" "Validation des chemins"
else
    say_end "WARN" "$C_SK" "Validation des chemins" "certains chemins manquent (run.sh vérifiera)"
fi
# --- 4. génération des configs mobile -----------------------------------------
# MS#1 (QEMU / mobile principal) et MS#2 (faketrx side-car) pour le profil hybrid.
BB_DIR="/root/.osmocom/bb"
mkdir -p "$BB_DIR"
# Sources possibles pour le template mobile
MS_TEMPLATE=""
for t in \
    "${OQC_ROOT:-}/cfgs/mobile_group1.cfg" \
    "$RUN_ROOT/cfgs/mobile_group1.cfg" \
    "$HERE/configs/mobile.cfg.template" \
    "$HERE/configs/mobile.cfg" \
    "$BB_DIR/mobile_group1.cfg" \
    "$BB_DIR/mobile.cfg"
do
    if [ -f "$t" ]; then MS_TEMPLATE="$t"; break; fi
done
generate_mobile_cfg() {
    local dest="$1" vty_port="$2" l2sock="$3" sapsock="$4" arfcn="$5" imsi="$6" ki="$7"
    if [ -n "$MS_TEMPLATE" ]; then
        sed \
            -e "s|bind 127.0.0.1 424[0-9]|bind 127.0.0.1 ${vty_port}|" \
            -e "s|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket ${l2sock}|" \
            -e "s|sap-socket /tmp/osmocom_sap[_0-9]*|sap-socket ${sapsock}|" \
            -e "s|stick [0-9]*|stick ${arfcn}|" \
            -e "s|imsi [0-9]*|imsi ${imsi}|" \
            -e "s|ki comp128 [0-9a-f ]*|ki comp128 ${ki}|" \
            "$MS_TEMPLATE" > "$dest"
    else
        # Template minimal de secours
        cat > "$dest" <<EOF
!
! mobile.cfg généré par start-direct.sh (secours)
!
log stderr
 logging color 1
 logging print category 1
 logging timestamp 0
!
line vty
 no login
 bind 127.0.0.1 ${vty_port}
!
ms 1
 layer2-socket ${l2sock}
 sap-socket ${sapsock}
 sim reader
 imsi ${imsi}
 ki comp128 ${ki}
 network-selection-mode auto
 stick ${arfcn}
!
EOF
    fi
}
say_begin "Génération mobile MS#1"
MS1_CFG="$BB_DIR/mobile.cfg"
generate_mobile_cfg "$MS1_CFG" \
    4247 \
    /tmp/osmocom_l2 \
    /tmp/osmocom_sap_1 \
    514 \
    "001010001000001" \
    "00 11 22 33 44 55 66 77 88 99 aa bb cc dd 01 01"
say_end " OK " "$C_OK" "Génération mobile MS#1" "$MS1_CFG"
say_begin "Génération mobile MS#2 (faketrx)"
MS2_CFG="$BB_DIR/mobile_faketrx_bts1.cfg"
generate_mobile_cfg "$MS2_CFG" \
    4248 \
    /tmp/ms2_l2 \
    /tmp/ms2_sap \
    516 \
    "001010001000002" \
    "00 11 22 33 44 55 66 77 88 99 aa bb cc dd 02 01"
say_end " OK " "$C_OK" "Génération mobile MS#2 (faketrx)" "$MS2_CFG"
# Export pour que les modules run.sh / hybrid puissent les retrouver
export MOBILE_CFG_MS1="$MS1_CFG"
export MOBILE_CFG_MS2="$MS2_CFG"
export CALYPSO_MS2_CFG="$MS2_CFG"
# --- 5. exports supplémentaires pour le profil hybrid -------------------------
if [ "$MODE" = "faketrx-qemu" ] || [ "$CALYPSO_PROFILE" = "hybrid" ]; then
    export QEMU_ATTACH_TRX="${QEMU_ATTACH_TRX:-0}"
    export NO_LOCAL_BTS="${NO_LOCAL_BTS:-0}"
    export NO_LOCAL_TRX="${NO_LOCAL_TRX:-0}"
    export TRX_BASE_PORT="${TRX_BASE_PORT:-6700}"
    export TRX_BIND="${TRX_BIND:-127.0.0.1}"
    export BTS1_UNIT_ID=6002
    export BTS1_ARFCN=516
    export BTS0_ARFCN=514
fi
# --- 6. résumé ----------------------------------------------------------------
banner
printf '  %sprofil%s     %s (%s)\n' "$C_DIM" "$C_Z" "$CALYPSO_PROFILE" "$MODE"
printf '  %srun.sh%s     %s\n' "$C_DIM" "$C_Z" "$RUN_SH"
printf '  %sMS#1%s       %s  IMSI 001010001000001  ARFCN 514  VTY 4247\n' "$C_DIM" "$C_Z" "$MS1_CFG"
printf '  %sMS#2%s       %s  IMSI 001010001000002  ARFCN 516  VTY 4248\n' "$C_DIM" "$C_Z" "$MS2_CFG"
printf '  %sjournaux%s   %s\n' "$C_DIM" "$C_Z" "$LOG_DIR"
printf '  %schiffrement%s %s\n' "$C_DIM" "$C_Z" "$ENCRYPTION"
printf '\n'
# --- 7. actions déléguées à run.sh --------------------------------------------
RUN_ARGS=()
[ "$DRY" -eq 1 ]     && RUN_ARGS+=(--dry-run)
[ "$FORCE" -eq 1 ]   && RUN_ARGS+=(--force)
[ "$VERBOSE" -eq 1 ] && RUN_ARGS+=(--verbose)
RUN_ARGS+=(--profile "$CALYPSO_PROFILE")
case "$ACTION" in
    list)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --list "${RUN_ARGS[@]}"
        ;;
    stop)
        say_begin "Arrêt de la pile via run.sh"
        bash "$RUN_SH" --stop --profile "$CALYPSO_PROFILE"
        say_end " OK " "$C_OK" "Arrêt de la pile via run.sh"
        exit 0
        ;;
    status)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --status --profile "$CALYPSO_PROFILE"
        ;;
    checkpaths)
        exec env CALYPSO_PROFILE="$CALYPSO_PROFILE" bash "$RUN_SH" --check-paths
        ;;
esac
# --- 8. lancement : exec run.sh -----------------------------------------------
say_begin "Transmission à run.sh"
if [ $DRY -eq 1 ]; then
    say_end " -- " "$C_DIM" "Transmission à run.sh" "dry-run"
    printf '  commande : CALYPSO_PROFILE=%s bash %s %s\n' \
        "$CALYPSO_PROFILE" "$RUN_SH" "${RUN_ARGS[*]}"
    exit 0
fi
say_end " OK " "$C_OK" "Transmission à run.sh" "profil=$CALYPSO_PROFILE"
# Hand-off total : ce processus devient run.sh
exec bash /opt/GSM/qemu-src/run.sh "${RUN_ARGS[@]}" --restart
