#!/bin/bash
set -euo pipefail

# =========================
# Couleurs
# =========================
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# =========================
# Root obligatoire
# =========================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERREUR] Ce script doit être lancé en root (sudo).${NC}"
   exit 1
fi

# =========================
# Kill restes éventuels
# =========================
killall -9 wireshark linphone 2>/dev/null || true

# =========================
# Détection réseau
# =========================
GW_IP=$(ip route show default | awk '/default/ {print $3}')
HOST_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

echo -e "${GREEN}[*] Gateway : ${GW_IP}${NC}"
echo -e "${GREEN}[*] IP hôte : ${HOST_IP}${NC}"

# =========================
# Fichiers temporaires
# =========================
touch /tmp/pcu_bts
chmod 777 /tmp/pcu_bts

# =========================
# Nettoyage Docker
# =========================
echo -e "${GREEN}[*] Nettoyage Docker...${NC}"
docker rm -f egprs 2>/dev/null || true

# =========================
# TUN / réseau hôte
# =========================
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

# =========================
# Build image
# =========================
echo -e "${GREEN}[*] Build image osmocom-run...${NC}"
docker build -f Dockerfile.run -t osmocom-run .

# =========================
# Lancement conteneur
# =========================
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

# =========================
# Attente systemd
# =========================
echo -e "${GREEN}[*] Attente systemd...${NC}"
for i in {1..20}; do
  docker exec egprs systemctl is-system-running --quiet && break
  sleep 1
done
echo -e "${GREEN}[*] systemd OK.${NC}"

# =========================
# Environnement graphique
# =========================
TARGET_USER="${SUDO_USER:-$(logname)}"
TARGET_UID="$(id -u "$TARGET_USER")"
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="/home/${TARGET_USER}/.Xauthority"

export XDG_RUNTIME_DIR="/run/user/${TARGET_UID}"

# =========================
# Wireshark (ROOT)
# =========================
echo -e "${GREEN}[*] Lancement Wireshark (root, lo, port 4249)...${NC}"
wireshark \
  -i lo \
  -f "udp port 4249" \
  >/dev/null 2>&1 &

# =========================
# Linphone (USER)
# =========================
echo -e "${GREEN}[*] Lancement Linphone (user)...${NC}"
sudo -u "$TARGET_USER" \
  env DISPLAY="$DISPLAY" \
      XAUTHORITY="$XAUTHORITY" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
  nohup linphone >/dev/null 2>&1 &

# =========================
# Stack Osmocom
# =========================
echo -e "${GREEN}[*] Lancement stack Osmocom...${NC}"
docker exec -it egprs /root/run.sh

# =========================
# Re-apply TUN (sécurité)
# =========================
echo -e "${GREEN}[*] Re-application réseau TUN...${NC}"
ip link del apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.1/24 dev apn0
ip link set apn0 up
echo "nameserver ${GW_IP}" > /etc/resolv.conf
