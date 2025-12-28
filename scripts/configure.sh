cat <<'EOF' > /etc/osmocom/osmo-config.sh
#!/bin/bash
echo "--- Configuration de l'environnement Osmocom ---"

# 1. Création de l'utilisateur (si inexistant)
id -u osmocom &>/dev/null || (groupadd osmocom && useradd -r -g osmocom -s /sbin/nologin osmocom)

# 2. Correction des fichiers services (Scheduling & User)
echo "[*] Correction des fichiers .service..."
sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service
sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service
sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service

# 3. Création du nœud TUN pour le GGSN
echo "[*] Configuration du périphérique TUN..."
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200
chmod 666 /dev/net/tun

# 4. Configuration de l'interface APN
echo "[*] Montage de l'interface apn0..."
ip link delete apn0 2>/dev/null || true
ip tuntap add dev apn0 mode tun
ip link set apn0 up
ip addr add 176.16.32.1/20 dev apn0
ip addr add 2001:780:44:2100::1/56 dev apn0

# 5. Routage et NAT
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 176.16.32.0/20 ! -d 176.16.32.0/20 -j MASQUERADE

# 6. Création du service BTS manquant
echo "[*] Génération de osmo-bts.service..."
cat <<EOT > /lib/systemd/system/osmo-bts.service
[Unit]
Description=Osmocom BTS (Virtual)
After=network-online.target osmo-bsc.service
[Service]
Type=simple
Restart=always
ExecStart=/usr/bin/osmo-bts-virtual -c /etc/osmocom/osmo-bts.cfg
RestartSec=2
User=root
[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
echo "--- Configuration terminée ---"
EOF

chmod +x /etc/osmocom/osmo-config.sh
