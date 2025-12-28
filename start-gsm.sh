#!/bin/bash

# --- 1. Vérification des privilèges ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit être lancé en tant que root (sudo).\033[0m" 
   exit 1
fi

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

# On enchaîne le script de démarrage Osmocom PUIS le bash interactif
docker run -ti --rm \
    --name sdr-egprs \
    --cap-add SYS_ADMIN \
    --cap-add NET_ADMIN \
    --security-opt apparmor=unconfined \
    --cgroupns host \
    --net host \
    --device /dev/net/tun:/dev/net/tun \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    sdr-build-env \
    /bin/bash -c "cd /etc/osmocom; /bin/bash"
