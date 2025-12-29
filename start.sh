#!/bin/bash

# --- 1. Vérification des privilèges ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit être lancé en tant que root (sudo).\033[0m" 
   exit 1
fi

[ "$(sudo docker inspect -f '{{.State.Running}}' egprs 2>/dev/null)" = "true" ] && sudo docker stop egprs

# --- 2. Préparation du noyau sur l'hôte ---
echo "[*] Configuration du module TUN sur l'hôte..."
modprobe tun
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# --- 3. Lancement du Docker ---
echo "[*] Lancement du conteneur sdr-egprs..."

# On lance en arrière-plan (-d) avec l'entrypoint par défaut qui démarre systemd
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

echo "[*] Attente du démarrage de systemd..."
sleep 2

# On rentre dedans interactivement sans arrêter le container
docker exec -it egprs /root/run.sh
