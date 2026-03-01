#!/bin/bash
set -euo pipefail

SESSION="osmocom"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

# Chemin absolu — l'alias ~/.bashrc n'est pas résolu dans les shells tmux non-interactifs
FAKETRX_PY="/opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py"

echo -e "${GREEN}=== Arrêt Asterisk ===${NC}"
usermod -u 0 -o osmocom
systemctl stop asterisk 2>/dev/null || true
asterisk -rx "core stop now" 2>/dev/null || true
pkill -9 -x asterisk 2>/dev/null || true

echo -e "${GREEN}=== Reset tmux ===${NC}"
tmux kill-server 2>/dev/null || true
tmux start-server
sleep 1

# ── Fenêtre 0 : FakeTRX ──
tmux new-session -d -s "$SESSION" -n faketrx
tmux send-keys -t "$SESSION:0" "python3 ${FAKETRX_PY}" C-m
sleep 2

echo -e "${GREEN}=== Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh
chmod 666 /tmp/pcu_bts 2>/dev/null || true
sleep 5

# ── Fenêtre 1 : MS1 (trxcon + mobile) ──
tmux new-window -t "$SESSION:1" -n ms1
tmux send-keys -t "$SESSION:1" "trxcon" C-m
tmux split-window -v -t "$SESSION:1"
tmux send-keys -t "$SESSION:1.1" "sleep 3 && mobile -c /root/.osmocom/bb/mobile.cfg" C-m

# ── Fenêtre 2 : Asterisk ──
tmux new-window -t "$SESSION:2" -n asterisk
tmux send-keys -t "$SESSION:2" "rm -f /var/lib/asterisk/astdb.sqlite3 && asterisk -cvvv" C-m

# ── Fenêtre 3 : proto-smsc-daemon (GSUP → HLR) ──
tmux new-window -t "$SESSION:3" -n smsc
tmux send-keys -t "$SESSION:3" "/etc/osmocom/smsc-start.sh" C-m

# ── Fenêtre 4 : gapk audio (intégration native) ──
tmux new-window -t "$SESSION:4" -n gapk
tmux send-keys -t "$SESSION:4" "gapk-start.sh auto" C-m

# ── Final ──
tmux select-window -t "$SESSION:1"
echo -e "${GREEN}=== Orchestration prête ===${NC}"
echo -e "${CYAN}  [0] faketrx  [1] ms1     [2] asterisk${NC}"
echo -e "${CYAN}  [3] smsc     [4] gapk${NC}"
echo -e ""
echo -e "${GREEN}SMS inter-op:${NC}"
echo -e "${CYAN}  python3 /etc/osmocom/send-interop-sms.sh <target_op> <imsi> <from> 'msg'${NC}"
echo -e "${GREEN}SMS local:${NC}"
echo -e "${CYAN}  /etc/osmocom/send-mt-sms.sh <imsi> 'message'${NC}"
echo -e "${GREEN}Logs:${NC}"
echo -e "${CYAN}  MO     : tail -f /var/log/osmocom/mo-sms-op\${OPERATOR_ID}.log${NC}"
echo -e "${CYAN}  Relay  : tail -f /var/log/osmocom/smsc-relay-op\${OPERATOR_ID}.log${NC}"
echo -e "${CYAN}  Router : tail -f /var/log/osmocom/sms-router-op\${OPERATOR_ID}.log${NC}"
tmux attach-session -t "$SESSION"
