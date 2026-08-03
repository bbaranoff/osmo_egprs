#!/bin/bash
# pulse-gsm-setup.sh — Configure PulseAudio for osmo-gapk audio
#
# Chaîne audio :
#   osmo-gapk → ALSA "gsm_out" → asound.conf(type pulse, device gsm_audio)
#              → PulseAudio null-sink "gsm_audio"
#              → gsm_audio.monitor → parec → WebSocket → navigateur
#
# Appelé par run.sh avant le lancement d'OsmocomBB/gapk.
# Requiert : PULSE_SERVER défini + socket monté par start.sh

set -u

TAG="[pulse-gsm]"
TIMEOUT="${PULSE_TIMEOUT:-30}"
SINK_NAME="gsm_audio"
SINK_RATE=8000
SINK_CHANNELS=1
SINK_FORMAT="s16le"

log()  { echo "$TAG $*"; }
err()  { echo "$TAG ERROR: $*" >&2; }

# ── 1. Attente PulseAudio ────────────────────────────────────────────────────
wait_pulse() {
    local i=0
    while [ $i -lt "$TIMEOUT" ]; do
        if pactl info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

log "Attente connexion PulseAudio (${PULSE_SERVER:-non défini})..."

if ! wait_pulse; then
    err "PulseAudio injoignable après ${TIMEOUT}s"
    err "Vérifier que PULSE_SERVER est défini et le socket monté"
    exit 1
fi

log "PulseAudio connecté"

# ── 2. Création du null-sink gsm_audio ───────────────────────────────────────
if pactl list short sinks 2>/dev/null | grep -q "$SINK_NAME"; then
    log "Sink ${SINK_NAME} déjà présent"
else
    if pactl load-module module-null-sink \
        sink_name="$SINK_NAME" \
        format="$SINK_FORMAT" \
        rate="$SINK_RATE" \
        channels="$SINK_CHANNELS" \
        sink_properties=device.description=GSM_Audio >/dev/null 2>&1; then
        log "Sink ${SINK_NAME} créé (${SINK_FORMAT}/${SINK_RATE}Hz/${SINK_CHANNELS}ch)"
    else
        err "Échec création sink ${SINK_NAME}"
        exit 1
    fi
fi

# ── 3. Vérification monitor ──────────────────────────────────────────────────
if pactl list short sources 2>/dev/null | grep -q "${SINK_NAME}.monitor"; then
    log "Source ${SINK_NAME}.monitor disponible"
else
    err "Source ${SINK_NAME}.monitor introuvable"
    exit 1
fi

# ── 4. Empêcher la suspension automatique ────────────────────────────────────
# PulseAudio suspend les sinks inactifs → osmo-gapk écrit dans le vide
# et il faut toggle les haut-parleurs sur l'hôte pour réveiller le flux

pactl suspend-sink "$SINK_NAME" 0 2>/dev/null || true
pactl suspend-source "${SINK_NAME}.monitor" 0 2>/dev/null || true

# Désactiver module-suspend-on-idle s'il est chargé
SUSPEND_IDX=$(pactl list short modules 2>/dev/null | awk '/module-suspend-on-idle/ {print $1; exit}')
if [ -n "$SUSPEND_IDX" ]; then
    pactl unload-module "$SUSPEND_IDX" 2>/dev/null && \
        log "module-suspend-on-idle désactivé" || true
fi

log "Sink ${SINK_NAME} forcé actif (pas de suspend)"

log "Configuration audio prête"
# NOTE : pas de loopback gsm_audio → haut-parleurs.
# Écoute via parec → WebSocket → navigateur uniquement.
# Sink maintenu actif par suspend-sink 0 + suppression module-suspend-on-idle (étape 4).
