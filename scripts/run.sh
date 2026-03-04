#!/bin/bash
# run.sh — Orchestrateur intra-container Osmocom
#
# Séquence garantie :
#   1. Reset
#   2. generate_ms_configs
#   3. osmo-start.sh       → STP HLR MGW MSC BSC GGSN SGSN PCU
#                            (PAS bts-trx ni sip-connector)
#   4. fake_trx démarre    → bind UDP 5700
#   5. osmo-bts-trx start  → se connecte à fake_trx déjà prêt ✓
#   6. MS windows (trxcon + mobile)
#   7. Asterisk
#   8. sip-connector       → après Asterisk UP + MNCC socket
#   9. SMSC + gapk
#
# DEBUG MODE: DEBUG=1 ./run.sh (affiche toutes les commandes)

set -euo pipefail

# ── DEBUG MODE ─────────────────────────────────────────────────────────────
if [[ -n "${DEBUG:-}" ]]; then
    set -x
    PS4='[DEBUG-run] + ${BASH_SOURCE}:${LINENO}: '
    echo "=== RUN.SH: MODE DEBUG ACTIVÉ (Op${OPERATOR_ID:-?}) ==="
    echo ""
fi

SESSION="osmocom"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

FAKETRX_PY="${FAKETRX_PY:-/opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py}"

OPERATOR_ID="${OPERATOR_ID:-1}"
N_MS="${N_MS:-1}"

[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] OPERATOR_ID=$OPERATOR_ID N_MS=$N_MS FAKETRX_PY=$FAKETRX_PY"

if ! [[ "$N_MS" =~ ^[0-9]+$ ]] || [ "$N_MS" -lt 1 ] || [ "$N_MS" -gt 9 ]; then
    echo -e "${YELLOW}[WARN] N_MS='${N_MS}' invalide → forcé à 1${NC}"
    N_MS=1
fi

# ── Génération des configs MS ─────────────────────────────────────────────────
generate_ms_configs() {
    local base_cfg="/root/.osmocom/bb/mobile.cfg"

    if [ ! -f "$base_cfg" ]; then
        echo -e "${RED}[ERR] mobile.cfg introuvable : ${base_cfg}${NC}"; return 1
    fi

    local ref_imsi ref_imei ref_ki ref_l2
    ref_imsi=$(grep -oP '^\s*imsi\s+\K[0-9]+' "$base_cfg" | head -1)
    ref_imei=$(grep -oP '^\s+imei \K[0-9]+' "$base_cfg" | head -1)
    ref_ki=$(grep -oP '^\s+ki comp128 \K[0-9a-f ]+' "$base_cfg" | head -1 \
             | sed 's/[[:space:]]*$//')
    ref_l2=$(grep -oP 'layer2-socket \K\S+' "$base_cfg" | head -1)
    ref_l2="${ref_l2:-\/tmp\/osmocom_l2}"

    if [ -z "$ref_imsi" ] || [ -z "$ref_imei" ] || [ -z "$ref_ki" ]; then
        echo -e "${RED}[ERR] Impossible d'extraire IMSI/IMEI/KI de ${base_cfg}${NC}"
        return 1
    fi

    local mcc mnc
    mcc=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $2}' | head -1)
    mnc=$(grep -E '^\s+rplmn ' "$base_cfg" | awk '{print $3}' | head -1)
    mcc="${mcc:-001}"; mnc="${mnc:-01}"

    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Base IMSI=$ref_imsi KI='$ref_ki' MCC=$mcc MNC=$mnc"

    echo -e "  Base : IMSI=${ref_imsi}  KI='${ref_ki}'  MCC=${mcc}  MNC=${mnc}"

    for ms_idx in $(seq 1 "${N_MS}"); do
        local cfg="/root/.osmocom/bb/mobile_ms${ms_idx}.cfg"
        local l2_sock="\/tmp\/osmocom_l2_${ms_idx}"
        local vty_ip="127.0.0.${ms_idx}"
        local msin; msin=$(printf '%04d%06d' "${OPERATOR_ID}" "${ms_idx}")
        local new_imsi="${mcc}${mnc}${msin}"
        local new_imei; new_imei="3589250059$(printf '%02d%02d' "${OPERATOR_ID}" "${ms_idx}")0"
        local new_ki; new_ki=$(printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x ff' \
                                      "${ms_idx}")
        sed \
            -e "s|127.0.0.1|127.0.0.$ms_idx|" \
            -e "s|layer2-socket ${ref_l2}|layer2-socket ${l2_sock}|" \
            -e "/^line vty/,/^[^ ]/{s|bind [0-9.]*|bind ${vty_ip}|}" \
            -e "s|imsi ${ref_imsi}|imsi ${new_imsi}|" \
            -e "s|imei ${ref_imei}|imei ${new_imei}|" \
            -e "s|ki comp128 ${ref_ki}|ki comp128 ${new_ki}|" \
            "$base_cfg" > "$cfg"

        if ! grep -q "${l2_sock}" "$cfg"; then
            sed -i "s|layer2-socket .*|layer2-socket ${l2_sock}|" "$cfg"
        fi

        [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] MS${ms_idx}: IMSI=$new_imsi KI=...$(printf '%02x ff' "${ms_idx}") VTY=${vty_ip}:4247 L1CTL=/tmp/osmocom_l2_${ms_idx}"

        echo -e "  ${CYAN}[MS${ms_idx}]${NC} IMSI=${new_imsi}  KI=…$(printf '%02x ff' "${ms_idx}")  VTY=${vty_ip}:4247  L1CTL=/tmp/osmocom_l2_${ms_idx}"
    done
}

# ── Helper : reset TRX via VTY OsmoBTS (port 4236) ──────────────────────────
reset_trx() {
    local vty_host="127.0.0.1" vty_port=4236
    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] reset_trx: attente ${vty_host}:${vty_port}"
    
    echo -ne "  Attente VTY OsmoBTS (${vty_host}:${vty_port})"
    local elapsed=0
    while ! bash -c "echo >/dev/tcp/${vty_host}/${vty_port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1)); echo -n "."
        if [ "$elapsed" -ge 60 ]; then
            echo -e " ${RED}TIMEOUT — reset TRX ignoré${NC}"; return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"

    cat > /tmp/trx_reset.vty << 'VTYCMDS'
enable
trx 0 reset
end
VTYCMDS

    if command -v nc >/dev/null 2>&1; then
        (sleep 1; cat /tmp/trx_reset.vty; sleep 1) \
            | nc -q2 "${vty_host}" "${vty_port}" 2>/dev/null \
            | grep -vE "^(OsmoBTS|Welcome|VTY|\s*$)" \
            | sed "s/^/  /" || true
    else
        (sleep 1; cat /tmp/trx_reset.vty; sleep 2) \
            | telnet "${vty_host}" "${vty_port}" 2>/dev/null \
            | grep -vE "^(Trying|Connected|Escape|OsmoBTS|Welcome)" \
            | sed "s/^/  /" || true
    fi
    rm -f /tmp/trx_reset.vty
    echo -e "  ${GREEN}✓ TRX reset envoyé${NC}"
}

# ── Helper : attendre qu'un port TCP soit ouvert ──────────────────────────────
wait_port() {
    local host="$1" port="$2" label="$3" timeout="${4:-60}"
    local elapsed=0
    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] wait_port: $host:$port ($label)"
    echo -ne "  Attente ${label} (${host}:${port})"
    while ! bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"; return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ── Helper : attendre qu'un port UDP soit bindé ───────────────────────────────
wait_udp() {
    local port="$1" label="$2" timeout="${3:-30}"
    local elapsed=0
    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] wait_udp: UDP $port ($label)"
    echo -ne "  Attente ${label} (UDP ${port})"
    while ! ss -unlp | grep -q ":${port} "; do
        sleep 1; elapsed=$((elapsed + 1))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"; return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. Reset ──────────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [1/9] Reset ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Killing old processes..."
usermod -u 0 -o osmocom 2>/dev/null || true

pkill -9 -f fake_trx.py 2>/dev/null || true
sleep 1

tmux kill-server 2>/dev/null || true
sleep 0.3
tmux start-server

# ── 2. Génération configs MS ──────────────────────────────────────────────────
echo -e "${GREEN}=== [2/9] Génération configs MS (N=${N_MS}) ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Calling generate_ms_configs..."
generate_ms_configs
echo ""

# ── 3. Core Osmocom (sans bts-trx ni sip-connector) ──────────────────────────
echo -e "${GREEN}=== [3/9] Core Osmocom ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Launching /etc/osmocom/osmo-start.sh..."
/etc/osmocom/osmo-start.sh

# ── 4. FakeTRX — créer la session tmux ET binder les sockets AVANT bts-trx ───
echo -e "${GREEN}=== [4/9] FakeTRX ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Creating tmux session and fake_trx..."

tmux new-session -d -s "$SESSION" -n faketrx

FAKETRX_CMD="python3 ${FAKETRX_PY}"
# MS1 utilise le port 6700 par défaut (pas de --trx nécessaire).
# On déclare seulement les TRX additionnels pour MS2..N.
for ms_idx in $(seq 2 "${N_MS}"); do
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))
    FAKETRX_CMD="${FAKETRX_CMD} --trx 127.0.0.1:${trx_port}"
done

[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] FakeTRX Cmd: ${FAKETRX_CMD}"
echo -e "  ${CYAN}Cmd :${NC} ${FAKETRX_CMD}"

tmux send-keys -t "${SESSION}:faketrx" "${FAKETRX_CMD}" C-m
wait_udp 5700 "FakeTRX" 30 || true

# ── 5. OsmoBTS-TRX (lancer APRÈS fake_trx pour éviter les race conditions) ───
echo -e "${GREEN}=== [5/9] OsmoBTS-TRX ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Launching osmo-bts-trx..."
# osmo-bts-trx est lancé via osmo-start.sh, on attend juste que ce soit prêt
wait_port 127.0.0.1 4241 "OsmoBTS VTY" 60 || true

# ── 6. Fenêtres MS ────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [6/9] MS (${N_MS}) ===${NC}"

for ms_idx in $(seq 1 "${N_MS}"); do
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))
    l2_socket="/tmp/osmocom_l2_${ms_idx}"
    cfg="/root/.osmocom/bb/mobile_ms${ms_idx}.cfg"
    win="ms${ms_idx}"

    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] MS${ms_idx}: TRX:${trx_port} L1CTL:${l2_socket} Config:${cfg}"

    echo -e "  ${CYAN}[MS${ms_idx}]${NC} TRX:${trx_port}  L1CTL:${l2_socket}  VTY:127.0.${OPERATOR_ID}.${ms_idx}:4247"

    tmux new-window -t "$SESSION" -n "$win"

    if [ "$ms_idx" -eq 1 ]; then
        trxcon_cmd="trxcon -s ${l2_socket}"
    else
        trxcon_cmd="trxcon -p ${trx_port} -s ${l2_socket}"
    fi
    
    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] trxcon_cmd: ${trxcon_cmd}"
    
    tmux send-keys -t "${SESSION}:${win}.0" \
        "echo '=== trxcon MS${ms_idx} → fake_trx:${trx_port} ===' && sleep 2 && ${trxcon_cmd}" C-m

    tmux split-window -v -t "${SESSION}:${win}"
    tmux send-keys -t "${SESSION}:${win}.1" \
        "echo '=== mobile MS${ms_idx} ===' && sleep 5 && mobile -c ${cfg}" C-m

    tmux select-layout -t "${SESSION}:${win}" even-vertical
done

# ── 7. Asterisk ───────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [7/9] Asterisk ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Starting Asterisk..."

tmux new-window -t "$SESSION" -n asterisk
tmux send-keys -t "${SESSION}:asterisk" \
    "pkill asterisk 2>/dev/null; sleep 2; pkill -9 asterisk 2>/dev/null; sleep 1; rm -f /var/lib/asterisk/astdb.sqlite3; asterisk -cvvv" C-m

wait_port 127.0.0.1 5060 "Asterisk SIP" 60 || true
sleep 3

# ── 8. sip-connector (OPTIONNEL - après Asterisk) ────────────────────────────
echo -e "${GREEN}=== [8/9] SIP-Connector ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] sip-connector (optionnel)"

if command -v sip-connector >/dev/null 2>&1 || [ -f /root/sip-connector.sh ]; then
    tmux new-window -t "$SESSION" -n sip-connector
    if [ -f /root/sip-connector.sh ]; then
        tmux send-keys -t "${SESSION}:sip-connector" \
            "sleep 3 && bash /root/sip-connector.sh" C-m
    else
        tmux send-keys -t "${SESSION}:sip-connector" \
            "sleep 3 && sip-connector" C-m
    fi
    sleep 3
else
    echo -e "  ${YELLOW}[*] sip-connector non disponible (optionnel)${NC}"
fi

# ── 9. SMSC + gapk ───────────────────────────────────────────────────────────
echo -e "${GREEN}=== [9/9] SMSC + gapk ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Starting SMSC and gapk..."

tmux new-window -t "$SESSION" -n smsc
if [ -f /etc/osmocom/smsc-start.sh ]; then
    tmux send-keys -t "${SESSION}:smsc" "/etc/osmocom/smsc-start.sh" C-m
else
    tmux send-keys -t "${SESSION}:smsc" "echo 'SMSC non disponible'" C-m
fi

tmux new-window -t "$SESSION" -n gapk
tmux send-keys -t "${SESSION}:gapk" \
    "echo '=== gapk audio ===' && sleep 3 && (gapk-start.sh auto 2>/dev/null || echo 'gapk non disponible')" C-m

tmux select-window -t "${SESSION}:ms1"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Opérateur ${OPERATOR_ID} — Stack prête  (${N_MS} MS)                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Fenêtres :${NC} faketrx  $(for i in $(seq 1 $N_MS); do printf "ms%s  " $i; done)asterisk  sip-connector  smsc  gapk"
echo ""
echo -e "  ${CYAN}Vérif TRX  :${NC} fenêtre faketrx → chercher 'RSP POWERON'"
echo -e "  ${CYAN}Vérif TCH  :${NC} telnet 127.0.0.1 4242 → show bts 0"
echo -e "  ${CYAN}Vérif PJSIP:${NC} asterisk -rx 'pjsip show endpoints'"
echo -e "  ${CYAN}VTY MSC    :${NC} telnet 127.0.0.1 4254"
echo -e "  ${CYAN}VTY HLR    :${NC} telnet 127.0.0.1 4258"
echo ""
echo -e "  ${CYAN}Navigation :${NC}  Ctrl-b w   Ctrl-b n/p"
echo ""

[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] run.sh: orchestration complète"

# ── Reset TRX via VTY OsmoBTS ─────────────────────────────────────────────────
echo -e "${GREEN}=== [+] Reset TRX ===${NC}"
reset_trx

tmux attach-session -t "$SESSION"
