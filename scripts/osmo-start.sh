#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}--- Création APN0 ---${NC}"
if ip link show apn0 > /dev/null 2>&1; then
    ip link del dev apn0
fi
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set dev apn0 up

echo -e "${GREEN}--- Démarrage de la pile Osmocom EGPRS ---${NC}"

check_service() {
    if systemctl is-active --quiet $1; then
        echo -e "  [OK] $1 est démarré"
    else
        echo -e "  ${RED}[ERREUR]${NC} $1 a échoué au démarrage"
        journalctl -u $1 -n 20 --no-pager
    fi
}

echo "[1/4] Configuration réseau et interface TUN..."

echo "[2/4] Lancement de la signalisation (STP, HLR, MGW)..."
systemctl start osmo-stp
sleep 1
systemctl start osmo-hlr
systemctl start osmo-mgw

echo "[3/4] Lancement du Core Network (MSC, BSC)..."
systemctl start osmo-msc
sleep 2
systemctl start osmo-bsc
sleep 3

echo "[4/4] Lancement des services DATA (GGSN, SGSN, PCU)..."
systemctl start osmo-ggsn
systemctl start osmo-sgsn
sleep 1
systemctl start osmo-pcu
sleep 1
chmod 777 /tmp/pcu_bts 2>/dev/null || true

# NOTE : osmo-bts-trx et osmo-sip-connector sont intentionnellement
# absents ici. run.sh les démarre dans l'ordre correct :
#   fake_trx → osmo-bts-trx   (évite la race condition TRX)
#   Asterisk → osmo-sip-connector  (évite le MNCC connect avant SIP UP)

echo -e "\n${GREEN}--- Vérification du statut ---${NC}"
SERVICES="osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu"
for svc in $SERVICES; do
    check_service $svc
done

echo -e "\n${GREEN}Core Osmocom prêt. BTS et SIP connector gérés par run.sh.${NC}"
