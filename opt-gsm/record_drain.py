#!/usr/bin/env python3
# record_drain.py — draine le FIFO live iq_record.fifo -> record.cfile en RING
# (128 MB, fseek wrap), HORS du hot-path qemu. C'est l'EXTERNALISATION du ring
# cfile que qemu ecrivait avant dans son hot-path DL (= ce qui causait les
# underruns). Ici qemu ne fait qu'un write() non-bloquant vers le FIFO ; ce
# process (independant) absorbe le flux et l'ecrit sur disque a son rythme.
# grgsm_decode -c relit record.cfile offline comme avant => SI preserve.
#
# Ouverture du FIFO en O_RDWR : ne bloque pas a l'ouverture ET ne voit jamais
# d'EOF (on garde nous-memes un write-end), donc qemu (O_WRONLY|O_NONBLOCK)
# trouve toujours un lecteur => son open reussit et le flux coule.
#
# FRAICHEUR (fix freeze FFT) : le ring rembobine en seek(0), donc la tete
# d'ecriture `w` est au MILIEU du fichier, pas a la fin -> un lecteur qui fait
# `tail -c` voit du frais une seule fois par cycle (~15s) = FIGE. On PUBLIE donc
# l'offset d'ecriture courant dans <record.cfile>.off (+ la taille du ring dans
# <record.cfile>.ring) pour que la FFT lise la fenetre fraiche finissant a `w`.
import os, sys

FIFO = os.environ.get("CALYPSO_RECORD_FIFO", "/tmp/iq_record.fifo")
OUT  = os.environ.get("CALYPSO_RECORD_FILE", "/tmp/record.cfile")
RING = int(os.environ.get("CALYPSO_RECORD_RING", str(128 << 20)))   # 128 MB
OFF  = OUT + ".off"      # offset d'ecriture courant (octets, ascii)
RNG  = OUT + ".ring"     # taille du ring (octets, ascii) -> modulo pour la FFT

if not os.path.exists(FIFO):
    os.mkfifo(FIFO, 0o666)

fd = os.open(FIFO, os.O_RDWR)            # O_RDWR : pas de blocage / pas d'EOF
out = open(OUT, "wb", buffering=1 << 20)
w = 0
with open(RNG, "w") as f: f.write(str(RING))
sys.stderr.write("[record-drain] %s -> %s (ring %d MB, offset -> %s)\n"
                 % (FIFO, OUT, RING >> 20, OFF))
sys.stderr.flush()
_pub = 0
while True:
    b = os.read(fd, 1 << 16)            # 64 KB
    if not b:
        continue
    out.write(b)
    w += len(b)
    if w >= RING:                        # RING : rembobine (grgsm relit depuis 0)
        out.seek(0); w = 0
    out.flush()
    # publie l'offset frais (throttle ~ tous les 256 KB pour limiter les writes)
    _pub += len(b)
    if _pub >= (1 << 18):
        _pub = 0
        try:
            with open(OFF, "w") as f: f.write(str(w))
        except OSError:
            pass
