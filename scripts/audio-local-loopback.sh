#!/usr/bin/env bash
# =============================================================================
#  scripts/audio-local-loopback.sh — brancher la voix descendante sur la carte
# =============================================================================
#  [2026-08-14] POURQUOI CE SCRIPT EXISTE.
#  `gsm_audio` est un module-null-sink : ce que `mobile` y écrit est jeté tant
#  que PERSONNE ne lit son monitor. Le dépôt supposait un module-loopback déjà
#  chargé (cf. commentaire de ensure_pulse dans lib/audio.sh) mais aucun chemin
#  ne le chargeait : enable_user_loopback() de start.sh n'est appelée nulle
#  part, et network/loopback.sh ne part qu'à la main. Symptôme : appel établi,
#  sortie ALSA SUSPENDED, pcm0p/sub0/status = "closed", zéro son.
#
#  Ce script est le point d'entrée BOOT de ensure_local_loopback() : il attend
#  que le démon PulseAudio réponde (course au démarrage : osmo-pulse.service
#  forke avant que le socket soit bindé), puis charge le loopback — une seule
#  fois, vers une sortie matérielle, jamais vers gsm_audio/gsm_mic.
#
#  Usage : audio-local-loopback.sh [timeout_s]   (défaut 30)
#  Neutralisé par AUDIO=0 ou AUDIO_LOCAL_LOOPBACK=0.
#  Latence réglable par LOOPBACK_LATENCY_MSEC (défaut 20).
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HERE
: "${PULSE_SOCK:=/var/run/pulse/native}"
export PULSE_SERVER="unix:${PULSE_SOCK}"

# shellcheck source=../lib/audio.sh
. "${HERE}/lib/audio.sh"

deadline="${1:-30}"
while [ "$deadline" -gt 0 ] && ! pactl info >/dev/null 2>&1; do
    sleep 1
    deadline=$(( deadline - 1 ))
done

if ! pactl info >/dev/null 2>&1; then
    echo "[audio] PulseAudio injoignable @ ${PULSE_SOCK} — loopback local non chargé" >&2
    exit 0   # non fatal : ne doit jamais faire échouer osmo-pulse.service
fi

ensure_local_loopback
exit 0
