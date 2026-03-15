#!/bin/bash
# pulse-gsm-setup.sh — Sink PulseAudio virtuel pour mobile (OsmocomBB)
#
# Crée gsm_audio (null-sink 8kHz mono) + loopback vers les HP.
# Patche les mobile_group*.cfg pour utiliser gsm_out / gsm_in.
# Appelé par run.sh APRÈS generate_ms_configs, AVANT mobile.

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'

GSM_SINK_NAME="gsm_audio"
LOOPBACK_LATENCY_MS=50

_check_pulse() {
    command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1
}

_sink_exists() {
    pactl list short sinks 2>/dev/null | grep -q "${GSM_SINK_NAME}"
}

pulse_gsm_setup() {
    echo -e "${CYAN}[pulse-gsm] Configuration audio isolée${NC}"

    if ! _check_pulse; then
        echo -e "  ${YELLOW}PulseAudio inaccessible — mobile utilisera default${NC}"
        _patch_mobile_configs "default" "default"
        return 0
    fi

    # 1. Nettoyer les anciens sinks gsm_audio (évite les doublons)
    pactl list short modules 2>/dev/null \
        | grep -E "null-sink.*${GSM_SINK_NAME}|loopback.*${GSM_SINK_NAME}" \
        | awk '{print $1}' \
        | xargs -rn1 pactl unload-module 2>/dev/null || true

    # 2. Créer UN SEUL null-sink
    local mod_sink
    mod_sink=$(pactl load-module module-null-sink \
        sink_name="${GSM_SINK_NAME}" \
        sink_properties=device.description="GSM-Audio" \
        rate=8000 channels=1 2>/dev/null) || true

    if _sink_exists; then
        echo -e "  ${GREEN}✓${NC} Sink ${GSM_SINK_NAME} (module ${mod_sink:-?})"
    else
        echo -e "  ${RED}✗${NC} Échec création sink — fallback default"
        _patch_mobile_configs "default" "default"
        return 0
    fi

    # 3. Loopback → HP (son GSM audible)
    local mod_lb
    mod_lb=$(pactl load-module module-loopback \
        source="${GSM_SINK_NAME}.monitor" \
        latency_msec="${LOOPBACK_LATENCY_MS}" 2>/dev/null) || true

    if [ -n "$mod_lb" ]; then
        echo -e "  ${GREEN}✓${NC} Loopback → HP (${LOOPBACK_LATENCY_MS}ms, module ${mod_lb})"
    else
        echo -e "  ${YELLOW}⚠${NC} Loopback échoué — GSM audible via Linphone uniquement"
    fi

    # 4. Vérification : exactement 1 sink
    local n_sinks
    n_sinks=$(pactl list short sinks 2>/dev/null | grep -c "${GSM_SINK_NAME}" || echo 0)
    if [ "$n_sinks" -ne 1 ]; then
        echo -e "  ${YELLOW}⚠${NC} ${n_sinks} sinks détectés (attendu: 1)"
    fi

    # 5. Patcher mobile configs
    _patch_mobile_configs "gsm_out" "gsm_in"

    echo -e "${GREEN}[pulse-gsm] Audio isolée — desktop libre${NC}"
}

_patch_mobile_configs() {
    local out_dev="$1" in_dev="$2"
    local patched=0

    for cfg in /root/.osmocom/bb/mobile_group*.cfg \
               /root/.osmocom/bb/mobile_ms*.cfg \
               /root/.osmocom/bb/mobile.cfg; do
        [ -f "$cfg" ] || continue
        grep -q "alsa-output-dev" "$cfg" 2>/dev/null || continue

        # sed -i échoue sur bind mounts Docker → cp/sed/cp
        cp "$cfg" /tmp/_mob_patch.tmp
        sed "s|alsa-output-dev .*|alsa-output-dev ${out_dev}|;s|alsa-input-dev .*|alsa-input-dev ${in_dev}|" \
            /tmp/_mob_patch.tmp > "$cfg"
        rm -f /tmp/_mob_patch.tmp
        patched=$((patched + 1))
    done

    [ "$patched" -gt 0 ] && \
        echo -e "  ${GREEN}✓${NC} ${patched} config(s) → ${out_dev}/${in_dev}" || \
        echo -e "  ${YELLOW}⚠${NC} Aucune config mobile trouvée"
}
pulse_gsm_status() {
    echo -e "${CYAN}── Audio GSM — État ──${NC}"
    if _check_pulse; then
        echo -e "  PulseAudio : ${GREEN}OK${NC}"
        pactl list short sinks 2>/dev/null | grep "${GSM_SINK_NAME}" | sed 's/^/    /'
        local lb; lb=$(pactl list short modules 2>/dev/null | grep -c "loopback.*${GSM_SINK_NAME}" || echo 0)
        echo -e "  Loopback : ${lb}"
    else
        echo -e "  PulseAudio : ${RED}inaccessible${NC}"
    fi
    echo -e "  asound.conf :"
    grep -E "^pcm\.|device " /etc/asound.conf 2>/dev/null | sed 's/^/    /' || echo "    (absent)"
    echo -e "  mobile.cfg :"
    grep "alsa-.*-dev" /root/.osmocom/bb/mobile_group*.cfg 2>/dev/null | head -2 | sed 's/^/    /' || true
}

pulse_gsm_teardown() {
    pactl list short modules 2>/dev/null \
        | grep -E "null-sink.*${GSM_SINK_NAME}|loopback.*${GSM_SINK_NAME}" \
        | awk '{print $1}' \
        | xargs -rn1 pactl unload-module 2>/dev/null || true
    echo -e "${GREEN}[pulse-gsm] Nettoyé${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-setup}" in
        setup)    pulse_gsm_setup ;;
        status)   pulse_gsm_status ;;
        teardown) pulse_gsm_teardown ;;
        *)        echo "Usage: $0 {setup|status|teardown}" ;;
    esac
fi
