#!/bin/bash

# Couleurs pour la lisibilité
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}--- Démarrage de la pile Osmocom EGPRS ---${NC}"

# Fonction pour vérifier si un service est bien actif
check_service() {
    if systemctl is-active --quiet $1; then
        echo -e "  [OK] $1 est démarré"
    else
        echo -e "  ${RED}[ERREUR]${NC} $1 a échoué au démarrage"
        journalctl -u $1 -n 20 --no-pager
    fi
}

# 1. Préparation du réseau (Interface apn0 et NAT)
echo "[1/5] Configuration réseau et interface TUN..."

# 2. Services de base (Signalisation et Base de données)
echo "[2/5] Lancement de la signalisation (STP, HLR, MGW)..."
systemctl start osmo-stp
sleep 1
systemctl start osmo-hlr
systemctl start osmo-mgw

# 3. Cœur de réseau (MSC et BSC)
echo "[3/5] Lancement du Core Network (MSC, BSC)..."
systemctl start osmo-msc
sleep 2 # Laisse le temps au MSC de se lier au STP via SIGTRAN
systemctl start osmo-bsc

# 4. GPRS / EDGE (SGSN, GGSN, PCU) et Radio (BTS)
echo "[4/5] Lancement des services DATA et Radio..."
systemctl start osmo-ggsn
systemctl start osmo-sgsn
sleep 1
systemctl start osmo-pcu
systemctl start osmo-bts

echo "[5/5] Lancement des services Voix..."
systemctl start osmo-sip-connector

echo -e "\n${GREEN}--- Vérification du statut final ---${NC}"
SERVICES="osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu osmo-bts osmo-sip-connector"

for svc in $SERVICES; do
    check_service $svc
done

echo -e "\n${GREEN}Logiciel défini par radio (SDR) prêt.${NC}"
echo "Pour surveiller les logs en temps réel : journalctl -f"
