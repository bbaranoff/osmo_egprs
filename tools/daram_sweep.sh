#!/bin/bash
# tools/daram_sweep.sh - balaye CALYPSO_BSP_DARAM_ADDR en full mode et compare
# l'activite du correlateur FB-det (fb0_att / snr / toa / pm).
# But : trancher empiriquement quelle zone DARAM debloque le FB-det.
#
# Robuste : run.sh est lance NO_ATTACH EN AVANT-PLAN (il rend la main seul
# apres avoir lance qemu, qui survit orphelin). On NE backgroude PAS run.sh
# avec & (ca cassait le pipe du log → qemu mourait). On verifie que qemu est
# vivant avant de mesurer ; sinon on le signale.
#
# Usage (conteneur) : /opt/GSM/daram_sweep.sh
# Env : ADDRS (defaut "0x0080 0x2a00 0x0060"), SETTLE (attente post-boot, 50s)
set -u
RUN=/opt/GSM/qemu-src/run.sh
QLOG=/root/qemu.log
ADDRS="${ADDRS:-0x0080 0x2a00 0x0060}"
SETTLE="${SETTLE:-50}"
declare -A R_FB R_SB R_NZ R_BEST R_ALIVE R_STATES

kill_all() {
    tmux kill-session -t calypso 2>/dev/null
    for p in $(pgrep -f qemu-system-arm); do kill -9 "$p" 2>/dev/null; done
    pkill -9 -f osmo-bts-trx 2>/dev/null; pkill -9 -f osmo-trx-ipc 2>/dev/null
    pkill -9 -f "mobile" 2>/dev/null; pkill -9 -f osmocon 2>/dev/null
    sleep 4
}

for a in $ADDRS; do
    echo "############ DARAM_ADDR=$a ############ $(date +%H:%M:%S)"
    kill_all
    : > "$QLOG"
    # run.sh NO_ATTACH rend la main seul apres le launch (~30-60s). timeout = filet.
    echo "  launch run.sh (NO_ATTACH, avant-plan, le boot prend ~30-60s)..."
    timeout 150 env CALYPSO_NO_ATTACH=1 CALYPSO_MODE=full CALYPSO_ICOUNT=off \
      CALYPSO_BSP_DARAM_ADDR="$a" "$RUN" </dev/null >"/tmp/sweep_$a.out" 2>&1
    echo "  run.sh rendu (code=$?). qemu doit tourner orphelin. settle ${SETTLE}s..."
    alive=no
    for i in $(seq 1 $((SETTLE/5))); do
        sleep 5
        if pgrep -f qemu-system-arm >/dev/null; then alive=yes; else alive=no; fi
        # stop tot si on a deja du FB data non trivial
        grep -qa "real DSP path" "$QLOG" 2>/dev/null && [ "$i" -ge 4 ] && break
    done

    fb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "fb0_att=[0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1)
    sb=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -oE "sb_att=[0-9]+"  | grep -oE "[0-9]+" | sort -n | tail -1)
    nz=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avE "snr=0 toa=0 ang=0 pm=0" | grep -c "last(")
    best=$(grep -a "real DSP path" "$QLOG" 2>/dev/null | grep -avE "snr=0 toa=0 ang=0 pm=0" \
             | grep -oE "last\(snr=[0-9-]+ toa=[0-9-]+ ang=[0-9-]+ pm=[0-9a-fx]+\)" | head -1)
    states=$(grep -aoE 'state=[A-Z0-9_]+' "$QLOG" 2>/dev/null | sort | uniq -c | tr '\n' ' ')
    qlines=$(wc -l < "$QLOG" 2>/dev/null)
    R_FB[$a]="${fb:-0}"; R_SB[$a]="${sb:-0}"; R_NZ[$a]="${nz:-0}"
    R_BEST[$a]="${best:-none}"; R_ALIVE[$a]="$alive"; R_STATES[$a]="${states:-<aucun>}"
    echo "  -> qemu_vivant=$alive  qemu.log=${qlines}l  fb0_att=${fb:-0}  sb_att=${sb:-0}  non0=${nz:-0}"
    echo "  -> etats: ${states:-<aucun>}"
    echo "  -> 1er correlateur non-nul: ${best:-none}"
done

kill_all
echo
echo "================= COMPARAISON ================="
printf "%-9s %-7s %-9s %-8s %-6s %s\n" "ADDR" "alive" "fb0_att" "sb_att" "non0" "1er_corr"
for a in $ADDRS; do
    printf "%-9s %-7s %-9s %-8s %-6s %s\n" \
      "$a" "${R_ALIVE[$a]}" "${R_FB[$a]}" "${R_SB[$a]}" "${R_NZ[$a]}" "${R_BEST[$a]}"
done
echo
echo "Gagnant = fb0_att>0 et/ou non0>0 (correlateur voit l'I/Q). alive=no => boot KO."
