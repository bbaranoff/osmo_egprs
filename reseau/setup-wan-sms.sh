#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# reseau/setup-wan-sms.sh — Routage SMS inter-serveur
#
# Ajoute le routage SMS pour le préfixe 66 dans la table sms-routing.conf
# de chaque opérateur. Les SMS à destination de 66XXXXX sont relayés
# via TCP vers le sms-interop-relay.py du serveur distant.
#
# Usage :
#   sudo ./reseau/setup-wan-sms.sh <remote_public_ip> [n_operators]
#
# Exécuter sur CHAQUE serveur.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

REMOTE_IP="${1:-}"
N_OPS="${2:-2}"
WAN_PREFIX="66"
RELAY_PORT=7890
CONTAINER_PREFIX="osmo-operator-"

if [ -z "$REMOTE_IP" ]; then
    echo "Usage: sudo $0 <remote_public_ip> [n_operators]"
    exit 1
fi

echo -e "${GREEN}Configuration SMS WAN → ${REMOTE_IP}${NC}"
echo ""

for i in $(seq 1 "$N_OPS"); do
    cname="${CONTAINER_PREFIX}${i}"

    echo -e "  ${CYAN}Op${i}${NC} — Mise à jour sms-routing.conf..."

    # Ajouter les routes WAN dans sms-routing.conf
    docker exec "$cname" bash -c "
        CONF='/etc/osmocom/sms-routing.conf'
        
        # Retirer l'ancien bloc WAN s'il existe
        sed -i '/# ── WAN ROUTES/,/# ── FIN WAN/d' \"\$CONF\" 2>/dev/null || true
        
        # Ajouter les opérateurs distants dans [operators]
        # On utilise des IDs 100+N pour les opérateurs distants
        cat >> \"\$CONF\" << SMSEOF

# ── WAN ROUTES — Serveur distant ${REMOTE_IP} ─────────────────────────────
# Les IDs 100+ désignent les opérateurs sur le serveur distant.
# Le relay utilise l'IP du serveur distant pour la connexion TCP.

SMSEOF

        # Ajouter dans la section [operators] si pas déjà présent
        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            if ! grep -q \"^\${wan_op_id} =\" \"\$CONF\"; then
                # Insérer après la dernière ligne de [operators]
                sed -i \"/^\\[operators\\]/,/^\\[/ {
                    /^\\[routes\\]/i \${wan_op_id} = ${REMOTE_IP}
                }\" \"\$CONF\" 2>/dev/null || true
            fi
        done

        # Ajouter les routes pour le préfixe WAN
        cat >> \"\$CONF\" << SMSEOF2
# Routes WAN : préfixe ${WAN_PREFIX}NXXXX → opérateur distant N
SMSEOF2

        for j in \$(seq 1 ${N_OPS}); do
            wan_op_id=\$((100 + j))
            # Route préfixe : 66 + opérateur + numéro
            echo \"${WAN_PREFIX}\${j}0000 = \${wan_op_id}\" >> \"\$CONF\"
            for ms in \$(seq 1 8); do
                msisdn=\$(( j * 10000 + ms ))
                echo \"${WAN_PREFIX}\${msisdn} = \${wan_op_id}\" >> \"\$CONF\"
            done
        done
        
        echo '# ── FIN WAN ─────────────────────────────────────────────────────' >> \"\$CONF\"
    "

    echo -e "  ${GREEN}✓${NC} Op${i} SMS WAN routes ajoutées"
done

echo ""
echo -e "${GREEN}SMS WAN routing configuré.${NC}"
echo -e "  SMS vers ${CYAN}${WAN_PREFIX}10001${NC} → serveur distant Op1 MS1"
echo -e "  SMS vers ${CYAN}${WAN_PREFIX}20001${NC} → serveur distant Op2 MS1"
echo ""
echo -e "  ${CYAN}Note :${NC} Le sms-interop-relay.py doit être accessible"
echo -e "  depuis l'extérieur sur le port TCP ${RELAY_PORT}."
echo -e "  Firewall : ufw allow from ${REMOTE_IP} to any port ${RELAY_PORT} proto tcp"
