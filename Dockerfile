FROM ubuntu:22.04 AS osmocom-nitb

ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM
ENV container=docker
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# 1. Dépendances système complètes (Infrastructure + Osmocom-BB)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Outils de build
    build-essential git gcc g++ make cmake autoconf automake libtool pkg-config wget curl \
    # Dépendances Osmocom Core & Network
    libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev liburing-dev asterisk-moh* \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev sqlite3 libc-ares-dev libgnutls28-dev \
    # Audio, Radio & SIP
    libortp-dev libfftw3-dev libusb-1.0-0-dev libsofia-sip-ua-dev libsofia-sip-ua-glib-dev \
    # Python & Outils système
    python3 python3-dev python3-scapy ca-certificates tmux systemd systemd-sysv \
    # ALSA — requis par osmo-gapk pour l'I/O audio matériel
    libasound2-dev libasound2 alsa-utils \
    # libgsm — codec GSM-FR natif (accélère gapk en mode gsmfr)
    libgsm1-dev libgsm1 \
    iptables iproute2 asterisk ffmpeg

SHELL ["/bin/bash", "-c"]
COPY configs/*conf /etc/asterisk/

WORKDIR ${ROOT}

# 2. Création de l'utilisateur osmocom
RUN groupadd osmocom && useradd -r -g osmocom -s /sbin/nologin -d /var/lib/osmocom osmocom && \
    mkdir -p /var/lib/osmocom && chown osmocom:osmocom /var/lib/osmocom

# 3. Compilation de la pile Osmocom (Ordre respecté)
RUN for repo in \
    libosmocore:1.12.1 \
    libosmo-netif:1.7.0 \
    libosmo-abis:2.1.0 \
    libosmo-sigtran:2.2.1 \
    libsmpp34:1.14.5 \
    libgtpnl:1.3.3 \
    osmo-hlr:1.9.2 \
    osmo-mgw:1.15.0 \
    osmo-ggsn:1.14.0 \
    osmo-sgsn:1.13.1 \
    osmo-msc:1.15.0 \
    osmo-bsc:1.14.0 \
    osmo-pcu:1.5.2 \
    osmo-bts:1.10.0 \
    osmo-sip-connector:1.7.2 \
    libosmo-gprs:0.2.1; \
    do \
    name=$(echo $repo | cut -d: -f1) && \
    version=$(echo $repo | cut -d: -f2) && \
    \
    if [ "$name" = "libosmocore" ]; then \
        GIT_URL="https://github.com/osmocom/$name"; \
    elif [[ "$name" =~ "libosmo" ]]; then \
        GIT_URL="https://gitea.osmocom.org/osmocom/$name"; \
    else \
        GIT_URL="https://gitea.osmocom.org/cellular-infrastructure/$name"; \
    fi && \
    \
    cd ${ROOT} && \
    git clone "$GIT_URL" && cd "$name" && \
    git checkout "$version" && \
    \
    autoreconf -fi && \
    EXTRA_FLAGS="" && \
    if [ "$name" = "libosmo-abis" ]; then EXTRA_FLAGS="--disable-dahdi"; fi && \
    if [ "$name" = "osmo-msc" ]; then EXTRA_FLAGS="--enable-smpp"; fi && \
    if [ "$name" = "osmo-mgw" ]; then EXTRA_FLAGS="--enable-alsa"; fi && \
    if [ "$name" = "osmo-bts" ]; then EXTRA_FLAGS="--enable-virtual --enable-trx"; fi && \
    if [ "$name" = "osmo-ggsn" ]; then EXTRA_FLAGS="--enable-gtp-linux"; fi && \
    \
    ./configure $EXTRA_FLAGS && \
    make -j$(nproc) && \
    make install && \
    ldconfig; \
    done

RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/osmocom/gapk osmo-gapk && \
    cd osmo-gapk && \
    autoreconf -fi && \
    ./configure --enable-alsa && \
    make -j$(nproc) && \
    make install && \
    ldconfig

    
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
    cd osmocom-bb/src && \
    # nofirmware désactive la compilation des firmwares .bin pour les téléphones
    make nofirmware -j$(nproc)

# ── gsup-smsc-proto : SMSC externe connecté à OsmoHLR via GSUP ────────────────
# Programmes : proto-smsc-daemon (réception MO SMS + relai MT via GSUP)
#              proto-smsc-sendmt (injection MT SMS via socket UNIX local)
# Dépendances build : libosmocore, libosmogsm, libosmo-gsup-client
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/themwi/gsup-smsc-proto && \
    cd gsup-smsc-proto && \
    ./configure --with-osmo=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# ── sms-coding-utils : encodage/décodage SMS PDU (GSM 03.40) ──────────────────
# sms-encode-text, gen-sms-deliver-pdu, sms-pdu-decode, etc.
RUN cd ${ROOT} && \
    wget -q https://www.freecalypso.org/pub/GSM/FreeCalypso/sms-coding-utils-latest.tar.bz2 && \
    tar xf sms-coding-utils-latest.tar.bz2 && \
    cd sms-coding-utils-r1 && \
    ./configure && \
    make -j$(nproc) && \
    make install INSTDIR=/usr/local/bin

# 4. Installation des fichiers du projet
WORKDIR /etc/osmocom
COPY scripts/. /etc/osmocom/
COPY configs/*cfg /etc/osmocom/
RUN mv /etc/osmocom/run.sh /root/run.sh
# Copie des binaires vers /usr/bin pour systemd et installation des .service
COPY scripts/gapk-start.sh /etc/osmocom/gapk-start.sh
RUN chmod +x /etc/osmocom/gapk-start.sh && \
    ln -sf /etc/osmocom/gapk-start.sh /usr/local/bin/gapk-start.sh && \
    mkdir -p /var/lib/gapk

RUN cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    cp -f /usr/local/bin/proto-smsc-* /usr/bin/ || true && \
    cp -f /usr/local/bin/sms-* /usr/bin/ || true && \
    cp -f /usr/local/bin/gen-sms-* /usr/bin/ || true && \
    # Si tu as des fichiers .service dans configs/
    cp /etc/osmocom/configs/*.service /lib/systemd/system/ 2>/dev/null || true

# 5. Fix Permissions & Systemd (Status 214/217)
RUN sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service && \
    chmod +x /etc/osmocom/*.sh

# Activation du service et nettoyage
RUN systemctl enable osmo-bts-trx.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Point d'entrée pour systemd
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
RUN mkdir -p /root/.osmocom/bb/
RUN cp /opt/GSM/osmocom-bb/src/host/trxcon/src/trxcon /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/layer23/src/mobile/mobile /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/virt_phy/src/virtphy /usr/local/bin
RUN echo "alias faketrx='python3 /opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py'" >> ~/.bashrc && source ~/.bashrc
COPY configs/mobile.cfg /root/.osmocom/bb/mobile.cfg
RUN chmod +x /root/run.sh

# Répertoires pour le proto-SMSC
RUN mkdir -p /var/log/osmocom /var/run/smsc

# ── QEMU Calypso (bbaranoff/qemu) ───────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv libglib2.0-dev libpixman-1-dev libslirp-dev socat \
    && rm -rf /var/lib/apt/lists/*

RUN cd /opt/GSM && git clone https://github.com/bbaranoff/qemu.git /opt/GSM/qemu-src \
    && cd /opt/GSM/qemu-src \
    && python3 -m venv /root/.env \
    && . /root/.env/bin/activate \
    && pip install ninja tomli \
    && mkdir build && cd build \
    && ../configure --target-list=arm-softmmu --prefix=/opt/GSM/qemu-install \
    && make -j$(nproc) \
    && make install \
    && cp /opt/GSM/qemu-install/bin/qemu-system-arm /usr/local/bin/qemu-system-arm

RUN mkdir -p /opt/GSM/qemu/build \
    && cp /opt/GSM/qemu-src/*.py /opt/GSM/qemu/ 2>/dev/null || true \
    && ln -sf /usr/local/bin/qemu-system-arm /opt/GSM/qemu/build/qemu-system-arm

# ── GCC 9/11 alternatives ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-9 g++-9 gcc-11 g++-11 \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-9 \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 \
       --slave /usr/bin/g++ g++ /usr/bin/g++-11

# ── libosmodsp (dépendance osmocom-bb transceiver/burst_ind) ─────────────────
RUN cd /opt/GSM \
    && git clone https://gitea.osmocom.org/sdr/libosmo-dsp.git \
    && cd libosmo-dsp \
    && autoreconf -fi \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && ldconfig

# ── Switch to gcc-9 for osmocom-bb transceiver ──────────────────────────────
RUN update-alternatives --set gcc /usr/bin/gcc-9

# ── osmocom-bb jolly/testing → transceiver ──────────────────────────────────
RUN git clone --branch jolly/testing --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/osmocom-bb-transceiver \
    && cd /opt/GSM/osmocom-bb-transceiver/src \
    && make HOST_layer23_CONFARGS=--enable-transceiver nofirmware -j$(nproc) \
    && cp /opt/GSM/osmocom-bb-transceiver/src/host/layer23/src/transceiver/transceiver \
       /usr/local/bin/transceiver

RUN git clone --branch fixeria/burst_ind --depth 1 \
        https://gitea.osmocom.org/phone-side/osmocom-bb.git \
        /opt/GSM/burst_ind \
    && cd /opt/GSM/burst_ind/src \
    && make nofirmware -j$(nproc) \
    && cp /opt/GSM/burst_ind/src/host/layer23/src/misc/ccch_scan \
       /usr/local/bin/ccch_scan \
    && cp /opt/GSM/burst_ind/src/host/layer23/src/misc/bcch_scan \
       /usr/local/bin/bcch_scan \
    && cp /opt/GSM/burst_ind/src/host/layer23/src/misc/cell_log \
       /usr/local/bin/cell_log

# ── Switch back to gcc-11 ────────────────────────────────────────────────────
RUN update-alternatives --set gcc /usr/bin/gcc-11

# ── Firmware Calypso ─────────────────────────────────────────────────────────
COPY firmware/board/ /opt/GSM/firmware/board/

CMD ["/bin/bash"]
