#!/bin/bash
set -e

# ── TUN device pour osmo-ggsn ─────────────────────────────────────────────────
echo "[*] Initialisation TUN..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# ── Résolution des placeholders résiduels uniquement ─────────────────────────
# (la substitution IP principale est faite par start.sh sur l'hôte avant docker run)
CFG_DIR=/etc/osmocom

CONTAINER_IP="${CONTAINER_IP:-}"
GATEWAY_IP="${GATEWAY_IP:-}"
HLR_IP="${HLR_IP:-127.0.0.2}"
INTER_STP_IP="${INTER_STP_IP:-127.0.0.1}"
OPERATOR_ID="${OPERATOR_ID:-1}"

if [ -z "$CONTAINER_IP" ] || [ -z "$GATEWAY_IP" ]; then
    _GW=$(ip route get 1 2>/dev/null | awk '{print $3; exit}')
    _IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    CONTAINER_IP="${CONTAINER_IP:-$_IP}"
    GATEWAY_IP="${GATEWAY_IP:-$_GW}"
fi

echo "=== entrypoint ==="
echo "CONTAINER_IP   = $CONTAINER_IP"
echo "GATEWAY_IP     = $GATEWAY_IP"
echo "INTER_STP_IP   = $INTER_STP_IP"
echo "OPERATOR_ID    = $OPERATOR_ID"
echo "HLR_IP         = $HLR_IP"
echo "=================="

[ -z "$CONTAINER_IP" ] && { echo "ERREUR : CONTAINER_IP introuvable"; exit 1; }

# Placeholders __XXXX__ uniquement — pas de regex IP générique
# (évite de corrompre les Point Codes SS7 type 0.23.1)
for f in "$CFG_DIR"/*.cfg "$CFG_DIR"/*.conf; do
    [ -f "$f" ] || continue
    sed -i \
        -e "s|__CONTAINER_IP__|${CONTAINER_IP}|g" \
        -e "s|__GATEWAY_IP__|${GATEWAY_IP}|g" \
        -e "s|__HLR_IP__|${HLR_IP}|g" \
        -e "s|__INTER_STP_IP__|${INTER_STP_IP}|g" \
        -e "s|__OPERATOR_ID__|${OPERATOR_ID}|g" \
        "$f"
done
echo "[*] Placeholders résolus dans $CFG_DIR"

# ── Environnement systemd ─────────────────────────────────────────────────────
export container=docker
env > /etc/docker-entrypoint-env

[ $# -eq 0 ] && { echo >&2 'ERROR: No command specified.'; exit 1; }

quoted_args="$(printf " %q" "${@}")"
echo "${quoted_args}" > /etc/docker-entrypoint-cmd

cat > /etc/systemd/system/docker-entrypoint.service << EOT
[Unit]
Description=Stack Osmocom GSM
After=network.target

[Service]
ExecStart=/bin/bash -exc "source /etc/docker-entrypoint-cmd"
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
WorkingDirectory=/etc/osmocom
EnvironmentFile=/etc/docker-entrypoint-env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

systemctl mask \
    systemd-firstboot.service \
    systemd-udevd.service \
    systemd-modules-load.service \
    systemd-udevd-kernel.socket \
    systemd-udevd-control.socket \
    2>/dev/null || true

systemctl enable docker-entrypoint.service

if   [ -x /lib/systemd/systemd ];     then
    exec /lib/systemd/systemd --show-status=false --unit=multi-user.target
elif [ -x /usr/lib/systemd/systemd ]; then
    exec /usr/lib/systemd/systemd --show-status=false --unit=multi-user.target
else
    echo >&2 'ERROR: systemd introuvable'; exit 1
fi
