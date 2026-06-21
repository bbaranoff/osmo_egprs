#!/bin/bash
# wslg-audio-bridge.sh — Fait sortir l'audio des conteneurs Osmocom sur les
# haut-parleurs de l'hôte Windows, depuis l'INTÉRIEUR du Docker (WSL2 + WSLg).
#
# Chaîne réalisée (toutes les étapes ont été testées à la main) :
#
#   [conteneur] gsm_audio (null-sink, voix GSM via gapk, monitor lu par le
#               dashboard web)
#        │  module-loopback  gsm_audio.monitor ──► win_out
#        ▼
#   [conteneur] win_out  (module-tunnel-sink-new, server=tcp:<gw>:4713)
#        │  TCP vers la gateway docker (= hôte WSL)
#        ▼
#   [hôte WSL]  /mnt/wslg/PulseServer  (module-native-protocol-tcp:4713)
#        │  WSLg
#        ▼
#   [Windows]   RDPSink → haut-parleurs
#
# Le conteneur garde son PulseAudio AUTONOME (cf. build_alsa_args dans start.sh) :
# on n'écrase PAS son socket /run/pulse/native, on AJOUTE juste un sink tunnel +
# un loopback. Le dashboard qui lit gsm_audio.monitor continue de fonctionner.
#
# Usage :
#   wslg-audio-bridge.sh host-relay                 # hôte : expose WSLg en TCP
#   wslg-audio-bridge.sh container <name> [gw]      # conteneur : tunnel + loopback
#   wslg-audio-bridge.sh test <name> [gw]           # bip 880Hz via gsm_audio
#   wslg-audio-bridge.sh all  <name> [gw]           # host-relay + container + test
#   wslg-audio-bridge.sh down <name>                # retire tunnel + loopback
set -euo pipefail

TCP_PORT="${WSLG_TCP_PORT:-4713}"
WSLG_SOCK="/mnt/wslg/PulseServer"
# ACL : tout le bloc privé 172.16/12 (couvre les subnets docker gsm-inter/op)
TCP_ACL="${WSLG_TCP_ACL:-127.0.0.1;172.16.0.0/12}"

log()  { echo -e "  [wslg-audio] $*"; }
die()  { echo -e "  [wslg-audio][FAIL] $*" >&2; exit 1; }

# IP de l'hôte WSL vue depuis le conteneur = gateway de sa route par défaut.
detect_gw() {
    local name="$1"
    docker exec "$name" sh -c "ip route 2>/dev/null | awk '/default/{print \$3; exit}'" 2>/dev/null \
        || true
}

# ── HÔTE : expose le PulseServer WSLg en TCP (idempotent) ────────────────────
# À lancer en tant qu'utilisateur de session (propriétaire du socket WSLg),
# PAS en root. Depuis start.sh sous sudo : sudo -u "$SUDO_USER" ... host-relay.
host_relay() {
    [ -S "$WSLG_SOCK" ] || die "WSLg introuvable ($WSLG_SOCK) — pas un environnement WSLg ?"
    export PULSE_SERVER="unix:${WSLG_SOCK}"

    if pactl list short modules 2>/dev/null \
        | grep -q "module-native-protocol-tcp.*port=${TCP_PORT}"; then
        log "relai TCP déjà actif sur :${TCP_PORT}"
        return 0
    fi

    pactl load-module module-native-protocol-tcp \
        "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
        || die "load module-native-protocol-tcp"
    log "relai TCP WSLg activé : tcp:<host>:${TCP_PORT} (ACL ${TCP_ACL})"
}

# ── CONTENEUR : sink tunnel vers Windows + loopback depuis gsm_audio ─────────
container_bridge() {
    local name="$1" gw="${2:-}"
    [ -n "$name" ] || die "nom de conteneur requis"
    [ -z "$gw" ] && gw="$(detect_gw "$name")"
    [ -n "$gw" ] || die "gateway introuvable pour $name (passer la GW en argument)"
    local server="tcp:${gw}:${TCP_PORT}"

    docker exec -i "$name" sh -s -- "$server" <<'EOSH'
set -eu
SERVER="$1"
pactl info >/dev/null 2>&1 || { echo "  [wslg-audio][FAIL] pas de daemon pulse dans le conteneur" >&2; exit 1; }

# win_out : tunnel-sink vers le PulseServer WSLg (Windows). Idempotent.
if ! pactl list short sinks 2>/dev/null | grep -q '[[:space:]]win_out[[:space:]]'; then
    pactl load-module module-tunnel-sink-new "server=${SERVER}" sink_name=win_out >/dev/null
    echo "  [wslg-audio] win_out créé -> ${SERVER}"
else
    echo "  [wslg-audio] win_out déjà présent"
fi

# loopback gsm_audio.monitor -> win_out : la voix GSM ressort sur Windows.
# (n'ajoute le loopback que si gsm_audio existe et qu'il n'y en a pas déjà un)
if pactl list short sinks 2>/dev/null | grep -q '[[:space:]]gsm_audio[[:space:]]'; then
    if ! pactl list short modules 2>/dev/null | grep -q 'module-loopback.*gsm_audio.monitor'; then
        pactl load-module module-loopback source=gsm_audio.monitor sink=win_out latency_msec=60 >/dev/null
        echo "  [wslg-audio] loopback gsm_audio.monitor -> win_out"
    else
        echo "  [wslg-audio] loopback gsm_audio déjà présent"
    fi
else
    # pas de sink GSM : on fait au moins de win_out la sortie par défaut
    pactl set-default-sink win_out >/dev/null 2>&1 || true
    echo "  [wslg-audio] gsm_audio absent -> win_out défini par défaut"
fi
EOSH
}

# ── CONTENEUR : bip de test via gsm_audio (preuve bout-en-bout) ──────────────
container_test() {
    local name="$1"
    docker exec -i "$name" sh -s <<'EOSH'
set -eu
DEV=gsm_audio
pactl list short sinks 2>/dev/null | grep -q '[[:space:]]gsm_audio[[:space:]]' || DEV=win_out
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=880:duration=1" -ar 8000 -ac 1 /tmp/wslg_test.wav
paplay -d "$DEV" /tmp/wslg_test.wav
echo "  [wslg-audio] bip 880Hz envoyé via $DEV -> Windows"
EOSH
}

container_down() {
    local name="$1"
    docker exec -i "$name" sh -s <<'EOSH'
set -eu
pactl list short modules 2>/dev/null | awk '/module-loopback.*gsm_audio.monitor/{print $1}' \
    | while read -r m; do pactl unload-module "$m" 2>/dev/null || true; done
pactl list short modules 2>/dev/null | awk '/module-tunnel-sink-new.*win_out|sink_name=win_out/{print $1}' \
    | while read -r m; do pactl unload-module "$m" 2>/dev/null || true; done
echo "  [wslg-audio] pont retiré"
EOSH
}

cmd="${1:-}"; shift || true
case "$cmd" in
    host-relay) host_relay ;;
    container)  container_bridge "${1:-}" "${2:-}" ;;
    test)       container_test "${1:-}" ;;
    down)       container_down "${1:-}" ;;
    all)        host_relay; container_bridge "${1:-}" "${2:-}"; container_test "${1:-}" ;;
    *) echo "usage: $0 {host-relay|container <name> [gw]|test <name>|down <name>|all <name> [gw]}" >&2; exit 2 ;;
esac
