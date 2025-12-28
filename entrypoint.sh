#!/bin/bash
set -e

# [cite_start]Configuration de l'environnement pour Docker [cite: 48]
container=docker
export container

# [cite_start]Vérification de la présence d'une commande [cite: 49]
if [ $# -eq 0 ]; then
  echo >&2 'ERROR: No command specified. You probably want to run bash or a script.'
  exit 1
fi

# [cite_start]Export des variables d'environnement pour les sessions systemd [cite: 51]
env > /etc/docker-entrypoint-env

# [cite_start]Création du service de démarrage pour votre script de simulation [cite: 51]
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

# [cite_start]Désactivation des services systemd conflictuels en container [cite: 52]
systemctl mask systemd-firstboot.service systemd-udevd.service systemd-modules-load.service \
               systemd-udevd-kernel systemd-udevd-control 2>/dev/null || true
systemctl enable docker-entrypoint.service

# [cite_start]Localisation et exécution de systemd [cite: 53]
if [ -x /lib/systemd/systemd ]; then
  exec /lib/systemd/systemd --show-status=false --unit=multi-user.target
elif [ -x /usr/lib/systemd/systemd ]; then
  exec /usr/lib/systemd/systemd --show-status=false --unit=multi-user.target
else
  echo >&2 'ERROR: systemd is not installed'
  exit 1
fi
