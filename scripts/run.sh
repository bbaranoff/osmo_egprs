#!/bin/bash

# Couleurs
GREEN='\033[0;32m'
NC='\033[0m'
SESSION="osmocom"
# 1. Lancer le coeur de réseau (Docker/Services)
echo "--- Démarrage du Core Network ---"
# Ton script de démarrage semble déjà gérer le sudo interne
/etc/osmocom/osmo-start.sh
sleep 3

echo -e "${GREEN}--- Initialisation de l'orchestration interne ---${NC}"

# 1. Gestion de la configuration du second mobile si DUAL_MOBILE est true
if [ "$DUAL_MOBILE" == "true" ]; then
    echo -e "${GREEN}[*] Configuration du Mobile 2 (IMSI distinct & Socket MS2)...${NC}"
    
    # Création du second config à partir du premier
    cp /root/.osmocom/bb/mobile.cfg /root/.osmocom/bb/mobile2.cfg
    
    # Patch automatique des ports et sockets
    sed -i 's/bind 127.0.0.1/bind 127.0.0.2/' /root/.osmocom/bb/mobile2.cfg
    sed -i 's/001010000000001/001010000000002/' /root/.osmocom/bb/mobile2.cfg
    sed -i 's/111111111111111/222222222222222/' /root/.osmocom/bb/mobile2.cfg
    sed -i 's/ms 1/ms 2/' /root/.osmocom/bb/mobile2.cfg
    
    # Ajout/Modif de la socket L1CTL pour isoler MS2
    if grep -q "layer2-socket" /root/.osmocom/bb/mobile2.cfg; then
        sed -i 's|layer2-socket.*|layer2-socket /tmp/osmocom_l2_ms2|' /root/.osmocom/bb/mobile2.cfg
    else
        echo "ms 2" >> /root/.osmocom/bb/mobile2.cfg
        echo " layer2-socket /tmp/osmocom_l2_ms2" >> /root/.osmocom/bb/mobile2.cfg
    fi
fi

# 2. Initialisation TMUX
tmux kill-server 2>/dev/null
tmux start-server
sleep 1

# --- Fenêtre 0 : Fake_TRX (Le bus radio + instance supplémentaire) ---
tmux new-session -d -s $SESSION -n "radio-trx"
# Modification ici : ajout du flag --trx
tmux send-keys -t $SESSION:0 " faketrx -R 127.0.0.3 -r 127.0.0.23 -b 127.0.0.13 --trx 127.0.0.33:6703" C-m
sleep 1

# --- Fenêtre 1 : MS1 (trxcon + mobile) ---
tmux new-window -t $SESSION:1 -n "ms1"
tmux send-keys -t $SESSION:1 "trxcon -i 127.0.0.13 -b 127.0.0.23" C-m
tmux split-window -v -t $SESSION:1
tmux send-keys -t $SESSION:1.1 "mobile -c /root/.osmocom/bb/mobile.cfg" C-m

# --- Fenêtre 2 : MS2 (si actif) ---
if [ "$DUAL_MOBILE" == "true" ]; then
    tmux new-window -t $SESSION:2 -n "ms2"
    # IMPORTANT : Si ton MS2 doit utiliser le nouveau transceiver, 
    # il faudra peut-être ajuster les ports de trxcon ici aussi.
    tmux send-keys -t $SESSION:2 "trxcon -i 127.0.0.13 -b 127.0.0.33 -p 6703 -s /tmp/osmocom_l2_ms2" C-m
    tmux split-window -v -t $SESSION:2
    tmux send-keys -t $SESSION:2.1 "mobile -c /root/.osmocom/bb/mobile2.cfg" C-m
fi


# 3. Finalisation
tmux select-window -t $SESSION:1
echo -e "${GREEN}--- Orchestration SDR Terminée ---${NC}"
tmux attach-session -t $SESSION
