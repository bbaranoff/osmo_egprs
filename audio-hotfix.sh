#!/bin/bash
# audio-hotfix.sh — Installe le plugin ALSA→PulseAudio dans un container vivant
# Usage: sudo docker exec -ti osmo-operator-1 bash /scripts/audio-hotfix.sh
#
# Après ça, relancer mobile pour que le son fonctionne.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== Hotfix audio — installation libasound2-plugins ===${NC}"

# Installer le plugin ALSA→PulseAudio
apt-get update -qq
apt-get install -y --no-install-recommends libasound2-plugins pulseaudio-utils 2>&1 | tail -3

# Vérifier que le plugin pulse est maintenant disponible
if [ -f /usr/lib/x86_64-linux-gnu/alsa-lib/libasound_module_pcm_pulse.so ] || \
   [ -f /usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pulse.so ]; then
    echo -e "${GREEN}✓ Plugin ALSA pulse installé${NC}"
else
    echo -e "${RED}✗ Plugin non trouvé — architecture non supportée ?${NC}"
    find / -name "libasound_module_pcm_pulse*" 2>/dev/null | head -3
fi

# Créer /etc/asound.conf pour router default → pulse
cat > /etc/asound.conf << 'ASOUND'
# Route ALSA "default" vers PulseAudio
pcm.!default {
    type pulse
}
ctl.!default {
    type pulse
}
ASOUND
echo -e "${GREEN}✓ /etc/asound.conf créé (default → pulse)${NC}"

# Tester PulseAudio
echo ""
echo -e "${CYAN}=== Test PulseAudio ===${NC}"
if pactl info 2>/dev/null | head -5; then
    echo -e "${GREEN}✓ PulseAudio accessible${NC}"
else
    echo -e "${RED}✗ PulseAudio non accessible${NC}"
    echo "  PULSE_SERVER = ${PULSE_SERVER:-<non défini>}"
    echo "  Vérifier que le socket est monté dans le container"
fi

# Test son
echo ""
echo -e "${CYAN}=== Test son (bip 440Hz) ===${NC}"
if command -v paplay >/dev/null 2>&1; then
    # Générer un WAV en Python et le jouer via paplay
    python3 -c "
import struct, math, sys
rate=8000; dur=0.5; freq=440; vol=0.5
n=int(rate*dur)
samples=[int(32767*vol*math.sin(2*math.pi*freq*t/rate)) for t in range(n)]
hdr=struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',36+n*2,b'WAVE',b'fmt ',16,1,1,rate,rate*2,2,16,b'data',n*2)
sys.stdout.buffer.write(hdr+struct.pack('<%dh'%n,*samples))
" > /tmp/test_beep.wav 2>/dev/null

    if paplay /tmp/test_beep.wav 2>/dev/null; then
        echo -e "${GREEN}✓ Son joué via PulseAudio ! Vérifiez vos enceintes.${NC}"
    else
        echo -e "${RED}✗ paplay échoué${NC}"
        echo "  Essayer aplay directement :"
        aplay /tmp/test_beep.wav 2>&1 | head -3 || true
    fi
    rm -f /tmp/test_beep.wav
elif command -v aplay >/dev/null 2>&1; then
    python3 -c "
import struct, math, sys
rate=8000; dur=0.5; freq=440; vol=0.5
n=int(rate*dur)
samples=[int(32767*vol*math.sin(2*math.pi*freq*t/rate)) for t in range(n)]
hdr=struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',36+n*2,b'WAVE',b'fmt ',16,1,1,rate,rate*2,2,16,b'data',n*2)
sys.stdout.buffer.write(hdr+struct.pack('<%dh'%n,*samples))
" > /tmp/test_beep.wav 2>/dev/null
    aplay /tmp/test_beep.wav 2>&1 || echo -e "${RED}✗ aplay échoué${NC}"
    rm -f /tmp/test_beep.wav
fi

echo ""
echo -e "${CYAN}=== Prochaine étape ===${NC}"
echo "  Si le bip a fonctionné :"
echo "    1. Relancer le mobile : dans tmux fenêtre ue_g1, Ctrl+C puis :"
echo "       mobile -c /root/.osmocom/bb/mobile_group1.cfg"
echo "    2. Attendre l'enregistrement réseau (NORMAL service)"
echo "    3. call 1 600  → vous devez entendre l'echo test"
echo ""
echo "  Si pas de son :"
echo "    pactl info       → vérifie la connexion PulseAudio"
echo "    pactl list sinks → liste les sorties disponibles"
echo "    aplay -l         → liste les devices ALSA hw:"
echo ""
echo "  Pour le rebuild permanent, ajouter au Dockerfile.run :"
echo "    RUN apt-get install -y libasound2-plugins pulseaudio-utils"
