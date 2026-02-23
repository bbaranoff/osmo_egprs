#!/bin/bash
set -euo pipefail

SESSION="osmocom"
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== Arrêt complet d'Asterisk ===${NC}"

usermod -u 0 -o osmocom

# Tentative propre via systemd
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop asterisk 2>/dev/null || true
fi

# Fallback CLI Asterisk (si encore vivant)
asterisk -rx "core stop now" 2>/dev/null || true

# Fallback brutal (au cas où)
pkill -9 -x asterisk 2>/dev/null || true

# Vérification
if pgrep -x asterisk >/dev/null; then
  echo "[!] Asterisk résiste encore"
else
  echo "[+] Asterisk est complètement mort"
fi

echo -e "${GREEN}=== Reset tmux ===${NC}"
tmux kill-server 2>/dev/null || true
tmux start-server
sleep 1

#################################
# Fenêtre 0 : FakeTRX
#################################
tmux new-session -d -s "$SESSION" -n faketrx
tmux send-keys -t "$SESSION:0" "faketrx" C-m
sleep 2

echo -e "${GREEN}=== Démarrage Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh
chmod 666 /tmp/pcu_bts
sleep 1

#################################
# Fenêtre 1 : MS1 (trxcon + mobile)
#################################
tmux new-window -t "$SESSION:1" -n ms1
tmux send-keys -t "$SESSION:1" "trxcon" C-m
tmux split-window -v -t "$SESSION:1"
tmux send-keys -t "$SESSION:1.1" "mobile -c /root/.osmocom/bb/mobile.cfg" C-m
sleep 1

#################################
# Fenêtre 2 : Asterisk CLI
#################################
tmux new-window -t "$SESSION:2" -n asterisk
tmux send-keys -t "$SESSION:2" "rm /var/lib/asterisk/astdb.sqlite3 && asterisk -cvvv" C-m

#################################
# Final
#################################
tmux select-window -t "$SESSION:1"
echo -e "${GREEN}=== Orchestration prête ===${NC}"
tmux attach-session -t "$SESSION"
