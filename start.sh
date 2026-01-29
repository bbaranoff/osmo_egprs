#!/bin/bash

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

killall -9 wireshark linphone
# --- 1. Vérification des privilèges ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit être lancé en tant que root (sudo).${NC}" 
   exit 1
fi
touch /tmp/pcu_bts
chmod 777 /tmp/pcu_bts
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
ip l del apn0
echo nameserver 192.168.1.254 > /etc/resolv.conf
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set apn0 up

# --- 4. Option Multi-Mobile (Avant de lancer le container) ---
# --- 5. Lancement du Docker ---
echo -e "${GREEN}[*] Lancement du conteneur egprs (Image: osmocom-nitb)...${NC}"
echo -e "${GREEN}[*] Build de l'image osmocom-run...${NC}"
docker build -f Dockerfile.run -t osmocom-run .

echo -e "${GREEN}[*] Lancement du conteneur egprs...${NC}"

# ⚠️ --rm retiré pour debug et stabilité
docker run -d \
  --name egprs \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --cgroupns host \
  --net host \
  --device /dev/net/tun \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run \
  --tmpfs /run/lock \
  --tmpfs /tmp \
  --rm  \
  osmocom-run

echo -e "${GREEN}[*] Attente de systemd (PID 1) dans le conteneur...${NC}"

# Attente réelle de systemd, pas un sleep aveugle
for i in {1..15}; do
  if docker exec egprs systemctl is-system-running --quiet 2>/dev/null; then
    break
  fi
  sleep 1
done

echo -e "${GREEN}[*] systemd opérationnel.${NC}"

# Préparation environnement graphique hôte (optionnel)
export XDG_RUNTIME_DIR="/tmp/runtime-root"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
TARGET_UID="$(id -u "$TARGET_USER")"

# --- Environnement graphique ---
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"

echo -e "${GREEN}[*] Préparation environnement graphique hôte...${NC}"

export XDG_RUNTIME_DIR="/tmp/runtime-root"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# --- Lancement Linphone ---
echo -e "${GREEN}[*] Lancement Linphone (VoIP)...${NC}"

sudo -u "$TARGET_USER" \
  env DISPLAY="$DISPLAY" \
      XAUTHORITY="$XAUTHORITY" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
  nohup linphone >/dev/null 2>&1 &

# --- Lancement Wireshark ---
echo -e "${GREEN}[*] Lancement Wireshark (capture)...${NC}"

sudo -u "$TARGET_USER" \
  env DISPLAY="$DISPLAY" \
      XAUTHORITY="$XAUTHORITY" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
  nohup wireshark -k -i any >/dev/null 2>&1 &

# --- Orchestration Osmocom dans le conteneur ---
echo -e "${GREEN}[*] Lancement de la stack Osmocom (conteneur egprs)...${NC}"

docker exec -it egprs /root/run.sh
