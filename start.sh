#!/bin/bash

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. Vérification des privilèges ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit être lancé en tant que root (sudo).${NC}" 
   exit 1
fi

# --- 2. Nettoyage : Stop si déjà lancé ---
echo -e "${GREEN}[*] Nettoyage de l'environnement...${NC}"
[ "$(sudo docker inspect -f '{{.State.Running}}' egprs 2>/dev/null)" = "true" ] && sudo docker stop egprs

# --- 3. Préparation du noyau sur l'hôte ---
echo -e "${GREEN}[*] Configuration du module TUN sur l'hôte...${NC}"
modprobe tun
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# --- 4. Option Multi-Mobile (Avant de lancer le container) ---
echo -e "\n${GREEN}--- Configuration des instances Mobile (sdr) ---${NC}"
read -p "Souhaitez-vous préparer 2 mobiles pour cette session ? (y/n) : " choice

if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    # On prépare le fichier sur l'hôte pour qu'il soit dispo si monté en volume 
    # ou on envoie un flag pour que le run.sh interne sache quoi faire.
    export DUAL_MOBILE=true
    echo -e "${GREEN}[INFO] Mode Double Mobile sélectionné.${NC}"
else
    export DUAL_MOBILE=false
fi

# --- 5. Lancement du Docker ---
echo -e "${GREEN}[*] Lancement du conteneur egprs (Image: osmocom-nitb)...${NC}"

# Lancement en mode détaché avec privilèges réseau totaux
docker run -d \
    --rm \
    --name egprs \
    --privileged \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --cgroupns host \
    --net host \
    --device /dev/net/tun:/dev/net/tun \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    osmocom-nitb

echo -e "${GREEN}[*] Attente du démarrage des services systemd (SS7/SIGTRAN)...${NC}"
sleep 3

# --- 6. Exécution de l'orchestration interne (Tmux) ---
# On passe la variable DUAL_MOBILE au script interne
docker exec -it egprs /bin/bash -c "export DUAL_MOBILE=$DUAL_MOBILE; /root/run.sh"
