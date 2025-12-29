FROM ubuntu:22.04

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
    libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev liburing-dev \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev sqlite3 libc-ares-dev libgnutls28-dev \
    # Audio, Radio & SIP
    libortp-dev libfftw3-dev libusb-1.0-0-dev libsofia-sip-ua-dev libsofia-sip-ua-glib-dev \
    # Python & Outils système
    python3 python3-dev python3-scapy ca-certificates tmux systemd systemd-sysv \
    iptables iproute2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

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
    if [ "$name" = "osmo-bts" ]; then EXTRA_FLAGS="--enable-virtual"; fi && \
    if [ "$name" = "osmo-ggsn" ]; then EXTRA_FLAGS="--enable-gtp-linux"; fi && \
    \
    ./configure $EXTRA_FLAGS && \
    make -j$(nproc) && \
    make install && \
    ldconfig; \
    done
    
RUN cd ${ROOT} && \
    git clone https://gitea.osmocom.org/phone-side/osmocom-bb && \
    cd osmocom-bb/src && \
    # nofirmware désactive la compilation des firmwares .bin pour les téléphones
    make nofirmware -j$(nproc)
# 4. Installation des fichiers du projet
WORKDIR /etc/osmocom
COPY scripts/. /etc/osmocom/
COPY configs/. /etc/osmocom/

# Copie des binaires vers /usr/bin pour systemd et installation des .service
RUN cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    # Si tu as des fichiers .service dans configs/
    cp /etc/osmocom/configs/*.service /lib/systemd/system/ 2>/dev/null || true

# 5. Fix Permissions & Systemd (Status 214/217)
RUN sed -i 's/^CPUScheduling/#CPUScheduling/g' /lib/systemd/system/osmo-*.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-ggsn.service && \
    sed -i 's/User=osmocom/User=root/g' /lib/systemd/system/osmo-sgsn.service && \
    chmod +x /etc/osmocom/*.sh

# 6. Configuration de osmo-bts.service
RUN cat <<EOF > /lib/systemd/system/osmo-bts.service
[Unit]
Description=Osmocom GSM Base Transceiver Station (BTS)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
# Utilisation de root pour éviter les problèmes de permissions sur les interfaces réseau/SDR
User=root
Group=root

# On utilise le binaire compilé avec l'option virtual (osmo-bts-virtual) 
# ou le binaire standard (osmo-bts-trx) selon ta config.
# -c pointe vers ton dossier de configuration défini en section 4
ExecStart=/usr/bin/osmo-bts-virtual -c /etc/osmocom/osmo-bts.cfg

Restart=always
RestartSec=5

# Désactivation des options qui causent des erreurs en Docker (Status 214/217)
# On commente les politiques de scheduling temps réel non supportées par le kernel Docker par défaut
# CPUSchedulingPolicy=rr
# CPUSchedulingPriority=1

[Install]
WantedBy=multi-user.target
EOF

# Activation du service et nettoyage
RUN systemctl enable osmo-bts.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Point d'entrée pour systemd
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
RUN mkdir -p /root/.osmocom/bb/
RUN cp /opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/trxcon/src/trxcon /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/layer23/src/mobile/mobile /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/virt_phy/src/virtphy /usr/local/bin
RUN cp /opt/GSM/osmocom-bb/src/host/layer23/src/misc/ccch_scan /usr/local/bin

COPY configs/mobile.cfg /root/.osmocom/bb/mobile.cfg
CMD ["systemctl start osmo-sip-connector && /bin/bash"]
