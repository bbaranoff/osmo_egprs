#!/bin/bash
# patch-pulse-gsm.sh — Intègre l'isolation audio PulseAudio dans le projet
#
# Ce script applique les modifications nécessaires :
#   1. Copie pulse-gsm-setup.sh dans scripts/
#   2. Patche run.sh pour appeler le setup avant mobile
#   3. Patche mobile.cfg pour utiliser gsm_out / gsm_in
#   4. Patche Dockerfile.run pour inclure le script
#
# Usage : bash patch-pulse-gsm.sh

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

# ══════════════════════════════════════════════════════════════════════════════
# 1. Copier le script
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[1/4] Installation pulse-gsm-setup.sh${NC}"

if [ ! -f "scripts/pulse-gsm-setup.sh" ]; then
    cp pulse-gsm-setup.sh scripts/pulse-gsm-setup.sh 2>/dev/null || \
    echo "ERREUR: pulse-gsm-setup.sh introuvable. Le placer dans scripts/"
fi
chmod +x scripts/pulse-gsm-setup.sh
echo -e "  ${GREEN}✓${NC} scripts/pulse-gsm-setup.sh"

# ══════════════════════════════════════════════════════════════════════════════
# 2. Patcher scripts/run.sh
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[2/4] Patch scripts/run.sh${NC}"

RUNSH="scripts/run.sh"
if [ ! -f "$RUNSH" ]; then
    echo "ERREUR: $RUNSH introuvable"; exit 1
fi

# Backup
cp "$RUNSH" "${RUNSH}.bak.$(date +%s)"

# Insérer le setup PulseAudio AVANT "[7/10] Mobile"
if ! grep -q 'pulse-gsm-setup' "$RUNSH"; then
    sed -i '/^echo -e ".*=== \[7\/10\] Mobile ===/i\
echo -e "${GREEN}=== [6b/10] Audio PulseAudio ===${NC}"\
PULSE_GSM_SCRIPT="/scripts/pulse-gsm-setup.sh"\
if [ -f "$PULSE_GSM_SCRIPT" ]; then\
    source "$PULSE_GSM_SCRIPT"\
    pulse_gsm_setup || echo -e "  ${YELLOW}PulseAudio setup échoué — audio fallback${NC}"\
else\
    echo -e "  ${YELLOW}pulse-gsm-setup.sh absent — audio sur default${NC}"\
fi\
echo ""' "$RUNSH"
    echo -e "  ${GREEN}✓${NC} Bloc PulseAudio inséré avant [7/10] Mobile"
else
    echo -e "  ${GREEN}✓${NC} Déjà patché"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. Patcher configs/mobile.cfg
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[3/4] Patch configs/mobile.cfg${NC}"

MOBILECFG="configs/mobile.cfg"
if [ ! -f "$MOBILECFG" ]; then
    echo "ERREUR: $MOBILECFG introuvable"; exit 1
fi

cp "$MOBILECFG" "${MOBILECFG}.bak.$(date +%s)"

# Remplacer __ALSA_OUTPUT__ par gsm_out et __ALSA_INPUT__ par gsm_in
sed -i \
    -e 's|alsa-output-dev __ALSA_OUTPUT__|alsa-output-dev gsm_out|' \
    -e 's|alsa-input-dev __ALSA_INPUT__|alsa-input-dev gsm_in|' \
    "$MOBILECFG"

echo -e "  ${GREEN}✓${NC} mobile.cfg : alsa-output-dev gsm_out / alsa-input-dev gsm_in"

# ══════════════════════════════════════════════════════════════════════════════
# 4. Patcher Dockerfile.run
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[4/4] Patch Dockerfile.run${NC}"

DOCKERFILE="Dockerfile.run"
if [ ! -f "$DOCKERFILE" ]; then
    echo "ERREUR: $DOCKERFILE introuvable"; exit 1
fi

if ! grep -q 'pulse-gsm-setup' "$DOCKERFILE"; then
    cp "$DOCKERFILE" "${DOCKERFILE}.bak.$(date +%s)"

    # Ajouter la copie du script après les autres COPY scripts/
    sed -i '/^COPY scripts\/smsc-start.sh/a\
COPY scripts/pulse-gsm-setup.sh /scripts/pulse-gsm-setup.sh' "$DOCKERFILE"

    # Ajouter le chmod
    sed -i 's|chmod +x /root/osmo-start.sh /root/run.sh|chmod +x /root/osmo-start.sh /root/run.sh \\\n    /scripts/pulse-gsm-setup.sh|' "$DOCKERFILE"

    echo -e "  ${GREEN}✓${NC} Dockerfile.run patché"
else
    echo -e "  ${GREEN}✓${NC} Déjà patché"
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}═══ Patch appliqué ═══${NC}"
echo ""
echo -e "  ${CYAN}Chaîne audio résultante :${NC}"
echo ""
echo "    mobile (io-handler gapk)"
echo "      ↓ ALSA device 'gsm_out'"
echo "    PulseAudio sink 'gsm_audio' (null-sink, 8kHz mono)"
echo "      ↓ module-loopback (50ms)"
echo "    PulseAudio default sink (carte son réelle)"
echo "      ↓"
echo "    HP / casque"
echo ""
echo "    Linphone / navigateur / desktop"
echo "      ↓ ALSA device 'default'"
echo "    PulseAudio default sink (même carte, pas de conflit)"
echo ""
echo -e "  ${CYAN}Rebuild :${NC}"
echo "    sudo docker build -f Dockerfile.run -t osmocom-run ."
echo "    sudo ./start.sh"
echo ""
echo -e "  ${CYAN}Diagnostic dans le container :${NC}"
echo "    /scripts/pulse-gsm-setup.sh status"
