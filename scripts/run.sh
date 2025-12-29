#!/bin/bash

SESSION="osmocom"

# 1. Lancer le coeur de réseau (Docker/Services)
echo "--- Démarrage du Core Network ---"
# Ton script de démarrage semble déjà gérer le sudo interne
/etc/osmocom/osmo-start.sh
sleep 3

echo "--- Initialisation de la session Tmux : $SESSION ---"

# On force l'arrêt de toute instance précédente pour nettoyer /tmp
tmux kill-server 2>/dev/null

# ÉTAPE CRUCIALE : On démarre le serveur explicitement
tmux start-server

# On crée la session initiale
# On utilise 'tail -f /dev/null' pour garder la fenêtre ouverte si le script plante
tmux new-session -d -s $SESSION -n "radio-trx"

# On envoie la commande à la fenêtre 0
tmux send-keys -t $SESSION:0 "faketrx" C-m

sleep 1

# On ajoute les fenêtres avec leurs commandes
tmux new-window -t $SESSION:1 -n "l1-bridge"
tmux send-keys -t $SESSION:1 "trxcon -i 127.0.0.1" C-m

sleep 1

tmux new-window -t $SESSION:2 -n "mobile-ms"
tmux send-keys -t $SESSION:2 "mobile" C-m

# 2. Finalisation
tmux select-window -t $SESSION:0
echo "--- Orchestration terminée. Connexion... ---"
tmux attach-session -t $SESSION
