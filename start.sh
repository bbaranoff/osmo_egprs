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

# --- 2. Nettoyage : Stop si déjà lancé ---
echo -e "${GREEN}[*] Nettoyage de l'environnement...${NC}"
[ "$(sudo docker inspect -f '{{.State.Running}}' egprs 2>/dev/null)" = "true" ] && sudo docker stop egprs


# ---- Network detection ----
GW_IP=$(ip route get 1 | awk '{print $3}')
SIP=$(ip route get 1 | awk '{print $7}')

[ -z "$SIP" ] && { echo "[!] SIP vide"; exit 0; }
[ -z "$GW_IP" ] && { echo "[!] GW_IP vide"; exit 0; }

GW_ESC=$(printf '%s\n' "$GW_IP" | sed 's/[.[\*^$]/\\&/g')
SIP_ESC=$(printf '%s\n' "$SIP"   | sed 's/[\/&]/\\&/g')

sed -Ei.bak \
-e '/127\./b' \
-e '/0\.0\.0\.0/b' \
-e "/$GW_ESC/b" \
-e "s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/$SIP_ESC/g" \
configs/*.cfg configs/*.conf
# --- 3. Préparation du noyau sur l'hôte ---
echo -e "${GREEN}[*] Configuration du module TUN sur l'hôte...${NC}"
modprobe tun
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi
ip l del apn0
ip tuntap add dev apn0 mode tun
ip addr add 176.16.32.0/24 dev apn0
ip link set apn0 up

# --- 4. Option Multi-Mobile (Avant de lancer le container) ---
# --- 5. Lancement du Docker ---
echo -e "${GREEN}[*] Lancement du conteneur egprs (Image: osmocom-nitb)...${NC}"
docker build -f Dockerfile.run -t osmocom-run .
# Lancement en mode détaché avec privilèges réseau totaux
docker run -d \
    --rm \
    --name egprs \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --cgroupns host \
    --net host \
    --device /dev/net/tun:/dev/net/tun \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    osmocom-run

echo -e "${GREEN}[*] Attente du démarrage des services systemd (SS7/SIGTRAN)...${NC}"
sleep 3

export XDG_RUNTIME_DIR="/tmp/runtime-root"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
TARGET_UID="$(id -u "$TARGET_USER")"

# Reprendre une session graphique si besoin
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"

sudo -u "$TARGET_USER" \
  env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
  nohup linphone >/dev/null 2>&1 &

wireshark -k -i any -f "udp port 4729" >/dev/null 2>&1 &
# --- 6. Exécution de l'orchestration interne (Tmux) ---
# On passe la variable DUAL_MOBILE au script interne
docker exec -it egprs /bin/bash -c "/root/run.sh"
