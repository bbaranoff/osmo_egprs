#!/usr/bin/env python3
# Bridge : grgsm_decode -v (qui DECODE le vrai SI du cfile continu) -> parse les
# lignes SI (PD=0x06) -> GSMTAP 16B + L2 -> 4730 (shunt feed_si -> DATA_IND -> mobile).
import subprocess, socket, struct, re, sys, os
GSMTAP = struct.pack(">BBBBHbbIBBBB", 2,4,0x01,0,0,0,0,0,0x01,0,0,0)  # 16B, type UM, BCCH
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
CF = sys.argv[1] if len(sys.argv)>1 else "/tmp/iq_grgsm.fifo"
p = subprocess.Popen(["grgsm_decode","-m","BCCH","-t","0","-a","514","-c",CF,"-s","1083333","-v"],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
SI={0x1b:"SI3",0x1a:"SI2",0x1c:"SI4",0x21:"SI13",0x19:"SI1",0x1d:"SI2bis",0x1e:"SI2ter",0x06:"RR"}
# Sentinelle de readiness : on ne lance le mobile QUE quand le bridge a vu
# au moins MOBILE_GATE_SCH bursts (SCH) ET MOBILE_GATE_SI SI. start-clean.sh
# attend l'apparition de READY_FILE avant de demarrer `mobile`.
READY_FILE = os.environ.get("SI_BRIDGE_READY_FILE", "/tmp/si_bridge_ready")
GATE_SI    = int(os.environ.get("MOBILE_GATE_SI",  "1"))
GATE_SCH   = int(os.environ.get("MOBILE_GATE_SCH", "1"))
try: os.remove(READY_FILE)
except OSError: pass
ready = False
def signal_ready():
    global ready
    if ready or n < GATE_SI or nsch < GATE_SCH: return
    ready = True
    try:
        with open(READY_FILE, "w") as f: f.write("%d %d\n"%(n, nsch))
    except OSError: pass
    print("[si-bridge] READY : %d SI + %d bursts -> mobile peut etre lance (%s)"
          %(n, nsch, READY_FILE), flush=True)
n=0; nsch=0
for line in p.stdout:
    # SCH REEL : le receiver gr-gsm patche imprime "SCHBSIC <bsic> <fn> <toa>" sur
    # stdout (le port measurements est avale par le CLI grgsm_decode). On le
    # forwarde au shunt en UDP 4731 {magic 'SCH1', int32 bsic, int32 fn, int32 toa}
    # -> feed_sb -> shunt_dispatch_sb (BSIC reel; TOA reel si hors CALYPSO_CANNED).
    msch = re.search(r"SCHBSIC\s+(\d+)\s+(\d+)\s+(-?\d+)", line)
    if msch:
        bsic, fn, toa = int(msch.group(1)), int(msch.group(2)), int(msch.group(3))
        s.sendto(b"SCH1" + struct.pack("<iii", bsic, fn, toa), ("127.0.0.1", 4731))
        nsch += 1
        if nsch<=10 or nsch%100==0:
            print("[si-bridge] SCH -> shunt 4731 : BSIC=%d (ncc=%d bcc=%d) FN=%d TOA=%d  #%d"
                  %(bsic,(bsic>>3)&7,bsic&7,fn,toa,nsch),flush=True)
        signal_ready()
        continue
    m = re.search(r":\s+([0-9a-fA-F][0-9a-fA-F ]+)$", line.strip())
    if not m: continue
    try: by = bytes(int(x,16) for x in m.group(1).split())
    except: continue
    if len(by) >= 3 and by[1]==0x06 and by[2] in SI:   # RR PD + SI type
        L2 = (by[:23] + b"\x2b"*23)[:23]
        s.sendto(GSMTAP + L2, ("127.0.0.1",4730))
        n+=1
        if n<=20 or n%50==0:
            print("[si-bridge] %s (mt=0x%02x) -> feed_si (4730)  #%d"%(SI[by[2]],by[2],n),flush=True)
        signal_ready()
print("[si-bridge] fini, %d SI transmis"%n,flush=True)
