#!/bin/bash

# 1. Vérification des privilèges ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit être lancé en tant que root (sudo).\033[0m" 
   exit 1
fi

echo "--- Préparation complète de l'hôte (SDR & Docker) ---"

# 2. Installation de Docker (si non présent)
if ! command -v docker &> /dev/null; then
    echo "[*] Docker n'est pas installé. Installation en cours..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# 3. Installation des dépendances critiques sur l'hôte
# SCTP est vital pour les protocoles de signalisation Osmocom
echo "[*] Installation de SCTP, TUN et D-Bus sur l'hôte..."
apt-get update
apt-get install -y lksctp-tools libsctp-dev dbus tunctl libusb-1.0-0-dev

# 4. Chargement des modules noyau
echo "[*] Chargement des modules noyau (SCTP & TUN)..."
modprobe sctp
modprobe tun

# Vérification du module SCTP
if lsmod | grep -q sctp; then
    echo -e "\033[0;32m[OK] Module SCTP chargé sur l'hôte.\033[0m"
else
    echo -e "\033[0;31m[ERREUR] Impossible de charger SCTP.\033[0m"
fi

# 5. Lancement du build Docker
echo "--- Lancement du build de l'image osmocom-nitb ---"
# On utilise --no-cache si tu veux une installation propre des paquets dans le container
docker build . -t osmocom-nitb

# 6. Vérification du succès
if [ $? -eq 0 ]; then
    echo -e "\033[0;32m[OK] Image osmocom-nitb construite avec succès.\033[0m"
else
    echo -e "\033[0;31m[ERREUR] Le build Docker a échoué.\033[0m"
    exit 1
fi
