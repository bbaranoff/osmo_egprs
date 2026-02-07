#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# ---- Root check ----
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit être lancé en root (sudo).${NC}"
   exit 1
fi

# ---- Kill old stuff ----
killall -9 wireshark linphone 2>/dev/null || true

# ---- Network detection ----
GW_IP=$(ip route show default | awk '/default/ {print $3}')
HOST_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

echo -e "${GREEN}[*] Gateway : ${GW_IP}${NC}"
echo -e "${GREEN}[*] IP hôte : ${HOST_IP}${NC}"

# ---- PCU socket ----
touch /tmp/pcu_bts
chmod 777 /tmp/pcu_bts

# ---- Docker cleanup ----
echo -e "${GREEN}[*] Nettoyage Docker...${NC}"
docker rm -f egprs 2>/dev/null || true

# ---- TUN setup ----
echo -e "${GREEN}[*] Configuration TUN...${NC}"
modprobe tun
mkdir -p /dev/net
[[ -c /dev/net/tun ]] || {
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
}

ip link del apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.1/24 dev apn0
ip link set apn0 up

echo "nameserver ${GW_IP}" > /etc/resolv.conf
service docker restart
# ---- Build Docker image ----
echo -e "${GREEN}[*] Build image osmocom-run...${NC}"
docker build -f Dockerfile.run -t osmocom-run .

# ---- Start container ----
echo -e "${GREEN}[*] Démarrage conteneur egprs...${NC}"
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
  osmocom-run

# ---- Wait for systemd ----
echo -e "${GREEN}[*] Attente systemd...${NC}"
if [ "$EUID" -ne 0 ]; then
    exec sudo env HOME="$HOME" USER="$USER" PATH="$PATH" bash "$0" "$@"
fi

echo -e "${GREEN}[*] systemd OK.${NC}"

# ---- Linphone (user) ----
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"

if [[ -n "${DISPLAY:-}" ]]; then
    echo -e "${GREEN}[*] Lancement Linphone (user)...${NC}"
    sudo -u "$TARGET_USER" \
      env DISPLAY="${DISPLAY}" \
          XAUTHORITY="${XAUTHORITY:-/home/${TARGET_USER}/.Xauthority}" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
      nohup linphone >/dev/null 2>&1 &
else
    echo -e "${GREEN}[*] Pas de DISPLAY, skip Linphone.${NC}"
fi

# ---- Launch Osmocom stack inside container ----
echo -e "${GREEN}[*] Lancement stack Osmocom...${NC}"
docker exec -it egprs /root/run.sh

# ---- Re-apply TUN on exit ----
echo -e "${GREEN}[*] Re-application réseau TUN...${NC}"
ip link del apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.1/24 dev apn0
ip link set apn0 up
echo "nameserver ${GW_IP}" > /etc/resolv.conf
