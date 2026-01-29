#!/bin/bash

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

killall -9 wireshark linphone 2>/dev/null || true

# --- ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit être lancé en tant que root (sudo).${NC}"
   exit 1
fi

# --- Détection réseau ---
GW_IP=$(ip route show default | awk '/default/ {print $3}')
HOST_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

echo -e "${GREEN}[*] Gateway détectée : ${GW_IP}${NC}"
echo -e "${GREEN}[*] IP hôte détectée : ${HOST_IP}${NC}"

touch /tmp/pcu_bts
chmod 777 /tmp/pcu_bts

# --- Nettoyage ---
echo -e "${GREEN}[*] Nettoyage de l'environnement...${NC}"
[ "$(docker inspect -f '{{.State.Running}}' egprs 2>/dev/null)" = "true" ] && docker stop egprs || true

# --- TUN ---
echo -e "${GREEN}[*] Configuration du module TUN sur l'hôte...${NC}"
modprobe tun
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

ip l del apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set apn0 up

echo "nameserver ${GW_IP}" > /etc/resolv.conf

# --- PATCH CONFIGS ---
echo -e "${GREEN}[*] Mise à jour automatique des IP dans les configs...${NC}"
sed -i "s/192\.168\.1\.101/${HOST_IP}/g" configs/*.cfg configs/*.conf 2>/dev/null || true

# --- BUILD ---
echo -e "${GREEN}[*] Build de l'image osmocom-run...${NC}"
docker build -f Dockerfile.run -t osmocom-run .

# --- RUN ---
echo -e "${GREEN}[*] Lancement du conteneur egprs...${NC}"
docker run -d \
  --name egprs \
  --rm \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --cgroupns host \
  --net host \
  --device /dev/net/tun \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run \
  --tmpfs /run/lock \
  --tmpfs /tmp \
  --rm \
  osmocom-run

# --- Attente systemd (comme avant) ---
echo -e "${GREEN}[*] Attente de systemd (PID 1) dans le conteneur...${NC}"
for i in {1..15}; do
  docker exec egprs systemctl is-system-running --quiet 2>/dev/null && break
  sleep 1
done
echo -e "${GREEN}[*] systemd opérationnel.${NC}"

# --- Environnement graphique ---
export XDG_RUNTIME_DIR="/tmp/runtime-root"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
TARGET_UID="$(id -u "$TARGET_USER")"
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="/home/$TARGET_USER/.Xauthority"

# --- Linphone ---
echo -e "${GREEN}[*] Lancement Linphone (VoIP)...${NC}"
sudo -u "$TARGET_USER" \
  env DISPLAY="$DISPLAY" \
      XAUTHORITY="$XAUTHORITY" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
  nohup linphone >/dev/null 2>&1 &

# --- Wireshark ---
echo -e "${GREEN}[*] Lancement Wireshark (capture en root)...${NC}"

DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-/root/.Xauthority}"

# Autoriser root à afficher sur le X de l'utilisateur courant (une fois)
xhost +SI:localuser:root >/dev/null 2>&1 || true

nohup wireshark -k -i any >/dev/null 2>&1 &

# --- Osmocom ---
echo -e "${GREEN}[*] Lancement de la stack Osmocom...${NC}"
docker exec -it egprs /root/run.sh

# --- Reapply réseau ---
ip l del apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set apn0 up
echo "nameserver ${GW_IP}" > /etc/resolv.conf

