#!/usr/bin/env python3
# cp210x_tee.py — tee bidirectionnel du lien série CP210x du Calypso.
#
# Le firmware Calypso (qemu) expose un PTY série (= le câble USB-série CP210x,
# le "jack"). osmocon ET trxcon doivent y accéder. Un PTY série ne se lit qu'à
# un consommateur ; socat est point-à-point. Ce relai fait le tee 3-voies :
#
#   qemu CP210x (PTY)  ──>  /tmp/cp210x_osmocon   (osmocon : romload + L1CTL)
#                      ──>  /tmp/cp210x_trxcon    (trxcon)
#   /tmp/cp210x_osmocon ──┐
#   /tmp/cp210x_trxcon  ──┴─>  qemu CP210x        (writes mergés vers le fw)
#
# Usage : cp210x_tee.py /dev/pts/N   (le PTY série0 de qemu = $PTY_MODEM)
import os, sys, select, termios, tty

if len(sys.argv) < 2:
    sys.stderr.write("usage: cp210x_tee.py <qemu_serial_pty>\n"); sys.exit(1)

qemu_pty = sys.argv[1]
LINK_OSMOCON = os.environ.get("CP210X_OSMOCON", "/tmp/cp210x_osmocon")
LINK_TRXCON  = os.environ.get("CP210X_TRXCON",  "/tmp/cp210x_trxcon")

def make_raw(fd):
    try:
        a = termios.tcgetattr(fd)
        tty.setraw(fd)
    except Exception:
        pass

qfd = os.open(qemu_pty, os.O_RDWR | os.O_NOCTTY)
make_raw(qfd)

# Deux PTY consommateurs, exposés via symlink stable.
m_o, s_o = os.openpty(); make_raw(s_o); make_raw(m_o)
m_t, s_t = os.openpty(); make_raw(s_t); make_raw(m_t)
for link, slave in ((LINK_OSMOCON, s_o), (LINK_TRXCON, s_t)):
    try: os.remove(link)
    except OSError: pass
    os.symlink(os.ttyname(slave), link)

sys.stderr.write("[cp210x-tee] %s -> {%s, %s} (tee bidirectionnel)\n"
                 % (qemu_pty, LINK_OSMOCON, LINK_TRXCON))
sys.stderr.flush()

consumers = [m_o, m_t]
fds = [qfd] + consumers
while True:
    try:
        r, _, _ = select.select(fds, [], [], 1.0)
    except (InterruptedError, OSError):
        continue
    for fd in r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            continue
        if fd == qfd:
            # firmware → les deux consommateurs (broadcast DL)
            for c in consumers:
                try: os.write(c, data)
                except OSError: pass
        else:
            # osmocon/trxcon → firmware (mergé)
            try: os.write(qfd, data)
            except OSError: pass
