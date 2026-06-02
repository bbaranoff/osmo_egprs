#!/usr/bin/env bash
set -euo pipefail

# ── 0. Nettoyage des résidus système ──
echo "=== Nettoyage ==="
rm -rf /usr/local/lib/libgnuradio-*
rm -rf /usr/local/lib/libgnuradio_*
rm -rf /usr/local/lib/libosmo*
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
pip install mako "numpy<2" pyyaml click click-plugins zmq scipy pybind11 jinja2

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
    -DBUILD_APPS=OFF
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

# Vérif que tout linke dans le venv
echo "=== Vérif linking ==="
ldd $PY_SITE/gnuradio/gsm/gsm_python*.so 2>/dev/null | grep gnuradio || true
ldd $PY_SITE/osmosdr/osmosdr_python*.so 2>/dev/null | grep gnuradio || true

echo "=== Terminé ==="
