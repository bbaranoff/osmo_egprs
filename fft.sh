#!/usr/bin/env bash
# fft.sh — FFT live "jolie" du flux I/Q Calypso, lue DIRECTEMENT dans le docker.
#
# Lit le tail de /tmp/relay_continu.cfile (le chunk relay CONTINU, tous TS, le
# meme que grgsm_decode -s 1083333 decode) DANS le container, le rapatrie en
# fc32 (complex64), et affiche sur le X de l'HOTE : PSD moyennee (Welch maison)
# + waterfall/spectrogramme defilant. Rafraichi en boucle (FuncAnimation).
#
# Usage :
#   ./fft.sh                      # live, parametres par defaut
#   ./fft.sh --save spectre.png   # une capture PNG (si pas de X)
#   CONTAINER=osmo-operator-1 CFILE=/tmp/relay_continu.cfile RATE=1083333 \
#   NSAMP=262144 REFRESH=1.0 ARFCN=514 ./fft.sh
#
set -euo pipefail
export CONTAINER="${CONTAINER:-osmo-operator-1}"
export FFT_SRC="${FFT_SRC:-fifo}"   # fifo (LIVE, defaut) | sweep | tail
export FIFO="${FIFO:-/tmp/iq_fft.fifo}"          # FIFO live (qemu y pousse chaque trame)
export CFILE="${CFILE:-/tmp/record.cfile}"       # fichier record (fallback sweep/tail)
export RATE="${RATE:-1083333}"      # 4 SPS natif = 26e6/24
export NSAMP="${NSAMP:-32768}"      # complex samples par fenetre (256 KB) — court = ca gigote
export REFRESH="${REFRESH:-0.25}"   # periode de rafraichissement (s) — court = fluide
export ARFCN="${ARFCN:-514}"        # juste pour le titre (DCS1800)
export DISPLAY="${DISPLAY:-:0}"
export FFT_SAVE=""
[ "${1:-}" = "--save" ] && export FFT_SAVE="${2:?--save needs a path}"

# garde-fous
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }
if [ "$FFT_SRC" = "fifo" ]; then
  docker exec "$CONTAINER" sh -c "[ -p '$FIFO' ] || mkfifo '$FIFO'" 2>/dev/null \
    || { echo "impossible de creer le FIFO $CONTAINER:$FIFO"; exit 1; }
  # UN SEUL lecteur : tuer les cat perimes sur ce FIFO (sinon le flux se PARTAGE
  # entre lecteurs et la FFT est hachee/figee). On lit le flux complet => ca gigote.
  docker exec "$CONTAINER" pkill -f "cat $FIFO" 2>/dev/null || true
  sleep 0.3
else
  docker exec "$CONTAINER" test -f "$CFILE" \
    || { echo "record absent $CONTAINER:$CFILE (lance ./run.sh d'abord)"; exit 1; }
fi

python3 - <<'PYEOF'
import os, sys, subprocess, numpy as np
import matplotlib
SAVE = os.environ.get("FFT_SAVE","")
if SAVE:
    matplotlib.use("Agg")
else:
    for bk in ("TkAgg","Qt5Agg","GTK3Agg"):
        try: matplotlib.use(bk); break
        except Exception: continue
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

CONT  = os.environ["CONTAINER"]; CFILE = os.environ["CFILE"]
RATE  = float(os.environ["RATE"]); NS = int(os.environ["NSAMP"])
REFRESH = float(os.environ["REFRESH"]); ARFCN = os.environ["ARFCN"]
NBYTES = NS*8                      # complex64 = 8 o/sample
NFFT  = 4096                       # resolution FFT (segment Welch)
WROWS = 120                        # lignes du waterfall

win = np.hanning(NFFT).astype(np.float32)
freqs = np.fft.fftshift(np.fft.fftfreq(NFFT, 1.0/RATE)) / 1e3   # kHz

import threading
SRC  = os.environ.get("FFT_SRC","fifo")    # fifo (LIVE, defaut) | sweep | tail
FIFO = os.environ.get("FIFO","/tmp/iq_fft.fifo")
BS   = 4096; NBLK = max(1, NBYTES//BS)

# ---- mode FIFO (LIVE) : thread qui draine le FIFO dans le docker en continu,
#      garde le dernier bloc de NBYTES => grab() rend toujours le PLUS FRAIS.
_latest = [None]; _lk = threading.Lock()
def _readexact(f, n):
    b = bytearray()
    while len(b) < n:
        c = f.read(n - len(b))
        if not c: return None
        b += c
    return bytes(b)
def _reader():
    while True:
        try:
            p = subprocess.Popen(["docker","exec",CONT,"cat",FIFO],
                                 stdout=subprocess.PIPE, bufsize=0)
        except Exception:
            return
        roll = bytearray()
        while True:
            c = p.stdout.read(1 << 16)
            if not c: break                      # writer parti -> on reouvre cat
            roll += c
            if len(roll) >= NBYTES:              # LILO : on garde la QUEUE = le PLUS FRAIS
                tail = bytes(roll[-NBYTES:])
                with _lk: _latest[0] = np.frombuffer(tail, dtype=np.complex64).copy()
                del roll[:-NBYTES]
        try: p.kill()
        except Exception: pass
if SRC == "fifo":
    threading.Thread(target=_reader, daemon=True).start()

# ---- modes fichier (fallback) : balaye le ring (sweep) ou lit le tail.
def _filesize():
    try:
        return int(subprocess.run(["docker","exec",CONT,"stat","-c","%s",CFILE],
                                  capture_output=True,timeout=5).stdout or 0)
    except Exception: return NBYTES
RING = _filesize() if SRC!="fifo" else NBYTES
_off = [0]

def grab():
    """Rend NBYTES d'I/Q complex64 (le plus frais).
    SRC=fifo  : LIVE, lit le dernier bloc draine du FIFO (defaut).
    SRC=sweep : balaye le ring record (offset qui avance).
    SRC=tail  : derniers octets (fichier en append)."""
    if SRC == "fifo":
        with _lk: return _latest[0]
    if SRC == "sweep":
        skip = _off[0] // BS
        try:
            raw = subprocess.run(["docker","exec",CONT,"dd","if="+CFILE,
                "bs="+str(BS),"skip="+str(skip),"count="+str(NBLK),"status=none"],
                capture_output=True, timeout=8).stdout
        except Exception:
            return None
        _off[0] += NBYTES
        if _off[0] + NBYTES > RING: _off[0] = 0
    else:
        try:
            raw = subprocess.run(["docker","exec",CONT,"tail","-c",str(NBYTES),CFILE],
                                 capture_output=True, timeout=8).stdout
        except Exception:
            return None
    n = (len(raw)//8)*8
    if n < NFFT*8: return None
    return np.frombuffer(raw[:n], dtype=np.complex64)

def welch_psd(iq):
    """PSD moyennee (segments NFFT, overlap 50%, fenetre Hann) en dB"""
    step = NFFT//2; nseg = max(1,(len(iq)-NFFT)//step + 1)
    acc = np.zeros(NFFT, dtype=np.float64)
    for i in range(nseg):
        seg = iq[i*step:i*step+NFFT]
        if len(seg) < NFFT: break
        sp = np.fft.fftshift(np.fft.fft(seg*win))
        acc += (sp.real**2 + sp.imag**2)
    psd = acc/max(1,nseg)
    return 10*np.log10(psd/ (NFFT*RATE) + 1e-20)

# ---- figure "jolie" ----
plt.style.use("dark_background")
fig, (axp, axw) = plt.subplots(2,1, figsize=(11,8),
                               gridspec_kw=dict(height_ratios=[1,1.4]))
fig.suptitle(f"Calypso I/Q live — {CONT}:{CFILE}  |  ARFCN={ARFCN}  Fs={RATE/1e6:.4f} MHz",
             fontsize=11, color="#7fd")
(line,) = axp.plot(freqs, np.full(NFFT,-120), lw=0.5, color="#39f")
axp.set_xlim(freqs[0],freqs[-1]); axp.set_ylim(-130,-30)
axp.set_ylabel("PSD (dB)"); axp.grid(alpha=0.25); axp.set_xlabel("offset (kHz)")
axp.axvline(0, color="#f55", lw=0.4, alpha=0.5)

wf = np.full((WROWS,NFFT), -120.0)
im = axw.imshow(wf, aspect="auto", origin="upper", cmap="turbo",
                extent=[freqs[0],freqs[-1],0,WROWS], vmin=-120, vmax=-50,
                interpolation="bilinear")
axw.set_ylabel("temps (frames)"); axw.set_xlabel("offset (kHz)")
fig.colorbar(im, ax=axw, label="dB", pad=0.01)
fig.tight_layout(rect=[0,0,1,0.96])

def update(_):
    iq = grab()
    if iq is None: return line, im
    psd = welch_psd(iq)
    line.set_ydata(psd)
    lo,hi = np.percentile(psd,5), np.percentile(psd,99.5)
    axp.set_ylim(lo-5, hi+8)
    global wf
    wf = np.roll(wf,1,axis=0); wf[0,:] = psd
    im.set_data(wf); im.set_clim(lo, hi+5)
    return line, im

if SAVE:
    update(0)                       # une passe
    fig.savefig(SAVE, dpi=110, facecolor=fig.get_facecolor())
    print("ecrit", SAVE)
else:
    ani = FuncAnimation(fig, update, interval=int(REFRESH*1000),
                        blit=False, cache_frame_data=False)
    print("FFT live — ferme la fenetre pour quitter.")
    plt.show()
PYEOF
