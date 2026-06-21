#!/bin/bash
# wslg-audio-bridge.sh — Fait sortir l'audio des conteneurs Osmocom sur les
# haut-parleurs de l'HÔTE, depuis l'INTÉRIEUR du Docker. Marche dans deux cas :
#
#   • WSL2 + WSLg  : l'hôte audio = PulseServer WSLg (/mnt/wslg/PulseServer),
#                    qui relaie lui-même vers Windows.
#   • Linux natif  : l'hôte audio = le PulseAudio/PipeWire de la session
#                    graphique (/run/user/<uid>/pulse/native).
#
# Principe (vérifié) :
#   host-relay  → expose le pulse de l'hôte en TCP (module-native-protocol-tcp)
#   container   → pont AUDIO direct dans le conteneur :
#                     parec(gsm_audio.monitor) | paplay(--server=tcp:<gw>:4713)
#
# On N'utilise PAS module-tunnel-sink : sur TCP/WSL son horloge dérive (la
# latence grimpe à >1 s → son haché « tout pété »). parec|paplay = un seul
# serveur d'horloge (celui de l'hôte) + simple pipe d'octets → audio propre.
#
# Le conteneur garde son PulseAudio autonome ; on ne touche pas à gsm_audio
# (le dashboard continue de lire gsm_audio.monitor).
#
# Usage :
#   wslg-audio-bridge.sh host-relay              # hôte : ouvre le pulse en TCP
#   wslg-audio-bridge.sh container <name> [gw]   # conteneur : lance le pont
#   wslg-audio-bridge.sh test <name>             # bip 880Hz via gsm_audio
#   wslg-audio-bridge.sh down <name>             # stoppe le pont
#   wslg-audio-bridge.sh all <name> [gw]         # host-relay + container + test
set -euo pipefail

TCP_PORT="${WSLG_TCP_PORT:-4713}"
# ACL : tout le bloc privé 172.16/12 (couvre les subnets docker gsm-inter/op)
TCP_ACL="${WSLG_TCP_ACL:-127.0.0.1;172.16.0.0/12}"

log()  { echo -e "  [host-audio] $*"; }
die()  { echo -e "  [host-audio][FAIL] $*" >&2; exit 1; }

# IP de l'hôte vue depuis le conteneur = gateway de sa route par défaut.
detect_gw() {
    docker exec "$1" sh -c "ip route 2>/dev/null | awk '/default/{print \$3; exit}'" 2>/dev/null || true
}

# Utilisateur de la session graphique (propriétaire du pulse natif).
session_user() { echo "${HOST_PULSE_USER:-${SUDO_USER:-$(id -un)}}"; }

# Exécute `pactl …` sur le pulse de l'hôte natif, en tant qu'utilisateur session.
pactl_native() {
    local u uid rt
    u="$(session_user)"; uid="$(id -u "$u")"; rt="/run/user/${uid}"
    if [ "$(id -un)" = "$u" ]; then
        XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    else
        sudo -u "$u" XDG_RUNTIME_DIR="$rt" PULSE_SERVER="unix:${rt}/pulse/native" pactl "$@"
    fi
}

# ── HÔTE : expose le pulse de l'hôte en TCP (idempotent) ─────────────────────
host_relay() {
    if [ -S /mnt/wslg/PulseServer ]; then
        # WSL2 + WSLg : socket monde-accessible (root OK)
        export PULSE_SERVER="unix:/mnt/wslg/PulseServer"
        if pactl list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP déjà actif (WSLg) :${TCP_PORT}"; return 0
        fi
        pactl load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (WSLg)"
        log "relai TCP WSLg → Windows activé :${TCP_PORT}"
    else
        # Linux natif : pulse de la session graphique
        local u uid; u="$(session_user)"; uid="$(id -u "$u")"
        [ -S "/run/user/${uid}/pulse/native" ] \
            || die "pulse de session introuvable (/run/user/${uid}/pulse/native) — session audio démarrée ? user=$u"
        if pactl_native list short modules 2>/dev/null | grep -q "protocol-tcp.*port=${TCP_PORT}"; then
            log "relai TCP déjà actif (natif, user=$u) :${TCP_PORT}"; return 0
        fi
        pactl_native load-module module-native-protocol-tcp \
            "port=${TCP_PORT}" "auth-ip-acl=${TCP_ACL}" auth-anonymous=1 >/dev/null \
            || die "load module-native-protocol-tcp (natif)"
        log "relai TCP natif activé (user=$u) :${TCP_PORT}"
    fi
}

# ── CONTENEUR : pont parec|paplay supervisé vers le pulse de l'hôte ──────────
container_bridge() {
    local name="$1" gw="${2:-}"
    [ -n "$name" ] || die "nom de conteneur requis"
    [ -z "$gw" ] && gw="$(detect_gw "$name")"
    [ -n "$gw" ] || die "gateway introuvable pour $name"
    docker exec -i "$name" sh -s -- "tcp:${gw}:${TCP_PORT}" <<'EOSH'
set -eu
RELAY="$1"
pactl info >/dev/null 2>&1 || { echo "  [host-audio][FAIL] pas de daemon pulse dans le conteneur" >&2; exit 1; }
# Le relai hôte doit être joignable
if ! pactl --server="$RELAY" info >/dev/null 2>&1; then
    echo "  [host-audio][FAIL] relai hôte injoignable ($RELAY) — lancer 'host-relay' d'abord" >&2; exit 1
fi
# Stoppe un pont précédent (idempotent)
pkill -f "paplay --server=${RELAY}" 2>/dev/null || true
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
mkdir -p /var/log/osmocom
# Pont supervisé : redémarre si parec/paplay tombe. setsid = nouveau groupe → kill propre.
setsid sh -c '
  while true; do
    parec -d gsm_audio.monitor --format=s16le --rate=8000 --channels=1 \
      | paplay --server='"${RELAY}"' --raw --format=s16le --rate=8000 --channels=1
    sleep 1
  done' >/var/log/osmocom/host-audio.log 2>&1 &
echo $! > /run/host-audio.pid
echo "  [host-audio] pont parec|paplay gsm_audio.monitor -> ${RELAY} (pgid $!)"
EOSH
}

# ── CONTENEUR : bip de test via gsm_audio (preuve bout-en-bout) ──────────────
container_test() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "sine=frequency=880:duration=1" -ar 8000 -ac 1 /tmp/host_test.wav
paplay -d gsm_audio /tmp/host_test.wav
echo "  [host-audio] bip 880Hz injecté dans gsm_audio -> hôte"
EOSH
}

container_down() {
    docker exec -i "$1" sh -s <<'EOSH'
set -eu
[ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
pkill -f 'parec -d gsm_audio.monitor' 2>/dev/null || true
rm -f /run/host-audio.pid
echo "  [host-audio] pont arrêté"
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
