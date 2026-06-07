#!/usr/bin/env bash
# fft2.sh — FFT du 2e cfile. Reutilise fft.sh avec un autre CFILE.
#
# fft.sh  = dsp_iq.cfile = MS  (entree DSP Calypso : le mobile qui repond a la BTS)
# fft2.sh = record.cfile = BTS (ce que la BTS emet)
# -> MEME signal aux deux bouts de la chaine (BTS TX <-> MS RX) ; la difference
#    entre les deux spectres = ce que la chaine (shunt/gr-gsm) fait au signal.
#
# Usage : ./fft2.sh            (defaut CFILE=/dev/shm/record.cfile)
#         CFILE=... ./fft2.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CFILE="${CFILE:-/dev/shm/record.cfile}"
export ARFCN="${ARFCN:-BTS-record}"
exec bash "$HERE/fft.sh" "$@"
