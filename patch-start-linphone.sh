#!/bin/bash
# patch-start-linphone.sh — Applique les modifications à start.sh
#
# Modifications :
#   1. Nouveaux placeholders : __HOST_IP__, __SIP_HOST_PORT__, __ALSA_OUTPUT__, __ALSA_INPUT__
#   2. Exposition port SIP/RTP pour Linphone depuis l'hôte
#   3. Instructions Linphone dans le résumé final
#
# Usage : bash patch-start-linphone.sh
#
# Ce script modifie start.sh en place (backup créé).

set -euo pipefail

STARTSH="./start.sh"

if [ ! -f "$STARTSH" ]; then
    echo "ERREUR: start.sh introuvable dans le répertoire courant"
    exit 1
fi

cp "$STARTSH" "${STARTSH}.bak.$(date +%s)"
echo "Backup créé"

# ═══ 1. Ajouter les helpers SIP port ═══
# Après la ligne "wan_rtp_end()" ajouter les helpers linphone
if ! grep -q 'linphone_sip_port' "$STARTSH"; then
    sed -i '/^wan_rtp_end/a\
\
# Linphone SIP port per operator (host-side)\
linphone_sip_port() { echo $(( 5060 + ($1 - 1) )); }\
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }\
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }' "$STARTSH"
    echo "✓ Helpers linphone_sip_port ajoutés"
fi

# ═══ 2. Ajouter les substitutions sed manquantes dans apply_config_templates ═══
# Chercher la dernière ligne sed dans apply_config_templates et ajouter les nouvelles
if ! grep -q '__HOST_IP__' "$STARTSH"; then
    sed -i '/__SMS_SC__/a\
            -e "s|__HOST_IP__|${HOST_IP:-127.0.0.1}|g" \
            -e "s|__SIP_HOST_PORT__|${SIP_HOST_PORT:-5060}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT:-default}|g" \
            -e "s|__ALSA_INPUT__|${ALSA_INPUT:-default}|g" \\' "$STARTSH"
    echo "✓ Placeholders HOST_IP/ALSA ajoutés à apply_config_templates"
fi

# ═══ 3. Ajouter HOST_IP auto-detection dans start_bridge_mode ═══
# Avant la boucle "Démarrage séquentiel des opérateurs"
if ! grep -q 'HOST_IP=' "$STARTSH" | grep -v 'WAN'; then
    sed -i '/# ── Démarrage séquentiel des opérateurs/i\
    # ── Détection IP hôte pour Linphone ─────────────────────────────────\
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '"'"'{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'"'"' | head -1) || true\
    if [ -z "$HOST_IP" ]; then\
        HOST_IP=$(hostname -I 2>/dev/null | awk '"'"'{print $1}'"'"') || HOST_IP="127.0.0.1"\
    fi\
    echo -e "${GREEN}IP hôte détectée : ${CYAN}${HOST_IP}${NC} (pour Linphone)"\
    echo ""\
    # ALSA device (configurable via env)\
    ALSA_OUTPUT="${ALSA_OUTPUT:-default}"\
    ALSA_INPUT="${ALSA_INPUT:-default}"\
' "$STARTSH"
    echo "✓ HOST_IP auto-detection ajouté"
fi

# ═══ 4. Ajouter port SIP dans le docker run ═══
# Ajouter l'exposition du port SIP pour chaque opérateur
# On ajoute après la ligne port_args="" existante
if ! grep -q 'linphone_sip_port' "$STARTSH" | grep -v 'helper'; then
    sed -i '/port_args=""/a\
        # Linphone SIP access from host\
        local lsip_port\
        lsip_port=$(linphone_sip_port "$i")\
        local lrtp_s lrtp_e\
        lrtp_s=$(linphone_rtp_start "$i")\
        lrtp_e=$(linphone_rtp_end "$i")\
        port_args="${port_args} -p ${lsip_port}:5060/udp -p ${lrtp_s}-${lrtp_e}:${lrtp_s}-${lrtp_e}/udp"\
        echo -e "  Linphone SIP : ${CYAN}${HOST_IP}:${lsip_port}${NC}  RTP ${lrtp_s}-${lrtp_e}"' "$STARTSH"
    echo "✓ Port SIP/RTP exposure ajouté dans docker run"
fi

# ═══ 5. Exporter HOST_IP et SIP_HOST_PORT dans le docker run -e ═══
if ! grep -q 'HOST_IP=' "$STARTSH" | grep 'docker run'; then
    sed -i '/-e INTER_STP_IP=/a\
            -e HOST_IP="${HOST_IP:-127.0.0.1}" \
            -e SIP_HOST_PORT="$(linphone_sip_port "$i")" \
            -e ALSA_OUTPUT="${ALSA_OUTPUT}" \
            -e ALSA_INPUT="${ALSA_INPUT}" \\' "$STARTSH"
    echo "✓ Variables HOST_IP/ALSA exportées dans le container"
fi

echo ""
echo "═══ Patch appliqué ═══"
echo ""
echo "Les conteneurs exposeront maintenant :"
echo "  Op1 : SIP :5060/udp  RTP 30000-30199/udp"
echo "  Op2 : SIP :5061/udp  RTP 30200-30399/udp"
echo "  Op3 : SIP :5062/udp  RTP 30400-30599/udp"
echo ""
echo "Configuration Linphone :"
echo "  SIP server : <HOST_IP>:<SIP_PORT>"
echo "  Username   : linphone_A (ou linphone_B)"
echo "  Password   : tester (ou testerB)"
echo "  Numéro     : 100 (ou 200)"
echo ""
echo "Alternative (accès direct Docker bridge) :"
echo "  SIP server : 172.20.0.11:5060 (Op1)"
echo "  → Pas de port mapping nécessaire depuis le host Linux"
