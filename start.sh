#!/bin/bash
# start.sh — Lance la stack Osmocom GSM
# Modes : net-host (1 opérateur, SDR physique) | bridge (N opérateurs SS7 inter-op)

set -e

IMAGE_BASE="osmocom-nitb"
IMAGE_RUN="osmocom-run"
INTER_NET="gsm-inter"
INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Osmocom GSM/EGPRS Virtual Network            ║"
    echo "║              Multi-Operator SS7 Edition              ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Build Dockerfile.run ──────────────────────────────────────────────────────
build_run_image() {
    if ! docker image inspect "$IMAGE_BASE" &>/dev/null; then
        echo -e "${YELLOW}Image de base '$IMAGE_BASE' introuvable, build complet...${NC}"
        docker build -t "$IMAGE_BASE" -f Dockerfile .
    fi
    echo -e "${GREEN}Build de l'image run (Dockerfile.run)...${NC}"
    docker build -f Dockerfile.run -t "$IMAGE_RUN" .
    echo -e "${GREEN}Image '$IMAGE_RUN' prête.${NC}"
}

# ── Vérification image ────────────────────────────────────────────────────────
check_image() {
    if ! docker image inspect "$IMAGE_RUN" &>/dev/null; then
        echo -e "${RED}Image '$IMAGE_RUN' introuvable — build en cours...${NC}"
        build_run_image
    fi
}

# ── Choix du mode réseau ──────────────────────────────────────────────────────
choose_network_mode() {
    echo -e "${BOLD}Mode réseau :${NC}"
    echo "  1) net-host    — Accès direct à l'interface physique (SDR, 1 opérateur)"
    echo "  2) bridge      — Réseau Docker isolé (multi-opérateurs, SS7 inter-op)"
    echo ""
    read -rp "Choix [1/2] : " NET_CHOICE
    case "$NET_CHOICE" in
        1) NETWORK_MODE="host" ;;
        2) NETWORK_MODE="bridge" ;;
        *) echo -e "${RED}Choix invalide.${NC}"; exit 1 ;;
    esac
}

# ── Préparation TUN sur l'hôte ────────────────────────────────────────────────
prepare_host_tun() {
    echo -e "${GREEN}[*] Configuration TUN sur l'hôte...${NC}"
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    if [ ! -c /dev/net/tun ]; then
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi
    ip link del apn0 2>/dev/null || true
    ip tuntap add dev apn0 mode tun
    ip addr add 176.16.32.0/24 dev apn0
    ip link set apn0 up
}

# ── Substitution des IPs et copie dans $dest ─────────────────────────────────
# $dest/osmocom → /etc/osmocom  (*.cfg + scripts)
# $dest/asterisk → /etc/asterisk (*.conf)
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3
    local op_id="${4:-1}"
    local pc_msc="${5:-1.23.1}" pc_stp="${6:-1.23.2}" pc_bsc="${7:-1.23.3}"
    local mcc="${8:-001}" mnc="${9:-01}" op_name="${10:-OsmoGSM}"
    local inter_stp="${11:-127.0.0.1}"

    mkdir -p "$dest/osmocom" "$dest/asterisk"

    # Copie vers les bons répertoires
    cp configs/*.cfg  "$dest/osmocom/"  2>/dev/null || true
    cp configs/*.conf "$dest/asterisk/" 2>/dev/null || true

    # Scripts dans /etc/osmocom
    for s in entrypoint.sh osmo-start.sh status.sh run.sh; do
        [ -f "scripts/$s" ] && cp "scripts/$s" "$dest/osmocom/$s" && chmod +x "$dest/osmocom/$s"
    done

    # Substitution IP brute (style run.sh original)
    # Préserve 127.x / 0.0.0.0 / 176.16.x / gateway — remplace le reste
    local gw_esc ip_esc
    gw_esc=$(printf '%s\n' "$gateway_ip"   | sed 's/[.[\*^$]/\\&/g')
    ip_esc=$(printf '%s\n' "$container_ip" | sed 's/[\/&]/\\&/g')
    sed -Ei \
        -e '/127\./b' \
        -e '/0\.0\.0\.0/b' \
        -e '/176\.16\./b' \
        -e "/$gw_esc/b" \
        -e "s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/$ip_esc/g" \
        "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf 2>/dev/null || true

    # Placeholders explicites (après substitution IP brute)
    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        sed -i \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" \
            -e "s|__PC_STP__|${pc_stp}|g" \
            -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__MCC__|${mcc}|g" \
            -e "s|__MNC__|${mnc}|g" \
            -e "s|__OP_NAME__|${op_name}|g" \
            "$f"
    done
}

# ── Mode host ─────────────────────────────────────────────────────────────────
start_host_mode() {
    echo -e "${GREEN}Démarrage en mode net-host...${NC}"

    GW_IP=$(ip route get 1 | awk '{print $3; exit}')
    SRC_IP=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$SRC_IP" ] && { echo -e "${RED}Impossible de détecter l'IP.${NC}"; exit 1; }
    echo -e "IP : ${CYAN}$SRC_IP${NC}  GW : ${CYAN}$GW_IP${NC}"

    prepare_host_tun

    [ "$(docker inspect -f '{{.State.Running}}' egprs 2>/dev/null)" = "true" ] && \
        docker stop egprs 2>/dev/null || true

    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" "$SRC_IP" "$GW_IP" \
        "1" "1.23.1" "1.23.2" "1.23.3" "001" "01" "OsmoGSM" "127.0.0.1"

    # Monte fichier par fichier pour ne pas écraser les configs de l'image
    local vol_args=""
    for f in "$tmpdir/osmocom"/*.cfg "$tmpdir/osmocom"/*.sh; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        vol_args="$vol_args -v $f:/etc/osmocom/$fname"
    done
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        vol_args="$vol_args -v $f:/etc/asterisk/$fname"
    done

    # shellcheck disable=SC2086
    docker run -d \
        --rm \
        --name egprs \
        --net host \
        --cap-add NET_ADMIN \
        --cap-add SYS_ADMIN \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -e CONTAINER_IP="$SRC_IP" \
        -e GATEWAY_IP="$GW_IP" \
        -e OPERATOR_ID="1" \
        -e INTER_STP_IP="127.0.0.1" \
        $vol_args \
        "$IMAGE_RUN" \
        /etc/osmocom/run.sh

    echo -e "${GREEN}[*] Attente démarrage systemd...${NC}"
    sleep 5

    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    TARGET_UID=$(id -u "$TARGET_USER")
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"
    sudo -u "$TARGET_USER" \
        env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        nohup linphone >/dev/null 2>&1 & true

    wireshark -k -i any -f "udp port 4729" >/dev/null 2>&1 & true

    docker exec -it egprs /bin/bash -c "/root/run.sh"
}

# ── Mode bridge ───────────────────────────────────────────────────────────────
start_bridge_mode() {
    read -rp "Nombre d'opérateurs [2] : " N_OPERATORS
    N_OPERATORS=${N_OPERATORS:-2}
    ! [[ "$N_OPERATORS" =~ ^[0-9]+$ ]] || [ "$N_OPERATORS" -lt 1 ] && \
        { echo -e "${RED}Nombre invalide.${NC}"; exit 1; }

    declare -A OP_MCC OP_MNC OP_NAME
    for i in $(seq 1 "$N_OPERATORS"); do
        echo -e "${CYAN}── Opérateur $i ──${NC}"
        read -rp "  MCC [001] : "       mcc;  OP_MCC[$i]=${mcc:-001}
        read -rp "  MNC [0$i] : "       mnc;  OP_MNC[$i]=${mnc:-0$i}
        read -rp "  Nom [OsmoOP$i] : " name; OP_NAME[$i]=${name:-OsmoOP$i}
    done

    echo -e "${GREEN}Création du réseau inter-opérateurs...${NC}"
    docker network inspect "$INTER_NET" &>/dev/null || \
        docker network create --subnet="$INTER_NET_SUBNET" \
            --gateway="$INTER_NET_GATEWAY" "$INTER_NET"

    echo -e "${GREEN}Lancement inter-STP...${NC}"
    docker rm -f "$INTER_STP_CONTAINER" 2>/dev/null || true
    generate_inter_stp_config "$N_OPERATORS"

    docker run -d \
        --name "$INTER_STP_CONTAINER" \
        --network "$INTER_NET" \
        --ip "$INTER_STP_IP" \
        --cap-add NET_ADMIN \
        --cap-add SYS_ADMIN \
        --cgroupns host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -v /tmp/inter-stp:/etc/osmocom \
        "$IMAGE_RUN" \
        osmo-stp -c /etc/osmocom/osmo-stp-inter.cfg

    for i in $(seq 1 "$N_OPERATORS"); do
        start_operator "$i" "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}"
    done

    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-opérateurs démarrée !${NC}"
    docker ps --filter "name=osmo-" --format "  {{.Names}}\t{{.Status}}"
    echo ""
    for i in $(seq 1 "$N_OPERATORS"); do
        echo -e "  Op$i (STP PC ${i}.23.2) ──► Inter-STP (${INTER_STP_IP})"
    done
}

generate_inter_stp_config() {
    local n=$1
    mkdir -p /tmp/inter-stp
    {
        cat << 'CFG'
!
log stderr
  logging filter all 1
  logging color 1
  logging print category 1
  logging timestamp 0
  logging level lss7 debug
  logging level lm3ua debug
!
line vty
 no login
!
cs7 instance 0
 point-code 0.0.1
 network-indicator international
 xua rkm routing-key-allocation dynamic-permitted

CFG
        for i in $(seq 1 "$n"); do
            echo " asp asp-op${i} 2905 2905 m3ua"
            echo "  remote-ip 172.20.${i}.10"
            echo "  local-ip ${INTER_STP_IP}"
            echo "  role sg"
            echo "  sctp-role server"
            echo "  no shutdown"
            echo " as as-op${i} m3ua"
            echo "  asp asp-op${i}"
            echo "  routing-key $((i * 10)) ${i}.23.2"
            echo "  traffic-mode override"
            echo ""
        done
        echo " route-table system"
        for i in $(seq 1 "$n"); do
            for s in 1 2 3; do
                echo "  update route ${i}.23.${s} 7.255.7 linkset as-op${i}"
            done
        done
        echo ""
        echo " listen m3ua 2905"
        echo "  accept-asp-connections dynamic-permitted"
    } > /tmp/inter-stp/osmo-stp-inter.cfg
}

start_operator() {
    local op_id=$1 mcc=$2 mnc=$3 op_name=$4
    local net_name="gsm-net-op${op_id}"
    local subnet="172.20.${op_id}.0/24"
    local gateway="172.20.${op_id}.1"
    local container_ip="172.20.${op_id}.10"
    local container_name="osmo-operator-${op_id}"

    docker network inspect "$net_name" &>/dev/null || \
        docker network create --subnet="$subnet" --gateway="$gateway" "$net_name"

    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$container_ip" "$gateway" \
        "$op_id" "${op_id}.23.1" "${op_id}.23.2" "${op_id}.23.3" \
        "$mcc" "$mnc" "$op_name" "$INTER_STP_IP"

    echo -e "${GREEN}Démarrage '${container_name}' (${container_ip}, STP PC ${op_id}.23.2)...${NC}"
    docker rm -f "$container_name" 2>/dev/null || true

    # Monte fichier par fichier vers /etc/osmocom et /etc/asterisk
    local vol_args=""
    for f in "$tmpdir/osmocom"/*.cfg "$tmpdir/osmocom"/*.sh; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        vol_args="$vol_args -v $f:/etc/osmocom/$fname"
    done
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        vol_args="$vol_args -v $f:/etc/asterisk/$fname"
    done

    # shellcheck disable=SC2086
    docker run -d \
        --name "$container_name" \
        --network "$net_name" \
        --ip "$container_ip" \
        --cap-add NET_ADMIN \
        --cap-add SYS_ADMIN \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -e OPERATOR_ID="$op_id" \
        -e CONTAINER_IP="$container_ip" \
        -e GATEWAY_IP="$gateway" \
        -e INTER_STP_IP="$INTER_STP_IP" \
        $vol_args \
        "$IMAGE_RUN" \
        /etc/osmocom/run.sh

    docker network connect --ip "172.20.0.$((10 + op_id))" "$INTER_NET" "$container_name"
}

stop_all() {
    echo -e "${YELLOW}Arrêt de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f
    echo -e "${GREEN}Arrêté.${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
banner

[ "$1" = "stop" ] && { stop_all; exit 0; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Doit être lancé en root (sudo).${NC}"; exit 1
fi

killall -9 wireshark linphone 2>/dev/null || true

build_run_image
check_image
choose_network_mode

case "$NETWORK_MODE" in
    host) start_host_mode ;;
    bridge)
        start_bridge_mode
        TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
        TARGET_UID=$(id -u "$TARGET_USER")
        DISPLAY="${DISPLAY:-:0}"
        XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"
        i=1
        while docker ps --format "{{.Names}}" | grep -q "osmo-operator-${i}"; do
            op_name="${OP_NAME[$i]:-OsmoOP$i}"
            sudo -u "$TARGET_USER" \
                env DISPLAY="$DISPLAY" \
                    XAUTHORITY="$XAUTHORITY" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
                gnome-terminal \
                    --title="Op${i} — ${op_name}" \
                    -- bash -c "sudo docker exec -ti osmo-operator-${i} /etc/osmocom/run.sh; exec bash"
            ((i++))
        done
        ;;
esac
