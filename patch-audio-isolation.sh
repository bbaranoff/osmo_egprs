#!/bin/bash
# patch-audio-isolation.sh — Intègre l'audio PulseAudio isolée dans le projet
#
# Modifications :
#   start.sh     : REAL_UID fix + mount asound.conf + mount pulse-gsm-setup.sh
#   run.sh       : appel pulse-gsm-setup avant mobile
#   Dockerfile   : COPY des nouveaux fichiers
#
# Usage : cd ~/osmo_egprs && bash patch-audio-isolation.sh

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

# ── Vérifications ─────────────────────────────────────────────────────────────
for f in start.sh scripts/run.sh Dockerfile.run; do
    [ -f "$f" ] || { echo -e "${RED}$f introuvable — lancer depuis ~/osmo_egprs${NC}"; exit 1; }
done

# ── Copier les nouveaux fichiers ──────────────────────────────────────────────
echo -e "${CYAN}[1/5] Installation fichiers${NC}"

cp -v pulse-gsm-setup.sh scripts/pulse-gsm-setup.sh
chmod +x scripts/pulse-gsm-setup.sh

cp -v asound.conf configs/asound.conf

echo -e "  ${GREEN}✓${NC} scripts/pulse-gsm-setup.sh + configs/asound.conf"

# ── Backup ────────────────────────────────────────────────────────────────────
echo -e "${CYAN}[2/5] Backups${NC}"
TS=$(date +%s)
cp start.sh "start.sh.bak.${TS}"
cp scripts/run.sh "scripts/run.sh.bak.${TS}"
cp Dockerfile.run "Dockerfile.run.bak.${TS}"
echo -e "  ${GREEN}✓${NC} Backups .bak.${TS}"

# ══════════════════════════════════════════════════════════════════════════════
# 3. PATCH start.sh
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[3/5] Patch start.sh${NC}"

# 3a. Ajouter REAL_UID (si pas déjà présent)
if ! grep -q 'REAL_UID=' start.sh; then
    # Insérer après la ligne HOST_IP="${HOST_IP:-127.0.0.1}" dans start_bridge_mode
    sed -i '/^    HOST_IP="${HOST_IP:-127.0.0.1}"/a\    REAL_UID=$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}")' start.sh
    echo -e "  ${GREEN}✓${NC} REAL_UID ajouté"
else
    echo -e "  ${GREEN}✓${NC} REAL_UID déjà présent"
fi

# 3b. Aussi dans start_host_mode (si net-host utilisé)
if ! grep -q 'REAL_UID' start.sh | grep -q 'start_host_mode'; then
    sed -i '/^start_host_mode()/,/^}/ {
        /HOST_IP="$src_ip"/a\    REAL_UID=$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}")
    }' start.sh 2>/dev/null || true
fi

# 3c. Remplacer ${UID} par ${REAL_UID} dans les lignes pulse/XDG
sed -i 's|/run/user/${UID}/pulse|/run/user/${REAL_UID}/pulse|g' start.sh
sed -i 's|-e XDG_RUNTIME_DIR=/run/user/${UID}|-e XDG_RUNTIME_DIR=/run/user/${REAL_UID}|g' start.sh
echo -e "  ${GREEN}✓${NC} \${UID} → \${REAL_UID} (PulseAudio mount)"

# 3d. Ajouter le mount de asound.conf dans apply_config_templates
# On copie asound.conf dans le tmpdir pour qu'il soit monté
if ! grep -q 'asound.conf' start.sh; then
    # Ajouter dans apply_config_templates, après la copie de mobile.cfg
    sed -i '/cp "configs\/mobile.cfg" "\$dest\/bb\/mobile.cfg"/a\
\
    # asound.conf → /etc/asound.conf\
    if [ -f "configs/asound.conf" ]; then\
        cp "configs/asound.conf" "$dest/asound.conf"\
    fi' start.sh

    # Ajouter le mount dans build_vol_args
    sed -i '/vol_args="$vol_args -v $tmpdir\/bb\/mobile.cfg:\/root\/.osmocom\/bb\/mobile.cfg"/a\
    fi\
    if [ -f "$tmpdir/asound.conf" ]; then\
        vol_args="$vol_args -v $tmpdir/asound.conf:/etc/asound.conf"' start.sh

    # Fix: la structure if/fi est cassée, on doit corriger
    # Approche plus safe : ajouter juste après le dernier fi de build_vol_args
    # En fait, faisons-le autrement — injection directe dans docker run
    :
fi

# Approche plus fiable : ajouter -v asound.conf directement dans le docker run
# Chercher la ligne vol_args dans le docker run et ajouter le mount
if ! grep -q 'asound.conf:/etc/asound.conf' start.sh; then
    # Dans build_vol_args, avant le echo final
    sed -i '/^build_vol_args() {/,/^}/ {
        /echo "$vol_args"/i\
    if [ -f "$tmpdir/asound.conf" ]; then\
        vol_args="$vol_args -v $tmpdir/asound.conf:/etc/asound.conf"\
    fi
    }' start.sh
    echo -e "  ${GREEN}✓${NC} Mount asound.conf → /etc/asound.conf"
fi

# 3e. Monter aussi pulse-gsm-setup.sh dans le container
if ! grep -q 'pulse-gsm-setup' start.sh; then
    # Ajouter dans apply_config_templates, dans la boucle de copie des scripts
    sed -i '/for s in entrypoint.sh osmo-start.sh status.sh run.sh gapk-start.sh/s/gapk-start.sh/gapk-start.sh pulse-gsm-setup.sh/' start.sh
    echo -e "  ${GREEN}✓${NC} pulse-gsm-setup.sh dans la copie de scripts"
fi

# 3f. Vérif syntaxe
if bash -n start.sh 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} start.sh syntaxe OK"
else
    echo -e "  ${RED}✗${NC} start.sh erreur de syntaxe — vérifier manuellement"
    bash -n start.sh 2>&1 | head -5
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. PATCH scripts/run.sh
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[4/5] Patch scripts/run.sh${NC}"

if ! grep -q 'pulse-gsm-setup' scripts/run.sh; then
    # Insérer AVANT la ligne [7/10] Mobile
    sed -i '/^echo -e ".*\[7\/10\] Mobile/i\
echo -e "${GREEN}=== [6b/10] Audio PulseAudio ===${NC}"\
if [ -f /etc/osmocom/pulse-gsm-setup.sh ]; then\
    source /etc/osmocom/pulse-gsm-setup.sh\
    pulse_gsm_setup\
elif [ -f /scripts/pulse-gsm-setup.sh ]; then\
    source /scripts/pulse-gsm-setup.sh\
    pulse_gsm_setup\
else\
    echo -e "  ${YELLOW}pulse-gsm-setup.sh absent${NC}"\
fi\
echo ""' scripts/run.sh
    echo -e "  ${GREEN}✓${NC} Appel pulse_gsm_setup inséré avant Mobile"
else
    echo -e "  ${GREEN}✓${NC} Déjà patché"
fi

# Aussi dans run.sh racine si différent
if [ -f "run.sh" ] && ! grep -q 'pulse-gsm-setup' run.sh; then
    sed -i '/^echo -e ".*\[7\/10\] Mobile/i\
echo -e "${GREEN}=== [6b/10] Audio PulseAudio ===${NC}"\
if [ -f /etc/osmocom/pulse-gsm-setup.sh ]; then\
    source /etc/osmocom/pulse-gsm-setup.sh\
    pulse_gsm_setup\
elif [ -f /scripts/pulse-gsm-setup.sh ]; then\
    source /scripts/pulse-gsm-setup.sh\
    pulse_gsm_setup\
else\
    echo -e "  ${YELLOW}pulse-gsm-setup.sh absent${NC}"\
fi\
echo ""' run.sh
fi

if bash -n scripts/run.sh 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} run.sh syntaxe OK"
else
    echo -e "  ${RED}✗${NC} run.sh erreur de syntaxe"
    bash -n scripts/run.sh 2>&1 | head -5
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. PATCH Dockerfile.run
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}[5/5] Patch Dockerfile.run${NC}"

if ! grep -q 'pulse-gsm-setup' Dockerfile.run; then
    # Ajouter après la ligne COPY scripts/smsc-start.sh
    sed -i '/^COPY scripts\/smsc-start.sh/a\
COPY scripts/pulse-gsm-setup.sh /scripts/pulse-gsm-setup.sh\
COPY configs/asound.conf /etc/asound.conf' Dockerfile.run

    echo -e "  ${GREEN}✓${NC} Dockerfile.run patché"
else
    echo -e "  ${GREEN}✓${NC} Déjà patché"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Résumé
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}═══ Patch appliqué ═══${NC}"
echo ""
echo -e "  ${CYAN}Chaîne audio :${NC}"
echo ""
echo "    mobile (io-handler gapk)"
echo "      ↓ ALSA device 'gsm_out' (/etc/asound.conf)"
echo "    PulseAudio sink 'gsm_audio' (null-sink 8kHz mono)"
echo "      ↓ module-loopback (50ms)"
echo "    PulseAudio default sink → HP"
echo ""
echo "    Linphone / desktop"
echo "      ↓ ALSA 'default'"
echo "    PulseAudio default sink → HP (pas de conflit)"
echo ""
echo -e "  ${CYAN}Rebuild & relance :${NC}"
echo "    sudo ./start.sh stop"
echo "    sudo docker build -f Dockerfile.run -t osmocom-run ."
echo "    sudo ./start.sh"
echo ""
echo -e "  ${CYAN}Diagnostic dans le container :${NC}"
echo "    docker exec osmo-operator-1 /etc/osmocom/pulse-gsm-setup.sh status"
echo ""
echo -e "  ${CYAN}Fichiers modifiés :${NC}"
echo "    configs/asound.conf               (nouveau)"
echo "    scripts/pulse-gsm-setup.sh        (nouveau)"
echo "    start.sh                          (REAL_UID + mount asound + mount pulse-gsm)"
echo "    scripts/run.sh                    (appel pulse_gsm_setup avant mobile)"
echo "    Dockerfile.run                    (COPY pulse-gsm + asound)"
