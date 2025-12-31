#!/bin/bash
set -euo pipefail

SESSION="osmocom"
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== Démarrage Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh
sleep 3

echo -e "${GREEN}=== Démarrage Asterisk ===${NC}"
# tente systemd, sinon fallback CLI
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  systemctl restart asterisk || true
else
  # kill un ancien asterisk si présent, puis lance en arrière-plan
  pkill -x asterisk 2>/dev/null || true
  asterisk -f -U root -G root -vvv >/var/log/asterisk/console.log 2>&1 &
fi
sleep 2

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

#################################
# Fenêtre 1 : MS1 (trxcon + mobile)
#################################
tmux new-window -t "$SESSION:1" -n ms1
tmux send-keys -t "$SESSION:1" "trxcon" C-m
tmux split-window -v -t "$SESSION:1"
tmux send-keys -t "$SESSION:1.1" "mobile -c /root/.osmocom/bb/mobile.cfg" C-m
sleep 2

#################################
# Fenêtre 2 : Asterisk CLI
#################################
tmux new-window -t "$SESSION:2" -n asterisk
tmux send-keys -t "$SESSION:2" "asterisk -rvvv" C-m

#################################
# Final
#################################
tmux select-window -t "$SESSION:1"
echo -e "${GREEN}=== Orchestration prête ===${NC}"
tmux attach-session -t "$SESSION"
