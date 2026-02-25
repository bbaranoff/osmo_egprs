#!/bin/bash
set -e

# --- AJOUT DE LA PARTIE TUN ---
echo "[*] Initialisation du périphérique TUN pour osmo-ggsn..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    # Création du nœud de périphérique (c = caractère, 10 = majeur, 200 = mineur)
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# --- CONFIGURATION ENVIRONNEMENT ---
container=docker
export container

# Vérification de la présence d'une commande
if [ $# -eq 0 ]; then
  echo >&2 'ERROR: No command specified. You probably want to run bash or a script.'
  exit 1
fi

# Export des variables pour les sessions systemd
env > /etc/docker-entrypoint-env

# Création du service de démarrage
quoted_args="$(printf " %q" "${@}")"
echo "${quoted_args}" > /etc/docker-entrypoint-cmd

cat >/etc/systemd/system/docker-entrypoint.service <<EOT
[Unit]
Description=Lancement de la stack Osmocom Simulee
After=network.target

[Service]
ExecStart=/bin/bash -exc "source /etc/docker-entrypoint-cmd"
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
WorkingDirectory=/etc/osmocom
EnvironmentFile=/etc/docker-entrypoint-env

[Install]
WantedBy=multi-user.target
EOT

# Désactivation des services systemd conflictuels
systemctl mask systemd-firstboot.service systemd-udevd.service systemd-modules-load.service \
               systemd-udevd-kernel systemd-udevd-control 2>/dev/null || true
systemctl enable docker-entrypoint.service

# Localisation et exécution de systemd
if [ -x /lib/systemd/systemd ]; then
  exec /lib/systemd/systemd --show-status=false --unit=multi-user.target
elif [ -x /usr/lib/systemd/systemd ]; then
  exec /usr/lib/systemd/systemd --show-status=false --unit=multi-user.target
else
  echo >&2 'ERROR: systemd is not installed'
  exit 1
fi
# ── Répertoires ───────────────────────────────────────────────────────────────
RUN mkdir -p \
    /etc/osmocom /etc/asterisk \
    /var/lib/asterisk /var/log/asterisk /var/run/asterisk \
    /var/log/osmocom /var/run/smsc \
    /root/.osmocom/bb /scripts && \
    chmod 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk \
              /var/run/asterisk /var/log/osmocom

RUN apt-get update && \
    apt-get install -y --no-install-recommends telnet iproute2 tmux && \
    rm -rf /var/lib/apt/lists/*

# ── Scripts généraux ──────────────────────────────────────────────────────────
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh 2>/dev/null || true

# ── Configs ───────────────────────────────────────────────────────────────────
COPY configs/*.conf /etc/asterisk/
COPY configs/*.cfg /etc/osmocom/
COPY configs/sms-routing.conf /etc/osmocom/sms-routing.conf
COPY configs/mobile.cfg /root/.osmocom/bb/mobile.cfg

# ── Scripts SMS (proto-smsc-daemon + interop relay) ───────────────────────────
COPY scripts/osmo-start.sh        /root/osmo-start.sh
COPY scripts/run.sh               /root/run.sh
COPY scripts/smsc-start.sh        /etc/osmocom/smsc-start.sh
COPY scripts/send-mt-sms.sh       /etc/osmocom/send-mt-sms.sh
COPY scripts/sms-interop-relay.py /etc/osmocom/sms-interop-relay.py
COPY var/*                         /var/lib/osmocom/

RUN chmod +x /root/osmo-start.sh /root/run.sh \
    /etc/osmocom/smsc-start.sh /etc/osmocom/send-mt-sms.sh \
    /etc/osmocom/sms-interop-relay.py

# ── Vérification binaires ────────────────────────────────────────────────────
RUN which proto-smsc-daemon && which proto-smsc-sendmt && \
    echo "=== proto-smsc binaries OK ===" || \
    echo "WARNING: proto-smsc binaries not found"

# ── Port TCP relay interop SMS (communication entre containers) ───────────────
EXPOSE 7890
