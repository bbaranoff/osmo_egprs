#!/usr/bin/env python3
# fft_web.py — 2 FFT (MS + BTS) sur UNE page, serveur web autonome (port 8081).
#
# Reprend la logique de fft.sh / fft2.sh (PSD Welch sur le cfile I/Q fc32) mais :
#   - NATIF : lit directement les cfiles de l'hôte (/dev/shm/*.cfile), pas de docker exec.
#   - HEADLESS : pas de matplotlib/X. numpy calcule la PSD → JSON → le navigateur dessine (canvas).
#   - fft.sh  = dsp_iq.cfile = MS (entrée DSP Calypso)
#     fft2.sh = record.cfile = BTS (ce que la BTS émet)  -> les deux spectres sur la même page.
#
# Lancement :  python3 /opt/GSM/osmo_egprs/fft-web/fft_web.py
#   FFT_WEB_PORT=8081 RATE=1083333 NSAMP=262144 NFFT=4096 ...  (overridables par env)
import os, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import numpy as np

PORT  = int(os.environ.get('FFT_WEB_PORT', '8081'))
RATE  = float(os.environ.get('RATE', '1083333'))   # 4 SPS natif = 26e6/24
NSAMP = int(os.environ.get('NSAMP', '262144'))     # complex samples lus en tail
NFFT  = int(os.environ.get('NFFT', '4096'))        # résolution FFT (segment Welch)

SRC = {
    'ms':  {'path': os.environ.get('CFILE_MS',  '/dev/shm/dsp_iq.cfile'),
            'arfcn': os.environ.get('ARFCN_MS', '514'),  'label': 'MS — Calypso DSP (dsp_iq.cfile)'},
    'bts': {'path': os.environ.get('CFILE_BTS', '/dev/shm/record.cfile'),
            'arfcn': os.environ.get('ARFCN_BTS', '514'), 'label': 'BTS — record (record.cfile)'},
}

def read_tail_iq(path, nsamp):
    sz = os.path.getsize(path)
    nbytes = min(sz - (sz % 8), nsamp * 8)         # complex64 = 8 octets/échantillon
    with open(path, 'rb') as f:
        if sz > nbytes:
            f.seek(sz - nbytes)
        raw = f.read(nbytes)
    return np.frombuffer(raw, dtype=np.complex64)

def welch_psd(iq, nfft, rate):
    if iq.size < nfft:
        return None, None
    win = np.hanning(nfft).astype(np.float32)
    nseg = iq.size // nfft
    acc = np.zeros(nfft, dtype=np.float64)
    for i in range(nseg):
        seg = iq[i*nfft:(i+1)*nfft] * win
        acc += np.abs(np.fft.fftshift(np.fft.fft(seg)))**2
    acc /= nseg
    psd_db = 10.0*np.log10(acc + 1e-12)
    freqs = np.fft.fftshift(np.fft.fftfreq(nfft, 1.0/rate)) / 1e3   # kHz
    return freqs, psd_db

def psd_json(src):
    s = SRC[src]
    try:
        iq = read_tail_iq(s['path'], NSAMP)
        f, p = welch_psd(iq, NFFT, RATE)
        if f is None:
            return {'error': 'pas assez d\'échantillons', 'label': s['label']}
        step = max(1, len(f)//1024)                # sous-échantillonne pour le transport
        return {'label': s['label'], 'arfcn': s['arfcn'], 'rate': RATE,
                'freqs': [round(x, 1) for x in f[::step].tolist()],
                'psd':   [round(x, 2) for x in p[::step].tolist()]}
    except FileNotFoundError:
        return {'error': 'cfile absent (%s) — lance la stack' % s['path'], 'label': s['label']}
    except Exception as e:
        return {'error': str(e), 'label': s['label']}

PAGE = """<!doctype html><html><head><meta charset=utf-8><title>Calypso FFT — MS & BTS</title>
<style>body{background:#0b0f14;color:#cdd6e0;font-family:monospace;margin:0;padding:12px}
h1{font-size:15px;color:#2aa198;margin:0 0 10px} .row{display:flex;gap:12px;flex-wrap:wrap}
.card{flex:1;min-width:380px;background:#0e151c;border:1px solid #1d2a33;border-radius:8px;padding:8px}
.t{font-size:12px;color:#b58900;margin-bottom:4px} canvas{width:100%;background:#060a0e;border-radius:4px;display:block}
.psd{height:200px} .wf{height:150px;margin-top:6px;image-rendering:pixelated}
.err{color:#dc322f;font-size:12px;min-height:14px}</style></head><body>
<h1>\U0001F4E1 Calypso I/Q FFT — MS vs BTS <span id=st style="color:#586e75;font-size:11px"></span></h1>
<div class=row>
 <div class=card><div class=t id=t-ms>MS</div><canvas id=c-ms class=psd></canvas><canvas id=w-ms class=wf></canvas><div class=err id=e-ms></div></div>
 <div class=card><div class=t id=t-bts>BTS</div><canvas id=c-bts class=psd></canvas><canvas id=w-bts class=wf></canvas><div class=err id=e-bts></div></div>
</div>
<script>
function draw(cid,d){var c=document.getElementById(cid),x=c.getContext('2d');
 var W=c.width=c.clientWidth*2,H=c.height=c.clientHeight*2;x.clearRect(0,0,W,H);
 var e=document.getElementById(cid.replace('c-','e-')),tt=document.getElementById(cid.replace('c-','t-'));
 if(d.error){e.textContent=d.error;tt.textContent=d.label||'';return;} e.textContent='';
 tt.textContent=d.label+'  •  ARFCN '+d.arfcn+'  •  Fs '+(d.rate/1e6).toFixed(3)+' MHz';
 var p=d.psd,n=p.length;if(!n)return;var mn=Math.min.apply(null,p),mx=Math.max.apply(null,p),rg=(mx-mn)||1;
 x.strokeStyle='#16222b';x.lineWidth=1;for(var g=0;g<=4;g++){var yy=H*g/4;x.beginPath();x.moveTo(0,yy);x.lineTo(W,yy);x.stroke();}
 x.beginPath();x.moveTo(W/2,0);x.lineTo(W/2,H);x.strokeStyle='#243845';x.stroke();
 x.strokeStyle='#2aa198';x.lineWidth=2;x.beginPath();
 for(var i=0;i<n;i++){var xx=W*i/(n-1),yy=H-(p[i]-mn)/rg*H*0.9-H*0.05;i?x.lineTo(xx,yy):x.moveTo(xx,yy);}
 x.stroke();}
function tick(){['ms','bts'].forEach(function(s){
  fetch('/psd?src='+s+'&t='+Date.now()).then(function(r){return r.json();}).then(function(d){draw('c-'+s,d);}).catch(function(){});});
 document.getElementById('st').textContent='— '+new Date().toLocaleTimeString();}
tick();setInterval(tick,1000);
</script></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == '/psd':
            q = parse_qs(u.query); src = q.get('src', ['ms'])[0]
            if src not in SRC:
                src = 'ms'
            body = json.dumps(psd_json(src)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        body = PAGE.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)

if __name__ == '__main__':
    print('FFT web on :%d  MS=%s  BTS=%s' % (PORT, SRC['ms']['path'], SRC['bts']['path']))
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
