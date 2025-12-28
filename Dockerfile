FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ROOT=/opt/GSM
ENV container=docker
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

# 1. Dépendances système
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 libpython3-dev liburing-dev ca-certificates git gcc g++ make cmake \
    autoconf automake libtool pkg-config wget curl tmux systemd systemd-sysv \
    iptables iproute2 libtalloc-dev libpcsclite-dev libsctp-dev libmnl-dev \
    libdbi-dev libdbd-sqlite3 libsqlite3-dev libc-ares-dev libgnutls28-dev \
    libortp-dev libfftw3-dev libusb-1.0-0-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* && update-ca-certificates

SHELL ["/bin/bash", "-c"]
WORKDIR ${ROOT}

# 2. Libosmocore (Version 1.12.0)
# 1. On définit les variables d'environnement de manière persistante
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# 2. La boucle de compilation
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
    elif [ "$name" = "libosmo-netif" ] || [ "$name" = "libosmo-abis" ] || [ "$name" = "libosmo-sigtran" ]; then \
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

# 5. Configuration du système et des services
WORKDIR /etc/osmocom
# On copie vos fichiers locaux (.service, .cfg, .sh) vers /etc/osmocom
COPY . /etc/osmocom/

# Correction des chemins dans les fichiers de service pour pointer vers /usr/local/bin
# et s'assurer que les binaires sont accessibles
RUN cp -f /usr/local/bin/osmo* /usr/bin/ || true && \
    chmod +x /etc/osmocom/entrypoint.sh /etc/osmocom/run_simulated.sh

# 6. Fix Login & Console
# Supprime le mot de passe root pour permettre l'accès console sans mdp
RUN passwd -d root && \
    # Masque le getty pour éviter l'invite de login bloquante sur le TTY principal
    systemctl mask getty@tty1.service serial-getty@tty1.service

# Point d'entrée pour systemd
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/etc/osmocom/entrypoint.sh"]
CMD ["/etc/osmocom/run_simulated.sh"]
