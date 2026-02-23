#!/bin/bash
# start.sh — Lance la stack Osmocom GSM
# Modes : net-host (1 opérateur, SDR physique) | bridge (N opérateurs SS7 inter-op)
#
# Topologie SS7 en mode bridge :
#
#   ┌─────────────── container osmo-operator-N ───────────────────┐
#   │  MSC (PC N.23.1) ──client──►                                │
#   │                              STP intra (PC N.23.2) ──client──►  Inter-STP (PC 0.23.0)
#   │  BSC (PC N.23.3) ──client──►                                │   172.20.0.10 : 2905
#   └─────────────────────────────────────────────────────────────┘
#
# Inter-STP : container autonome, --entrypoint osmo-stp, config statique
#             (configs/osmo-stp-interop.cfg, aucun placeholder).
# Opérateurs : démarrent sur gsm-inter en premier (interface inter dispo dès le boot)
#              puis rattachés à leur réseau opérateur via docker network connect.

set -e

IMAGE_BASE="osmocom-nitb"
IMAGE_RUN="osmocom-run"

INTER_NET="gsm-inter"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"
INTER_STP_CFG="$(pwd)/configs/osmo-stp-interop.cfg"

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

./prepare_host.sh

# ── Build ──────────────────────────────────────────────────────────────────────
build_run_image() {
    if ! docker image inspect "$IMAGE_BASE" &>/dev/null; then
        echo -e "${YELLOW}Image '$IMAGE_BASE' introuvable, build complet...${NC}"
        docker build -t "$IMAGE_BASE" -f Dockerfile .
    fi
    echo -e "${GREEN}Build de l'image run (Dockerfile.run)...${NC}"
    docker build -f Dockerfile.run -t "$IMAGE_RUN" . &> /dev/null
    echo -e "${GREEN}Image '$IMAGE_RUN' prête.${NC}"
}

check_image() {
    if ! docker image inspect "$IMAGE_RUN" &>/dev/null; then
        echo -e "${RED}Image '$IMAGE_RUN' introuvable — build en cours...${NC}"
        build_run_image
    fi
}

# ── Mode réseau ────────────────────────────────────────────────────────────────
choose_network_mode() {
    echo -e "${BOLD}Mode réseau :${NC}"
    echo "  1) net-host  — SDR physique, 1 opérateur, accès direct"
    echo "  2) bridge    — Multi-opérateurs, SS7 inter-op via inter-STP"
    echo ""
    read -rp "Choix [1/2] : " NET_CHOICE
    case "$NET_CHOICE" in
        1) NETWORK_MODE="host" ;;
        2) NETWORK_MODE="bridge" ;;
        *) echo -e "${RED}Choix invalide.${NC}"; exit 1 ;;
    esac
}

# ── TUN hôte ───────────────────────────────────────────────────────────────────
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

# ── Substitution des placeholders (configs opérateur uniquement) ───────────────
# Placeholders :
#   __CONTAINER_IP__       IP du container sur son réseau opérateur
#   __GATEWAY_IP__         Passerelle réseau opérateur
#   __HLR_IP__             IP OsmoHLR (toujours 127.0.0.2)
#   __INTER_STP_IP__       IP inter-STP (bridge: 172.20.0.10 | host: 127.0.0.1)
#   __INTER_STP_SHUTDOWN__ "no shutdown" (bridge) | "shutdown" (host)
#   __OPERATOR_ID__        Numéro opérateur
#   __PC_MSC__ / __PC_STP__ / __PC_BSC__
#   __MCC__ / __MNC__ / __OP_NAME__
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3
    local op_id="${4:-1}"
    local pc_msc="${5:-1.23.1}" pc_stp="${6:-1.23.2}" pc_bsc="${7:-1.23.3}"
    local mcc="${8:-001}" mnc="${9:-01}" op_name="${10:-OsmoGSM}"
    local inter_stp="${11:-127.0.0.1}"
    local inter_stp_shutdown="${12:-shutdown}"

    mkdir -p "$dest/osmocom" "$dest/asterisk"

    # Copie de toutes les configs SAUF osmo-stp-interop.cfg (inter-STP only)
    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done
    cp configs/*.conf "$dest/asterisk/" 2>/dev/null || true

    for s in entrypoint.sh osmo-start.sh status.sh run.sh; do
        [ -f "scripts/$s" ] && cp "scripts/$s" "$dest/osmocom/$s" && chmod +x "$dest/osmocom/$s"
    done


    # mobile.cfg va dans /root/.osmocom/bb/ (path spécifique OsmocomBB)
    mkdir -p "$dest/bb"
    # Utilisez TOUJOURS mobile.cfg.template et copiez-le vers mobile.cfg
    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
        echo -e "${GREEN}Template mobile.cfg copié depuis mobile.cfg.template${NC}"
    elif [ -f "configs/mobile.cfg" ]; then
        # Fallback sur l'ancien nom
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
        echo -e "${YELLOW}Attention: utilisation de mobile.cfg (pas de template)${NC}"
    fi
    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        # ── Valeurs dérivées de op_id ──────────────────────────────────────────
        # RCTX globalement uniques sur l'inter-STP
        local rctx_msc=$(( op_id * 100 + 10 ))
        local rctx_stp=$(( op_id * 100 + 20 ))
        local rctx_bsc=$(( op_id * 100 + 30 ))
        # ARFCN unique par opérateur (DCS1800 : 514, 516, 518 …)
        local arfcn=$(( 512 + op_id * 2 ))
        # IPA unit-id unique (BTS identity sur le réseau A-bis)
        local ipa_unit_id=$(( 6000 + op_id ))
        # Cell identity, BSIC, BVCI, NSEI, NSVCI uniques par opérateur
        local cell_id=$(( 6000 + op_id ))
        local bsic=$(( 60 + op_id ))
        local bvci=$(( op_id * 10 + 2 ))
        local nsei=$(( op_id * 10 ))
        local nsvci=$(( op_id * 10 ))
        # IMSI : MCC(3) + MNC(2) + MSIN(10) — unique par opérateur
        local imsi="${mcc}${mnc}$(printf '%010d' ${op_id})"
        # IMEI : 15 chiffres, unique par opérateur
        local imei="35892500591$(printf '%04d' ${op_id})"
        # KI d'authentification : varie par opérateur (16 octets)
        local ki="00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x' ${op_id}) ff"
        # SMS service center
        local sms_sc="+336661234$(printf '%04d' ${op_id})"
        # PC MSC de l'opérateur distant (pour sccp-address interop)
        # Simplifié : op_id=1 → interop=2.23.1, op_id=2 → interop=1.23.1
        # Pour N>2 : premier opérateur différent de soi
        local interop_op_id=$(( op_id == 1 ? 2 : 1 ))
        local interop_pc_msc="${interop_op_id}.23.1"
        # IP inter-net de l'opérateur distant (pour trunk SIP)
        local interop_trunk_ip="172.20.0.$((10 + interop_op_id))"
        # IP inter-net locale (eth0 du container sur gsm-inter)
        local inter_local_ip="172.20.0.$((10 + op_id))"

        sed -i \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__INTER_STP_SHUTDOWN__|${inter_stp_shutdown}|g" \
            -e "s|__INTER_LOCAL_IP__|${inter_local_ip}|g" \
            -e "s|__INTEROP_TRUNK_IP__|${interop_trunk_ip}|g" \
            -e "s|__INTEROP_PC_MSC__|${interop_pc_msc}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" \
            -e "s|__PC_STP__|${pc_stp}|g" \
            -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__RCTX_MSC__|${rctx_msc}|g" \
            -e "s|__RCTX_STP__|${rctx_stp}|g" \
            -e "s|__RCTX_BSC__|${rctx_bsc}|g" \
            -e "s|__MCC__|${mcc}|g" \
            -e "s|__MNC__|${mnc}|g" \
            -e "s|__OP_NAME__|${op_name}|g" \
            -e "s|__ARFCN__|${arfcn}|g" \
            -e "s|__IPA_UNIT_ID__|${ipa_unit_id}|g" \
            -e "s|__CELL_ID__|${cell_id}|g" \
            -e "s|__BSIC__|${bsic}|g" \
            -e "s|__BVCI__|${bvci}|g" \
            -e "s|__NSEI__|${nsei}|g" \
            -e "s|__NSVCI__|${nsvci}|g" \
            -e "s|__IMSI__|${imsi}|g" \
            -e "s|__IMEI__|${imei}|g" \
            -e "s|__KI__|${ki}|g" \
            -e "s|__SMS_SC__|${sms_sc}|g" \
            "$f"
    done
}

build_vol_args() {
    local tmpdir=$1
    local vol_args=""
    for f in "$tmpdir/osmocom"/*.cfg "$tmpdir/osmocom"/*.sh; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/osmocom/$(basename "$f")"
    done
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/asterisk/$(basename "$f")"
    done
    # mobile.cfg dans son répertoire dédié OsmocomBB
    if [ -f "$tmpdir/bb/mobile.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile.cfg:/root/.osmocom/bb/mobile.cfg"
    fi
    echo "$vol_args"
}

# ── Inter-STP : cas entièrement séparé ───────────────────────────────────────
# - Config statique (configs/osmo-stp-interop.cfg), aucun placeholder
# - --entrypoint osmo-stp : bypass entrypoint.sh et run.sh
# - -c explicite : ne jamais tomber sur osmo-stp.cfg (qui a des placeholders)
# - Pas de systemd / cgroup / TUN
# - Readiness : grep sur les logs (M3UA est SCTP, nc/nmap TCP ne fonctionnent pas)
start_inter_stp() {
    echo -e "${GREEN}Lancement inter-STP (${INTER_STP_IP})...${NC}"

    if [ ! -f "$INTER_STP_CFG" ]; then
        echo -e "${RED}Config introuvable : ${INTER_STP_CFG}${NC}"
        exit 1
    fi

    docker rm -f "$INTER_STP_CONTAINER" 2>/dev/null || true

    docker run -d \
        --name "$INTER_STP_CONTAINER" \
        --network "$INTER_NET" \
        --ip "$INTER_STP_IP" \
        --cap-add NET_ADMIN \
        -v "${INTER_STP_CFG}:/etc/osmocom/osmo-stp-interop.cfg:ro" \
        --entrypoint osmo-stp \
        "$IMAGE_RUN" \
        -c /etc/osmocom/osmo-stp-interop.cfg

    echo -ne "${GREEN}[*] Attente démarrage inter-STP"
    local retries=20
    while [ $retries -gt 0 ]; do
        if docker logs "$INTER_STP_CONTAINER" 2>&1 | grep -q "binding m3ua Server"; then
            echo -e " ${GREEN}✓${NC}"
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$INTER_STP_CONTAINER" 2>/dev/null)" != "true" ]; then
            echo -e " ${RED}CRASH${NC}"
            docker logs "$INTER_STP_CONTAINER"
            exit 1
        fi
        echo -n "."
        sleep 1
        ((retries--))
    done

    echo -e " ${RED}TIMEOUT${NC}"
    docker logs "$INTER_STP_CONTAINER"
    exit 1
}

# ── Mode host ─────────────────────────────────────────────────────────────────
start_host_mode() {
    echo -e "${GREEN}Démarrage en mode net-host...${NC}"

    GW_IP=$(ip route get 1 | awk '{print $3; exit}')
    SRC_IP=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$SRC_IP" ] && { echo -e "${RED}Impossible de détecter l'IP hôte.${NC}"; exit 1; }
    echo -e "  IP hôte : ${CYAN}${SRC_IP}${NC}  GW : ${CYAN}${GW_IP}${NC}"

    prepare_host_tun
    docker rm -f egprs 2>/dev/null || true

    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" "$SRC_IP" "$GW_IP" \
        "1" "1.23.1" "1.23.2" "1.23.3" "001" "01" "OsmoGSM" \
        "127.0.0.1" "shutdown"

    vol_args=$(build_vol_args "$tmpdir")

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

    echo -e "${GREEN}[*] Attente démarrage (5 s)...${NC}"
    sleep 5
    docker exec -it egprs /bin/bash -c "/root/run.sh"
}

# ── Mode bridge ───────────────────────────────────────────────────────────────
start_bridge_mode() {
    read -rp "Nombre d'opérateurs [2] : " N_OPERATORS
    N_OPERATORS=${N_OPERATORS:-2}
    if ! [[ "$N_OPERATORS" =~ ^[0-9]+$ ]] || [ "$N_OPERATORS" -lt 1 ]; then
        echo -e "${RED}Nombre invalide.${NC}"; exit 1
    fi

    declare -A OP_MCC OP_MNC OP_NAME
    for i in $(seq 1 "$N_OPERATORS"); do
        echo -e "${CYAN}── Opérateur $i ──${NC}"
        read -rp "  MCC [001] : "       mcc;  OP_MCC[$i]=${mcc:-001}
        read -rp "  MNC [0$i] : "       mnc;  OP_MNC[$i]=${mnc:-0$i}
        read -rp "  Nom [OsmoOP$i] : " name; OP_NAME[$i]=${name:-OsmoOP$i}
    done

    echo -e "${GREEN}Création du réseau inter (${INTER_NET})...${NC}"
    docker network inspect "$INTER_NET" &>/dev/null || \
        docker network create \
            --subnet="$INTER_NET_SUBNET" \
            --gateway="$INTER_NET_GATEWAY" \
            "$INTER_NET"

    # Inter-STP en premier — doit écouter avant que les opérateurs démarrent
    start_inter_stp

    for i in $(seq 1 "$N_OPERATORS"); do
        start_operator "$i" "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}"
    done

    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-opérateurs démarrée !${NC}"
    echo ""
    docker ps --filter "name=osmo-" --format "  {{.Names}}\t{{.Status}}"
    echo ""
    echo -e "  Inter-STP @ ${CYAN}${INTER_STP_IP}:2905${NC} (PC 0.23.0)"
    for i in $(seq 1 "$N_OPERATORS"); do
        echo -e "  Op${i} STP (PC ${i}.23.2 @ 172.20.0.$((10+i))) ──client──► inter-STP"
    done

    # ── Gnome Terminal ───────────────────────────────────────────────────────────
    # gnome-terminal nécessite le D-Bus de la session graphique → lancer en tant
    # qu'utilisateur réel (pas root) via su -c, avec DISPLAY/XAUTHORITY transmis.
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"

    _open_term() {
        local title="$1"
        local cmd="$2"
        # xterm : aucune dépendance D-Bus/dbus-launch, fonctionne directement en root
        DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
        xterm -title "$title" \
              -fa 'Monospace' -fs 10 \
              -bg '#1e1e1e' -fg '#d4d4d4' \
              -e bash -c "$cmd; exec bash" \
        2>/dev/null &
    }

    for i in $(seq 1 "$N_OPERATORS"); do
        _open_term \
            "Op${i} — ${OP_NAME[$i]:-OsmoOP$i}" \
            "echo '=== Op${i} — ${OP_NAME[$i]:-OsmoOP$i} ==='; \
             echo 'VTY STP : docker exec -it osmo-operator-${i} telnet 127.0.0.1 4239'; \
             echo 'VTY MSC : docker exec -it osmo-operator-${i} telnet 127.0.0.1 4254'; \
             echo 'VTY BSC : docker exec -it osmo-operator-${i} telnet 127.0.0.1 4242'; \
             echo 'SCCP    : show cs7 instance 0 sccp users'; \
             echo '          show cs7 instance 0 sccp connections'; \
             echo ''; \
             sudo docker exec -ti osmo-operator-${i} /etc/osmocom/run.sh"
    done

    _open_term \
        "Inter-STP (PC 0.23.0)" \
        "echo '=== Inter-STP ==='; \
         echo 'VTY : sudo docker exec -it osmo-inter-stp telnet 127.0.0.1 4239'; \
         echo ''; \
         sudo docker logs -f osmo-inter-stp" 
}

# ── Démarrage d'un opérateur ──────────────────────────────────────────────────
# Le container démarre sur gsm-inter en premier (interface inter dispo dès le boot),
# puis rattaché au réseau opérateur. Ainsi asp-to-inter peut atteindre 172.20.0.10
# dès le démarrage d'osmo-stp, sans attendre le timer de reconnexion.
start_operator() {
    local op_id=$1 mcc=$2 mnc=$3 op_name=$4
    local net_name="gsm-net-op${op_id}"
    local subnet="172.20.${op_id}.0/24"
    local gateway="172.20.${op_id}.1"
    local container_ip="172.20.${op_id}.10"
    local container_name="osmo-operator-${op_id}"
    local inter_local_ip="172.20.0.$((10 + op_id))"

    docker network inspect "$net_name" &>/dev/null || \
        docker network create --subnet="$subnet" --gateway="$gateway" "$net_name"

    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$container_ip" "$gateway" \
        "$op_id" "${op_id}.23.1" "${op_id}.23.2" "${op_id}.23.3" \
        "$mcc" "$mnc" "$op_name" \
        "$INTER_STP_IP" "no shutdown"

    echo -e "${GREEN}Démarrage '${container_name}'${NC}"
    echo -e "  réseau op    : ${CYAN}${container_ip}${NC} (${subnet})"
    echo -e "  réseau inter : ${CYAN}${inter_local_ip}${NC} → ${INTER_STP_IP}"
    echo -e "  PC : MSC=${op_id}.23.1  STP=${op_id}.23.2  BSC=${op_id}.23.3"

    docker rm -f "$container_name" 2>/dev/null || true

    vol_args=$(build_vol_args "$tmpdir")

    # shellcheck disable=SC2086
    docker run -d \
        --name "$container_name" \
        --network "$INTER_NET" \
        --ip "$inter_local_ip" \
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

    # Réseau opérateur ajouté après — loopback et services MSC/BSC non affectés
    docker network connect --ip "$container_ip" "$net_name" "$container_name"

    echo -e "  ${GREEN}✓ ${container_name} démarré${NC}"
}

# ── Arrêt ──────────────────────────────────────────────────────────────────────
stop_all() {
    echo -e "${YELLOW}Arrêt de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f
    docker network ls --filter "name=gsm-net-op" --format "{{.Name}}" | xargs -r docker network rm 2>/dev/null || true
    echo -e "${GREEN}Arrêté.${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
banner

[ "$1" = "stop" ] && { stop_all; exit 0; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Doit être lancé en root (sudo).${NC}"; exit 1
fi

build_run_image
check_image
choose_network_mode

case "$NETWORK_MODE" in
    host)   start_host_mode ;;
    bridge) start_bridge_mode ;;
esac
