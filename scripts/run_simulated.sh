#!/bin/bash
# Initialise le tunnel TUN pour la data
bash /etc/osmocom/tun.sh 

# Lancement des services en arrière-plan (Simulation)
osmo-hlr -c /etc/osmocom/osmo-hlr.cfg &
osmo-mgw -c /etc/osmocom/osmo-mgw.cfg &
osmo-msc -c /etc/osmocom/osmo-msc.cfg &
osmo-bsc -c /etc/osmocom/osmo-bsc.cfg &
# Le BTS virtuel remplace le matériel physique
osmo-bts-virtual -c /etc/osmocom/osmo-bts-virtual.cfg
