#!/bin/bash
# run.sh — Orchestrateur intra-container Osmocom
#
# Modes mobile :
#   MOBILE_MODE=combined (défaut) — groupes de 8 MS, 1 mobile process par groupe
#   MOBILE_MODE=split             — 1 mobile process par MS, cfg individuel
#
# Nouveau : Attente séquentielle des groupes
#   Groupe 1 (127.0.0.1:4247) → OK → sleep 3 → Groupe 2 (127.0.0.2:4247) → OK → etc.

set -euo pipefail

# ── LOGGING ───────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/osmocom/run.sh.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "========================================"
echo "  run.sh démarré à $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# ── DEBUG MODE ────────────────────────────────────────────────────────────────
if [[ -n "${DEBUG:-}" ]]; then
    set -x
    PS4='[DEBUG-run] + ${BASH_SOURCE}:${LINENO}: '
    echo "=== RUN.SH: MODE DEBUG ACTIVÉ (Op${OPERATOR_ID:-?}) ==="
fi

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

FAKETRX_PY="${FAKETRX_PY:-/opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py}"

OPERATOR_ID="${OPERATOR_ID:-1}"
N_MS="${N_MS:-1}"
MOBILE_MODE="${MOBILE_MODE:-combined}"   # combined | split

# ── Constantes ────────────────────────────────────────────────────────────────
MAX_MS=64                # MS max par opérateur
MAX_MS_PER_MOBILE=8      # MS max par processus mobile (combined)
MS_PER_TRX=16            # 1 TRX BTS enfant tous les 16 MS
BB_PORT_BASE=6700        # Port BB base pour trxcon MS1
BB_PORT_STEP=3           # Pas entre ports BB
BTS_PORT_BASE=5700       # Port BTS base

L2_SOCK_BASE="/tmp/osmocom_l2"
SAP_SOCK_BASE="/tmp/osmocom_sap"

# ── Validation ────────────────────────────────────────────────────────────────
if ! [[ "$N_MS" =~ ^[0-9]+$ ]] || [ "$N_MS" -lt 1 ] || [ "$N_MS" -gt "$MAX_MS" ]; then
    echo -e "${YELLOW}[WARN] N_MS='${N_MS}' invalide (1-${MAX_MS}) → forcé à 1${NC}"
    N_MS=1
fi

if ! [[ "$OPERATOR_ID" =~ ^[0-9]+$ ]] || [ "$OPERATOR_ID" -lt 1 ] || [ "$OPERATOR_ID" -gt 24 ]; then
    echo -e "${RED}[ERR] OPERATOR_ID='${OPERATOR_ID}' invalide (1-24)${NC}"
    exit 1
fi

if [[ "$MOBILE_MODE" != "combined" && "$MOBILE_MODE" != "split" ]]; then
    echo -e "${YELLOW}[WARN] MOBILE_MODE='${MOBILE_MODE}' invalide → combined${NC}"
    MOBILE_MODE="combined"
fi

# Calculs dérivés
N_TRX=$(( (N_MS + MS_PER_TRX - 1) / MS_PER_TRX ))   # ceil(N_MS/16)
if [ "$MOBILE_MODE" = "combined" ]; then
    N_GROUPS=$(( (N_MS + MAX_MS_PER_MOBILE - 1) / MAX_MS_PER_MOBILE ))
else
    N_GROUPS=$N_MS
fi

echo -e "  ${CYAN}Op${OPERATOR_ID}${NC}  N_MS=${N_MS}  mode=${MOBILE_MODE}  TRX=${N_TRX}  groups=${N_GROUPS}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

# Port BB pour un MS global (1-based)
bb_port()  { echo $(( BB_PORT_BASE + ($1 - 1) * BB_PORT_STEP )); }

# Socket L2/SAP pour un MS global (1-based)
l2_sock()  { echo "${L2_SOCK_BASE}_${1}"; }
sap_sock() { echo "${SAP_SOCK_BASE}_${1}"; }

# IP de groupe pour un MS global (1-based)
# Groupe 1 → 127.0.0.1, Groupe 2 → 127.0.0.2, etc.
group_ip() {
    local ms_idx=$1
    local group=$(( (ms_idx - 1) / 8 + 1 ))
    echo "127.0.0.${group}"
}

# Credentials pour un MS global
ms_imsi() {
    local ms_idx=$1
    local msin; msin=$(printf '%04d%06d' "${OPERATOR_ID}" "${ms_idx}")
    echo "${_MCC}${_MNC}${msin}"
}
ms_imei() {
    local ms_idx=$1
    printf '3589250059%02d%02d0' "${OPERATOR_ID}" "${ms_idx}"
}
ms_ki() {
    local ms_idx=$1
    printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x %02x' "${ms_idx}" "${OPERATOR_ID}"
}

wait_port() {
    local host="$1" port="$2" label="$3" timeout="${4:-60}"
    local elapsed=0
    echo -ne "  Attente ${label} (${host}:${port})"
    while ! bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"; return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

wait_udp() {
    local port="$1" label="$2" timeout="${3:-30}"
    local elapsed=0
    echo -ne "  Attente ${label} (UDP ${port})"
    while ! ss -unlp | grep -q ":${port} "; do
        sleep 1; elapsed=$((elapsed + 1)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"; return 1
        fi
    done
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Génération des configs mobile
# ══════════════════════════════════════════════════════════════════════════════
generate_ms_configs() {
    local base_cfg="/root/.osmocom/bb/mobile.cfg"

    if [ ! -f "$base_cfg" ]; then
        echo -e "${RED}[ERR] mobile.cfg introuvable : ${base_cfg}${NC}"
        ls -la /root/.osmocom/bb/ 2>&1 | sed 's/^/      /'
        return 1
    fi

    # ── Extraction des valeurs de référence ───────────────────────────────
    local ref_imsi ref_imei ref_ki ref_l2 ref_sap

    ref_imsi=$(grep -oP '^\s+imsi\s+\K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_imei=$(grep -oP '^\s+imei \K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_ki=$(grep -oP '^\s+ki comp128 \K[0-9a-f ]+' "$base_cfg" 2>/dev/null | head -1 \
             | sed 's/[[:space:]]*$//' || true)
    ref_l2=$(grep -oP 'layer2-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_l2="${ref_l2:-/tmp/osmocom_l2}"
    ref_sap=$(grep -oP 'sap-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || true)

    # Fallback grep -E
    if [ -z "$ref_imsi" ]; then
        ref_imsi=$(grep -E 'imsi [0-9]+' "$base_cfg" | head -1 | awk '{print $NF}' || true)
        ref_imei=$(grep -E 'imei [0-9]+' "$base_cfg" | head -1 | awk '{print $2}' || true)
        ref_ki=$(grep -E 'ki comp128' "$base_cfg" | head -1 | sed 's/.*ki comp128 //' | sed 's/[[:space:]]*$//' || true)
        ref_l2=$(grep -E 'layer2-socket' "$base_cfg" | head -1 | awk '{print $2}' || true)
        ref_l2="${ref_l2:-/tmp/osmocom_l2}"
        ref_sap=$(grep -E 'sap-socket' "$base_cfg" | head -1 | awk '{print $2}' || true)
    fi

    if [ -z "$ref_imsi" ] || [ -z "$ref_imei" ] || [ -z "$ref_ki" ]; then
        echo -e "${RED}[ERR] Impossible d'extraire IMSI/IMEI/KI de ${base_cfg}${NC}"
        return 1
    fi

    # MCC/MNC pour les IMSI
    _MCC=$(grep -E '^\s+rplmn ' "$base_cfg" 2>/dev/null | awk '{print $2}' | head -1 || true)
    _MNC=$(grep -E '^\s+rplmn ' "$base_cfg" 2>/dev/null | awk '{print $3}' | head -1 || true)
    _MCC="${_MCC:-001}"; _MNC="${_MNC:-01}"

    echo -e "  ${CYAN}[ref]${NC} IMSI=${ref_imsi}  IMEI=${ref_imei}  MCC/MNC=${_MCC}/${_MNC}"

    # ── Partie globale (tout avant le premier 'ms N') ─────────────────────
    local global_line
    global_line=$(grep -n '^ms [0-9]' "$base_cfg" | head -1 | cut -d: -f1 || true)
    if [ -z "$global_line" ]; then
        echo -e "${RED}[ERR] Pas de bloc 'ms' trouvé dans ${base_cfg}${NC}"
        return 1
    fi

    local global_header
    global_header=$(head -n $(( global_line - 1 )) "$base_cfg")

    # ── Template = premier bloc ms ────────────────────────────────────────
    local ms_template
    ms_template=$(awk '
        /^ms [0-9]/ { if (found) exit; found=1; printing=1 }
        printing { print }
        /^(exit|end)$/ && printing && found { printing=0; exit }
    ' "$base_cfg")

    if [ -z "$ms_template" ]; then
        echo -e "${RED}[ERR] Extraction bloc ms échouée${NC}"
        return 1
    fi

    # ── Fonction interne : écrire un bloc ms dans un fichier ──────────────
    _write_ms_block() {
        local outfile="$1"
        local local_ms_num="$2"    # numéro ms dans le fichier (1..8)
        local global_ms_idx="$3"   # index MS global (1..64)

        local new_imsi; new_imsi=$(ms_imsi "$global_ms_idx")
        local new_imei; new_imei=$(ms_imei "$global_ms_idx")
        local new_ki;   new_ki=$(ms_ki "$global_ms_idx")
        local new_l2;   new_l2=$(l2_sock "$global_ms_idx")
        local new_sap;  new_sap=$(sap_sock "$global_ms_idx")

        local block
        block=$(echo "$ms_template" \
            | sed \
                -e "s|^ms [0-9]\+|ms ${local_ms_num}|" \
                -e "s|layer2-socket ${ref_l2}|layer2-socket ${new_l2}|" \
                -e "s|imsi ${ref_imsi}|imsi ${new_imsi}|" \
                -e "s|imei ${ref_imei}[[:space:]]*[0-9]*|imei ${new_imei}|" \
                -e "s|ki comp128 ${ref_ki}|ki comp128 ${new_ki}|" \
        )

        # sap-socket
        if [ -n "$ref_sap" ]; then
            block=$(echo "$block" | sed "s|sap-socket ${ref_sap}|sap-socket ${new_sap}|")
        else
            block=$(echo "$block" | sed "/layer2-socket/a\\ sap-socket ${new_sap}")
        fi

        echo "$block" >> "$outfile"
        echo "" >> "$outfile"
    }

    # ── Génération selon le mode ──────────────────────────────────────────
    rm -f /root/.osmocom/bb/mobile_ms*.cfg
    rm -f /root/.osmocom/bb/mobile_group*.cfg

    if [ "$MOBILE_MODE" = "split" ]; then
        echo -e "  ${CYAN}Mode SPLIT :${NC} ${N_MS} fichiers (1 MS chacun)"
        for ms_idx in $(seq 1 "$N_MS"); do
            local cfg="/root/.osmocom/bb/mobile_ms${ms_idx}.cfg"
            echo "$global_header" > "$cfg"
            _write_ms_block "$cfg" 1 "$ms_idx"
            echo -e "  ${CYAN}[MS${ms_idx}]${NC} → mobile_ms${ms_idx}.cfg  IMSI=$(ms_imsi $ms_idx)  L2=$(l2_sock $ms_idx)"
        done
    else
        echo -e "  ${CYAN}Mode COMBINED :${NC} ${N_GROUPS} groupe(s) de max ${MAX_MS_PER_MOBILE} MS"
        local group=1
        local group_start=1
        while [ "$group_start" -le "$N_MS" ]; do
            local group_end=$(( group_start + MAX_MS_PER_MOBILE - 1 ))
            [ "$group_end" -gt "$N_MS" ] && group_end=$N_MS
            local group_size=$(( group_end - group_start + 1 ))

            local cfg="/root/.osmocom/bb/mobile_group${group}.cfg"
            # L'IP du groupe est 127.0.0.X où X = numéro de groupe
            echo "$global_header" \
                | sed "s|127\.0\.0\.1|127.0.0.${group}|g" \
                > "$cfg"

            local local_idx=1
            for ms_idx in $(seq "$group_start" "$group_end"); do
                _write_ms_block "$cfg" "$local_idx" "$ms_idx"
                local_idx=$((local_idx + 1))
            done
            echo -e "  ${CYAN}[Grp${group}]${NC} → mobile_group${group}.cfg  IP=127.0.0.${group} MS ${group_start}-${group_end} (${group_size} MS)"
            group=$((group + 1))
            group_start=$((group_end + 1))
        done
    fi

    echo -e "  ${GREEN}✓ Configs mobile générées (${MOBILE_MODE}, ${N_MS} MS)${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Injection TRX enfants
# ══════════════════════════════════════════════════════════════════════════════
inject_extra_trx() {
    local n_trx="$1"
    [ "$n_trx" -le 1 ] && return 0

    echo -e "  ${CYAN}Injection ${n_trx} TRX (${n_trx} - 1 = $((n_trx-1)) enfants)${NC}"

    local bts_cfg="/etc/osmocom/osmo-bts.cfg"
    local bsc_cfg="/etc/osmocom/osmo-bsc.cfg"

    local base_arfcn
    base_arfcn=$(grep -E '^\s+arfcn [0-9]+' "$bsc_cfg" | head -1 | awk '{print $2}')
    echo -e "  ${CYAN}ARFCN base :${NC} ${base_arfcn}"

    # osmo-bts.cfg
    local tmp_bts; tmp_bts=$(mktemp)
    awk -v n_trx="$n_trx" '
    /^ osmotrx ip local/ && !injected {
        for (i = 1; i < n_trx; i++) {
            printf " instance %d\n", i
            printf "  osmotrx rx-gain 40\n"
            printf "  osmotrx tx-attenuation 50\n"
        }
        injected = 1
    }
    { print }
    ' "$bts_cfg" > "$tmp_bts"
    cp "$tmp_bts" "$bts_cfg"
    rm -f "$tmp_bts"

    for trx_idx in $(seq 1 $((n_trx - 1))); do
        local arfcn=$(( base_arfcn + trx_idx * 2 ))
        echo -e "  ${CYAN}TRX ${trx_idx} :${NC} ARFCN=${arfcn}  phy 0 instance ${trx_idx}"
        cat >> "$bts_cfg" <<TRXBLOCK
 trx ${trx_idx}
  power-ramp max-initial 23000 mdBm
  power-ramp step-size 2000 mdB
  power-ramp step-interval 1
  ms-power-control osmo
  phy 0 instance ${trx_idx}
TRXBLOCK
    done

    # osmo-bsc.cfg
    if [ -f "$bsc_cfg" ]; then
        local tmp_bsc; tmp_bsc=$(mktemp)
        local trx_blocks=""
        for trx_idx in $(seq 1 $((n_trx - 1))); do
            local arfcn=$(( base_arfcn + trx_idx * 2 ))
            trx_blocks+="  trx ${trx_idx}
   rf_locked 0
   arfcn ${arfcn}
   nominal power 23
   max_power_red 0
   rsl e1 tei 0
   timeslot 0
    phys_chan_config CCCH+SDCCH4
    hopping enabled 0
   timeslot 1
    phys_chan_config SDCCH8
    hopping enabled 0
   timeslot 2
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
   timeslot 3
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
   timeslot 4
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
   timeslot 5
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
   timeslot 6
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
   timeslot 7
    phys_chan_config DYNAMIC/OSMOCOM
    hopping enabled 0
"
        done

        awk -v blocks="$trx_blocks" '
            /^msc 0/ && !done { printf "%s", blocks; done=1 }
            { print }
        ' "$bsc_cfg" > "$tmp_bsc"
        cp "$tmp_bsc" "$bsc_cfg"
        rm -f "$tmp_bsc"

        echo -e "  ${GREEN}✓ ${n_trx} TRX dans osmo-bsc.cfg${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Injection handover
# ══════════════════════════════════════════════════════════════════════════════
inject_handover() {
    local bsc_cfg="/etc/osmocom/osmo-bsc.cfg"
    [ -f "$bsc_cfg" ] || return 0

    echo -e "  ${CYAN}Injection handover (algo 2) dans osmo-bsc.cfg${NC}"

    local tmp; tmp=$(mktemp)

    awk '
    /^ handover 0/ {
        print " handover 1"
        next
    }
    /^ handover algorithm 1/ {
        print " handover algorithm 2"
        next
    }
    { print }
    ' "$bsc_cfg" > "$tmp"

    awk '
    /^ handover algorithm 2/ && !ho2_done {
        print
        print " handover2 window rxlev averaging 10"
        print " handover2 window rxqual averaging 1"
        print " handover2 window rxlev neighbor averaging 10"
        print " handover2 power budget interval 6"
        print " handover2 power budget hysteresis 3"
        print " handover2 maximum distance 9999"
        print " handover2 assignment 1"
        print " handover2 tdma-measurement full"
        ho2_done = 1
        next
    }
    /^ handover1 / { next }
    { print }
    ' "$tmp" > "${tmp}.2"

    cp "${tmp}.2" "$bsc_cfg"
    rm -f "$tmp" "${tmp}.2"

    echo -e "  ${GREEN}✓ Handover algo 2 activé${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Attente du service mobile pour un groupe spécifique
# ══════════════════════════════════════════════════════════════════════════════
wait_group_vty() {
    local group_num="$1"
    local ip="127.0.0.${group_num}"
    local port="4247"
    local timeout=60
    local elapsed=0

    echo -ne "  Attente Groupe ${group_num} (${ip}:${port})"
    while ! bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            return 1
        fi
    done
    echo -e " ${GREEN}OK${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
SESSION="osmocom"
TMUX_SOCKET="/tmp/osmocom_tmux"
init_tmux() {
    echo -e "  ${CYAN}Initialisation tmux pour Op${OPERATOR_ID}...${NC}"
    
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "  ${RED}✗ tmux n'est pas installé${NC}"
        return 1
    fi
    
    if [ ! -d "/tmp" ] || [ ! -w "/tmp" ]; then
        echo -e "  ${RED}✗ /tmp n'est pas accessible en écriture${NC}"
        return 1
    fi
    
    # Nettoyer l'ancien socket s'il existe
    rm -f "$TMUX_SOCKET"
    
    # Démarrer le serveur tmux
    tmux -S "$TMUX_SOCKET" start-server
    
    # Créer une session main
    tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION" -n main 2>/dev/null || true
    
    echo -e "  ${GREEN}✓ Socket tmux: ${TMUX_SOCKET}${NC}"
    echo -e "  ${GREEN}✓ Session: ${SESSION}${NC}"
    
    return 0
}


# Initialisation tmux
echo -e "${GREEN}=== Initialisation tmux ===${NC}"
init_tmux
echo ""

# ── 2. Génération config MS ──────────────────────────────────────────────────
echo -e "${GREEN}=== [2/10] Génération config MS (${MOBILE_MODE}, N=${N_MS}) ===${NC}"
generate_ms_configs
echo ""

# ── 2b. Injection TRX enfants ────────────────────────────────────────────────
echo -e "${GREEN}=== [2b/10] TRX enfants (${N_TRX} TRX) ===${NC}"
inject_extra_trx "$N_TRX"
echo ""

# ── 2c. Injection handover ───────────────────────────────────────────────────
echo -e "${GREEN}=== [2c/10] Handover ===${NC}"
inject_handover
echo ""

# ── 3. Core Osmocom ─────────────────────────────────────────────────────────
echo -e "${GREEN}=== [3/10] Core Osmocom ===${NC}"
/etc/osmocom/osmo-start.sh

# ── 4. FakeTRX ──────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [4/10] FakeTRX (${N_MS} UE, ${N_TRX} TRX) ===${NC}"

tmux -S "$TMUX_SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION" -n main

while [ ! -S "$TMUX_SOCKET" ]; do sleep 0.1; done

tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n faketrx

FAKETRX_CMD="python3 ${FAKETRX_PY} -b 127.0.0.1 -R 127.0.0.1 -r 127.0.0.1 -P ${BTS_PORT_BASE} -p ${BB_PORT_BASE}"

for trx_idx in $(seq 1 $((N_TRX - 1))); do
    FAKETRX_CMD="${FAKETRX_CMD} --trx bts${trx_idx}@127.0.0.1:${BTS_PORT_BASE}/${trx_idx}"
done

for ms_idx in $(seq 2 "${N_MS}"); do
    ue_group=$(( (ms_idx - 1) / 8 + 1 ))
    FAKETRX_CMD="${FAKETRX_CMD} --trx ue${ms_idx}@127.0.0.${ue_group}:$(bb_port $ms_idx)"
done

tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:faketrx" "${FAKETRX_CMD}" C-m
wait_udp "$BTS_PORT_BASE" "fake_trx UDP" 30 || true

# ── 6. trxcon — N_MS instances ───────────────────────────────────────────────
echo -e "${GREEN}=== [6/10] trxcon (${N_MS} UE) ===${NC}"

tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n trxcon

for ms_idx in $(seq 1 "${N_MS}"); do
    local_l2=$(l2_sock "$ms_idx")
    local_port=$(bb_port "$ms_idx")
    pane_window_idx=$(( (ms_idx - 1) / 8 ))
    pane_local_idx=$(( (ms_idx - 1) % 8 ))
    ue_group=$(( pane_window_idx + 1 ))
    group_ip="127.0.0.${ue_group}"

    trxcon_cmd="trxcon ue${ms_idx} -C 1 -i 127.0.0.1 -b ${group_ip} -p ${local_port} -s ${local_l2} -F 100"
    trxcon_win="trxcon${pane_window_idx}"

    if [ "$pane_local_idx" -eq 0 ]; then
        if [ "$pane_window_idx" -gt 0 ]; then
            tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n "$trxcon_win"
        else
            tmux -S "$TMUX_SOCKET" rename-window -t "${SESSION}:trxcon" "$trxcon_win"
        fi
    else
        tmux -S "$TMUX_SOCKET" split-window -v -t "${SESSION}:${trxcon_win}"
        tmux -S "$TMUX_SOCKET" select-layout -t "${SESSION}:${trxcon_win}" even-vertical 2>/dev/null || true
    fi

    tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${trxcon_win}.${pane_local_idx}" \
        "echo '=== ue${ms_idx} (group ${ue_group}, IP ${group_ip}) ===' && ${trxcon_cmd}" C-m

    if [ "$N_MS" -le 16 ] || [ $(( ms_idx % 8 )) -eq 1 ] || [ "$ms_idx" -eq "$N_MS" ]; then
        echo -e "  ${CYAN}[ue${ms_idx}]${NC} bind=${group_ip}:${local_port} l2=${local_l2}"
    fi
done

# ── 7. Mobile processes — AVEC ATTENTE SÉQUENTIELLE DES GROUPES ──────────────
echo -e "${GREEN}=== [7/10] Mobile Processes (${MOBILE_MODE}) — Séquentiel par groupe ===${NC}"

if [ "$MOBILE_MODE" = "split" ]; then
    # Mode split : 1 MS par processus
    for ms_idx in $(seq 1 "${N_MS}"); do
        group_num=$(( (ms_idx - 1) / 8 + 1 ))
        win_name="ue${ms_idx}"
        
        # Attendre que le groupe précédent soit prêt
        if [ $ms_idx -gt 1 ]; then
            prev_group=$(( (ms_idx - 2) / 8 + 1 ))
            if [ $prev_group -ne $group_num ]; then
                # On change de groupe → attendre que le nouveau groupe soit prêt
                echo -e "  ${CYAN}--- Passage au Groupe ${group_num} (IP 127.0.0.${group_num}) ---${NC}"
                wait_group_vty "$group_num"
                echo -e "  ${GREEN}[*] Stabilisation Groupe ${group_num} (3s)...${NC}"
                sleep 3
            fi
        fi
        
        tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n "$win_name"
        tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${win_name}" \
            "mobile -c /root/.osmocom/bb/mobile_ms${ms_idx}.cfg" C-m
    done
else
    # Mode combined : groupes de MS
    # Mode combined : groupes de MS
    for g_idx in $(seq 1 "${N_GROUPS}"); do
        win_name="ue_g${g_idx}"
        group_ip="127.0.0.${g_idx}"
        
        # Attendre que le groupe PRÉCÉDENT soit prêt avant de lancer le suivant
        if [ $g_idx -gt 1 ]; then
            prev_group=$((g_idx - 1))
            prev_ip="127.0.0.${prev_group}"
            echo -e "  ${CYAN}--- Attente Groupe ${prev_group} (${prev_ip}:4247) avant Groupe ${g_idx} ---${NC}"
            
            # Attendre que le groupe précédent soit prêt
            # Attendre que le groupe précédent soit prêt
            retry=0
            while ! bash -c "echo >/dev/tcp/${prev_ip}/4247" 2>/dev/null; do
                sleep 2
                echo -n "."
                retry=$((retry + 1))
                if [ $retry -ge 30 ]; then
                    echo -e " ${RED}TIMEOUT${NC}"
                    break
                fi
            done
            echo -e " ${GREEN}OK${NC}"
            
            # Stabilisation
            echo -e "  ${GREEN}[*] Stabilisation (3s)...${NC}"
            sleep 3
        fi
        
        tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n "$win_name"
        tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:${win_name}" \
            "mobile -c /root/.osmocom/bb/mobile_group${g_idx}.cfg" C-m
        
        echo -e "  ${GREEN}[*] Groupe ${g_idx} (${group_ip}) démarré${NC}"
    done
fi

# ── 9. Asterisk ──────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [9/10] Asterisk ===${NC}"
tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n asterisk
tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:asterisk" \
    "pkill asterisk 2>/dev/null; sleep 2; pkill -9 asterisk 2>/dev/null; sleep 1; rm -f /var/lib/asterisk/astdb.sqlite3; asterisk -cvvv" C-m

# ── 10. SMSC + gapk ─────────────────────────────────────────────────────────
echo -e "${GREEN}=== [10/10] SMSC + gapk ===${NC}"
tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n smsc

if [ -f /etc/osmocom/smsc-start.sh ]; then
    tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:smsc" "/etc/osmocom/smsc-start.sh" C-m
else
    tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:smsc" "echo 'SMSC non disponible'" C-m
fi

tmux -S "$TMUX_SOCKET" new-window -t "$SESSION" -n gapk
tmux -S "$TMUX_SOCKET" send-keys -t "${SESSION}:gapk" \
    "echo '=== gapk audio ===' && sleep 3 && (gapk-start.sh auto 2>/dev/null || echo 'gapk non disponible')" C-m

# ── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Op${OPERATOR_ID} — ${N_MS} MS — ${MOBILE_MODE} — ${N_TRX} TRX              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Mobile mode :${NC} ${MOBILE_MODE}"
if [ "$MOBILE_MODE" = "split" ]; then
    echo -e "  ${CYAN}Fichiers    :${NC} mobile_ms1.cfg .. mobile_ms${N_MS}.cfg"
else
    echo -e "  ${CYAN}Fichiers    :${NC} mobile_group1.cfg .. mobile_group${N_GROUPS}.cfg"
fi
echo -e "  ${CYAN}TRX BTS     :${NC} ${N_TRX} (1 base + $((N_TRX-1)) enfants)"
echo -e "  ${CYAN}Handover    :${NC} algo 2 activé"
echo -e "  ${CYAN}UE          :${NC} ue1 .. ue${N_MS}"
echo -e "  ${CYAN}Sockets L2  :${NC} ${L2_SOCK_BASE}_1 .. ${L2_SOCK_BASE}_${N_MS}"
echo -e "  ${CYAN}Sockets SAP :${NC} ${SAP_SOCK_BASE}_1 .. ${SAP_SOCK_BASE}_${N_MS}"
echo -e "  ${CYAN}Ports BB    :${NC} $(bb_port 1) .. $(bb_port $N_MS)"
echo ""
echo -e "  ${CYAN}Fenêtres tmux :${NC}"
echo -e "    faketrx  trxcon*  ue*  asterisk  smsc  gapk"
echo ""
echo -e "  ${CYAN}Contrôle UE :${NC} Ctrl-b w → choisir fenêtre ue*"
echo -e "    enable → show ms → ms 1 → network select 1"
echo ""
echo -e "  ${CYAN}Navigation :${NC}  Ctrl-b w   Ctrl-b n/p"
echo ""

tmux select-window -t "${SESSION}:ue_g1" 2>/dev/null \
    || tmux select-window -t "${SESSION}:ue1" 2>/dev/null \
    || true
tmux attach-session -t "$SESSION"
