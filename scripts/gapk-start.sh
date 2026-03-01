#!/bin/bash
# gapk-start.sh — Gestionnaire audio GSM (osmo-gapk ↔ ALSA/RTP)
#
# Intégration native dans la stack osmo_egprs :
#   • Mode `auto`  : se greffe sur OsmoMGW pour détecter les appels actifs
#                    et démarre/arrête gapk automatiquement via hook MGCP.
#   • Mode `call`  : appel bidirectionnel ALSA ↔ RTP (RX + TX en background).
#   • Mode `monitor`: écoute passive RTP → ALSA (foreground).
#   • Mode `record` : enregistre flux RTP → fichier .gsm (foreground).
#   • Mode `playback`: injecte fichier .gsm → RTP (foreground).
#   • Mode `loopback`: boucle codec ALSA micro → GSM → HP (test).
#   • Mode `mgw-ports`: liste les endpoints/ports RTP OsmoMGW actifs.
#   • Mode `stop`  : arrête toutes les instances en background.
#   • Mode `status`: état des instances en cours.
#
# ══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE AUDIO
# ══════════════════════════════════════════════════════════════════════════════
#
#   Micro ALSA ──[PCM 8kHz]──► gapk-TX ──[GSM FR]──► RTP ──► OsmoMGW
#   OsmoMGW  ──► RTP ──[GSM FR]──► gapk-RX ──[PCM 8kHz]──► HP ALSA
#
#   OsmoMGW alloue les ports RTP dynamiquement (plage 4002–16001).
#   Les endpoints actifs sont visibles via :
#     echo "show mgcp" | telnet 127.0.0.1 4243
#
# ══════════════════════════════════════════════════════════════════════════════
# INTÉGRATION NATIVE (mode auto)
# ══════════════════════════════════════════════════════════════════════════════
#
#   gapk-start.sh auto [FORMAT] [ALSA_DEV]
#
#   Surveille OsmoMGW toutes les 2 secondes.
#   Dès qu'un endpoint passe en état "active" (connexion RTP ouverte),
#   démarre gapk RX+TX sur les ports détectés.
#   Dès que l'endpoint redevient idle, arrête les instances gapk.
#
#   Ce mode tourne en foreground — idéal pour la fenêtre tmux [4].
#
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GAPK_DEFAULT_FORMAT="${GAPK_FORMAT:-gsmfr}"
GAPK_DEFAULT_DEVICE="${GAPK_ALSA_DEV:-${ALSA_CARD:-default}}"
GAPK_LOG_DIR="${GAPK_LOG_DIR:-/var/log/osmocom}"
GAPK_REC_DIR="${GAPK_REC_DIR:-/var/lib/gapk}"
GAPK_FRAME_MS=20
MGW_VTY_HOST="127.0.0.1"
MGW_VTY_PORT="4243"
AUTO_POLL_INTERVAL="${GAPK_POLL_INTERVAL:-2}"

GAPK_PID_RX="/var/run/gapk-rx.pid"
GAPK_PID_TX="/var/run/gapk-tx.pid"
GAPK_AUTO_LOCK="/var/run/gapk-auto.lock"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

mkdir -p "$GAPK_LOG_DIR" "$GAPK_REC_DIR"

log_info()  { echo -e "${GREEN}[gapk]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[gapk]${NC} $*"; }
log_error() { echo -e "${RED}[gapk ERROR]${NC} $*" >&2; }
log_auto()  { echo -e "${CYAN}[gapk-auto]${NC} $(date '+%H:%M:%S') $*"; }

# ── Vérifications ──────────────────────────────────────────────────────────────
check_gapk() {
    command -v osmo-gapk >/dev/null 2>&1 || {
        log_error "osmo-gapk introuvable."
        log_error "Vérifier que le Dockerfile inclut l'étape osmo-gapk --enable-alsa."
        exit 1
    }
}

check_alsa() {
    local dev="${1:-default}"
    if [ ! -d /dev/snd ]; then
        log_warn "/dev/snd absent — container lancé sans --device /dev/snd"
        log_warn "Modes record/playback fonctionnent sans ALSA."
        return 1
    fi
    return 0
}

# ── Cycle de vie background ────────────────────────────────────────────────────
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
        kill "$pid" 2>/dev/null && log_info "Arrêté PID $pid" || true
    fi
    rm -f "$pid_file"
}

is_running() {
    local pid_file="$1"
    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
# mgw-ports — interroge OsmoMGW VTY et retourne les ports RTP actifs
#
# Sortie : une ligne par endpoint actif "RX_PORT TX_IP:TX_PORT"
# (RX = port local MGW pour downlink ; TX = destination uplink MGW)
# ══════════════════════════════════════════════════════════════════════════════
mode_mgw_ports() {
    local quiet="${1:-}"
    local mgw_out

    mgw_out=$(echo "show mgcp" | telnet "$MGW_VTY_HOST" "$MGW_VTY_PORT" 2>/dev/null \
        | grep -v "^Trying\|^Connected\|^Escape\|Welcome\|OsmoMGW[>#]") || true

    if [ -z "$mgw_out" ]; then
        [ -z "$quiet" ] && echo "(MGW non disponible ou aucun endpoint)"
        return 1
    fi

    # Extrait les endpoints actifs avec leur port RTP local
    # Format VTY OsmoMGW :
    #   Endpoint: rtpbridge/*@mgw
    #     Conn: 0x... (RHCF)  port: 4002  ...
    #     Conn: 0x... (LCLS)  port: 4004  RTP-IP: 127.0.0.1 RTP-Port: 4006
    if [ -z "$quiet" ]; then
        echo -e "${CYAN}── Endpoints OsmoMGW actifs ──${NC}"
        echo "$mgw_out" | grep -E "Endpoint:|port:|RTP" | sed 's/^/  /' || true
    else
        # Mode machine : sortie parsée "RX_PORT TX_IP:TX_PORT"
        echo "$mgw_out" | awk '
            /Endpoint:/ { ep=$0 }
            /port:/ {
                match($0, /port: ([0-9]+)/, p)
                match($0, /RTP-IP: ([0-9.]+) RTP-Port: ([0-9]+)/, r)
                if (p[1] != "" && r[1] != "")
                    print p[1], r[1]":"r[2]
            }
        '
    fi
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
    check_alsa "$dev" || true

    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   gapk — Appel bidirectionnel ALSA↔RTP  ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    printf "  Codec     : ${CYAN}%s${NC}\n" "$fmt"
    printf "  Périph.   : ${CYAN}%s${NC}\n" "$dev"
    printf "  RX écoute : ${CYAN}0.0.0.0:%s${NC}  (downlink MGW → HP)\n" "$rx_port"
    printf "  TX envoi  : ${CYAN}%s${NC}  (micro → uplink MGW)\n" "$tx_dest"
    echo ""

    local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
    local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

    log_info "RX : rtp://0.0.0.0:${rx_port} → alsa://${dev}"
    run_bg "$GAPK_PID_RX" "$log_rx" \
        -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"

    sleep 0.3

    log_info "TX : alsa://${dev} → rtp://${tx_dest}"
    run_bg "$GAPK_PID_TX" "$log_tx" \
        -f "$fmt" \
        -i "alsa://${dev}/${GAPK_FRAME_MS}" \
        -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"

    echo ""
    log_info "Appel actif. Arrêter : gapk-start.sh stop"
    log_info "Logs RX : tail -f $log_rx"
    log_info "Logs TX : tail -f $log_tx"
}

# ══════════════════════════════════════════════════════════════════════════════
# auto — intégration native : surveille MGW et gère gapk automatiquement
#
# Démarre gapk dès qu'un endpoint MGW passe actif (connexion RTP ouverte).
# Arrête gapk quand l'endpoint redevient idle.
# Tourne en foreground dans la fenêtre tmux [4].
# ══════════════════════════════════════════════════════════════════════════════
mode_auto() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa "$dev" || log_warn "ALSA absent — mode RTP-only si appel détecté"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   gapk-auto — Intégration native OsmoMGW        ║"
    echo "║   Surveille les endpoints RTP actifs             ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    log_auto "Codec=${fmt}  Périph=${dev}  Poll=${AUTO_POLL_INTERVAL}s"
    log_auto "Ctrl+C pour arrêter"
    echo ""

    touch "$GAPK_AUTO_LOCK"
    local prev_rx_port=""

    cleanup_auto() {
        log_auto "Arrêt..."
        stop_pid "$GAPK_PID_RX"
        stop_pid "$GAPK_PID_TX"
        rm -f "$GAPK_AUTO_LOCK"
        exit 0
    }
    trap cleanup_auto SIGINT SIGTERM

    while [ -f "$GAPK_AUTO_LOCK" ]; do
        # Lire le premier endpoint actif (port RX + TX dest)
        local first_active
        first_active=$(mode_mgw_ports "quiet" 2>/dev/null | head -1) || first_active=""

        if [ -n "$first_active" ]; then
            local rx_port tx_dest
            rx_port=$(echo "$first_active" | awk '{print $1}')
            tx_dest=$(echo "$first_active" | awk '{print $2}')

            if [ "$rx_port" != "$prev_rx_port" ]; then
                if [ -n "$prev_rx_port" ]; then
                    log_auto "Changement d'endpoint (${prev_rx_port} → ${rx_port}) — restart gapk"
                    stop_pid "$GAPK_PID_RX"
                    stop_pid "$GAPK_PID_TX"
                fi

                log_auto "Endpoint actif détecté : RX=${rx_port}  TX=${tx_dest}"
                log_auto "Démarrage gapk (${fmt}) ..."

                local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
                local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

                # RX : MGW → ALSA (downlink)
                run_bg "$GAPK_PID_RX" "$log_rx" \
                    -f "$fmt" \
                    -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
                    -o "alsa://${dev}/${GAPK_FRAME_MS}"

                sleep 0.3

                # TX : ALSA → MGW (uplink)
                run_bg "$GAPK_PID_TX" "$log_tx" \
                    -f "$fmt" \
                    -i "alsa://${dev}/${GAPK_FRAME_MS}" \
                    -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"

                prev_rx_port="$rx_port"
                log_auto "Audio actif (PID RX=$(cat $GAPK_PID_RX 2>/dev/null) TX=$(cat $GAPK_PID_TX 2>/dev/null))"
            fi

            # Vérifier que les processus sont toujours vivants
            if ! is_running "$GAPK_PID_RX" || ! is_running "$GAPK_PID_TX"; then
                log_warn "Processus gapk mort de façon inattendue — restart"
                stop_pid "$GAPK_PID_RX"
                stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        else
            # Pas d'endpoint actif
            if [ -n "$prev_rx_port" ]; then
                log_auto "Endpoint disparu (port ${prev_rx_port}) — arrêt gapk"
                stop_pid "$GAPK_PID_RX"
                stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        fi

        sleep "$AUTO_POLL_INTERVAL"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# monitor — écoute passive RTP → ALSA (foreground)
# ══════════════════════════════════════════════════════════════════════════════
mode_monitor() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local fmt="${2:-$GAPK_DEFAULT_FORMAT}"
    local dev="${3:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa "$dev" || true
    stop_pid "$GAPK_PID_RX"

    log_info "Monitor : rtp://0.0.0.0:${rx_port} → alsa://${dev}  [${fmt}]"
    log_info "Ctrl+C pour arrêter"

    exec osmo-gapk \
        -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# record — enregistre flux RTP → fichier .gsm brut
# ══════════════════════════════════════════════════════════════════════════════
mode_record() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local outfile="${2:-${GAPK_REC_DIR}/record_$(date '+%Y%m%d_%H%M%S').gsm}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    stop_pid "$GAPK_PID_RX"

    log_info "Record : rtp://0.0.0.0:${rx_port} → ${outfile}  [${fmt}]"
    log_info "Ctrl+C pour arrêter"
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
    check_alsa "$dev" || { log_error "ALSA requis pour le loopback."; exit 1; }

    echo -e "${YELLOW}${BOLD}⚠  UTILISEZ DES ÉCOUTEURS — risque de larsen !${NC}"
    echo ""
    log_info "Loopback : alsa://${dev} → [${fmt}] → alsa://${dev}"
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
    rm -f "$GAPK_AUTO_LOCK"
    pkill -x osmo-gapk 2>/dev/null && log_info "Toutes instances arrêtées" \
        || log_info "Aucune instance active"
}

mode_status() {
    echo -e "${CYAN}── État osmo-gapk ──${NC}"
    local any=0
    for f in "$GAPK_PID_RX" "$GAPK_PID_TX"; do
        [ -f "$f" ] || continue
        local pid; pid=$(cat "$f")
        if kill -0 "$pid" 2>/dev/null; then
            local cmdline; cmdline=$(cat "/proc/${pid}/cmdline" 2>/dev/null \
                | tr '\0' ' ' | cut -c1-80 || echo "?")
            echo -e "  ${GREEN}●${NC} PID ${pid}  [$(basename "$f")]  ${cmdline}"
            any=1
        else
            echo -e "  ${RED}✗${NC} PID ${pid} mort"; rm -f "$f"
        fi
    done
    [ -f "$GAPK_AUTO_LOCK" ] && echo -e "  ${CYAN}●${NC} mode AUTO actif" && any=1
    [ $any -eq 0 ] && echo -e "  ${YELLOW}Aucune instance active${NC}"
    if pgrep -x osmo-gapk >/dev/null 2>&1; then
        echo ""
        echo -e "${CYAN}Processus détectés :${NC}"
        ps -o pid,args --no-headers -C osmo-gapk 2>/dev/null | sed 's/^/  /' || true
    fi
}

mode_list_codecs() {
    check_gapk
    echo -e "${CYAN}Codecs disponibles :${NC}"
    osmo-gapk --list-codecs 2>&1 || \
        osmo-gapk --help 2>&1 | grep -A30 -i "format\|codec" || true
}

mode_list_devices() {
    echo -e "${CYAN}── Périphériques ALSA ──${NC}"
    echo "Lecture (HP) :"
    aplay -L 2>/dev/null | head -20 || echo "  (aplay indisponible)"
    echo ""
    echo "Capture (micro) :"
    arecord -L 2>/dev/null | head -20 || echo "  (arecord indisponible)"
    echo ""
    echo "Cartes son :"
    cat /proc/asound/cards 2>/dev/null || echo "  (relancer avec --device /dev/snd)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Usage
# ══════════════════════════════════════════════════════════════════════════════
usage() {
    cat <<'EOF'
Usage: gapk-start.sh <mode> [options]

  auto     [FORMAT] [ALSA_DEV]
               Intégration native : surveille MGW, démarre/arrête gapk auto.
               Tourne en foreground (idéal fenêtre tmux).
               ex: gapk-start.sh auto gsmfr default

  call     <RX_PORT> <TX_DEST:PORT> [FORMAT] [ALSA_DEV]
               Appel bidirectionnel ALSA ↔ RTP (background).
               ex: gapk-start.sh call 4002 127.0.0.1:4004 gsmfr

  monitor  <RX_PORT> [FORMAT] [ALSA_DEV]
               Écoute passive RTP → ALSA (foreground).
               ex: gapk-start.sh monitor 4002

  record   <RX_PORT> [FICHIER] [FORMAT]
               Enregistre flux RTP → fichier .gsm.
               ex: gapk-start.sh record 4002 /var/lib/gapk/appel.gsm

  playback <FICHIER> <TX_DEST:PORT> [FORMAT]
               Injecte fichier .gsm → RTP.
               ex: gapk-start.sh playback /var/lib/gapk/appel.gsm 127.0.0.1:4002

  loopback [FORMAT] [ALSA_DEV]
               Loopback codec ALSA (ÉCOUTEURS OBLIGATOIRES).

  mgw-ports     Liste les endpoints/ports RTP OsmoMGW actifs.
  stop          Arrête toutes les instances.
  status        État des instances.
  list-codecs   Codecs disponibles.
  list-devices  Périphériques ALSA.

Formats : gsmfr (défaut) | gsmefr | gsmhr | pcm8 | pcm16
Variables : GAPK_FORMAT, GAPK_ALSA_DEV, ALSA_CARD, GAPK_POLL_INTERVAL

Ports RTP OsmoMGW (manuel) :
  echo "show mgcp" | telnet 127.0.0.1 4243
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
MODE="${1:-help}"; shift 2>/dev/null || true
case "$MODE" in
    auto)          mode_auto "$@" ;;
    call)          mode_call "$@" ;;
    monitor)       mode_monitor "$@" ;;
    record)        mode_record "$@" ;;
    playback)      mode_playback "$@" ;;
    loopback)      mode_loopback "$@" ;;
    mgw-ports)     mode_mgw_ports "" ;;
    stop)          mode_stop ;;
    status)        mode_status ;;
    list-codecs)   mode_list_codecs ;;
    list-devices)  mode_list_devices ;;
    help|-h|--help) usage ;;
    *) log_error "Mode inconnu : $MODE"; echo ""; usage; exit 1 ;;
esac
