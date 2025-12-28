FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM
ENV container=docker
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# 1. Dépendances système
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 libpython3-dev liburing-dev ca-certificates git gcc g++ make cmake \
    autoconf automake libtool pkg-config wget curl tmux systemd systemd-sysv \
    iptables iproute2 libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev libc-ares-dev libgnutls28-dev \
    libortp-dev libfftw3-dev libusb-1.0-0-dev sqlite3 \
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
    osmo-bts:1.10.0; \
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

# 6. Configuration de l'Auto-Start au boot du conteneur
RUN cat <<EOF > /lib/systemd/system/osmo-autostart.service
[Unit]
Description=Lancement auto de la pile Osmocom
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/osmocom/osmo-start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

RUN systemctl enable osmo-autostart.service && \
    passwd -d root && \
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Point d'entrée pour systemd
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
CMD ["/bin/bash"]
