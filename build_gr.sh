#!/usr/bin/env bash
set -euo pipefail
# build_gr.sh — install GNU Radio 3.10 + gr-osmosdr + gr-gsm dans un venv
# /root/.env. Basé sur le gist bbaranoff/3683811057933af0954b661821e950d1.
#
# SEULE DIVERGENCE vs le gist : gr-gsm est buildé avec -DBUILD_APPS=ON (le gist
# a OFF). Le pipeline qui CAMPE utilise le CLI `grgsm_decode` (via
# si_bridge.py) ; avec BUILD_APPS=OFF il n'est pas construit → pas de SI →
# pas de camping. ON installe donc grgsm_decode dans /root/.env/bin.

# ── 0. Nettoyage des résidus système ──
echo "=== Nettoyage ==="
rm -rf /usr/local/lib/libgnuradio-*
rm -rf /usr/local/lib/libgnuradio_*
rm -rf /usr/local/lib/libgrgsm*
rm -rf /usr/local/lib/python3*/dist-packages/gnuradio
rm -rf /usr/local/lib/python3*/dist-packages/osmosdr
rm -rf /usr/local/lib/python3*/dist-packages/grgsm
rm -rf /usr/local/include/gnuradio
rm -rf /usr/local/include/osmosdr
rm -rf /usr/local/include/gsm
rm -rf /usr/local/lib/cmake/gnuradio
rm -rf /usr/local/lib/cmake/osmosdr
rm -rf /usr/local/lib/cmake/gsm
rm -rf /usr/lib/python3*/dist-packages/gnuradio
rm -rf /usr/lib/python3*/dist-packages/osmosdr
rm -rf /usr/lib/python3*/dist-packages/grgsm
rm -rf /opt/GSM/gnuradio
rm -rf /opt/GSM/gr-osmosdr
rm -rf /opt/GSM/gr-gsm
rm -rf /root/.env
ldconfig

# ── 1. Créer le venv et installer les dépendances Python ──
echo "=== Venv ==="
python3 -m venv /root/.env
source /root/.env/bin/activate
pip install --upgrade pip wheel
pip install mako "numpy<2" pyyaml click click-plugins zmq scipy pybind11 jinja2 six pyqt5

# ── 2. Variables d'environnement ──
export PREFIX=/root/.env
export PYBIN=$PREFIX/bin/python3
PYVER=$($PYBIN -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
export PY_SITE=$PREFIX/lib/python${PYVER}/site-packages

export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}
export PYTHONPATH=$PY_SITE:${PYTHONPATH:-}
export CMAKE_PREFIX_PATH=$PREFIX
export LDFLAGS="-L$PREFIX/lib"

mkdir -p /opt/GSM
cd /opt/GSM

# ── 3. Build GNU Radio ──
echo "=== GNU Radio ==="
git clone --recursive --branch maint-3.10 https://github.com/gnuradio/gnuradio.git
cd gnuradio
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DENABLE_GRC=OFF \
    -DENABLE_DEFAULT=ON \
    -DENABLE_TESTING=OFF \
    -DENABLE_DOXYGEN=OFF \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib
cmake --build build -j$(nproc)
cmake --install build

echo "$PREFIX/lib" > /etc/ld.so.conf.d/gnuradio.conf
ldconfig

$PYBIN -c "from gnuradio import gr, blocks, digital, filter; print('GR', gr.version())"
cd /opt/GSM

# ── 4. Build gr-osmosdr ──
echo "=== gr-osmosdr ==="
git clone https://gitea.osmocom.org/sdr/gr-osmosdr
cd gr-osmosdr
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib
cmake --build build -j$(nproc)
cmake --install build
ldconfig
cd /opt/GSM

# ── 5. Build gr-gsm ──
echo "=== gr-gsm ==="
git clone https://github.com/bkerler/gr-gsm
cd gr-gsm
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DENABLE_PYTHON=ON \
    -DPYTHON_EXECUTABLE=$PYBIN \
    -DGR_PYTHON_DIR=$PY_SITE \
    -DCMAKE_INSTALL_RPATH=$PREFIX/lib \
    -DBUILD_APPS=ON          # <-- ON (gist=OFF) : on a besoin du CLI grgsm_decode
cmake --build build -j$(nproc)
cmake --install build
ldconfig

# Fix pybind11 : gr::block doit être chargé avant gr-gsm
sed -i '1i from gnuradio import gr' $PY_SITE/gnuradio/gsm/__init__.py

cd /opt/GSM

# ── 6. Vérifications finales ──
echo "=== Vérifications ==="
$PYBIN -c "from gnuradio import gr; print('GNU Radio', gr.version())"
$PYBIN -c "import osmosdr; print('osmosdr OK')"
$PYBIN -c "from gnuradio import gsm; print('gr-gsm OK')"
command -v grgsm_decode >/dev/null && echo "grgsm_decode OK ($(command -v grgsm_decode))" \
    || echo "!! grgsm_decode ABSENT — BUILD_APPS a-t-il bien ete pris ?"

# Vérif que tout linke dans le venv
echo "=== Vérif linking ==="
ldd $PY_SITE/gnuradio/gsm/gsm_python*.so 2>/dev/null | grep gnuradio || true
ldd $PY_SITE/osmosdr/osmosdr_python*.so 2>/dev/null | grep gnuradio || true
