#!/usr/bin/env python3
"""
iq_fft_live.py — pop-up FFT temps réel de l'I/Q du BTS (tee BSP qemu).

Lit les bursts I/Q forwardés par le tee BSP (UDP, CALYPSO_IQ_TEE_PORT, défaut
6703 : 8 octets TRXD hdr + 148 paires cs16 LE), et affiche en direct :
  - le SPECTRE (FFT, magnitude dB, axe en kHz autour de fs=270.833 kHz)
  - la CONSTELLATION dérotée (-pi/2 par sample → BPSK si GMSK propre)
  - le module temporel (rampe de puissance du burst)

⚠️ Ce script tourne SUR L'HÔTE (X natif :0, matplotlib+tkinter présents).
Le tee BSP (gaté shunt-only, dans le conteneur réseau gsm-inter) doit viser
l'hôte via la gateway 172.20.0.1 — d'où CALYPSO_IQ_TEE_HOST.

Recette :
  # conteneur — shunt-ipc, bridge coupé (libère 6703), tee → hôte :
  docker exec -e CALYPSO_MODE=shunt-ipc -e CALYPSO_SKIP_DEMOD_BRIDGE=1 \
    -e CALYPSO_IQ_TEE_HOST=172.20.0.1 osmo-operator-1 /opt/GSM/qemu-src/run.sh
  # hôte — le pop-up FFT (pas de X dans docker) :
  python3 iq_fft_live.py

Env : IQ_FFT_PORT (défaut = CALYPSO_IQ_TEE_PORT ou 6703)
      FS_HZ (défaut 270833 = débit symbole GSM, 1 SPS)
"""
import os, socket, struct
import numpy as np
import matplotlib
matplotlib.use("TkAgg")           # backend pop-up ; fallback Qt5Agg si absent
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

PORT  = int(os.environ.get("IQ_FFT_PORT",
            os.environ.get("CALYPSO_IQ_TEE_PORT", "6703")))
FS    = float(os.environ.get("FS_HZ", "270833"))
NB    = 148                        # samples I/Q par burst
HDR   = 8                          # TRXD header

rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
rx.bind(("0.0.0.0", PORT))
rx.setblocking(False)

# état partagé
state = {"iq": np.zeros(NB, np.complex64), "fn": 0, "n": 0,
         "acc": np.zeros(NB, np.complex64)}   # acc = moyenne glissante du module spectre

def drain():
    """Vide la socket, garde le dernier burst valide."""
    last = None
    while True:
        try:
            pkt, _ = rx.recvfrom(8192)
        except BlockingIOError:
            break
        if len(pkt) >= HDR + NB * 4:
            last = pkt
    if last is None:
        return False
    fn  = struct.unpack(">I", last[1:5])[0]
    raw = np.frombuffer(last[HDR:HDR + NB * 4], dtype="<i2").astype(np.float32)
    state["iq"] = raw[0::2] + 1j * raw[1::2]
    state["fn"] = fn
    state["n"] += 1
    return True

# --- figure ---
fig, (axS, axC, axT) = plt.subplots(1, 3, figsize=(15, 4.5))
fig.suptitle(f"I/Q live BTS (tee udp:{PORT}, fs={FS/1e3:.1f} kHz)  —  ferme la fenêtre pour quitter")

freqs = np.fft.fftshift(np.fft.fftfreq(NB, d=1.0 / FS)) / 1e3   # kHz
(lineS,) = axS.plot(freqs, np.zeros(NB), lw=1.2)
axS.set_title("Spectre FFT"); axS.set_xlabel("kHz"); axS.set_ylabel("dB")
axS.set_ylim(-10, 90); axS.grid(True, alpha=0.3)

scatC = axC.scatter([], [], s=8, alpha=0.5)
axC.set_title("Constellation dérotée (-π/2)"); axC.set_xlabel("I"); axC.set_ylabel("Q")
axC.set_xlim(-1.4, 1.4); axC.set_ylim(-1.4, 1.4); axC.grid(True, alpha=0.3)
axC.set_aspect("equal")

(lineT,) = axT.plot(np.arange(NB), np.zeros(NB), lw=1.0)
axT.set_title("|I/Q| temporel (rampe burst)"); axT.set_xlabel("sample"); axT.set_ylabel("|s|")
axT.set_ylim(0, 35000); axT.grid(True, alpha=0.3)

EMA = 0.3   # lissage spectre

def update(_):
    if not drain():
        return lineS, scatC, lineT
    s = state["iq"]
    # spectre (dB), lissé EMA
    mag = 20 * np.log10(np.abs(np.fft.fftshift(np.fft.fft(s))) + 1e-3)
    state["acc"] = (1 - EMA) * state["acc"].real + EMA * mag if state["n"] > 1 else mag
    lineS.set_ydata(state["acc"].real)
    # constellation dérotée + normalisée
    k = np.arange(NB)
    y = s * np.exp(-1j * np.pi / 2 * k)
    amp = np.abs(y).max() + 1e-6
    y = y / amp
    scatC.set_offsets(np.column_stack([y.real, y.imag]))
    # temporel
    lineT.set_ydata(np.abs(s))
    axS.set_title(f"Spectre FFT  (fn={state['fn']}, #{state['n']})")
    return lineS, scatC, lineT

ani = FuncAnimation(fig, update, interval=50, blit=False, cache_frame_data=False)
print(f"[fft] écoute udp:{PORT} — pop-up matplotlib (DISPLAY={os.environ.get('DISPLAY','?')})",
      flush=True)
plt.tight_layout()
plt.show()
