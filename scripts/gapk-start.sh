#!/bin/bash
# gapk-start.sh — Gestionnaire de sessions osmo-gapk (GSM Audio Pocket Knife)
#
# osmo-gapk est le composant Osmocom qui relie l'audio d'un appel GSM à ALSA.
# Il encode/décode les codecs GSM (FR, EFR, HR, AMR) entre un flux RTP
# (OsmoMGW) et la carte son locale.
#
# ══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE
# ══════════════════════════════════════════════════════════════════════════════
#
#   Micro ALSA ──[PCM 8kHz]──► gapk-TX ──[GSM FR trames]──► RTP ──► OsmoMGW
#   OsmoMGW ──► RTP ──[GSM FR trames]──► gapk-RX ──[PCM 8kHz]──► HP ALSA
#
#   Les ports RTP sont alloués par OsmoMGW pour chaque endpoint actif.
#   gapk-start.sh utilise les ports 17000–17009 (hors plage MGW 4002–16001).
#
# ══════════════════════════════════════════════════════════════════════════════
# TROUVER LES PORTS RTP OSMOMGW
# ══════════════════════════════════════════════════════════════════════════════
#
#   telnet 127.0.0.1 4243
#   OsmoMGW> show mgcp
#
#   Chaque ligne "endpoint" affiche le port RTP local alloué.
#   Utiliser ce port comme RTP_RX_PORT (downlink) et RTP_TX_DEST (uplink).
#
# ══════════════════════════════════════════════════════════════════════════════
# MODES
# ══════════════════════════════════════════════════════════════════════════════
#
#   call      Appel bidirectionnel ALSA ↔ RTP (RX + TX en background)
#   monitor   Écoute passive RTP → ALSA (foreground)
#   record    Enregistre flux RTP → fichier .gsm (foreground)
#   playback  Injecte fichier .gsm → flux RTP (foreground)
#   loopback  Loopback ALSA micro → codec → HP (test — ÉCOUTEURS OBLIGATOIRES)
#   stop      Arrête toutes les instances en background
#   status    État des instances en cours
#   list-codecs    Codecs disponibles dans cette installation
#   list-devices   Périphériques ALSA disponibles
#
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GAPK_DEFAULT_FORMAT="${GAPK_FORMAT:-gsmfr}"
GAPK_DEFAULT_DEVICE="${GAPK_ALSA_DEV:-${ALSA_CARD:-default}}"
GAPK_LOG_DIR="${GAPK_LOG_DIR:-/var/log/osmocom}"
GAPK_REC_DIR="${GAPK_REC_DIR:-/var/lib/gapk}"
GAPK_FRAME_MS=20        # ms par trame GSM FR

GAPK_PID_RX="/var/run/gapk-rx.pid"
GAPK_PID_TX="/var/run/gapk-tx.pid"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

mkdir -p "$GAPK_LOG_DIR" "$GAPK_REC_DIR"

log_info()  { echo -e "${GREEN}[gapk]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[gapk]${NC} $*"; }
log_error() { echo -e "${RED}[gapk ERROR]${NC} $*" >&2; }

check_gapk() {
    command -v osmo-gapk >/dev/null 2>&1 || {
        log_error "osmo-gapk introuvable."
        log_error "Vérifier que le Dockerfile contient l'étape osmo-gapk avec --enable-alsa."
        exit 1
    }
}

check_alsa_device() {
    local dev="${1:-default}"
    if [ ! -d /dev/snd ]; then
        log_warn "/dev/snd absent — container lancé sans --device /dev/snd ?"
        log_warn "Les modes record/playback/loopback-rtp fonctionnent sans ALSA."
        return 1
    fi
    return 0
}

# Lance gapk en background, enregistre le PID
run_bg() {
    local pid_file="$1"; shift
    local log_file="$1"; shift
    osmo-gapk "$@" >> "$log_file" 2>&1 &
    echo $! > "$pid_file"
    log_info "PID $(cat "$pid_file") → $(basename "$log_file")"
}

stop_pid() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 0
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && log_info "Arrêté PID $pid"
    fi
    rm -f "$pid_file"
}

# ══════════════════════════════════════════════════════════════════════════════
# call — appel bidirectionnel ALSA ↔ RTP
# ══════════════════════════════════════════════════════════════════════════════
mode_call() {
    local rx_port="${1:?RTP_RX_PORT requis (port MGW downlink)}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis (dest MGW uplink)}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"
    local dev="${4:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa_device "$dev" || true

    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   gapk — Appel bidirectionnel ALSA↔RTP  ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    printf "  Codec     : ${CYAN}%s${NC}\n" "$fmt"
    printf "  Périph.   : ${CYAN}%s${NC}\n" "$dev"
    printf "  RX écoute : ${CYAN}0.0.0.0:%s${NC}  (downlink MGW → haut-parleur)\n" "$rx_port"
    printf "  TX envoi  : ${CYAN}%s${NC}  (micro → uplink MGW)\n" "$tx_dest"
    echo ""

    local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
    local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

    # RX : trames GSM entrantes (downlink) → décodage → haut-parleur ALSA
    log_info "RX : rtp://0.0.0.0:${rx_port} → alsa://${dev}"
    run_bg "$GAPK_PID_RX" "$log_rx" \
        -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"

    sleep 0.3  # Laisser le socket RTP s'ouvrir

    # TX : microphone ALSA → encodage → trames GSM sortantes (uplink)
    log_info "TX : alsa://${dev} → rtp://${tx_dest}"
    run_bg "$GAPK_PID_TX" "$log_tx" \
        -f "$fmt" \
        -i "alsa://${dev}/${GAPK_FRAME_MS}" \
        -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"

    echo ""
    log_info "Appel actif. Arrêter : gapk-start.sh stop"
    log_info "Logs : tail -f $log_rx  $log_tx"
}

# ══════════════════════════════════════════════════════════════════════════════
# monitor — écoute passive RTP → ALSA (foreground)
# ══════════════════════════════════════════════════════════════════════════════
mode_monitor() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local fmt="${2:-$GAPK_DEFAULT_FORMAT}"
    local dev="${3:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa_device "$dev" || true
    stop_pid "$GAPK_PID_RX"

    log_info "Monitor : rtp://0.0.0.0:${rx_port} → alsa://${dev}  [${fmt}]"
    log_info "Ctrl+C pour arrêter"

    exec osmo-gapk \
        -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# record — enregistre flux RTP dans un fichier GSM brut
# ══════════════════════════════════════════════════════════════════════════════
mode_record() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local outfile="${2:-${GAPK_REC_DIR}/record_$(date '+%Y%m%d_%H%M%S').gsm}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    stop_pid "$GAPK_PID_RX"

    log_info "Record : rtp://0.0.0.0:${rx_port} → ${outfile}  [${fmt}]"
    log_info "Ctrl+C pour arrêter l'enregistrement"
    log_info "Relire : gapk-start.sh playback ${outfile} <DEST:PORT>"

    exec osmo-gapk \
        -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "rawfile://${outfile}"
}

# ══════════════════════════════════════════════════════════════════════════════
# playback — injecte fichier .gsm dans un flux RTP
# ══════════════════════════════════════════════════════════════════════════════
mode_playback() {
    local infile="${1:?INPUT_FILE requis}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    [ -f "$infile" ] || { log_error "Fichier introuvable : $infile"; exit 1; }

    log_info "Playback : ${infile} → rtp://${tx_dest}  [${fmt}]"
    log_info "Ctrl+C pour arrêter"

    exec osmo-gapk \
        -f "$fmt" \
        -i "rawfile://${infile}" \
        -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# loopback — ALSA micro → encode → décode → ALSA HP (test codec)
# ══════════════════════════════════════════════════════════════════════════════
mode_loopback() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa_device "$dev" || { log_error "ALSA requis pour le loopback."; exit 1; }

    echo -e "${YELLOW}${BOLD}⚠  UTILISEZ DES ÉCOUTEURS — risque de larsen !${NC}"
    echo ""
    log_info "Loopback : alsa://${dev} → [${fmt} codec] → alsa://${dev}"
    log_info "Ce que vous dites sort encodé puis décodé en GSM — test qualité codec"
    log_info "Ctrl+C pour arrêter"
    echo ""

    exec osmo-gapk \
        -f "$fmt" \
        -i "alsa://${dev}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# stop / status / list
# ══════════════════════════════════════════════════════════════════════════════
mode_stop() {
    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"
    pkill -x osmo-gapk 2>/dev/null && log_info "Toutes les instances arrêtées" \
        || log_info "Aucune instance active"
}

mode_status() {
    echo -e "${CYAN}── État osmo-gapk ──${NC}"
    local any=0
    for f in "$GAPK_PID_RX" "$GAPK_PID_TX"; do
        [ -f "$f" ] || continue
        local pid; pid=$(cat "$f")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} PID ${pid}  ($(basename "$f"))"
            any=1
        else
            echo -e "  ${RED}✗${NC} PID ${pid} mort"; rm -f "$f"
        fi
    done
    [ $any -eq 0 ] && echo -e "  ${YELLOW}Aucune instance active${NC}"
    # Processus résiduels sans pid file
    if pgrep -x osmo-gapk >/dev/null 2>&1; then
        echo ""
        echo -e "${CYAN}Processus detectés :${NC}"
        ps aux | grep '[o]smo-gapk' | sed 's/^/  /'
    fi
}

mode_list_codecs() {
    check_gapk
    echo -e "${CYAN}Codecs disponibles :${NC}"
    # osmo-gapk n'a pas --list-codecs dans toutes les versions ; on essaie les deux
    osmo-gapk --list-codecs 2>&1 || \
        osmo-gapk --help 2>&1 | grep -A30 -i "format\|codec" || true
}

mode_list_devices() {
    echo -e "${CYAN}── Périphériques ALSA ──${NC}"
    echo ""
    echo "Lecture (haut-parleur) :"
    aplay -L 2>/dev/null | head -20 || echo "  (aplay non disponible)"
    echo ""
    echo "Capture (microphone) :"
    arecord -L 2>/dev/null | head -20 || echo "  (arecord non disponible)"
    echo ""
    echo "Cartes son :"
    cat /proc/asound/cards 2>/dev/null || echo "  (pas de carte — relancer avec --device /dev/snd)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Usage
# ══════════════════════════════════════════════════════════════════════════════
usage() {
    cat <<'EOF'
Usage: gapk-start.sh <mode> [options]

  call     <RX_PORT> <TX_DEST:PORT> [FORMAT] [ALSA_DEV]
               Appel bidirectionnel ALSA ↔ RTP (background)
               ex: gapk-start.sh call 16000 127.0.0.1:16002 gsmfr default

  monitor  <RX_PORT> [FORMAT] [ALSA_DEV]
               Écoute passive RTP → ALSA (foreground)
               ex: gapk-start.sh monitor 16000

  record   <RX_PORT> [FICHIER] [FORMAT]
               Enregistre flux RTP → fichier .gsm (foreground)
               ex: gapk-start.sh record 16000 /var/lib/gapk/appel.gsm

  playback <FICHIER> <TX_DEST:PORT> [FORMAT]
               Injecte fichier .gsm → RTP (foreground)
               ex: gapk-start.sh playback /var/lib/gapk/appel.gsm 127.0.0.1:16000

  loopback [FORMAT] [ALSA_DEV]
               Loopback codec ALSA (micro → GSM → HP) — ÉCOUTEURS OBLIGATOIRES
               ex: gapk-start.sh loopback gsmfr

  stop          Arrête les instances en background
  status        État des instances
  list-codecs   Codecs disponibles
  list-devices  Périphériques ALSA

Formats : gsmfr (défaut) | gsmefr | gsmhr | pcm8 | pcm16
Variables : GAPK_FORMAT, GAPK_ALSA_DEV, ALSA_CARD

Ports RTP OsmoMGW :  telnet 127.0.0.1 4243  →  show mgcp
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
MODE="${1:-help}"; shift 2>/dev/null || true
case "$MODE" in
    call)          mode_call "$@" ;;
    monitor)       mode_monitor "$@" ;;
    record)        mode_record "$@" ;;
    playback)      mode_playback "$@" ;;
    loopback)      mode_loopback "$@" ;;
    stop)          mode_stop ;;
    status)        mode_status ;;
    list-codecs)   mode_list_codecs ;;
    list-devices)  mode_list_devices ;;
    help|-h|--help) usage ;;
    *) log_error "Mode inconnu : $MODE"; echo ""; usage; exit 1 ;;
esac
