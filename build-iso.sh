#!/bin/bash
# build-iso.sh — Génère une ISO bootable en utilisant build.sh et start.sh
# Aucun docker build direct dans ce script, tout passe par les scripts existants.
set -euo pipefail

OUTPUT="osmo_egprs.iso"
WORK="/tmp/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS"
DIR="$(cd "$(dirname "$0")" && pwd)"

for arg in "$@"; do case "$arg" in --output=*) OUTPUT="${arg#*=}" ;; esac; done
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

cleanup() { umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }
for t in docker mksquashfs xorriso grub-mkrescue debootstrap git; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo_egprs ISO builder (via build.sh + start.sh) ══${NC}"

# ── Étape 1 : Exécuter build.sh pour préparer l'hôte et construire osmocom-nitb ──
echo -e "${GREEN}[1/7] Exécution de build.sh...${NC}"
if [ -f "$DIR/build.sh" ]; then
    bash "$DIR/build.sh"
else
    echo -e "${YELLOW}build.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
    docker build -t osmocom-nitb "$DIR"
fi
echo -e "  ${GREEN}✓${NC} image osmocom-nitb prête"

load_start_lib() {
    local src="$DIR/start.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Étape 2 : Construire l'image osmocom-run via start.sh ─────────────────────
echo -e "${GREEN}[2/7] Construction de l'image osmocom-run via start.sh...${NC}"
load_start_lib
build_run_image
echo -e "  ${GREEN}✓${NC} osmocom-run construite"

echo -e "${GREEN}[2b/7] Préparation d'une image osmocom-run (net-host)...${NC}"

ISO_N_MS=8
ENCRYPTION="a5 0"

HOST_IP="127.0.0.1"
GATEWAY_IP="127.0.0.1"

ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
PHY_MODE="${PHY_MODE:-faketrx}"
INTER_STP_IP="127.0.0.1"

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"
echo -e "  PHY        : ${CYAN}${PHY_MODE}${NC}"

TEMP_CONFIG="$(mktemp -d)"
SMS_ROUTING_DIR="$(mktemp -d)"

if declare -f sms_routing_generate >/dev/null 2>&1; then
    sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$ISO_N_MS" || true
fi

apply_config_templates "$TEMP_CONFIG" \
    "127.0.0.1" "127.0.0.1" \
    "1" "1.1.1" "1.1.2" "1.1.3" \
    "001" "01" "OsmoGSM" \
    "127.0.0.1" "shutdown" "1"

ISO_RUN_IMAGE="osmocom-run-iso-net-host"
TMP_CID="$(docker create osmocom-run /bin/sh)"

docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG" "$SMS_ROUTING_DIR"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prête"

# ── Étape 3 : Sauvegarde de l'image Docker pour l'inclure dans l'ISO ───────
echo -e "${GREEN}[3/7] Sauvegarde de l'image osmocom-run net-host...${NC}"
mkdir -p "$ROOTFS/opt/osmo_egprs/images"
docker save "$ISO_RUN_IMAGE" | gzip > "$ROOTFS/opt/osmo_egprs/images/osmocom-run.tar.gz"
echo -e "  ${GREEN}✓${NC} image sauvegardée ($(du -h "$ROOTFS/opt/osmo_egprs/images/osmocom-run.tar.gz" | cut -f1))"

# ── Étape 4 : Bootstrap rootfs minimal ─────────────────────────────────────
echo -e "${GREEN}[4/7] debootstrap jammy (minimal)...${NC}"
debootstrap --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
    jammy "$ROOTFS" http://archive.ubuntu.com/ubuntu
echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"

# ── Étape 5 : Injection des binaires et libs depuis l'image osmocom-run ───
echo -e "${GREEN}[5/7] Injection stack Osmocom...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
docker cp "$CID:/usr/local/bin/." "$ROOTFS/usr/local/bin/"  2>/dev/null||true
docker cp "$CID:/usr/local/lib/." "$ROOTFS/usr/local/lib/"  2>/dev/null||true
docker cp "$CID:/usr/local/include/." "$ROOTFS/usr/local/include/" 2>/dev/null||true
docker cp "$CID:/opt/GSM"             "$ROOTFS/opt/GSM"     2>/dev/null||true
docker cp "$CID:/etc/osmocom/."       "$ROOTFS/etc/osmocom/" 2>/dev/null||true
docker cp "$CID:/etc/asterisk/."      "$ROOTFS/etc/asterisk/" 2>/dev/null||true
for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
    docker cp "$CID:/lib/systemd/system/${svc}.service" "$ROOTFS/lib/systemd/system/" 2>/dev/null||true
done
docker rm "$CID" &>/dev/null
echo -e "  ${GREEN}✓${NC} binaires + libs + configs injectés"
echo -e "${GREEN}[5c/7] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5b/7] Patch configs ISO...${NC}"

echo -e "${GREEN}[5b/7] Patch configs ISO...${NC}"

if [ -f "$ROOTFS/etc/osmocom/osmo-sgsn.cfg" ]; then
    sed -i \
        -e 's/^\([[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e 's/^\([[:space:]]*gsup[[:space:]]\+remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e '/^[[:space:]]*bind udp local$/,/^[[:space:]]*!$/ s/^\([[:space:]]*listen[[:space:]]\+\).*/\1127.0.0.2 23000/' \
        "$ROOTFS/etc/osmocom/osmo-sgsn.cfg"
fi

if [ -f "$ROOTFS/etc/osmocom/osmo-msc.cfg" ]; then
    sed -i \
        -e '/^hlr$/,/^!$/ s/^\([[:space:]]*remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        "$ROOTFS/etc/osmocom/osmo-msc.cfg"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + MSC appliqué"

# run.sh: réduire toute ligne "trxcon options..." à "trxcon"
#         et toute ligne "mobile options..." à "mobile"
if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    sed -i \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?trxcon\([[:space:]].*\)\?$#trxcon#' \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?mobile\([[:space:]].*\)\?$#mobile#' \
        "$ROOTFS/etc/osmocom/run.sh"
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + run.sh appliqué"
mkdir -p "$ROOTFS/usr/bin"
cp -a "$ROOTFS/usr/local/bin/." "$ROOTFS/usr/bin/" 2>/dev/null || true

mkdir -p "$ROOTFS/root/.osmocom/bb"
if [ -f "$ROOTFS/opt/osmo_egprs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo_egprs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/opt/osmo_egprs/configs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo_egprs/configs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/etc/osmocom/mobile.cfg" ]; then
    cp "$ROOTFS/etc/osmocom/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
fi

if ! chroot "$ROOTFS" getent passwd osmocom >/dev/null 2>&1; then
    chroot "$ROOTFS" useradd -m -s /bin/bash osmocom 2>/dev/null || true
fi

chroot "$ROOTFS" usermod -o -u 0 -g 0 osmocom 2>/dev/null || true

mkdir -p "$ROOTFS/home/osmocom"
chown -R 0:0 "$ROOTFS/home/osmocom" "$ROOTFS/root/.osmocom" 2>/dev/null || true

echo -e "  ${GREEN}✓${NC} user osmocom + /usr/bin + mobile.cfg prêts"

chmod +x "$ROOTFS/etc/osmocom/run.sh"

# ── Étape 6 : Injection du dashboard web ───────────────────────────────────
echo -e "${GREEN}[6/7] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
WEB_BRANCH="${OSMO_WEB_BRANCH:-main}"

WEB_TMP="$WORK/osmo-egprs-web"
git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2

mkdir -p "$WEB/web"
[ -f "$WEB_TMP/server/server.js" ]    && cp "$WEB_TMP/server/server.js"    "$WEB/server.js"
[ -f "$WEB_TMP/server/package.json" ] && cp "$WEB_TMP/server/package.json" "$WEB/package.json"
[ -d "$WEB_TMP/web" ]                 && cp -r "$WEB_TMP/web/."            "$WEB/web/"
[ -f "$WEB_TMP/start-web.sh" ]        && cp "$WEB_TMP/start-web.sh"        "$WEB/" && chmod +x "$WEB/start-web.sh"
[ -f "$WEB_TMP/Dockerfile" ]          && cp "$WEB_TMP/Dockerfile"          "$WEB/Dockerfile"
rm -rf "$WEB_TMP"
echo -e "  ${GREEN}✓${NC} /opt/osmo-egprs-web"

# ── Étape 7 : Injection des scripts projet et création de start-in-iso.sh ──
echo -e "${GREEN}[7/7] Scripts projet et adaptation ISO...${NC}"
P="$ROOTFS/opt/osmo_egprs"
mkdir -p "$P"/{scripts,configs,checks,helpers}
for f in start.sh build.sh loopback.sh vty-menu.sh vty-connect.exp \
         firewall-wan.sh setup-wan-interop.sh setup-wan-sms.sh; do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$P/$f" && chmod +x "$P/$f"
done
for d in scripts configs checks helpers; do
    [ -d "$DIR/$d" ] && cp -r "$DIR/$d/." "$P/$d/" && find "$P/$d" -name "*.sh" -exec chmod +x {} \;
done
[ -f "$DIR/Dockerfile" ]     && cp "$DIR/Dockerfile"     "$P/"
[ -f "$DIR/Dockerfile.run" ] && cp "$DIR/Dockerfile.run" "$P/"
ln -sf /opt/osmo_egprs/start.sh "$ROOTFS/usr/local/bin/osmo-start-lab"
[ -f "$DIR/osmo-launch.sh" ] && cp "$DIR/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"

# Copie du script start-in-iso.sh (s'il existe)
if [ -f "$DIR/start-in-iso.sh" ]; then
    cp "$DIR/start-in-iso.sh" "$P/start-in-iso.sh"
    chmod +x "$P/start-in-iso.sh"
    echo -e "  ${GREEN}✓${NC} /opt/osmo_egprs/start-in-iso.sh copié"
else
    echo -e "  ${YELLOW}start-in-iso.sh non trouvé, création d'un script minimal...${NC}"
    cat > "$P/start-in-iso.sh" <<'EOF'
#!/bin/bash
# start-in-iso.sh minimal (à remplacer par votre version)
echo "Veuillez fournir un script start-in-iso.sh complet."
exit 1
EOF
    chmod +x "$P/start-in-iso.sh"
fi

# ── Étape 8 : Service systemd pour charger l'image Docker au boot ─────────
cat > "$ROOTFS/etc/systemd/system/load-osmocom-image.service" <<'EOF'
[Unit]
Description=Load osmocom-run Docker image
Before=docker.service
After=docker.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/bin/bash -c 'while ! docker info &>/dev/null; do sleep 1; done'
ExecStart=/bin/bash -c 'gunzip -c /opt/osmo_egprs/images/osmocom-run.tar.gz | docker load'
ExecStartPost=rm -f /opt/osmo_egprs/images/osmocom-run.tar.gz

[Install]
WantedBy=multi-user.target
EOF

chroot "$ROOTFS" systemctl enable load-osmocom-image 2>/dev/null || true

# ── Étape 9 : Configuration chroot (paquets) ───────────────────────────────
echo -e "${GREEN}[8/7] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

chroot "$ROOTFS" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"
APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

cat > /etc/apt/sources.list <<SOURCES
deb http://archive.ubuntu.com/ubuntu jammy           main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates    main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security   main universe multiverse
SOURCES
apt-get update -qq

apt-get install -y $APT_OPTS --no-install-recommends \
    linux-image-generic initramfs-tools \
    live-boot live-boot-initramfs-tools

apt-get install -y $APT_OPTS --no-install-recommends \
    libtalloc2 libpcsclite1 libsctp1 libc-ares2 libgnutls30 \
    libortp-dev libdbi1 libdbd-sqlite3 sqlite3 \
    libfftw3-single3 libusb-1.0-0 \
    libgsm1 libasound2 libasound2-plugins \
    libsofia-sip-ua-glib3 libmnl0 \
    liburing2

apt-get install -y $APT_OPTS --no-install-recommends \
    iproute2 iptables net-tools lksctp-tools \
    tmux telnet expect whiptail netcat-openbsd \
    lsb-release pulseaudio-utils \
    console-setup keyboard-configuration locales

apt-get install -y $APT_OPTS --no-install-recommends \
    python3 python3-scapy \
    tshark wireshark-common \
    asterisk \
    ffmpeg

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

if [ ! -f /usr/bin/dockerd ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y $APT_OPTS --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/osmo-egprs-web/package.json ]; then
    cd /opt/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
'

# ── Configuration système ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
EOF
chroot "$ROOTFS" systemctl enable systemd-networkd systemd-resolved docker 2>/dev/null||true

# Autologin root
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Service web dashboard
cat > "$ROOTFS/etc/systemd/system/osmo-egprs-web.service" <<'EOF'
[Unit]
Description=osmo_egprs Web Dashboard
After=network.target docker.service
[Service]
Type=simple
WorkingDirectory=/opt/osmo-egprs-web
ExecStart=/usr/bin/node /opt/osmo-egprs-web/server.js --verbose
Restart=always
RestartSec=5
Environment=HTTP_PORT=8080
Environment=CONTAINER_PREFIX=osmo-operator-
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# Modules noyau
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Variables d'environnement
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# bashrc pour root
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
alias faketrx='python3 /opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py'
alias osmo-lab='cd /opt/osmo_egprs && ./start-in-iso.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/opt/osmo-launch.sh status'
export PS1='\[\033[0;36m\]osmo-egprs\[\033[0m\]:\[\033[0;33m\]\w\[\033[0m\]\$ '
BASH

# Message du jour
cat > "$ROOTFS/etc/motd" <<'MOTD'

  ╔══════════════════════════════════════════════════════════════╗
  ║  osmo_egprs — GSM/EGPRS Multi-PLMN Live System              ║
  ║  SS7/SIGTRAN • Osmocom • Web Dashboard                      ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  /opt/osmo-launch.sh            ← lance tout (lab + web)     ║
  ║  /opt/osmo_egprs/start-in-iso.sh ← lancement manuel du lab  ║
  ║  http://localhost:8080           ← dashboard web             ║
  ║                                                              ║
  ║  loadkeys fr                     ← changer clavier après boot║
  ╚══════════════════════════════════════════════════════════════╝

MOTD

chroot "$ROOTFS" passwd -d root 2>/dev/null||true

# Script de configuration clavier au premier boot
cat > "$ROOTFS/etc/profile.d/01-keyboard-setup.sh" <<'KBSCRIPT'
#!/bin/bash
[ -f /var/lib/osmo-kb-done ] && return 0
[ "$(id -u)" -ne 0 ] && return 0

echo ""
echo -e "\033[1;36m══ Configuration clavier ══\033[0m"
echo ""
echo "  1) fr    — Français (AZERTY)"
echo "  2) us    — English (QWERTY)"
echo "  3) de    — Deutsch (QWERTZ)"
echo "  4) es    — Español"
echo "  5) it    — Italiano"
echo "  6) pt    — Português"
echo "  7) gb    — UK English"
echo "  8) be    — Belge"
echo "  9) ch    — Suisse"
echo "  0) Autre (saisie manuelle)"
echo ""
read -rp "  Choix [1] : " KB_CHOICE
KB_CHOICE="${KB_CHOICE:-1}"

case "$KB_CHOICE" in
    1) KB_LAYOUT="fr" ;;
    2) KB_LAYOUT="us" ;;
    3) KB_LAYOUT="de" ;;
    4) KB_LAYOUT="es" ;;
    5) KB_LAYOUT="it" ;;
    6) KB_LAYOUT="pt" ;;
    7) KB_LAYOUT="gb" ;;
    8) KB_LAYOUT="be" ;;
    9) KB_LAYOUT="ch" ;;
    0)
        read -rp "  Layout (ex: fr, us, de, ru, ar...) : " KB_LAYOUT
        KB_LAYOUT="${KB_LAYOUT:-us}"
        ;;
    *) KB_LAYOUT="fr" ;;
esac

echo ""
echo -e "  \033[1;32m→ Clavier : ${KB_LAYOUT}\033[0m"

loadkeys "$KB_LAYOUT" 2>/dev/null || true

cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF

setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

touch /var/lib/osmo-kb-done

echo -e "  \033[1;33mDisclaimer:\033[0m aucun service Osmocom n'est lancé automatiquement."
echo -e "  \033[1;33mPour démarrer la stack manuellement : /etc/osmocom/run.sh\033[0m"

echo -e "  \033[1;32m✓ Clavier configuré (${KB_LAYOUT}). Rechargez avec : loadkeys ${KB_LAYOUT}\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"
umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminée"

# ── Création du squashfs et de l'ISO ───────────────────────────────────────
echo -e "${GREEN}[9/7] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-*|sort -V|tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-*|sort -V|tail -1)
[ -z "$VMLINUZ" ]||[ -z "$INITRD" ] && { echo -e "${RED}Kernel absent${NC}"; exit 1; }
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 1M \
    -e 'boot/vmlinuz-*' -e 'boot/initrd*' \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

cp "$VMLINUZ" "$ISOROOT/boot/vmlinuz"
cp "$INITRD"  "$ISOROOT/boot/initrd.img"

cat > "$ISOROOT/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5
menuentry "osmo_egprs — Live" {
    linux  /boot/vmlinuz boot=live toram quiet
    initrd /boot/initrd.img
}
menuentry "osmo_egprs — Live (verbose)" {
    linux  /boot/vmlinuz boot=live toram
    initrd /boot/initrd.img
}
menuentry "osmo_egprs — Copy to RAM" {
    linux  /boot/vmlinuz boot=live toram copytoram quiet
    initrd /boot/initrd.img
}
GRUB# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
    --product-name "osmo_egprs" -- -volid "$LABEL"
    
if command -v isohybrid &>/dev/null; then
    isohybrid --uefi "$OUTPUT"
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}grub-mkrescue a échoué — ISO non créée${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}═══ ISO prête : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
