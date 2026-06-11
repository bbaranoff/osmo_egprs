#!/bin/bash
# start_dbg.sh — lance le labo en capturant les crashes.
#
# Active les core dumps, attache gdb EN LIVE a calypso-ipc-device et
# osmo-trx-ipc (re-attache s'ils sont relances par run.sh), lance le labo
# (start-clean.sh par defaut), et ecrit les backtraces dans /tmp/osmo-dbg/.
# Aucun reseau requis : tout reste en local.
#
# Usage :
#   sudo ./start_dbg.sh                 # lance /opt/GSM/qemu-src/start-clean.sh
#   sudo LAB=/opt/GSM/qemu-src/run.sh ./start_dbg.sh
#   sudo LAB=none ./start_dbg.sh        # ne lance rien, surveille seulement
#   sudo TARGETS="calypso-ipc-device osmo-trx-ipc osmo-bts-trx" ./start_dbg.sh
#
# Resultats : /tmp/osmo-dbg/bt_<binaire>.txt  (+ cores dans /tmp/osmo-dbg/)
set -u

DBG="${DBG:-/tmp/osmo-dbg}"
LAB="${LAB:-/opt/GSM/qemu-src/start-clean.sh}"
TARGETS="${TARGETS:-calypso-ipc-device osmo-trx-ipc}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ "$(id -u)" -ne 0 ] && echo -e "${YELLOW}[dbg] conseille en root (gdb attach + core_pattern).${NC}"

mkdir -p "$DBG"; rm -f "$DBG"/bt_*.txt "$DBG"/core.* 2>/dev/null || true

# ── 1. core dumps (filet de securite si gdb n'attrape pas) ───────────────────
ulimit -c unlimited 2>/dev/null || true
echo "$DBG/core.%e.%p" > /proc/sys/kernel/core_pattern 2>/dev/null \
  || echo "$DBG/core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern >/dev/null 2>&1 || true

if ! command -v gdb >/dev/null 2>&1; then
    echo -e "${YELLOW}[dbg] gdb absent — tentative d'installation...${NC}"
    apt-get update -qq && apt-get install -y --no-install-recommends gdb \
        || echo -e "${RED}[dbg] installe gdb manuellement (apt-get install gdb).${NC}"
fi

# PID dont l'executable reel a pour basename exactement $1 (evite de matcher
# le script, tmux, ou la ligne de commande de gdb).
real_pid() {
    local name="$1" p exe
    for p in $(pgrep -f "$name" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        exe=$(readlink -f "/proc/$p/exe" 2>/dev/null) || continue
        [ "$(basename "$exe")" = "$name" ] && { echo "$p"; return 0; }
    done
    return 1
}

# ── 2. un watcher gdb par binaire : attend le PID, attache, capture le crash ─
watch_target() {
    local name="$1" out="$DBG/bt_$1.txt" pid run=0
    : > "$out"
    while true; do
        if pid=$(real_pid "$name"); then
            run=$((run+1))
            {
                echo "================================================================"
                echo "[dbg] $name  pid=$pid  attache #$run  $(date)"
                echo "----- ldd -----"
                ldd "$(readlink -f /proc/$pid/exe)" 2>&1
                echo "----- gdb (attend le crash) -----"
                gdb -p "$pid" -batch \
                    -ex 'set pagination off' \
                    -ex 'handle SIGPIPE nostop noprint pass' \
                    -ex continue \
                    -ex 'printf "\n===== CRASH (%s) =====\n", "'"$name"'"' \
                    -ex 'bt full' \
                    -ex 'info registers' \
                    -ex 'thread apply all bt' 2>&1
                echo "[dbg] $name pid=$pid termine $(date)"
            } >> "$out"
            echo -e "${RED}[dbg] $name (pid=$pid) a quitte -> bt dans $out${NC}"
        fi
        sleep 2
    done
}

WPIDS=()
for t in $TARGETS; do
    watch_target "$t" &
    WPIDS+=("$!")
done

summary() {
    echo ""
    echo -e "${CYAN}========== RESULTATS DEBUG ==========${NC}"
    ls -l "$DBG"/bt_*.txt "$DBG"/core.* 2>/dev/null
    echo -e "${CYAN}Backtraces : ${DBG}/bt_*.txt${NC}"
    echo -e "${CYAN}Recupere-les : scp -P 2222 root@localhost:'${DBG}/bt_*.txt' .${NC}"
    kill "${WPIDS[@]}" 2>/dev/null || true
}
trap 'summary; exit 0' INT TERM EXIT

echo -e "${CYAN}[dbg] watchers gdb actifs : ${TARGETS}${NC}"
echo -e "${CYAN}[dbg] backtraces -> ${DBG}/bt_*.txt${NC}"

# ── 3. lance le labo (ou non) ────────────────────────────────────────────────
if [ "$LAB" = "none" ]; then
    echo -e "${YELLOW}[dbg] LAB=none — lance ton labo a la main. Ctrl-C pour finir.${NC}"
elif [ -x "$LAB" ]; then
    echo -e "${GREEN}[dbg] lancement ${LAB}${NC}"
    ( cd "$(dirname "$LAB")" && "$LAB" ) || true
else
    echo -e "${YELLOW}[dbg] ${LAB} introuvable — lance ton labo a la main. Ctrl-C pour finir.${NC}"
fi

# Le labo (tmux) rend souvent la main : on garde les watchers vivants jusqu'au Ctrl-C.
echo -e "${CYAN}[dbg] surveillance active. Reproduis le crash, puis Ctrl-C.${NC}"
while true; do sleep 5; done
