cat <<'EOF' > /etc/osmocom/osmo-start.sh
#!/bin/bash
echo "--- Démarrage de la pile Osmocom ---"

# Services de base (Signalisation et Database)
for svc in osmo-stp osmo-hlr osmo-mgw; do
    echo "Lancement de $svc..."
    systemctl start $svc
    sleep 1
done

# Cœur de réseau
for svc in osmo-msc osmo-bsc; do
    echo "Lancement de $svc..."
    systemctl start $svc
    sleep 1
done

# GPRS / Data
for svc in osmo-ggsn osmo-sgsn osmo-pcu; do
    echo "Lancement de $svc..."
    systemctl start $svc
    sleep 1
done

# Accès Radio (BTS)
echo "Lancement de osmo-bts..."
systemctl start osmo-bts

echo "--- Tous les services ont reçu l'ordre de démarrage ---"
systemctl status osmo-hlr osmo-msc osmo-mgw osmo-stp osmo-bsc osmo-ggsn osmo-sgsn osmo-pcu osmo-bts | grep -E "Active:|●"
EOF

chmod +x /etc/osmocom/osmo-start.sh
