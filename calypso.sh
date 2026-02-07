#!/usr/bin/env bash
set -e

BASE=~/trx/src
ELF=$BASE/target/firmware/board/compal_e88/trx.highram.elf
BIN=$BASE/target/firmware/board/compal_e88/hello_world.compalram.bin
SERIAL=/tmp/serial1

sudo pkill socat 2>/dev/null || true
sudo pkill qemu-system-arm 2>/dev/null || true

echo "[*] starting QEMU"

sudo qemu-system-arm \
  -M calypso-high \
  -cpu arm946 \
  -kernel $ELF \
  -serial pty \
  -nographic \
  -s -S \
| sudo tee /tmp/qemu.log &

sleep 2

PTY=$(grep -o '/dev/pts/[0-9]*' /tmp/qemu.log | head -n1)
echo "[+] QEMU PTY = $PTY"

sudo socat \
  open:$PTY,raw,echo=0 \
  pty,raw,echo=0,link=$SERIAL &

sleep 1
ls -l $SERIAL

echo "[*] unfreezing ARM via gdbstub"

echo "continue" | nc localhost 1234 >/dev/null 2>&1 || true

sleep 1

echo "[*] running osmocon"

cd $BASE
sudo ./osmocon/osmocon -v \
  -p $SERIAL \
  -m c123xor \
  $BIN
