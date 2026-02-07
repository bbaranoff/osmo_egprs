#!/bin/bash
set -euo pipefail

SESSION="osmocom"
GREEN='\033[0;32m'
NC='\033[0m'

# ---- Kill old tmux ----
tmux has-session -t osmocom 2>/dev/null && tmux kill-session -t osmocom
sleep 1

# ---- Start Osmocom core ----
echo -e "${GREEN}=== Démarrage Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh
sleep 3

# ---- Start Asterisk ----
echo -e "${GREEN}=== Démarrage Asterisk ===${NC}"
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl restart asterisk || true
else
    pkill -x asterisk 2>/dev/null || true
    sleep 1
    asterisk -f -U root -G root -vvv >/var/log/asterisk/console.log 2>&1 &
fi
sleep 2

SESSION=osmocom

echo "=== Reset tmux ==="

# Kill session if it exists (silencieux)
tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

# Crée une session détachée
tmux new-session -d -s "$SESSION" -n virtual-bts

# Fenêtre 0: BTS virtuelle
tmux new-window -t "$SESSION" -n osmo-bts-virtual
tmux send-keys -t "$SESSION:0" "osmo-bts-virtual -c /usr/local/etc/osmocom/osmo-bts-virtual.cfg" C-m

# Fenêtre 1: virtphy
tmux new-window -t "$SESSION" -n virtphy
tmux send-keys -t "$SESSION:1" "virtphy" C-m

# Fenêtre 2: mobile
tmux new-window -t "$SESSION" -n mobile
tmux send-keys -t "$SESSION:2" "mobile -c /root/.osmocom/bb/mobile.cfg" C-m

# Fenêtre 3: asterisk
tmux new-window -t "$SESSION" -n asterisk
tmux send-keys -t "$SESSION:3" "rm -f /var/lib/asterisk/astdb.sqlite3*" C-m
tmux send-keys -t "$SESSION:3" "asterisk -rvvv" C-m

echo "[+] Osmocom stack launched in tmux session '$SESSION'"
echo "[+] Attach (optionnel): tmux attach -t $SESSION"


# ---- Done ----
echo -e "${GREEN}[+] Stack launched in tmux session '$SESSION'${NC}"
echo -e "${GREEN}    Windows: bts | virtphy | mobile | asterisk${NC}"
echo ""
echo "    tmux attach -t $SESSION          # voir tout"
echo "    tmux select-window -t $SESSION:mobile  # aller au mobile"
echo ""

# Stay attached so docker exec -it doesn't exit
tmux attach -t "$SESSION"
