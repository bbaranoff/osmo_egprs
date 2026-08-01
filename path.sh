#!/bin/bash
# start-direct.sh — Launcher Osmocom NATIF (sans Docker), multi-mode
#
# Port direct de start.sh. Chaque `docker run/exec` est remplacé par un
# process hôte. Rien n'est réimplémenté : on réutilise scripts/run.sh
# (cœur + radio, piloté par PHY_MODE/RUN_NO_PROCESS) et qemu-src/start-clean.sh.
#
# Modes :
#   noproc        cœur seul (STP+HLR+MSC+MGW+BSC+Asterisk)            [1 op]
#   faketrx       cœur + osmo-bts + fake_trx + trxcon + mobile        [1 op]
#   virtphy       cœur + osmo-bts-virtual + virtphy + mobile          [1 op]
#   qemu          cœur (no-process) + qemu-src/start-clean.sh         [1 op]
#   faketrx-qemu  cœur + fake_trx vivant, Calypso QEMU attaché        [1 op] *combiné*
#   hw            SDR physique (net-host natif)                       [1 op]
#   virtual       multi-opérateurs SS7 via ip netns (ex-bridge)       [N op]
#
# Sélection : MODE=faketrx ./start-direct.sh   |   ./start-direct.sh faketrx
#             OSMO_MENU=1 ./start-direct.sh     (menu whiptail comme l'original)
#
# Hypothèses : binaires osmo-*/asterisk/nc/ip dans le PATH ; run.sh tourne
# hors conteneur (root) ; IPs backbone provisionnées (ajoutées sinon).
set -eu
DEBUG=
[[ -n "$DEBUG" ]] && { set -x; PS4='[DBG] +${BASH_SOURCE}:${LINENO}: '; }

HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

# ── Paramètres surchargables ────────────────────────────────────────────────
MODE="${MODE:-qemu}"
IFACE="${IFACE:-enp0s3}"
BRIDGE="${BRIDGE:-gsm-inter}"
QEMU_SRC="${QEMU_SRC:-/opt/GSM/qemu-src}"; [ -d "$QEMU_SRC" ] || QEMU_SRC="$HERE/qemu-src"
ENCRYPTION="${ENCRYPTION:-a5 0}"
RUN_DIR="${RUN_DIR:-/run/osmo-direct}"
LOG_DIR="${LOG_DIR:-/var/log/osmocom}"
N_OPERATORS="${N_OPERATORS:-2}"
MS_PER_OP="${MS_PER_OP:-8}"
INTER_STP_IP="172.20.0.10"

# Contrat d'env pour le mode combiné (à honorer dans qemu-src/start-clean.sh) :
#   QEMU_ATTACH_TRX=1  NO_LOCAL_BTS=1  NO_LOCAL_TRX=1
#   TRX_REMOTE=<ip fake_trx>  TRX_BASE_PORT=<port base, défaut 6700>
TRX_BASE_PORT="${TRX_BASE_PORT:-6700}"
TRX_BIND="${TRX_BIND:-127.0.0.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── Helpers IP (identiques à start.sh) ──────────────────────────────────────
op_backbone_ip()  { echo "172.20.0.$((10 + $1))"; }
op_private_ip()   { echo "172.20.$1.10"; }
op_private_gw()   { echo "172.20.$1.1"; }
op_private_net()  { echo "172.20.$1.0/24"; }
op_netns()        { echo "osmo-op$1"; }
op_rctx_msc()     { echo $(( $1 * 100 + 10 )); }
op_rctx_stp()     { echo $(( $1 * 100 + 20 )); }
op_rctx_bsc()     { echo $(( $1 * 100 + 30 )); }
op_rctx_inter()   { echo $(( $1 * 100 + 50 )); }
linphone_sip_port()  { echo $(( 5060 + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }

HOST_IP="127.0.0.1"
ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"

# NS_EXEC : préfixe `ip netns exec` si $NETNS est posé, sinon rien.
ns() { if [ -n "${NETNS:-}" ]; then ip netns exec "$NETNS" "$@"; else "$@"; fi; }

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       Osmocom GSM/EGPRS — Launcher NATIF (no-docker)  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Whiptail (repris de start.sh) ───────────────────────────────────────────
WT_BACKTITLE="Osmocom GSM/EGPRS — natif"; WT_WIDTH=72
wt_menu() {
    local title="$1" prompt="$2"; shift 2
    whiptail --backtitle "$WT_BACKTITLE" --title "$title" \
        --menu "$prompt" 20 "$WT_WIDTH" $(( $# / 2 )) "$@" 3>&1 1>&2 2>&3
}
wt_input() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" \
        --inputbox "$2" 10 "$WT_WIDTH" "$3" 3>&1 1>&2 2>&3
}

# ── Générateurs de config (verbatim de start.sh) ────────────────────────────
generate_pjsip_interop_trunks() {
    local op_id=$1 n_operators=$2 remote_op remote_ip
    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
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
generate_extensions_interop_out() {
    local op_id=$1 n_operators=$2 remote_op
    printf '[interop_out]\n\n'
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
_generate_sms_routing_conf_fallback() {
    local op_id=$1 n_operators=$2 i j
    printf '# sms-routing.conf — Fallback\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' "$op_id" "$op_id"
    for i in $(seq 1 "$n_operators"); do printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"; done
    printf '\n[routes]\n'
    for i in $(seq 1 "$n_operators"); do
        printf '%s0000 = %s\n' "$i" "$i"
        for j in 001 002 003 004 005; do printf '%s%s = %s\n' "$i" "$j" "$i"; done
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}
apply_config_templates() {
    local dest=$1 container_ip=$2 gateway_ip=$3 op_id=$4
    local pc_msc=$5 pc_stp=$6 pc_bsc=$7 mcc=$8 mnc=$9 op_name=${10}
    local inter_stp=${11} inter_stp_shutdown=${12} n_operators=${13}
    mkdir -p "$dest/osmocom" "$dest/asterisk" "$dest/bb"
    local f bn s
    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done
    [ -f "configs/osmo-bts-virtual.cfg" ] && cp "configs/osmo-bts-virtual.cfg" "$dest/osmocom/"
    for f in configs/*.conf; do
        bn=$(basename "$f"); [ "$bn" = "sms-routing.conf" ] && continue
        cp "$f" "$dest/asterisk/"
    done
    for s in entrypoint.sh osmo-start.sh status.sh run.sh gapk-start.sh; do
        [ -f "scripts/$s" ] && cp "scripts/$s" "$dest/osmocom/$s" && chmod +x "$dest/osmocom/$s"
    done
    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg.template" "$dest/bb/mobile_group1.cfg"
    elif [ -f "configs/mobile.cfg" ]; then
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
        cp "configs/mobile.cfg" "$dest/bb/mobile_group1.cfg"
    fi
    local rctx_msc rctx_stp rctx_bsc rctx_inter
    rctx_msc=$(op_rctx_msc "$op_id"); rctx_stp=$(op_rctx_stp "$op_id")
    rctx_bsc=$(op_rctx_bsc "$op_id"); rctx_inter=$(op_rctx_inter "$op_id")
    local arfcn=$(( 512 + op_id * 2 )) ipa_unit_id=$(( 6000 + op_id ))
    local cell_id=$(( 6000 + op_id )) bsic=$(( (op_id * 7) % 64 ))
    local bvci=$(( op_id * 10 + 2 )) nsei=$(( op_id * 10 )) nsvci=$(( op_id * 10 ))
    local imsi="${mcc}${mnc}$(printf '%010d' "${op_id}")"
    local imei="3589250059$(printf '%04d' "${op_id}")0"
    local ki="00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x' "${op_id}") ff"
    local sms_sc="+336661234$(printf '%04d' "${op_id}")"
    local inter_local_ip; inter_local_ip=$(op_backbone_ip "$op_id")
    local rtp_start rtp_end sip_host_port
    rtp_start=$(linphone_rtp_start "$op_id"); rtp_end=$(linphone_rtp_end "$op_id")
    sip_host_port=$(linphone_sip_port "$op_id")
    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        sed -i \
            -e "s|__ENCRYPTION__|${ENCRYPTION}|g" \
            -e "s|__INTER_NET_GATEWAY__|172.20.0.1|g" \
            -e "s|__CONTAINER_IP__|${container_ip}|g" \
            -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
            -e "s|__HLR_IP__|127.0.0.2|g" \
            -e "s|__INTER_STP_IP__|${inter_stp}|g" \
            -e "s|__INTER_STP_SHUTDOWN__|${inter_stp_shutdown}|g" \
            -e "s|__INTER_LOCAL_IP__|${inter_local_ip}|g" \
            -e "s|__OPERATOR_ID__|${op_id}|g" \
            -e "s|__PC_MSC__|${pc_msc}|g" -e "s|__PC_STP__|${pc_stp}|g" -e "s|__PC_BSC__|${pc_bsc}|g" \
            -e "s|__RCTX_MSC__|${rctx_msc}|g" -e "s|__RCTX_STP__|${rctx_stp}|g" \
            -e "s|__RCTX_BSC__|${rctx_bsc}|g" -e "s|__RCTX_INTER__|${rctx_inter}|g" \
            -e "s|__MCC__|${mcc}|g" -e "s|__MNC__|${mnc}|g" -e "s|__OP_NAME__|${op_name}|g" \
            -e "s|__ARFCN__|${arfcn}|g" -e "s|__IPA_UNIT_ID__|${ipa_unit_id}|g" \
            -e "s|__CELL_ID__|${cell_id}|g" -e "s|__BSIC__|${bsic}|g" \
            -e "s|__BVCI__|${bvci}|g" -e "s|__NSEI__|${nsei}|g" -e "s|__NSVCI__|${nsvci}|g" \
            -e "s|__IMSI__|${imsi}|g" -e "s|__IMEI__|${imei}|g" -e "s|__KI__|${ki}|g" \
            -e "s|__SMS_SC__|${sms_sc}|g" -e "s|__HOST_IP__|${HOST_IP}|g" \
            -e "s|__SIP_HOST_PORT__|${sip_host_port}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT}|g" -e "s|__ALSA_INPUT__|${ALSA_INPUT}|g" \
            -e "s|__RTP_START__|${rtp_start}|g" -e "s|__RTP_END__|${rtp_end}|g" \
            "$f"
    done
    generate_pjsip_interop_trunks "$op_id" "$n_operators" >> "$dest/asterisk/pjsip.conf"
    generate_extensions_interop_out "$op_id" "$n_operators" >> "$dest/asterisk/extensions.conf"
    _generate_sms_routing_conf_fallback "$op_id" "$n_operators" > "$dest/osmocom/sms-routing.conf"
}

# ── Install configs natif. $1=src $2=prefix racine (/ ou /etc/netns/<ns>) ──
install_configs_native() {
    local src=$1 root="${2:-}"
    mkdir -p "${root}/etc/osmocom" "${root}/etc/asterisk" "$HOME/.osmocom/bb"
    cp -f "$src/osmocom"/*      "${root}/etc/osmocom/"  2>/dev/null || true
    cp -f "$src/asterisk"/*.conf "${root}/etc/asterisk/" 2>/dev/null || true
    [ -f "$src/bb/mobile.cfg" ]        && cp -f "$src/bb/mobile.cfg"        "$HOME/.osmocom/bb/mobile.cfg"
    [ -f "$src/bb/mobile_group1.cfg" ] && cp -f "$src/bb/mobile_group1.cfg" "$HOME/.osmocom/bb/mobile_group1.cfg"
    if [ -f configs/asound.conf ]; then
        cp -f configs/asound.conf "${root}/etc/asound.conf"
        ALSA_OUTPUT="gsm_out"; ALSA_INPUT="gsm_in"
    fi
}

# ── Réseau hôte : tun + IP inter-STP sur $1 (iface ou bridge) ───────────────
ensure_tun() {
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || { mknod /dev/net/tun c 10 200; chmod 666 /dev/net/tun; }
}
ensure_inter_stp_ip() {
    local dev=$1
    ip -o addr show dev "$dev" 2>/dev/null | grep -q "${INTER_STP_IP}/" || {
        echo -e "  ${YELLOW}[net] +${INTER_STP_IP}/24 sur ${dev}${NC}"
        ip addr add "${INTER_STP_IP}/24" dev "$dev" 2>/dev/null || true
    }
}

# ── Bridge backbone + netns par opérateur (multi-op) ────────────────────────
setup_bridge() {
    ip link show "$BRIDGE" &>/dev/null || ip link add "$BRIDGE" type bridge
    ip addr show dev "$BRIDGE" | grep -q '172.20.0.1/' || ip addr add 172.20.0.1/24 dev "$BRIDGE"
    ip link set "$BRIDGE" up
    ensure_inter_stp_ip "$BRIDGE"
}
ns_create() {
    local i=$1 nsn vethh vethp bb priv
    nsn=$(op_netns "$i"); vethh="vop${i}"; vethp="vop${i}p"
    bb=$(op_backbone_ip "$i"); priv=$(op_private_ip "$i")
    ip netns add "$nsn" 2>/dev/null || true
    ip netns exec "$nsn" ip link set lo up
    ip link show "$vethh" &>/dev/null || ip link add "$vethh" type veth peer name "$vethp"
    ip link set "$vethh" master "$BRIDGE"; ip link set "$vethh" up
    ip link set "$vethp" netns "$nsn" 2>/dev/null || true
    ip netns exec "$nsn" ip addr add "${bb}/24"   dev "$vethp" 2>/dev/null || true
    ip netns exec "$nsn" ip addr add "${priv}/24" dev "$vethp" 2>/dev/null || true
    ip netns exec "$nsn" ip link set "$vethp" up
    ip netns exec "$nsn" ip route replace default via 172.20.0.1 2>/dev/null || true
}
ns_destroy_all() {
    local nsn
    for nsn in $(ip netns list 2>/dev/null | awk '{print $1}' | grep '^osmo-op'); do
        ip netns del "$nsn" 2>/dev/null || true
    done
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^vop' | while read -r l; do
        ip link del "${l%@*}" 2>/dev/null || true
    done
    ip link del "$BRIDGE" 2>/dev/null || true
}

# ── Inter-STP natif (host ou netns selon $NETNS) ────────────────────────────
start_inter_stp() {
    local n_operators=$1 inter_cfg="${RUN_DIR}/osmo-stp-interop.cfg"
    echo -e "${GREEN}Config inter-STP (${n_operators} op)...${NC}"
    bash ./helpers/create_interop.sh "$n_operators" "$inter_cfg" > /dev/null
    [ -f "$inter_cfg" ] || { echo -e "${RED}Échec config inter-STP${NC}"; exit 1; }
    echo -e "${GREEN}Inter-STP @ ${INTER_STP_IP}:2908...${NC}"
    setsid osmo-stp -c "$inter_cfg" > "${RUN_DIR}/osmo-stp-interop.log" 2>&1 < /dev/null &
    echo $! > "${RUN_DIR}/osmo-stp-interop.pid"
    echo -ne "${GREEN}[*] Attente inter-STP"
    local r=25
    while [ $r -gt 0 ]; do
        grep -qE "listening|m3ua.*[Ss]erver|bound" "${RUN_DIR}/osmo-stp-interop.log" 2>/dev/null \
            && { echo -e " ${GREEN}✓${NC}"; return 0; }
        kill -0 "$(cat "${RUN_DIR}/osmo-stp-interop.pid")" 2>/dev/null \
            || { echo -e " ${RED}CRASH${NC}"; cat "${RUN_DIR}/osmo-stp-interop.log"; exit 1; }
        echo -n "."; sleep 1; ((r--)) || true
    done
    echo -e " ${YELLOW}(timeout, on continue)${NC}"
}

# ── Cœur natif (env = ce que le conteneur passait). $1=op $2=cip $3=gw ──────
#    Variables modifiables avant appel : PHY_MODE, RUN_NO_PROCESS, EXTRA_ENV
start_core_native() {
    local op_id=$1 cip=$2 gw=$3 run_sh="/etc/osmocom/run.sh"
    [ -x "$run_sh" ] || run_sh="$HERE/scripts/run.sh"
    [ -n "${NETNS:-}" ] && run_sh="$HERE/scripts/run.sh"   # netns : copie hôte
    echo -e "  ${GREEN}[*] run.sh natif — PHY=${PHY_MODE} no_process=${RUN_NO_PROCESS}${NETNS:+ netns=$NETNS}${NC}"
    mkdir -p "$LOG_DIR"
    ns setsid env \
        RUN_NO_PROCESS="${RUN_NO_PROCESS}" \
        OPERATOR_ID="$op_id" N_MS="${N_MS:-1}" \
        CONTAINER_IP="$cip" GATEWAY_IP="$gw" \
        INTER_STP_IP="$INTER_STP_IP" \
        HOST_IP="$HOST_IP" SIP_HOST_PORT="$(linphone_sip_port "$op_id")" \
        PHY_MODE="$PHY_MODE" \
        ALSA_OUTPUT="$ALSA_OUTPUT" ALSA_INPUT="$ALSA_INPUT" \
        ${EXTRA_ENV:-} \
        bash "$run_sh" > "${LOG_DIR}/run-op${op_id}.log" 2>&1 < /dev/null &
    echo $! > "${RUN_DIR}/core-op${op_id}.pid"
}

# ── Attente + alimentation HLR. $1=op $2=mcc $3=mnc $4=n_ms ────────────────
feed_hlr() {
    local op_id=$1 mcc=$2 mnc=$3 n_ms=${4:-1}
    echo -ne "  ${GREEN}[*] Attente HLR (4258)${NC}"
    local retry=0
    while ! ns bash -c "echo >/dev/tcp/127.0.0.1/4258" 2>/dev/null; do
        sleep 2; echo -n "."; retry=$((retry + 1))
        [ $retry -ge 45 ] && { echo -e " ${RED}TIMEOUT${NC}"; return 1; }
    done
    echo -e " ${GREEN}✓${NC}"
    local feed="${RUN_DIR}/hlr_feed-op${op_id}.vty" m msin imsi msisdn ki
    { echo "enable"
      for m in $(seq 1 "$n_ms"); do
          msin=$(printf '%04d%06d' "$op_id" "$m")
          imsi="${mcc}${mnc}${msin}"
          msisdn=$(( op_id * 10000 + m ))
	  ki=$(printf '00112233445566778899aabbccdd%02xff' "$m")
          echo "subscriber imsi ${imsi} create"
          echo "subscriber imsi ${imsi} update msisdn ${msisdn}"
          echo "subscriber imsi ${imsi} update aud2g comp128v1 ki ${ki}"
      done
      echo "end"
    } > "$feed"
    echo -e "  ${GREEN}[*] HLR Op${op_id} (${n_ms} abonné(s))...${NC}"
    if command -v nc >/dev/null 2>&1; then
        ns bash -c "(sleep 1; cat '$feed'; sleep 2) | nc -q2 127.0.0.1 4258" 2>/dev/null | grep -cE "^%" || true
    else
        ns bash -c "(sleep 1; cat '$feed'; sleep 3) | telnet 127.0.0.1 4258" 2>/dev/null | grep -cE "^%" || true
    fi
    rm -f "$feed"
    echo -e "  ${GREEN}✓ HLR Op${op_id}${NC}"
}

detect_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    [ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    HOST_IP="${HOST_IP:-127.0.0.1}"
}

# ══════════════════════════════════════════════════════════════════════════
# Modes 1 opérateur (host loopback + enp0s3) : noproc/faketrx/virtphy/qemu/combiné
# ══════════════════════════════════════════════════════════════════════════
run_single_op() {
    local mode=$1
    local op_id=1 mcc="001" mnc="01" op_name="OsmoDirect"
    local cip gw; cip=$(op_private_ip "$op_id"); gw=$(op_private_gw "$op_id")
    NETNS=""; N_MS=1
    detect_host_ip
    ensure_tun
    ensure_inter_stp_ip "$IFACE"

    # PHY / no-process / post selon le mode
    local post="none"
    case "$mode" in
        noproc)        PHY_MODE="faketrx"; RUN_NO_PROCESS=1; post="none" ;;
        faketrx)       PHY_MODE="faketrx"; RUN_NO_PROCESS=0; post="none" ;;
        virtphy)       PHY_MODE="virtphy"; RUN_NO_PROCESS=0; post="none" ;;
        qemu)          PHY_MODE="faketrx"; RUN_NO_PROCESS=1; post="qemu" ;;
        faketrx-qemu)  PHY_MODE="faketrx"; RUN_NO_PROCESS=0; post="qemu-attach" ;;
        hw)            PHY_MODE="${PHY_MODE:-trx}"; RUN_NO_PROCESS=0; post="none"
                       INTER_STP_IP="127.0.0.1" ;;   # net-host : pas de backbone
        *) echo -e "${RED}Mode inconnu : ${mode}${NC}"; exit 1 ;;
    esac
    echo -e "  ${CYAN}[${mode}] PHY=${PHY_MODE} no_process=${RUN_NO_PROCESS} enc='${ENCRYPTION}'${NC}"
    echo -e "  IP hôte : ${CYAN}${HOST_IP}${NC}"

    # Inter-STP (sauf hw qui est INTER_STP_IP=127.0.0.1 → STP local du cœur)
    [ "$mode" != "hw" ] && start_inter_stp 1

    local tmpdir; tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" "$cip" "$gw" "$op_id" \
        "1.1.1" "1.1.2" "1.1.3" "$mcc" "$mnc" "$op_name" \
        "$INTER_STP_IP" "no shutdown" "1"
    install_configs_native "$tmpdir" ""
    rm -rf "$tmpdir"

    start_core_native "$op_id" "$cip" "$gw"
    feed_hlr "$op_id" "$mcc" "$mnc" 1

    echo ""
    echo -e "${GREEN}${BOLD}Cœur prêt (natif).${NC}"
    echo -e "  HLR VTY   @ ${CYAN}127.0.0.1:4258${NC}   BB VTY @ ${CYAN}127.0.0.1:4247${NC}"
    echo -e "  Linphone  @ ${CYAN}${HOST_IP}:$(linphone_sip_port "$op_id")${NC}"
    echo -e "  Logs      @ ${CYAN}${LOG_DIR}/run-op1.log${NC}"
    echo ""

    case "$post" in
        none)
            echo -e "${GREEN}Processus en arrière-plan. './start-direct.sh stop' pour tout arrêter.${NC}"
            ;;
        qemu)
            [ -d "$QEMU_SRC" ] || { echo -e "${RED}qemu-src introuvable : ${QEMU_SRC}${NC}"; exit 1; }
            echo -e "  ${CYAN}[*] qemu-src/start-clean.sh (terminal courant)${NC}"
            cd "$QEMU_SRC"; exec ./start-clean.sh
            ;;
        qemu-attach)
            # Combiné : run.sh a démarré osmo-bts + fake_trx. QEMU s'y attache
            # au lieu de spawner sa propre radio (contrat d'env ci-dessous).
            [ -d "$QEMU_SRC" ] || { echo -e "${RED}qemu-src introuvable : ${QEMU_SRC}${NC}"; exit 1; }
            echo -e "  ${YELLOW}[combiné] fake_trx partagé @ ${TRX_BIND}:${TRX_BASE_PORT}${NC}"
            echo -e "  ${YELLOW}           contrat : QEMU_ATTACH_TRX/NO_LOCAL_BTS/NO_LOCAL_TRX${NC}"
            cd "$QEMU_SRC"
            exec env \
                QEMU_ATTACH_TRX=1 NO_LOCAL_BTS=1 NO_LOCAL_TRX=1 \
                TRX_REMOTE="$TRX_BIND" TRX_BASE_PORT="$TRX_BASE_PORT" \
                ./start-clean.sh
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════
# Mode multi-opérateurs SS7 (ex-bridge) via ip netns
# ══════════════════════════════════════════════════════════════════════════
run_multi_op() {
    local n_operators=$N_OPERATORS ms=$MS_PER_OP i
    [ "$n_operators" -ge 1 ] || { echo -e "${RED}N_OPERATORS invalide${NC}"; exit 1; }
    detect_host_ip
    ensure_tun
    echo -e "${GREEN}Multi-op SS7 natif : ${CYAN}${n_operators} op × ${ms} MS${NC} (netns)${NC}"
    echo -e "  IP hôte : ${CYAN}${HOST_IP}${NC}"

    setup_bridge
    NETNS="" start_inter_stp "$n_operators"   # inter-STP sur l'hôte (bridge .10)

    for i in $(seq 1 "$n_operators"); do
        local nsn cip gw bb
        nsn=$(op_netns "$i"); cip=$(op_private_ip "$i")
        gw=$(op_private_gw "$i"); bb=$(op_backbone_ip "$i")
        echo -e "${CYAN}── Op${i} (backbone ${bb}, privé ${cip}) ──${NC}"
        ns_create "$i"

        # Configs dans /etc/netns/<ns>/etc/... → vu comme /etc dans le netns
        local nsroot="/etc/netns/${nsn}"; mkdir -p "$nsroot"
        local tmpdir; tmpdir=$(mktemp -d)
        apply_config_templates "$tmpdir" "$cip" "$gw" "$i" \
            "1.${i}.1" "1.${i}.2" "1.${i}.3" "001" "$(printf '%02d' "$i")" "OsmoOP${i}" \
            "$INTER_STP_IP" "no shutdown" "$n_operators"
        install_configs_native "$tmpdir" "$nsroot"
        rm -rf "$tmpdir"

        NETNS="$nsn" PHY_MODE="faketrx" RUN_NO_PROCESS=1 N_MS="$ms" \
            start_core_native "$i" "$cip" "$gw"
        NETNS="$nsn" feed_hlr "$i" "001" "$(printf '%02d' "$i")" "$ms"
        echo ""
    done

    echo -e "${GREEN}${BOLD}Stack multi-op prête (${n_operators} netns).${NC}"
    echo -e "  Accès VTY op i : ${CYAN}ip netns exec $(op_netns N) <client> 127.0.0.1:42xx${NC}"
    echo -e "  Stop           : ${CYAN}./start-direct.sh stop${NC}"
}

# ── Stop : process natifs + netns + bridge ──────────────────────────────────
stop_all() {
    echo -e "${YELLOW}Arrêt natif...${NC}"
    if [ -d "$RUN_DIR" ]; then
        local pidf
        for pidf in "$RUN_DIR"/*.pid; do [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true; done
    fi
    local nsn
    for nsn in $(ip netns list 2>/dev/null | awk '{print $1}' | grep '^osmo-op'); do
        ip netns pids "$nsn" 2>/dev/null | xargs -r kill 2>/dev/null || true
    done
    pkill -f 'osmo-stp|osmo-hlr|osmo-msc|osmo-mgw|osmo-bsc|osmo-bts|trxcon|fake_trx|virtphy|osmo-trx|mobile' 2>/dev/null || true
    pkill -f 'qemu-system-arm' 2>/dev/null || true
    pkill -x asterisk 2>/dev/null || true
    ns_destroy_all
    ip addr del "${INTER_STP_IP}/24" dev "$IFACE" 2>/dev/null || true
    rm -rf "$RUN_DIR" /etc/netns/osmo-op* 2>/dev/null || true
    echo -e "${GREEN}Arrêté.${NC}"
}

# ── Menu whiptail (optionnel) ───────────────────────────────────────────────
choose_mode() {
    MODE=$(wt_menu "Mode" "Lancer en natif :" \
        "qemu"         "PoC QEMU Calypso (défaut)" \
        "faketrx"      "fake_trx + trxcon + mobile" \
        "virtphy"      "osmo-bts-virtual + virtphy" \
        "noproc"       "cœur seul (configs + HLR)" \
        "faketrx-qemu" "COMBINÉ : fake_trx vivant + Calypso QEMU" \
        "hw"           "SDR physique (net-host)" \
        "virtual"      "Multi-opérateurs SS7 (netns)") || { echo "Annulé."; exit 1; }
    if [ "$MODE" = "virtual" ]; then
        N_OPERATORS=$(wt_input "Multi-op" "Nombre d'opérateurs (1-36) :" "$N_OPERATORS") || exit 1
        MS_PER_OP=$(wt_input "Multi-op" "MS par opérateur :" "$MS_PER_OP") || exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════
banner
[ "${1:-}" = "stop" ] && { stop_all; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis${NC}"; exit 1; }
# arg positionnel = mode
[ -n "${1:-}" ] && MODE="$1"
[ "${OSMO_MENU:-0}" = "1" ] && { command -v whiptail >/dev/null || { echo "whiptail requis pour OSMO_MENU"; exit 1; }; choose_mode; }

mkdir -p "$RUN_DIR"
[ -x ./helpers/prepare_host.sh ] && ./helpers/prepare_host.sh || true

case "$MODE" in
    qemu|faketrx|virtphy|noproc|faketrx-qemu|hw) run_single_op "$MODE" ;;
    virtual)                                     run_multi_op ;;
    *) echo -e "${RED}Mode inconnu : ${MODE}${NC}"
       echo "  modes : qemu faketrx virtphy noproc faketrx-qemu hw virtual"; exit 1 ;;
esac
