#!/bin/bash
# gapk-start.sh — Gestionnaire audio GSM (osmo-gapk ↔ ALSA/RTP)
#
# ══════════════════════════════════════════════════════════════════════════════
# ARCHITECTURE AUDIO DOUBLE CHEMIN (osmo-nitb-for-calypso v2)
# ══════════════════════════════════════════════════════════════════════════════
#
# CHEMIN 1 — Baseband (mobile l1phy) :
#   mobile process ← TCH frames → trxcon → fake_trx → osmo-bts-trx
#                  ↓ io-handler l1phy
#                  ALSA device (décodage GSM-FR direct, zéro latence réseau)
#
#   → Activé par tch-voice { io-handler l1phy } dans mobile.cfg
#   → Pas besoin de gapk pour ce chemin
#   → Simule un combiné GSM physique
#
# CHEMIN 2 — Réseau (MGW RTP) :
#   BTS → BSC → MSC → MNCC → Asterisk → SIP → Linphone
#                           → MGCP → OsmoMGW → RTP
#                                                ↓
#                                           osmo-gapk (monitor/record/bridge)
#
#   → osmo-gapk se greffe sur les ports RTP du MGW
#   → Utile pour : monitoring, enregistrement, injection audio, tests
#   → Linphone reçoit l'audio directement via SIP (pas besoin de gapk)
#
# RÉSUMÉ :
#   • Appel MS → MS (même opérateur) : audio via l1phy ALSA (chemin 1)
#   • Appel MS → Linphone            : audio via Asterisk SIP (chemin 2)
#   • Monitoring réseau              : gapk mode auto/monitor (chemin 2)
#   • Enregistrement appel           : gapk mode record (chemin 2)
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
        log_warn "/dev/snd absent — container sans --device /dev/snd"
        log_warn "Modes record/playback fonctionnent sans ALSA."
        return 1
    fi
    return 0
}

# ── Détection du mode audio mobile ────────────────────────────────────────────
detect_audio_mode() {
    # Vérifie si le mobile.cfg utilise l1phy
    local cfg="/root/.osmocom/bb/mobile.cfg"
    if [ -f "$cfg" ] && grep -q "io-handler l1phy" "$cfg" 2>/dev/null; then
        echo "l1phy"
    else
        echo "gapk"
    fi
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
# info — affiche l'architecture audio actuelle
# ══════════════════════════════════════════════════════════════════════════════
mode_info() {
    local audio_mode
    audio_mode=$(detect_audio_mode)

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        Architecture audio osmo-nitb-for-calypso                 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "  Mode mobile.cfg : ${BOLD}${audio_mode}${NC}"
    echo ""

    if [ "$audio_mode" = "l1phy" ]; then
        echo -e "  ${YELLOW}● Chemin 1 — Baseband (l1phy)${NC}"
        echo -e "    mobile.cfg a tch-voice l1phy mais fake_trx ne transporte"
        echo -e "    PAS le payload audio TCH (bursts downlink = zéros)."
        echo -e "    → Pas de son direct sur les MS virtuels."
        echo ""
        echo -e "  ${GREEN}● Chemin 2 — Réseau (SIP/RTP) — SEUL CHEMIN AUDIO${NC}"
        echo -e "    MS appelle → Asterisk → SIP → Linphone (audio natif)"
        echo -e "    Linphone appelle → Asterisk → MNCC → MSC → MS (signalisation)"
        echo -e "    → L'audio du lab passe par Linphone."
    else
        echo -e "  ${GREEN}● Mode gapk classique${NC}"
        echo -e "    osmo-gapk bridge RTP ↔ ALSA"
        echo -e "    → Requis pour l'audio des appels MS"
    fi

    echo ""
    echo -e "  ${BOLD}Linphone :${NC}"
    local inter_ip
    inter_ip=$(ip -4 addr show | grep '172\.20\.0\.' | awk '{print $2}' | cut -d/ -f1 | head -1 || echo "172.20.0.X")
    echo -e "    SIP server : ${CYAN}${inter_ip}:5060${NC}"
    echo -e "    linphone_A : user=${CYAN}linphone_A${NC}  pass=${CYAN}tester${NC}   → 100"
    echo -e "    linphone_B : user=${CYAN}linphone_B${NC}  pass=${CYAN}testerB${NC}  → 200"
    echo ""

    # MGW ports
    mode_mgw_ports "" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# mgw-ports
# ══════════════════════════════════════════════════════════════════════════════
mode_mgw_ports() {
    local quiet="${1:-}"
    local mgw_out

    mgw_out=$( (echo "show mgcp"; sleep 1; echo "exit") | telnet "$MGW_VTY_HOST" "$MGW_VTY_PORT" 2>/dev/null \
        | grep -v "^Trying\|^Connected\|^Escape\|Welcome\|OsmoMGW[>#]\|Copyright\|License\|Contributions\|free software\|NO WARRANTY\|Based on") || true

    if [ -z "$mgw_out" ]; then
        [ -z "$quiet" ] && echo "(MGW non disponible ou aucun endpoint)"
        return 1
    fi

    # Format réel OsmoMGW :
    #   Virtual trunk 0 endpoint rtpbridge/1@mgw:
    #      CONN: (9/rtp C:51E1AF8F r=127.0.0.1:4072<->l=127.0.0.1:4068)
    #      CONN: (9/rtp C:96FA1465 r=127.0.0.1:30004<->l=127.0.0.1:4066)

    if [ -z "$quiet" ]; then
        echo -e "${CYAN}── Endpoints OsmoMGW actifs ──${NC}"
        local has_conn=false
        echo "$mgw_out" | while IFS= read -r line; do
            if echo "$line" | grep -q "endpoint.*@mgw"; then
                local ep; ep=$(echo "$line" | grep -oP 'rtpbridge/\S+')
                # Peek if next lines have CONN
                continue
            fi
            if echo "$line" | grep -q "CONN:.*r="; then
                has_conn=true
                local remote local_p
                remote=$(echo "$line" | grep -oP 'r=\K[0-9.]+:[0-9]+')
                local_p=$(echo "$line" | grep -oP 'l=\K[0-9.]+:[0-9]+')
                echo -e "  ${GREEN}●${NC} local=${CYAN}${local_p}${NC}  remote=${CYAN}${remote}${NC}"
            fi
        done
        if [ "$has_conn" = false ]; then
            echo "  (aucune connexion active)"
        fi
    else
        # Mode machine : "LOCAL_PORT REMOTE_IP:REMOTE_PORT" par connexion active
        echo "$mgw_out" | grep "CONN:.*r=" | while IFS= read -r line; do
            local remote local_p
            remote=$(echo "$line" | grep -oP 'r=\K[0-9.]+:[0-9]+')
            local_p=$(echo "$line" | grep -oP 'l=\K[0-9]+:[0-9]+' | cut -d: -f2)
            [ -n "$local_p" ] && [ -n "$remote" ] && echo "$local_p $remote"
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# call — appel bidirectionnel ALSA ↔ RTP (chemin 2 uniquement)
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

    local audio_mode; audio_mode=$(detect_audio_mode)
    if [ "$audio_mode" = "l1phy" ]; then
        echo -e "${YELLOW}${BOLD}NOTE: mobile.cfg utilise io-handler l1phy${NC}"
        echo -e "${YELLOW}L'audio MS passe directement via ALSA (pas via gapk).${NC}"
        echo -e "${YELLOW}Ce mode gapk bridge le RTP réseau (MGW) ↔ ALSA.${NC}"
        echo -e "${YELLOW}Pour les appels MS↔MS, l'audio est déjà géré par mobile.${NC}"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   gapk — Bridge RTP réseau ↔ ALSA       ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    printf "  Codec     : ${CYAN}%s${NC}\n" "$fmt"
    printf "  Périph.   : ${CYAN}%s${NC}\n" "$dev"
    printf "  RX écoute : ${CYAN}0.0.0.0:%s${NC}  (MGW downlink → HP)\n" "$rx_port"
    printf "  TX envoi  : ${CYAN}%s${NC}  (micro → MGW uplink)\n" "$tx_dest"
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
    log_info "Bridge actif. Arrêter : gapk-start.sh stop"
}

# ══════════════════════════════════════════════════════════════════════════════
# auto — surveille MGW, bridge gapk auto
# ══════════════════════════════════════════════════════════════════════════════
mode_auto() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa "$dev" || log_warn "ALSA absent — mode RTP-only"

    local audio_mode; audio_mode=$(detect_audio_mode)

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   gapk-auto — Intégration OsmoMGW (chemin réseau)   ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "$audio_mode" = "l1phy" ]; then
        log_auto "Mode l1phy détecté → audio MS via mobile process"
        log_auto "gapk surveille le chemin réseau (MGW RTP) uniquement"
        log_auto "Pour les appels MS↔MS, l'audio est géré nativement"
        echo ""
    fi

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
        local first_active
        first_active=$(mode_mgw_ports "quiet" 2>/dev/null | head -1) || first_active=""

        if [ -n "$first_active" ]; then
            local rx_port tx_dest
            rx_port=$(echo "$first_active" | awk '{print $1}')
            tx_dest=$(echo "$first_active" | awk '{print $2}')

            if [ "$rx_port" != "$prev_rx_port" ]; then
                if [ -n "$prev_rx_port" ]; then
                    log_auto "Changement endpoint (${prev_rx_port} → ${rx_port})"
                    stop_pid "$GAPK_PID_RX"
                    stop_pid "$GAPK_PID_TX"
                fi

                log_auto "Endpoint actif : RX=${rx_port}  TX=${tx_dest}"

                local log_rx="${GAPK_LOG_DIR}/gapk-rx.log"
                local log_tx="${GAPK_LOG_DIR}/gapk-tx.log"

                run_bg "$GAPK_PID_RX" "$log_rx" \
                    -f "$fmt" \
                    -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
                    -o "alsa://${dev}/${GAPK_FRAME_MS}"
                sleep 0.3
                run_bg "$GAPK_PID_TX" "$log_tx" \
                    -f "$fmt" \
                    -i "alsa://${dev}/${GAPK_FRAME_MS}" \
                    -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"

                prev_rx_port="$rx_port"
                log_auto "Audio actif (PID RX=$(cat $GAPK_PID_RX 2>/dev/null) TX=$(cat $GAPK_PID_TX 2>/dev/null))"
            fi

            if ! is_running "$GAPK_PID_RX" || ! is_running "$GAPK_PID_TX"; then
                log_warn "Processus gapk mort — restart"
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        else
            if [ -n "$prev_rx_port" ]; then
                log_auto "Endpoint disparu — arrêt gapk"
                stop_pid "$GAPK_PID_RX"; stop_pid "$GAPK_PID_TX"
                prev_rx_port=""
            fi
        fi
        sleep "$AUTO_POLL_INTERVAL"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# monitor — écoute passive RTP → ALSA
# ══════════════════════════════════════════════════════════════════════════════
mode_monitor() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local fmt="${2:-$GAPK_DEFAULT_FORMAT}"
    local dev="${3:-$GAPK_DEFAULT_DEVICE}"

    check_gapk; check_alsa "$dev" || true
    stop_pid "$GAPK_PID_RX"

    log_info "Monitor : rtp://0.0.0.0:${rx_port} → alsa://${dev}  [${fmt}]"
    exec osmo-gapk -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# record — RTP → fichier .gsm
# ══════════════════════════════════════════════════════════════════════════════
mode_record() {
    local rx_port="${1:?RTP_RX_PORT requis}"
    local outfile="${2:-${GAPK_REC_DIR}/record_$(date '+%Y%m%d_%H%M%S').gsm}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk; stop_pid "$GAPK_PID_RX"

    log_info "Record : rtp://0.0.0.0:${rx_port} → ${outfile}  [${fmt}]"
    exec osmo-gapk -f "$fmt" \
        -i "rtp://0.0.0.0:${rx_port}/${GAPK_FRAME_MS}" \
        -o "rawfile://${outfile}"
}

# ══════════════════════════════════════════════════════════════════════════════
# playback — fichier .gsm → RTP
# ══════════════════════════════════════════════════════════════════════════════
mode_playback() {
    local infile="${1:?INPUT_FILE requis}"
    local tx_dest="${2:?RTP_TX_DEST:PORT requis}"
    local fmt="${3:-$GAPK_DEFAULT_FORMAT}"

    check_gapk
    [ -f "$infile" ] || { log_error "Fichier introuvable : $infile"; exit 1; }

    log_info "Playback : ${infile} → rtp://${tx_dest}  [${fmt}]"
    exec osmo-gapk -f "$fmt" \
        -i "rawfile://${infile}" \
        -o "rtp://${tx_dest}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# loopback — ALSA micro → codec → ALSA HP
# ══════════════════════════════════════════════════════════════════════════════
mode_loopback() {
    local fmt="${1:-$GAPK_DEFAULT_FORMAT}"
    local dev="${2:-$GAPK_DEFAULT_DEVICE}"

    check_gapk
    check_alsa "$dev" || { log_error "ALSA requis."; exit 1; }

    echo -e "${YELLOW}${BOLD}⚠  UTILISEZ DES ÉCOUTEURS — risque de larsen !${NC}"
    log_info "Loopback : alsa://${dev} → [${fmt}] → alsa://${dev}"
    exec osmo-gapk -f "$fmt" \
        -i "alsa://${dev}/${GAPK_FRAME_MS}" \
        -o "alsa://${dev}/${GAPK_FRAME_MS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# stop / status
# ══════════════════════════════════════════════════════════════════════════════
mode_stop() {
    stop_pid "$GAPK_PID_RX"
    stop_pid "$GAPK_PID_TX"
    rm -f "$GAPK_AUTO_LOCK"
    pkill -x osmo-gapk 2>/dev/null && log_info "Toutes instances arrêtées" \
        || log_info "Aucune instance active"
}

mode_status() {
    local audio_mode; audio_mode=$(detect_audio_mode)
    echo -e "${CYAN}── État audio ──${NC}"
    echo -e "  Mode mobile.cfg : ${BOLD}${audio_mode}${NC}"
    echo ""

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
    [ $any -eq 0 ] && echo -e "  ${YELLOW}Aucune instance gapk active${NC}"

    if [ "$audio_mode" = "l1phy" ]; then
        echo ""
        echo -e "  ${GREEN}●${NC} Audio MS via l1phy (natif dans mobile process)"
        if pgrep -f "mobile.*mobile" >/dev/null 2>&1; then
            echo -e "  ${GREEN}●${NC} Processus mobile actif"
        else
            echo -e "  ${YELLOW}○${NC} Processus mobile non détecté"
        fi
    fi

    if pgrep -x osmo-gapk >/dev/null 2>&1; then
        echo ""; echo -e "${CYAN}Processus gapk :${NC}"
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
    echo ""; echo "Capture (micro) :"
    arecord -L 2>/dev/null | head -20 || echo "  (arecord indisponible)"
    echo ""; echo "Cartes son :"
    cat /proc/asound/cards 2>/dev/null || echo "  (relancer avec --device /dev/snd)"

    local audio_mode; audio_mode=$(detect_audio_mode)
    if [ "$audio_mode" = "l1phy" ]; then
        echo ""
        echo -e "${CYAN}── Config l1phy (mobile.cfg) ──${NC}"
        grep -A3 "tch-voice" /root/.osmocom/bb/mobile.cfg 2>/dev/null | sed 's/^/  /' || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Usage
# ══════════════════════════════════════════════════════════════════════════════
usage() {
    local audio_mode; audio_mode=$(detect_audio_mode)
    cat <<EOF
Usage: gapk-start.sh <mode> [options]

  Mode audio mobile.cfg : ${audio_mode}
  $([ "$audio_mode" = "l1phy" ] && echo "  → Audio MS natif via l1phy. gapk = monitoring réseau uniquement." || echo "  → Audio MS via gapk (mode classique).")

  info                    Affiche l'architecture audio et les IPs Linphone

  auto     [FORMAT] [ALSA_DEV]
               Surveille MGW, bridge RTP↔ALSA auto (chemin réseau).

  call     <RX_PORT> <TX_DEST:PORT> [FORMAT] [ALSA_DEV]
               Bridge bidirectionnel RTP réseau ↔ ALSA.

  monitor  <RX_PORT> [FORMAT] [ALSA_DEV]
               Écoute passive RTP → ALSA.

  record   <RX_PORT> [FICHIER] [FORMAT]
               Enregistre flux RTP → fichier .gsm.

  playback <FICHIER> <TX_DEST:PORT> [FORMAT]
               Injecte fichier .gsm → RTP.

  loopback [FORMAT] [ALSA_DEV]
               Loopback codec ALSA (ÉCOUTEURS OBLIGATOIRES).

  mgw-ports     Endpoints RTP OsmoMGW actifs.
  stop          Arrête les instances gapk.
  status        État audio complet (l1phy + gapk).
  list-codecs   Codecs disponibles.
  list-devices  Périphériques ALSA + config l1phy.

Formats : gsmfr (défaut) | gsmefr | gsmhr | pcm8 | pcm16
Variables : GAPK_FORMAT, GAPK_ALSA_DEV, ALSA_CARD, GAPK_POLL_INTERVAL
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
MODE="${1:-help}"; shift 2>/dev/null || true
case "$MODE" in
    info)          mode_info ;;
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
