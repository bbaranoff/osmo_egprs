#!/usr/bin/env bash
# run.sh — Lance tout : trx_test + stack osmocom (Docker)
# Usage: ./run.sh

# ---- auto-elevation ----
if [ "$EUID" -ne 0 ]; then
    echo "[*] Not root, re-executing with sudo..."
    exec sudo env HOME="$HOME" USER="$USER" PATH="$PATH" \
         DISPLAY="${DISPLAY:-:0}" \
         XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
         bash "$0" "$@"
fi

echo "[+] Running as root with user environment"
echo "    HOME=$HOME"

# ---- cleanup ----
echo "[*] Cleaning up old processes..."
pkill -f "trx_test.py" 2>/dev/null || true
pkill -f tshark 2>/dev/null || true

# ---- TRX loopback test (background) ----
echo "[*] Starting TRX loopback test..."
cd "$HOME/calypso-pkg/test-firmware" || exit 1
python3 trx_test.py --loopback &
TRX_PID=$!
sleep 1

# ---- Packet capture (background) ----
echo "[*] Starting tshark capture..."
tshark -i lo -f "udp port 4729 or udp port 4829" -w /tmp/trx.pcap 2>/dev/null &
TSHARK_PID=$!

# ---- Osmocom stack (Docker) ----
echo "[*] Starting Osmocom stack..."
cd "$HOME/osmo_egprs" || exit 1
bash start.sh

# ---- Cleanup on exit ----
echo "[*] Cleaning up..."
kill $TRX_PID 2>/dev/null || true
kill $TSHARK_PID 2>/dev/null || true
echo "[+] Done."
