#!/bin/bash
# run.sh — Orchestrateur intra-container Osmocom
#
# Séquence garantie :
#   1. Reset
#   2. generate_ms_configs  → UN SEUL mobile_combined.cfg avec N blocs ms
#   3. osmo-start.sh        → STP HLR MGW MSC BSC GGSN SGSN PCU
#                             (PAS bts-trx ni sip-connector)
#   4. fake_trx démarre     → bind UDP 5700 (+trx additionnels via --trx)
#   5. osmo-bts-trx start   → se connecte à fake_trx déjà prêt ✓
#   6. trxcon × N (chacun -C) → N process, N sockets L1CTL
#   7. mobile (UN SEUL)     → charge tous les ms depuis le combined cfg
#   8. sip-connector        → après MNCC socket prêt
#   9. Asterisk              → après sip-connector
#  10. SMSC + gapk
#
# Architecture OsmocomBB multi-MS :
#
#       fake_trx (1 process)
#          │  (N TRX internes : --trx pour chaque MS ≥ 2)
#          │
#     ┌────┼────┐
#   trxcon1 trxcon2 trxcon3  ← chacun avec -C, son port TRX, son socket L1CTL
#     │     │     │
#     └────┼────┘
#       mobile (1 process)
#       mobile_combined.cfg : ms 1 / ms 2 / ms 3
#
# OsmocomBB a été conçu pour UN téléphone Calypso physique → une seule
# couche radio. fake_trx a gardé cette architecture : 1 transceiver,
# N MS logiques au-dessus. Donc : 1 mobile process, 1 fichier cfg, N blocs ms.
#
# DEBUG MODE: DEBUG=1 ./run.sh

set -euo pipefail

# ── LOGGING ────────────────────────────────────────────────────────────────
# Tout stdout+stderr → fichier log + console
# Lire depuis le host : docker exec <container> cat /var/log/osmocom/run.sh.log
LOG_FILE="/var/log/osmocom/run.sh.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "========================================"
echo "  run.sh démarré à $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

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

# Base du socket L1CTL — chaque trxcon -C -s crée un socket
# trxcon MS1 → ${L2_SOCK_BASE}_1, MS2 → ${L2_SOCK_BASE}_2, etc.
L2_SOCK_BASE="/tmp/osmocom_l2"
SAP_SOCK_BASE="/tmp/osmocom_sap"

[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] OPERATOR_ID=$OPERATOR_ID N_MS=$N_MS FAKETRX_PY=$FAKETRX_PY"

if ! [[ "$N_MS" =~ ^[0-9]+$ ]] || [ "$N_MS" -lt 1 ] || [ "$N_MS" -gt 9 ]; then
    echo -e "${YELLOW}[WARN] N_MS='${N_MS}' invalide → forcé à 1${NC}"
    N_MS=1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Génération d'UN SEUL mobile_combined.cfg contenant N blocs ms
#
# Format VTY OsmocomBB :
#   ┌── partie globale (line vty, gps, no hide-default)
#   ├── ms 1
#   │     ├── layer2-socket, sap-socket, sim, imei, support {...exit}, test-sim {...exit}
#   │     └── exit            ← sans indentation = ferme le bloc ms
#   ├── ms 2 (optionnel)
#   │     └── exit
#   └── !
#
# Format ancien (configs/) : le bloc ms se termine par 'end' au lieu de 'exit'
#
# On extrait SEULEMENT le premier bloc ms comme template, puis on le
# duplique N fois avec des credentials/sockets différents.
# ══════════════════════════════════════════════════════════════════════════════
generate_ms_configs() {
    local base_cfg="/root/.osmocom/bb/mobile.cfg"
    local combined_cfg="/root/.osmocom/bb/mobile_combined.cfg"

    echo -e "  ${CYAN}[cfg]${NC} Source  : ${base_cfg}"
    echo -e "  ${CYAN}[cfg]${NC} Sortie  : ${combined_cfg}"

    if [ ! -f "$base_cfg" ]; then
        echo -e "${RED}[ERR] mobile.cfg introuvable : ${base_cfg}${NC}"
        echo -e "${RED}      ls /root/.osmocom/bb/ :${NC}"
        ls -la /root/.osmocom/bb/ 2>&1 | sed 's/^/      /'
        return 1
    fi

    echo -e "  ${CYAN}[cfg]${NC} Taille  : $(wc -l < "$base_cfg") lignes, $(wc -c < "$base_cfg") octets"

    # ── Dump rapide du fichier source ─────────────────────────────────────
    echo -e "  ${CYAN}[cfg]${NC} Contenu (premières / dernières lignes) :"
    head -5 "$base_cfg" | sed 's/^/      | /'
    echo "      | ..."
    tail -5 "$base_cfg" | sed 's/^/      | /'

    # ── Extraction des valeurs de référence ───────────────────────────────
    # IMPORTANT: || true sur chaque grep — sinon set -e tue le script
    # silencieusement si un pattern ne matche pas (grep retourne 1)
    local ref_imsi ref_imei ref_ki ref_l2 ref_sap

    ref_imsi=$(grep -oP '^\s+imsi\s+\K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_imei=$(grep -oP '^\s+imei \K[0-9]+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_ki=$(grep -oP '^\s+ki comp128 \K[0-9a-f ]+' "$base_cfg" 2>/dev/null | head -1 \
             | sed 's/[[:space:]]*$//' || true)
    ref_l2=$(grep -oP 'layer2-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || true)
    ref_l2="${ref_l2:-/tmp/osmocom_l2}"
    ref_sap=$(grep -oP 'sap-socket \K\S+' "$base_cfg" 2>/dev/null | head -1 || true)

    # Fallback si grep -P (PCRE) pas dispo dans le container
    if [ -z "$ref_imsi" ]; then
        echo -e "  ${YELLOW}[ref] grep -oP échoué → fallback grep -E${NC}"
        ref_imsi=$(grep -E 'imsi [0-9]+' "$base_cfg" 2>/dev/null | head -1 | awk '{print $NF}' || true)
        ref_imei=$(grep -E 'imei [0-9]+' "$base_cfg" 2>/dev/null | head -1 | awk '{print $2}' || true)
        ref_ki=$(grep -E 'ki comp128' "$base_cfg" 2>/dev/null | head -1 \
                 | sed 's/.*ki comp128 //' | sed 's/[[:space:]]*$//' || true)
        ref_l2=$(grep -E 'layer2-socket' "$base_cfg" 2>/dev/null | head -1 | awk '{print $2}' || true)
        ref_l2="${ref_l2:-/tmp/osmocom_l2}"
        ref_sap=$(grep -E 'sap-socket' "$base_cfg" 2>/dev/null | head -1 | awk '{print $2}' || true)
    fi

    echo -e "  ${CYAN}[ref]${NC} IMSI    : '${ref_imsi:-${RED}VIDE${NC}}'"
    echo -e "  ${CYAN}[ref]${NC} IMEI    : '${ref_imei:-${RED}VIDE${NC}}'"
    echo -e "  ${CYAN}[ref]${NC} KI      : '${ref_ki:-${RED}VIDE${NC}}'"
    echo -e "  ${CYAN}[ref]${NC} L2 sock : '${ref_l2}'"
    echo -e "  ${CYAN}[ref]${NC} SAP sock: '${ref_sap:-ABSENT → injection auto}'"

    if [ -z "$ref_imsi" ] || [ -z "$ref_imei" ] || [ -z "$ref_ki" ]; then
        echo -e "${RED}[ERR] Impossible d'extraire IMSI/IMEI/KI de ${base_cfg}${NC}"
        echo -e "${RED}      Lignes contenant imsi/imei/ki :${NC}"
        grep -inE '(imsi|imei|ki comp128)' "$base_cfg" 2>/dev/null | head -10 | sed 's/^/      /' || true
        echo -e "${RED}      → Les __PLACEHOLDERS__ ont-ils été substitués par start.sh ?${NC}"
        return 1
    fi

    local mcc mnc
    mcc=$(grep -E '^\s+rplmn ' "$base_cfg" 2>/dev/null | awk '{print $2}' | head -1 || true)
    mnc=$(grep -E '^\s+rplmn ' "$base_cfg" 2>/dev/null | awk '{print $3}' | head -1 || true)
    mcc="${mcc:-001}"; mnc="${mnc:-01}"

    echo -e "  ${CYAN}[ref]${NC} MCC/MNC : ${mcc} / ${mnc}"

    # ── Extraction partie globale (tout avant le premier 'ms N') ──────────
    local global_line
    global_line=$(grep -n '^ms [0-9]' "$base_cfg" 2>/dev/null | head -1 | cut -d: -f1 || true)

    if [ -z "$global_line" ]; then
        echo -e "${RED}[ERR] Pas de bloc 'ms' trouvé dans ${base_cfg}${NC}"
        echo -e "${RED}      Le fichier ne contient pas de ligne commençant par 'ms [0-9]'${NC}"
        echo -e "${RED}      grep 'ms ' résultat :${NC}"
        grep -n 'ms ' "$base_cfg" 2>/dev/null | head -5 | sed 's/^/      /' || true
        return 1
    fi

    echo -e "  ${CYAN}[parse]${NC} Premier 'ms' trouvé ligne ${global_line}"
    echo -e "  ${CYAN}[parse]${NC} Partie globale : lignes 1-$(( global_line - 1 ))"

    head -n $(( global_line - 1 )) "$base_cfg" > "$combined_cfg"

    # ── Template = premier bloc ms SEULEMENT ──────────────────────────────
    # S'arrête au premier ^exit$ ou ^end$ ou au prochain ^ms [0-9]
    # Les ' exit' indentés (support/test-sim) sont ignorés.
    local ms_template
    ms_template=$(awk '
        /^ms [0-9]/ {
            if (found) { exit }
            found=1; printing=1
        }
        printing { print }
        /^(exit|end)$/ && printing && found { printing=0; exit }
    ' "$base_cfg")

    if [ -z "$ms_template" ]; then
        echo -e "${RED}[ERR] Extraction du bloc ms échouée (awk n'a rien trouvé)${NC}"
        echo -e "${RED}      Lignes autour de 'ms 1' :${NC}"
        sed -n "$(( global_line - 2 )),$(( global_line + 5 ))p" "$base_cfg" | sed 's/^/      | /'
        return 1
    fi

    local tpl_lines
    tpl_lines=$(echo "$ms_template" | wc -l)
    local tpl_first
    tpl_first=$(echo "$ms_template" | head -1)
    local tpl_last
    tpl_last=$(echo "$ms_template" | tail -1)

    echo -e "  ${CYAN}[parse]${NC} Template ms : ${tpl_lines} lignes"
    echo -e "  ${CYAN}[parse]${NC}   première : '${tpl_first}'"
    echo -e "  ${CYAN}[parse]${NC}   dernière : '${tpl_last}'"

    # Vérifier que le template se termine bien par exit ou end
    if ! echo "$tpl_last" | grep -qE '^(exit|end)$'; then
        echo -e "  ${YELLOW}[WARN] Template ne se termine pas par exit/end → dernière ligne : '${tpl_last}'${NC}"
    fi

    # ── Écriture des N blocs ms ───────────────────────────────────────────
    echo ""
    for ms_idx in $(seq 1 "${N_MS}"); do
        local l2_sock="${L2_SOCK_BASE}_${ms_idx}"
        local sap_sock="${SAP_SOCK_BASE}_${ms_idx}"
        local msin; msin=$(printf '%04d%06d' "${OPERATOR_ID}" "${ms_idx}")
        local new_imsi="${mcc}${mnc}${msin}"
        local new_imei; new_imei="3589250059$(printf '%02d%02d' "${OPERATOR_ID}" "${ms_idx}")0"
        local new_ki; new_ki=$(printf '00 11 22 33 44 55 66 77 88 99 aa bb cc dd %02x ff' \
                                      "${ms_idx}")

        local ms_block
        ms_block=$(echo "$ms_template" \
            | sed \
                -e "s|^ms [0-9]\+|ms ${ms_idx}|" \
                -e "s|layer2-socket ${ref_l2}|layer2-socket ${l2_sock}|" \
                -e "s|imsi ${ref_imsi}|imsi ${new_imsi}|" \
                -e "s|imei ${ref_imei}[[:space:]]*[0-9]*|imei ${new_imei}|" \
                -e "s|ki comp128 ${ref_ki}|ki comp128 ${new_ki}|" \
        )

        # sap-socket : remplacer si présent, sinon injecter après layer2-socket
        if [ -n "$ref_sap" ]; then
            ms_block=$(echo "$ms_block" \
                | sed "s|sap-socket ${ref_sap}|sap-socket ${sap_sock}|")
        else
            ms_block=$(echo "$ms_block" \
                | sed "/layer2-socket/a\\ sap-socket ${sap_sock}")
        fi

        echo "$ms_block" >> "$combined_cfg"
        echo "" >> "$combined_cfg"

        echo -e "  ${CYAN}[MS${ms_idx}]${NC} IMSI=${new_imsi}  IMEI=${new_imei}  KI=…$(printf '%02x ff' "${ms_idx}")"
        echo -e "  ${CYAN}[MS${ms_idx}]${NC} L1CTL=${l2_sock}  SAP=${sap_sock}"

        # Vérification post-sed : les substitutions ont-elles marché ?
        if echo "$ms_block" | grep -q "${ref_imsi}"; then
            echo -e "  ${YELLOW}[WARN MS${ms_idx}] IMSI ref '${ref_imsi}' encore présent après sed !${NC}"
        fi
        if echo "$ms_block" | grep -q "layer2-socket ${ref_l2}\$"; then
            echo -e "  ${YELLOW}[WARN MS${ms_idx}] layer2-socket ref '${ref_l2}' encore présent après sed !${NC}"
        fi
    done

    # ── Vérification finale ───────────────────────────────────────────────
    echo ""
    local n_ms_found n_exit_found
    n_ms_found=$(grep -c '^ms [0-9]' "$combined_cfg")
    n_exit_found=$(grep -cE '^(exit|end)$' "$combined_cfg")

    echo -e "  ${CYAN}[check]${NC} Blocs ms dans combined : ${n_ms_found}  (attendu: ${N_MS})"
    echo -e "  ${CYAN}[check]${NC} Terminateurs exit/end  : ${n_exit_found}  (attendu: ${N_MS})"
    echo -e "  ${CYAN}[check]${NC} Taille combined        : $(wc -l < "$combined_cfg") lignes"

    if [ "$n_ms_found" -ne "$N_MS" ]; then
        echo -e "  ${RED}[ERR] Nombre de blocs ms incorrect !${NC}"
    fi
    if [ "$n_exit_found" -ne "$N_MS" ]; then
        echo -e "  ${YELLOW}[WARN] Nombre de exit/end != N_MS${NC}"
    fi

    echo -e "  ${GREEN}→ ${combined_cfg} (${N_MS} blocs ms)${NC}"
}

# ── Helper : reset TRX via VTY OsmoBTS (port 4236) ──────────────────────────
reset_trx() {
    local vty_host="127.0.0.1" vty_port=4236
    [[ -n "${DEBUG:-}" ]] && echo "[DEBUG] reset_trx: attente ${vty_host}:${vty_port}"

    echo -ne "  Attente VTY OsmoBTS (${vty_host}:${vty_port})"
    elapsed=0
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
    elapsed=0
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
    elapsed=0
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
echo -e "${GREEN}=== [1/10] Reset ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Killing old processes..."
usermod -u 0 -o osmocom 2>/dev/null || true

pkill -9 -f fake_trx.py 2>/dev/null || true
pkill -9 -f "mobile -c" 2>/dev/null || true
pkill -9 -f trxcon 2>/dev/null || true
sleep 1

tmux kill-server 2>/dev/null || true
sleep 0.3
tmux start-server
tmux new-session -d -s "$SESSION" -n main

# ── 2. Génération config MS combinée ─────────────────────────────────────────
echo -e "${GREEN}=== [2/10] Génération config MS combinée (N=${N_MS}) ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Calling generate_ms_configs..."
generate_ms_configs
echo ""

# ── 3. Core Osmocom (sans bts-trx ni sip-connector) ──────────────────────────
echo -e "${GREEN}=== [3/10] Core Osmocom ===${NC}"
[[ -n "${DEBUG:-}" ]] && echo "[DEBUG] Launching /etc/osmocom/osmo-start.sh..."
/etc/osmocom/osmo-start.sh

# ── 4. FakeTRX ───────────────────────────────────────────────────────────────
echo -e "${GREEN}=== [4/10] FakeTRX ===${NC}"

tmux new-window -t "$SESSION" -n faketrx

# Bind explicite sur 127.0.0.1, adresses BTS et BB explicites
# -b  = fake_trx bind address
# -R  = BTS remote (osmo-bts-trx)
# -r  = BB remote (trxcon)
# -P  = BTS base port (défaut 5700, osmo-bts-trx s'y connecte)
# -p  = BB base port  (défaut 6700, trxcon MS1 s'y connecte)
FAKETRX_CMD="python3 ${FAKETRX_PY} -b 127.0.0.1 -R 127.0.0.1 -r 127.0.0.1 -P 5700 -p 6700"
for ms_idx in $(seq 2 "${N_MS}"); do
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))
    FAKETRX_CMD="${FAKETRX_CMD} --trx 127.0.0.1:${trx_port}"
done

echo -e "  ${CYAN}Cmd :${NC} ${FAKETRX_CMD}"
tmux send-keys -t "${SESSION}:faketrx" "${FAKETRX_CMD}" C-m
wait_udp 5700 "fake_trx UDP" 30 || true

# ── 5. OsmoBTS-TRX (APRÈS fake_trx confirmé) ─────────────────────────────────
echo -e "${GREEN}=== [5/10] OsmoBTS-TRX ===${NC}"
systemctl start osmo-bts-trx
wait_port 127.0.0.1 4241 "OsmoBTS VTY" 60 || true

# ── 6. trxcon — N instances séparées, chacune avec -C ─────────────────────────
#
# OsmocomBB : 1 trxcon par MS, chacun -C 1 (1 seul client L1CTL) :
#   trxcon -C 1 -b 127.0.0.1 -i 127.0.0.1 -p 6700 -s /tmp/osmocom_l2_1   (MS1)
#   trxcon -C 1 -b 127.0.0.1 -i 127.0.0.1 -p 6720 -s /tmp/osmocom_l2_2   (MS2)
#   trxcon -C 1 -b 127.0.0.1 -i 127.0.0.1 -p 6740 -s /tmp/osmocom_l2_3   (MS3)
#
# -b = trxcon bind address (écoute réponses de fake_trx)
# -i = TRX remote address  (envoie vers fake_trx)
# -p = TRX base port       (doit matcher le port BB de fake_trx pour ce MS)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}=== [6/10] trxcon (${N_MS} instances, -C 1) ===${NC}"

tmux new-window -t "$SESSION" -n trxcon

for ms_idx in $(seq 1 "${N_MS}"); do
    l2_sock="${L2_SOCK_BASE}_${ms_idx}"
    trx_port=$(( 6700 + (ms_idx - 1) * 20 ))

    # Toujours explicite : bind, remote, port, max-clients=1
    trxcon_cmd="trxcon -C 1 -b 127.0.0.1 -i 127.0.0.1 -p ${trx_port} -s ${l2_sock} -F 100"

    echo -e "  ${CYAN}[trxcon${ms_idx}]${NC} ${trxcon_cmd}"

    # Premier dans le pane existant, suivants dans des splits
    if [ "$ms_idx" -gt 1 ]; then
        tmux split-window -v -t "${SESSION}:trxcon"
        tmux select-layout -t "${SESSION}:trxcon" even-vertical
    fi

    pane_idx=$(( ms_idx - 1 ))
    tmux send-keys -t "${SESSION}:trxcon.${pane_idx}" \
        "echo '=== trxcon MS${ms_idx} ===' && sleep 2 && ${trxcon_cmd}" C-m
done

# ── 7. mobile (UN SEUL process, tous les ms) ──────────────────────────────────
echo -e "${GREEN}=== [7/10] mobile (1 process, ${N_MS} MS) ===${NC}"

combined_cfg="/root/.osmocom/bb/mobile_combined.cfg"

# Attendre que les sockets L1CTL existent (créés par trxcon)
echo -ne "  Attente sockets L1CTL"
elapsed=0
all_ready=false
while [ "$elapsed" -lt 30 ]; do
    all_ready=true
    for ms_idx in $(seq 1 "${N_MS}"); do
        if [ ! -S "${L2_SOCK_BASE}_${ms_idx}" ]; then
            all_ready=false
            break
        fi
    done
    if $all_ready; then break; fi
    sleep 1; elapsed=$((elapsed + 1)); echo -n "."
done
if $all_ready; then
    echo -e " ${GREEN}OK${NC} (${elapsed}s)"
else
    # Diagnostic : lister ce que trxcon a réellement créé
    echo -e " ${YELLOW}partiel${NC}"
    echo -e "  ${CYAN}Sockets L1CTL présents :${NC}"
    ls -la ${L2_SOCK_BASE}* 2>/dev/null | sed 's/^/    /' || echo "    (aucun)"
    echo -e "  ${YELLOW}→ Si nommage différent, ajuster L2_SOCK_BASE dans run.sh${NC}"
fi

tmux new-window -t "$SESSION" -n mobile
tmux send-keys -t "${SESSION}:mobile" \
    "echo '=== mobile — ${N_MS} MS ===' && sleep 3 && mobile -c ${combined_cfg}" C-m

echo -e "  ${GREEN}→ mobile -c ${combined_cfg}${NC}"
echo -e "  ${CYAN}Contrôle VTY :${NC} enable → show ms → ms 1 → network select 1"

# ── 8. SIP-Connector (AVANT Asterisk — MNCC doit être prêt) ──────────────────
echo -e "${GREEN}=== [8/10] SIP-Connector ===${NC}"

echo -ne "  Attente MNCC socket /tmp/msc_mncc"
elapsed=0
while [ ! -S /tmp/msc_mncc ] && [ $elapsed -lt 30 ]; do
    sleep 1; elapsed=$((elapsed + 1)); echo -n "."
done
[ -S /tmp/msc_mncc ] && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}absent${NC}"

systemctl start osmo-sip-connector
wait_port 127.0.0.1 4255 "SIP-Connector VTY" 30 || true

# ── 9. Asterisk (APRÈS SIP-Connector) ────────────────────────────────────────
echo -e "${GREEN}=== [9/10] Asterisk ===${NC}"

tmux new-window -t "$SESSION" -n asterisk
tmux send-keys -t "${SESSION}:asterisk" \
    "pkill asterisk 2>/dev/null; sleep 2; pkill -9 asterisk 2>/dev/null; sleep 1; rm -f /var/lib/asterisk/astdb.sqlite3; asterisk -cvvv" C-m

# ── 10. SMSC + gapk ──────────────────────────────────────────────────────────
echo -e "${GREEN}=== [10/10] SMSC + gapk ===${NC}"
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

tmux select-window -t "${SESSION}:mobile"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Opérateur ${OPERATOR_ID} — Stack prête  (${N_MS} MS)                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Fenêtres :${NC} faketrx  trxcon  mobile  asterisk  smsc  gapk"
echo ""
echo -e "  ${CYAN}Contrôle MS :${NC} dans la fenêtre mobile (VTY) :"
echo -e "    enable → show ms → ms 1 → network select 1"
echo ""
echo -e "  ${CYAN}Vérif TRX  :${NC} fenêtre faketrx → chercher 'RSP POWERON'"
echo -e "  ${CYAN}Vérif TCH  :${NC} telnet 127.0.0.1 4242 → show bts 0"
echo -e "  ${CYAN}Vérif PJSIP:${NC} asterisk -rx 'pjsip show endpoints'"
echo -e "  ${CYAN}VTY MSC    :${NC} telnet 127.0.0.1 4254"
echo -e "  ${CYAN}VTY HLR    :${NC} telnet 127.0.0.1 4258"
echo ""
echo -e "  ${CYAN}Navigation :${NC}  Ctrl-b w   Ctrl-b n/p"
echo ""

tmux select-window -t "${SESSION}:mobile"
tmux attach-session -t "$SESSION"
