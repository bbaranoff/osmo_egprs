#!/bin/bash
# start.sh — Lance la stack Osmocom GSM multi-opérateurs
#
# Modes : net-host (1 opérateur, SDR physique) | bridge (N opérateurs SS7 inter-op)
set -eu
DEBUG=
if [[ -n "$DEBUG" ]]; then
    set -x
    PS4='[DEBUG] + ${BASH_SOURCE}:${LINENO}: '
    echo "=== MODE DEBUG ACTIVÉ ==="
fi

IMAGE_BASE="osmocom-nitb"
IMAGE_RUN="osmocom-run"

INTER_NET="gsm-inter"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── SMS Routing ────────────────────────────────────────────────────────────────
SMS_ROUTING_SCRIPT="$(dirname "$0")/scripts/sms-routing-setup.sh"
if [ -f "$SMS_ROUTING_SCRIPT" ]; then
    source "$SMS_ROUTING_SCRIPT"
fi
SMS_ROUTING_DIR=""

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
WAN_ENABLED="false"
WAN_LOCAL_IP=""
WAN_REMOTE_IP=""
WAN_N_REMOTE=""
WAN_PREFIX="66"
WAN_SIP_BASE=5080
WAN_RTP_BASE=20000
WAN_RTP_PER_OP=500
PHY_MODE="faketrx"   # faketrx | virtphy

# ── Helpers ────────────────────────────────────────────────────────────────────
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
op_private_ip()   { echo "172.20.$1.10"; }
op_private_gw()   { echo "172.20.$1.1"; }
op_private_net()  { echo "172.20.$1.0/24"; }
op_container()    { echo "osmo-operator-$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }

# WAN helpers
wan_sip_port()    { echo $(( WAN_SIP_BASE + ($1 - 1) * 2 )); }
wan_rtp_start()   { echo $(( WAN_RTP_BASE + ($1 - 1) * WAN_RTP_PER_OP )); }
wan_rtp_end()     { echo $(( WAN_RTP_BASE + $1 * WAN_RTP_PER_OP - 1 )); }

# Linphone helpers — port SIP/RTP exposé sur le host
linphone_sip_port()  { echo $(( 5060 + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }

# Global — détecté avant la boucle opérateurs
HOST_IP="127.0.0.1"
ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Osmocom GSM/EGPRS Virtual Network            ║"
    echo "║        Multi-Operator SS7 + osmo-gapk Audio          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}
# ── Loopback audio côté session utilisateur ───────────────────────────────
enable_user_loopback() {
    local target_user target_uid target_runtime loopback_script

    target_user="${SUDO_USER:-nirvana}"
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    loopback_script="/home/${target_user}/osmo_egprs/loopback.sh"

    echo -e "${GREEN}=== [audio] Loopback user session ===${NC}"
    echo -e "  user    : ${CYAN}${target_user}${NC}"
    echo -e "  runtime : ${CYAN}${target_runtime}${NC}"
    echo -e "  script  : ${CYAN}${loopback_script}${NC}"

    if [[ ! -x "$loopback_script" ]]; then
        echo -e "  ${RED}[FAIL]${NC} script introuvable ou non exécutable"
        return 1
    fi

    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" enable >/dev/null 2>&1 || {
            echo -e "  ${RED}[FAIL]${NC} enable loopback"
            return 1
        }

    echo -e "[ OK ]${NC} loopback activé"
}

disable_user_loopback() {
    local target_user target_uid target_runtime loopback_script

    target_user="${SUDO_USER:-nirvana}"
    target_uid="$(id -u "$target_user")"
    target_runtime="/run/user/${target_uid}"
    loopback_script="/home/${target_user}/osmo_egprs/loopback.sh"

    sudo -u "$target_user" \
        XDG_RUNTIME_DIR="$target_runtime" \
        PULSE_SERVER="unix:${target_runtime}/pulse/native" \
        "$loopback_script" disable || true
}
build_alsa_args() {
    local alsa_args=""
    local src_asound="$(dirname "$0")/configs/asound.conf"
    local host_asound="/tmp/osmocom-alsa/asound.conf"

    mkdir -p /tmp/osmocom-alsa

    # /dev/snd passthrough
    if [ -d /dev/snd ]; then
        alsa_args="${alsa_args} --device /dev/snd"
        if getent group audio >/dev/null 2>&1; then
            alsa_args="${alsa_args} --group-add $(getent group audio | cut -d: -f3)"
        fi
    fi

    # PulseAudio socket forwarding
    local real_user="${SUDO_USER:-$USER}"
    local real_uid; real_uid=$(id -u "$real_user" 2>/dev/null || echo "")
    local pulse_sock="/run/user/${real_uid}/pulse/native"
    local has_pulse="false"

    if [ -n "$real_uid" ] && [ -S "$pulse_sock" ]; then
        alsa_args="${alsa_args} -v ${pulse_sock}:/run/pulse/native"
        alsa_args="${alsa_args} -e PULSE_SERVER=unix:/run/pulse/native"
        local pulse_cookie="/home/${real_user}/.config/pulse/cookie"
        [ ! -f "$pulse_cookie" ] && pulse_cookie="/home/${real_user}/.pulse-cookie"
        if [ -f "$pulse_cookie" ]; then
            alsa_args="${alsa_args} -v ${pulse_cookie}:/root/.config/pulse/cookie:ro"
        fi
        has_pulse="true"
    fi

    # asound.conf : copie depuis configs/
    if [ -f "$src_asound" ]; then
        cp "$src_asound" "$host_asound"
        alsa_args="${alsa_args} -v ${host_asound}:/etc/asound.conf:rw"
        alsa_args="${alsa_args} -e ALSA_OUTPUT=gsm_out -e ALSA_INPUT=gsm_in"
        alsa_args="${alsa_args} -e ALSA_CARD=gsm_out -e GAPK_ALSA_DEV=gsm_out"
        if [ "$has_pulse" = "true" ]; then
            echo -e "  ${GREEN}Audio : PulseAudio + asound.conf${NC}" >&2
        else
            echo -e "  ${YELLOW}Audio : asound.conf sans PulseAudio${NC}" >&2
        fi
    else
        alsa_args="${alsa_args} -e ALSA_OUTPUT=default -e ALSA_INPUT=default"
        alsa_args="${alsa_args} -e ALSA_CARD=default -e GAPK_ALSA_DEV=default"
        echo -e "  ${YELLOW}Audio : configs/asound.conf absent, fallback default${NC}" >&2
    fi

    echo "$alsa_args"
}
# ══════════════════════════════════════════════════════════════════════════════
# Build
# ══════════════════════════════════════════════════════════════════════════════
build_run_image() {
    echo -e "${GREEN}Build de l'image run...${NC}"
    docker build --no-cache -f Dockerfile.run -t "$IMAGE_RUN" . \
        < /dev/null > /tmp/docker-build.log 2>&1
    echo -e "${GREEN}Image '$IMAGE_RUN' prête.${NC}"
}
check_image() {
    if ! docker image inspect "$IMAGE_RUN" &>/dev/null; then
        echo -e "${RED}Image '$IMAGE_RUN' introuvable — build en cours...${NC}"
        build_run_image
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Génération dynamique — pjsip interop trunks
# ══════════════════════════════════════════════════════════════════════════════
generate_pjsip_interop_trunks() {
    local op_id=$1
    local n_operators=$2

    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        local remote_ip
        remote_ip=$(op_backbone_ip "$remote_op")
        cat <<EOF

[interop-identify-op${remote_op}]
type=identify
endpoint=interop_trunk_op${remote_op}
match=${remote_ip}

[interop_trunk_op${remote_op}]
type=endpoint
transport=transport-udp
context=interop_in
disallow=all
allow=gsm
allow=ulaw
aors=interop_trunk_op${remote_op}
direct_media=no
rtp_symmetric=yes
force_rport=yes
media_encryption=no

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Génération dynamique — dialplan [interop_out]
# ══════════════════════════════════════════════════════════════════════════════
generate_extensions_interop_out() {
    local op_id=$1
    local n_operators=$2

    cat <<'EOF'
[interop_out]

EOF

    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
exten => _${remote_op}XXXX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

exten => _${remote_op}XXXXX,1,NoOp(=== INTEROP OUT Op${remote_op} 5d: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,Congestion()
 same => n,Hangup()

EOF
    done

    cat <<'EOF'
exten => _X.,1,NoOp(=== INTEROP OUT: inconnu ${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# SMS routing fallback
# ══════════════════════════════════════════════════════════════════════════════
_generate_sms_routing_conf_fallback() {
    local op_id=$1 n_operators=$2
    printf '# sms-routing.conf — Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    for i in $(seq 1 "$n_operators"); do
        printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"
    done
    printf '\n[routes]\n'
    for i in $(seq 1 "$n_operators"); do
        printf '%s0000 = %s\n' "$i" "$i"
        for j in 001 002 003 004 005; do printf '%s%s = %s\n' "$i" "$j" "$i"; done
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}

# ══════════════════════════════════════════════════════════════════════════════
# apply_config_templates — substitution des placeholders
# ══════════════════════════════════════════════════════════════════════════════
apply_config_templates() {
    local dest=$1
    local container_ip=$2
    local gateway_ip=$3
    local op_id=$4
    local pc_msc=$5 pc_stp=$6 pc_bsc=$7
    local mcc=$8 mnc=$9 op_name=${10}
    local inter_stp=${11}
    local inter_stp_shutdown=${12}
    local n_operators=${13}

    mkdir -p "$dest/osmocom" "$dest/asterisk" "$dest/bb"

    # Copie configs Osmocom
    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done

    if [ -f "configs/osmo-bts-virtual.cfg" ]; then
        cp "configs/osmo-bts-virtual.cfg" "$dest/osmocom/"
    fi

    # Copie configs Asterisk (y compris rtp.conf)
    for f in configs/*.conf; do
        local bn
        bn=$(basename "$f")
        [ "$bn" = "sms-routing.conf" ] && continue
        cp "$f" "$dest/asterisk/"
    done

    # Scripts
    for s in entrypoint.sh osmo-start.sh status.sh run.sh gapk-start.sh; do
        [ -f "scripts/$s" ] && cp "scripts/$s" "$dest/osmocom/$s" && chmod +x "$dest/osmocom/$s"
    done

    # mobile.cfg
    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
    elif [ -f "configs/mobile.cfg" ]; then
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
    fi

    # Calculs dérivés
    local rctx_msc rctx_stp rctx_bsc rctx_inter
    rctx_msc=$(op_rctx_msc "$op_id")
    rctx_stp=$(op_rctx_stp "$op_id")
    rctx_bsc=$(op_rctx_bsc "$op_id")
    rctx_inter=$(op_rctx_inter "$op_id")

    local arfcn=$(( 512 + op_id * 2 ))
    local ipa_unit_id=$(( 6000 + op_id ))
    local cell_id=$(( 6000 + op_id ))
    local bsic=$(( (op_id * 7) % 64 ))
    local bvci=$(( op_id * 10 + 2 ))
    local nsei=$(( op_id * 10 ))
    local nsvci=$(( op_id * 10 ))
    local imsi="${mcc}${mnc}$(printf '%010d' "${op_id}")"
    local imei="3589250059$(printf '%04d' "${op_id}")0"
    local ki="00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x' "${op_id}") ff"
    local sms_sc="+336661234$(printf '%04d' "${op_id}")"
    local inter_local_ip
    inter_local_ip=$(op_backbone_ip "$op_id")

    # Plage RTP Linphone pour cet opérateur
    local rtp_start rtp_end sip_host_port
    rtp_start=$(linphone_rtp_start "$op_id")
    rtp_end=$(linphone_rtp_end "$op_id")
    sip_host_port=$(linphone_sip_port "$op_id")

    # ── Substitution sed — TOUTES les valeurs en un seul passage ──────────
    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        sed -i \
            -e "s|__INTER_NET_GATEWAY__|172.20.0.1|g" \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__INTER_STP_SHUTDOWN__|${inter_stp_shutdown}|g" \
            -e "s|__INTER_LOCAL_IP__|${inter_local_ip}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" \
            -e "s|__PC_STP__|${pc_stp}|g" \
            -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__RCTX_MSC__|${rctx_msc}|g" \
            -e "s|__RCTX_STP__|${rctx_stp}|g" \
            -e "s|__RCTX_BSC__|${rctx_bsc}|g" \
            -e "s|__RCTX_INTER__|${rctx_inter}|g" \
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
            -e "s|__HOST_IP__|${HOST_IP}|g" \
            -e "s|__SIP_HOST_PORT__|${sip_host_port}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT}|g" \
            -e "s|__ALSA_INPUT__|${ALSA_INPUT}|g" \
            -e "s|__RTP_START__|${rtp_start}|g" \
            -e "s|__RTP_END__|${rtp_end}|g" \
            "$f"
    done

    # Append pjsip trunks + dialplan interop
    generate_pjsip_interop_trunks "$op_id" "$n_operators" \
        >> "$dest/asterisk/pjsip.conf"

    generate_extensions_interop_out "$op_id" "$n_operators" \
        >> "$dest/asterisk/extensions.conf"

    # SMS Routing
    if declare -f sms_routing_generate > /dev/null 2>&1 && \
       [ -n "${SMS_ROUTING_DIR:-}" ] && \
       [ -f "${SMS_ROUTING_DIR}/sms-routing-op${op_id}.conf" ]; then
        cp "${SMS_ROUTING_DIR}/sms-routing-op${op_id}.conf" \
           "$dest/osmocom/sms-routing.conf"
    else
        _generate_sms_routing_conf_fallback "$op_id" "$n_operators" \
            > "$dest/osmocom/sms-routing.conf"
    fi
}

build_vol_args() {
    local tmpdir=$1
    local vol_args=""
    for f in "$tmpdir/osmocom"/*.cfg "$tmpdir/osmocom"/*.sh "$tmpdir/osmocom"/*.conf; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/osmocom/$(basename "$f")"
    done
    for f in "$tmpdir/asterisk"/*.conf; do
        [ -f "$f" ] || continue
        vol_args="$vol_args -v $f:/etc/asterisk/$(basename "$f")"
    done
    if [ -f "$tmpdir/bb/mobile.cfg" ]; then
        vol_args="$vol_args -v $tmpdir/bb/mobile.cfg:/root/.osmocom/bb/mobile.cfg"
    fi
    echo "$vol_args"
}

# ══════════════════════════════════════════════════════════════════════════════
# TUN hôte
# ══════════════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════════════
# Inter-STP
# ══════════════════════════════════════════════════════════════════════════════
start_inter_stp() {
    local n_operators=$1
    local tmpdir
    tmpdir=$(mktemp -d)
    local inter_cfg="${tmpdir}/osmo-stp-interop.cfg"

    echo -e "${GREEN}Génération config inter-STP (${n_operators} opérateurs)...${NC}"
    bash ./helpers/create_interop.sh "$n_operators" "$inter_cfg" > /dev/null

    if [ ! -f "$inter_cfg" ]; then
        echo -e "${RED}Échec génération config inter-STP${NC}"; exit 1
    fi

    echo -e "${GREEN}Lancement inter-STP @ ${INTER_STP_IP}:2908 (PC 0.23.0)...${NC}"
    docker rm -f "$INTER_STP_CONTAINER" &>/dev/null || true

    docker run -d \
        --rm \
        --name "$INTER_STP_CONTAINER" \
        --network "$INTER_NET" \
        --ip "$INTER_STP_IP" \
        --cap-add NET_ADMIN \
        -v "${inter_cfg}:/etc/osmocom/osmo-stp-interop.cfg:ro" \
        --entrypoint bash \
        "$IMAGE_RUN" \
        -c "sleep infinity" > /dev/null

    docker exec "$INTER_STP_CONTAINER" \
        tmux new-session -d -s stp \
        "osmo-stp -c /etc/osmocom/osmo-stp-interop.cfg 2>&1 | tee /tmp/osmo-stp.log"

    echo -ne "${GREEN}[*] Attente démarrage inter-STP"
    local retries=25
    while [ $retries -gt 0 ]; do
        if docker exec "$INTER_STP_CONTAINER" \
            grep -qE "listening|m3ua.*[Ss]erver|bound" /tmp/osmo-stp.log 2>/dev/null; then
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
        ((retries--)) || true
    done
    echo -e " ${YELLOW}(timeout log, on continue)${NC}"
}

wait_inter_stp_ready() {
    local n_operators=$1
    echo -ne "${GREEN}[*] Vérification stabilisation inter-STP (routes SS7)${NC}"
    for i in {1..15}; do sleep 1; echo -n "."; done
    echo -e " ${GREEN}✓${NC}"
    return 0
}

wait_bb_vty() {
    local container="$1"
    local timeout=120
    local elapsed=0
    echo -ne "  Attente BB VTY 4247 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4247" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

wait_stp_vty() {
    local container="$1"
    local timeout=60
    local elapsed=0
    echo -ne "  Attente STP VTY 4239 "
    while ! docker exec "$container" bash -c "echo >/dev/tcp/127.0.0.1/4239" 2>/dev/null; do
        sleep 2; elapsed=$((elapsed + 2)); echo -n "."
        if [ "$elapsed" -ge "$timeout" ]; then echo -e " ${RED}TIMEOUT${NC}"; return 1; fi
    done
    echo -e " ${GREEN}OK${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# WAN Interop
# ══════════════════════════════════════════════════════════════════════════════
setup_wan_interop() {
    local n_local=$1
    local n_remote=$2
    local script_path
    script_path="$(dirname "$0")/setup-wan-interop.sh"
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}[WAN] setup-wan-interop.sh introuvable${NC}"
        return 1
    fi
    chmod +x "$script_path"
    bash "$script_path" "$WAN_LOCAL_IP" "$WAN_REMOTE_IP" "$n_local" "$n_remote"
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode bridge
# ══════════════════════════════════════════════════════════════════════════════
start_bridge_mode() {
    local n_operators
    read -rp "Nombre d'opérateurs [2] : " n_operators
    n_operators=${n_operators:-2}
    if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 36 ]; then
        echo -e "${RED}Nombre invalide (1–36).${NC}"; exit 1
    fi

    local use_defaults
    read -rp "Valeurs par défaut pour tous (MCC=001, MNC=01/02/…) ? [o/N] : " use_defaults

    local same_ms_all="N"
    if [[ ! "$use_defaults" =~ ^[OoYy]$ ]]; then
        read -rp "Même nombre de MS pour tous ? [o/N] : " same_ms_all
    fi

    declare -A OP_MCC OP_MNC OP_NAME OP_MS

    if [[ "$use_defaults" =~ ^[OoYy]$ ]]; then
        local common_ms
        read -rp "  MS par opérateur [8] : " common_ms
        common_ms=${common_ms:-8}
        if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
        for i in $(seq 1 "$n_operators"); do
            OP_MCC[$i]="001"; OP_MNC[$i]=$(printf '%02d' "$i")
            OP_NAME[$i]="OsmoOP${i}"; OP_MS[$i]=$common_ms
        done
    else
        if [[ "$same_ms_all" =~ ^[OoYy]$ ]]; then
            local common_ms
            read -rp "  MS par opérateur [8] : " common_ms
            common_ms=${common_ms:-8}
            if ! [[ "$common_ms" =~ ^[0-9]+$ ]] || [ "$common_ms" -lt 1 ] || [ "$common_ms" -gt 64 ]; then common_ms=8; fi
            for i in $(seq 1 "$n_operators"); do
                echo -e "${CYAN}── Opérateur ${i} ──${NC}"
                read -rp "  MCC [001] : " mcc; OP_MCC[$i]=${mcc:-001}
                read -rp "  MNC [$(printf '%02d' "$i")] : " mnc; OP_MNC[$i]=${mnc:-$(printf '%02d' "$i")}
                read -rp "  Nom [OsmoOP${i}] : " name; OP_NAME[$i]=${name:-"OsmoOP${i}"}
                OP_MS[$i]=$common_ms
            done
        else
            for i in $(seq 1 "$n_operators"); do
                echo -e "${CYAN}── Opérateur ${i} ──${NC}"
                read -rp "  MCC [001] : " mcc; OP_MCC[$i]=${mcc:-001}
                read -rp "  MNC [$(printf '%02d' "$i")] : " mnc; OP_MNC[$i]=${mnc:-$(printf '%02d' "$i")}
                read -rp "  Nom [OsmoOP${i}] : " name; OP_NAME[$i]=${name:-"OsmoOP${i}"}
                read -rp "  MS  [1] : " n_ms; OP_MS[$i]=${n_ms:-1}
                if ! [[ "${OP_MS[$i]}" =~ ^[0-9]+$ ]] || [ "${OP_MS[$i]}" -lt 1 ] || [ "${OP_MS[$i]}" -gt 64 ]; then OP_MS[$i]=1; fi
            done
        fi
    fi

    # ── WAN Interop ──
    echo ""
    echo -e "${CYAN}${BOLD}── WAN Interop ──${NC}"
    local wan_choice
    read -rp "Activer WAN vers un serveur distant ? [o/N] : " wan_choice
    if [[ "$wan_choice" =~ ^[OoYy]$ ]]; then
        WAN_ENABLED="true"
        local auto_ip=""
        auto_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
        [ -z "$auto_ip" ] && auto_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
        read -rp "  IP publique locale [${auto_ip}] : " wan_local; WAN_LOCAL_IP="${wan_local:-$auto_ip}"
        [ -z "$WAN_LOCAL_IP" ] && WAN_ENABLED="false"
        if [ "$WAN_ENABLED" = "true" ]; then
            read -rp "  IP publique distante : " wan_remote; WAN_REMOTE_IP="$wan_remote"
            [ -z "$WAN_REMOTE_IP" ] && WAN_ENABLED="false"
        fi
        if [ "$WAN_ENABLED" = "true" ]; then
            read -rp "  Nb opérateurs distants [${n_operators}] : " wan_nremote
            WAN_N_REMOTE="${wan_nremote:-$n_operators}"
            read -rp "  Préfixe WAN [${WAN_PREFIX}] : " wan_pfx; WAN_PREFIX="${wan_pfx:-$WAN_PREFIX}"
            echo -e "  ${GREEN}WAN: ${WAN_LOCAL_IP} ↔ ${WAN_REMOTE_IP} (local=${n_operators} remote=${WAN_N_REMOTE} prefix=${WAN_PREFIX})${NC}"
        fi
    fi
    # ── PHY Mode ──
    echo ""
    echo -e "${CYAN}${BOLD}── PHY Mode ──${NC}"
    echo "  1) faketrx  — fake_trx + trxcon (TRXD, défaut)"
    echo "  2) virtphy  — osmo-bts-virtual + virtphy (multicast) - EXPERIMENTAL !!"
    local phy_choice
    read -rp "Mode PHY [1] : " phy_choice
    case "$phy_choice" in
        2) PHY_MODE="virtphy" ;;
        *) PHY_MODE="faketrx" ;;
    esac
    echo -e "  ${GREEN}PHY : ${PHY_MODE}${NC}"
    
    # ── Détection IP hôte pour Linphone ────────────────────────────────────
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    HOST_IP="${HOST_IP:-127.0.0.1}"
    REAL_UID=$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}")
    echo -e "${GREEN}IP hôte : ${CYAN}${HOST_IP}${NC}  (Linphone)${NC}"
    echo ""

    # ── Réseau backbone ────────────────────────────────────────────────────
    docker network inspect "$INTER_NET" &>/dev/null || \
        docker network create --subnet="$INTER_NET_SUBNET" --gateway="$INTER_NET_GATEWAY" "$INTER_NET" &>/dev/null

    # ── SMS Routing ────────────────────────────────────────────────────────
    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate_all > /dev/null 2>&1; then
        local _ms_counts=()
        for i in $(seq 1 "$n_operators"); do _ms_counts+=("${OP_MS[$i]}"); done
        sms_routing_generate_all "$n_operators" "$SMS_ROUTING_DIR" "${_ms_counts[@]}"
        sms_routing_summary "$n_operators" "${_ms_counts[@]}"
    fi

    # ── Inter-STP ──────────────────────────────────────────────────────────
    start_inter_stp "$n_operators"
    wait_inter_stp_ready "$n_operators"

    # ── HLR subscribers ────────────────────────────────────────────────────
    local all_subscribers_file
    all_subscribers_file=$(mktemp)
    echo "# op_id:ms_idx:imsi:msisdn:ki" > "$all_subscribers_file"
    for op_id in $(seq 1 "$n_operators"); do
        local mcc="${OP_MCC[$op_id]}" mnc="${OP_MNC[$op_id]}" n_ms="${OP_MS[$op_id]}"
        for ms_idx in $(seq 1 "$n_ms"); do
            local msin; msin=$(printf '%04d%06d' "${op_id}" "${ms_idx}")
            local imsi="${mcc}${mnc}${msin}"
            local msisdn=$(( op_id * 10000 + ms_idx ))
            local ki; ki=$(printf '00112233445566778899aabbccdd%02x%02x' "${ms_idx}" "${op_id}")
            echo "${op_id}:${ms_idx}:${imsi}:${msisdn}:${ki}" >> "$all_subscribers_file"
        done
    done
    local total_subs; total_subs=$(( $(wc -l < "$all_subscribers_file") - 1 ))
    echo -e "${GREEN}Abonnés total : ${total_subs}${NC}"
    echo ""

    # ── Démarrage séquentiel des opérateurs ────────────────────────────────
    for i in $(seq 1 "$n_operators"); do
        local container_name net_name subnet gateway container_ip inter_local_ip rctx_inter
        local n_groups last_group_ip

        container_name=$(op_container "$i")
        net_name="gsm-net-op${i}"
        subnet=$(op_private_net "$i")
        gateway=$(op_private_gw "$i")
        container_ip=$(op_private_ip "$i")
        inter_local_ip=$(op_backbone_ip "$i")
        rctx_inter=$(op_rctx_inter "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        last_group_ip="127.0.0.${n_groups}"

        echo -e "${CYAN}── Opérateur ${i} : ${OP_NAME[$i]} (MCC=${OP_MCC[$i]} MNC=${OP_MNC[$i]}) ──${NC}"
        echo -e "  Backbone   : ${CYAN}${inter_local_ip}${NC}  Privé : ${CYAN}${container_ip}${NC}"
        echo -e "  STP PC     : 1.${i}.2  RCTX : ${rctx_inter}  MS : ${CYAN}${OP_MS[$i]}${NC}"

        docker network inspect "$net_name" &>/dev/null || \
            docker network create --subnet="$subnet" --gateway="$gateway" "$net_name" &>/dev/null

        local tmpdir
        tmpdir=$(mktemp -d)
        apply_config_templates "$tmpdir" \
            "$container_ip" "$gateway" \
            "$i" "1.${i}.1" "1.${i}.2" "1.${i}.3" \
            "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}" \
            "$INTER_STP_IP" "no shutdown" \
            "$n_operators"

        local vol_args alsa_args
        vol_args=$(build_vol_args "$tmpdir")
        alsa_args=$(build_alsa_args)

        mkdir -p /tmp/osmocom-logs/op${i}

        # ── Ports à exposer ───────────────────────────────────────────────
        local port_args=""

        # Linphone SIP/RTP — toujours exposé
        local lsip_port lrtp_s lrtp_e
        lsip_port=$(linphone_sip_port "$i")
        lrtp_s=$(linphone_rtp_start "$i")
        lrtp_e=$(linphone_rtp_end "$i")
        port_args="-p ${lsip_port}:5060/udp -p ${lrtp_s}-${lrtp_e}:${lrtp_s}-${lrtp_e}/udp"
        echo -e "  Linphone   : ${CYAN}${HOST_IP}:${lsip_port}${NC}  RTP ${lrtp_s}-${lrtp_e}"

        # WAN en plus si activé
        if [ "$WAN_ENABLED" = "true" ]; then
            local sip_port rtp_start rtp_end
            sip_port=$(wan_sip_port "$i")
            rtp_start=$(wan_rtp_start "$i")
            rtp_end=$(wan_rtp_end "$i")
            port_args="${port_args} -p ${sip_port}:5060/tcp -p ${rtp_start}-${rtp_end}:${rtp_start}-${rtp_end}/udp"
            echo -e "  WAN        : SIP ${sip_port} RTP ${rtp_start}-${rtp_end}"
        fi
        docker rm -f "$container_name" 2>/dev/null || true
        # shellcheck disable=SC2086
        docker run -d \
            --rm \
            --name "$container_name" \
            --network "$INTER_NET" \
            --ip "$inter_local_ip" \
            --cap-add NET_ADMIN \
            --cap-add SYS_ADMIN \
            --cgroupns host \
            --device /dev/net/tun:/dev/net/tun \
            $alsa_args \
            $port_args \
            -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            -v /tmp/osmocom-logs/op${i}:/var/log/osmocom \
            --tmpfs /tmp \
            --tmpfs /run:exec,size=64m \
            --tmpfs /run/lock \
            -e OPERATOR_ID="$i" \
            -e N_MS="${OP_MS[$i]}" \
            -e CONTAINER_IP="$container_ip" \
            -e GATEWAY_IP="$gateway" \
            -e INTER_STP_IP="$INTER_STP_IP" \
            -e HOST_IP="${HOST_IP}" \
            -e SIP_HOST_PORT="${lsip_port}" \
            -e PHY_MODE="${PHY_MODE}" \
            $vol_args \
            "$IMAGE_RUN" \
            sleep infinity
        docker network connect --ip "$container_ip" "$net_name" "$container_name"

        echo -e "  ${GREEN}[*] Lancement run.sh...${NC}"
        docker exec -d "$container_name" bash -c "mkdir -p /var/log/osmocom && /etc/osmocom/run.sh > /var/log/osmocom/run.sh.log 2>&1"

        # Attente HLR
        echo -ne "  ${GREEN}[*] Attente HLR (4258)${NC}"
        local retry=0
        while ! docker exec "$container_name" bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
            sleep 2; echo -n "."; retry=$((retry + 1))
            if [ $retry -ge 45 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
        done
        echo -e " ${GREEN}✓${NC}"

        # Feed HLR
        echo -e "  ${GREEN}[*] Alimentation HLR Op${i} (${total_subs} abonnés)...${NC}"
        {
            echo "#!/bin/bash"
            echo "cat > /tmp/hlr_feed.vty << 'VTYCMDS'"
            echo "enable"
            while IFS=: read -r feed_op feed_ms feed_imsi feed_msisdn feed_ki; do
                [[ "$feed_op" =~ ^#.*$ ]] && continue
                echo "subscriber imsi ${feed_imsi} create"
                echo "subscriber imsi ${feed_imsi} update msisdn ${feed_msisdn}"
                echo "subscriber imsi ${feed_imsi} update aud2g comp128v1 ki ${feed_ki}"
            done < "$all_subscribers_file"
            echo "end"
            echo "VTYCMDS"
        } | docker exec -i "$container_name" bash

        docker exec "$container_name" bash -c '
            if command -v nc >/dev/null 2>&1; then
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 2) | nc -q2 127.0.0.1 4258 2>/dev/null | grep -cE "^%" || true
            else
                (sleep 1; cat /tmp/hlr_feed.vty; sleep 3) | telnet 127.0.0.1 4258 2>/dev/null | grep -cE "^%" || true
            fi
            rm -f /tmp/hlr_feed.vty
        '
        echo -e "  ${GREEN}✓ HLR Op${i} alimenté${NC}"

        # Attente dernier groupe
        echo -ne "  ${GREEN}[*] Attente groupe (${last_group_ip}:4247)${NC}"
        retry=0
        while ! docker exec "$container_name" bash -c "echo >/dev/tcp/${last_group_ip}/4247" 2>/dev/null; do
            sleep 2; echo -n "."; retry=$((retry + 1))
            if [ $retry -ge 90 ]; then echo -e " ${RED}TIMEOUT${NC}"; break; fi
        done
        echo -e " ${GREEN}OK${NC}"
        sleep 3
        echo -e "  ${GREEN}✓${NC} ${container_name} prêt"
        echo ""
    done

    rm -f "$all_subscribers_file"

    # ── Attente relays SMS ─────────────────────────────────────────────────
    if declare -f sms_routing_wait_ready > /dev/null 2>&1; then
        for i in $(seq 1 "$n_operators"); do
            sms_routing_wait_ready "$(op_container "$i")" 90 || true
        done
    fi

    # ── WAN ────────────────────────────────────────────────────────────────
    if [ "$WAN_ENABLED" = "true" ]; then
        setup_wan_interop "$n_operators" "$WAN_N_REMOTE"
    fi

    # ── Résumé ─────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-opérateurs démarrée !${NC}"
    echo ""
    echo -e "  Inter-STP @ ${CYAN}${INTER_STP_IP}:2908${NC}  PC=0.0.0"
    for i in $(seq 1 "$n_operators"); do
        local rctx bb_ip n_groups
        rctx=$(op_rctx_inter "$i"); bb_ip=$(op_backbone_ip "$i")
        n_groups=$(( (${OP_MS[$i]} + 7) / 8 ))
        echo -e "  Op${i} ${OP_NAME[$i]}  STP 1.${i}.2 @ ${bb_ip}  RCTX ${rctx}  [${OP_MS[$i]} MS]"
    done

    echo ""
    echo -e "  ${BOLD}Linphone (depuis l'hôte) :${NC}"
    for i in $(seq 1 "$n_operators"); do
        local lsip bb_ip
        lsip=$(linphone_sip_port "$i"); bb_ip=$(op_backbone_ip "$i")
        echo -e "    Op${i}: ${CYAN}${HOST_IP}:${lsip}${NC}  (ou direct ${bb_ip}:5060)"
    done
    echo -e "    linphone_A / tester → 100  |  linphone_B / testerB → 200"

    if [ "$WAN_ENABLED" = "true" ]; then
        echo ""
        echo -e "  ${BOLD}WAN :${NC} ${CYAN}${WAN_LOCAL_IP}${NC} (${n_operators} ops) ↔ ${CYAN}${WAN_REMOTE_IP}${NC} (${WAN_N_REMOTE} ops)  prefix=${WAN_PREFIX}"
    fi
    echo ""

    # ── Wireshark ─────────────────────────────────────────────────────────
    local bridge_if
    bridge_if=$(docker network inspect "$INTER_NET" -f '{{.Id}}' 2>/dev/null | cut -c1-12)
    if [ -n "$bridge_if" ] && command -v wireshark &>/dev/null; then
        TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
        DISPLAY="${DISPLAY:-:0}"
        XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"
        DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            wireshark -k -i "br-${bridge_if}" -f "sctp or udp port 4729" \
            >/dev/null 2>&1 & true
        echo -e "  Wireshark sur ${CYAN}br-${bridge_if}${NC}"
    fi

    # ── Terminaux xterm ───────────────────────────────────────────────────
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"

    _open_term_script() {
        local title="$1" script_file="$2"
        chmod +x "$script_file"
        DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
        xterm -title "$title" -fa 'Monospace' -fs 10 \
              -bg '#1e1e1e' -fg '#d4d4d4' -e bash "$script_file" 2>/dev/null &
        sleep 0.3
    }

    for i in $(seq 1 "$n_operators"); do
        local cname; cname=$(op_container "$i")
        echo -ne "${YELLOW}Attente tmux ${cname}...${NC}"
        while ! sudo docker exec "${cname}" [ -S /tmp/osmocom_tmux ] 2>/dev/null; do sleep 1; echo -n "."; done
        echo -e " ${GREEN}OK${NC}"

        local tmpscript="/tmp/osmo-xterm-op${i}.sh"
        cat > "$tmpscript" <<EOF
#!/usr/bin/env bash
echo "=== Op${i} — ${OP_NAME[$i]} ==="
exec sudo docker exec -ti ${cname} tmux -S /tmp/osmocom_tmux attach
EOF
        _open_term_script "Op${i} — ${OP_NAME[$i]}" "$tmpscript"
    done

    echo "=== ${INTER_STP_CONTAINER} ==="
    wait_stp_vty "$INTER_STP_CONTAINER"

    local tmpscript_stp="/tmp/osmo-xterm-stp.sh"
    cat > "$tmpscript_stp" <<EOF
#!/usr/bin/env bash
exec sudo docker logs -f --tail 50 "${INTER_STP_CONTAINER}"
EOF
    _open_term_script "Inter-STP" "$tmpscript_stp"

    echo -e "\n${GREEN}${BOLD}Stack prête !${NC}"
    enable_user_loopback
    if [ -f "./vty-menu.sh" ]; then
        chmod +x ./vty-menu.sh
        exec ./vty-menu.sh
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode net-host
# ══════════════════════════════════════════════════════════════════════════════
start_host_mode() {
    echo -e "${GREEN}Démarrage en mode net-host (1 opérateur)...${NC}"
    local src_ip gw_ip
    gw_ip=$(ip route get 1 | awk '{print $3; exit}')
    src_ip=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$src_ip" ] && { echo -e "${RED}Impossible de détecter l'IP hôte.${NC}"; exit 1; }
    HOST_IP="$src_ip"

    local n_ms
    read -rp "Nombre de MS [1] : " n_ms
    n_ms=${n_ms:-1}

    prepare_host_tun
    docker rm -f egprs &>/dev/null || true

    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate > /dev/null 2>&1; then
        sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$n_ms"
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$src_ip" "$gw_ip" \
        "1" "1.1.1" "1.1.2" "1.1.3" \
        "001" "01" "OsmoGSM" \
        "127.0.0.1" "shutdown" "1"

    local vol_args alsa_args
    vol_args=$(build_vol_args "$tmpdir")
    alsa_args=$(build_alsa_args)

    # shellcheck disable=SC2086
    docker run -d --rm --name egprs --net host \
        --cap-add NET_ADMIN --cap-add SYS_ADMIN --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        $alsa_args \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -e CONTAINER_IP="$src_ip" -e GATEWAY_IP="$gw_ip" \
        -e OPERATOR_ID="1" -e N_MS="$n_ms" \
        -e INTER_STP_IP="127.0.0.1" \
        -e HOST_IP="${HOST_IP}" -e SIP_HOST_PORT="5060" \
        -e ALSA_OUTPUT="${ALSA_OUTPUT}" -e ALSA_INPUT="${ALSA_INPUT}" \
        $vol_args \
        "$IMAGE_RUN" /root/run.sh

    wait_bb_vty "egprs"
    sleep 3
    docker exec -it egprs /bin/bash -c "/root/run.sh"
}

# ══════════════════════════════════════════════════════════════════════════════
stop_all() {
    echo -e "${YELLOW}Arrêt de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    iptables -t nat -D PREROUTING -j OSMO_WAN_INTEROP 2>/dev/null || true
    iptables -t nat -F OSMO_WAN_INTEROP 2>/dev/null || true
    iptables -t nat -X OSMO_WAN_INTEROP 2>/dev/null || true
    echo -e "${GREEN}Arrêté.${NC}"
    disable_user_loopback
}

choose_network_mode() {
    echo -e "${BOLD}Mode réseau :${NC}"
    echo "  1) net-host  — SDR physique, 1 opérateur - HAS TO BE REPAIRED ?"
    echo "  2) bridge    — Multi-opérateurs SS7 inter-op"
    read -rp "Choix [1/2] : " NET_CHOICE
    case "$NET_CHOICE" in
        1) NETWORK_MODE="host" ;;
        2) NETWORK_MODE="bridge" ;;
        *) echo -e "${RED}Choix invalide.${NC}"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
# Main
banner
[ "${1:-}" = "stop" ] && { stop_all; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis${NC}"; exit 1; }

# 1. Toutes les questions d'abord (avant tout restart)
choose_network_mode
# 2. Ensuite le restart docker + build
./helpers/prepare_host.sh
build_run_image
check_image

# 3. Lancement
case "$NETWORK_MODE" in
    host)   start_host_mode ;;
    bridge) start_bridge_mode ;;
esac
