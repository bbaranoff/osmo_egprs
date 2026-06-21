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
# qemu-src migré dans osmo_egprs : on lance run.sh/start-clean.sh/calypso.env du dossier
# courant ($HERE). Fallback /opt/GSM/qemu-src si start-clean.sh absent ici.
QEMU_SRC="${QEMU_SRC:-$HERE}"; [ -f "$QEMU_SRC/start-clean.sh" ] || QEMU_SRC="/opt/GSM/qemu-src"
ENCRYPTION="${ENCRYPTION:-a5 0}"
RUN_DIR="${RUN_DIR:-/run/osmo-direct}"
LOG_DIR="${LOG_DIR:-/var/log/osmocom}"
N_OPERATORS="${N_OPERATORS:-2}"
MS_PER_OP="${MS_PER_OP:-8}"
MS_COUNT="${MS_COUNT:-1}"          # MS (abonnés HLR) en mono-op core
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
    for s in entrypoint.sh osmo-start.sh status.sh run.sh gapk-start.sh \
             smsc-start.sh pulse-gsm-setup.sh sms-interop-relay.py send-mt-sms.sh; do
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
        PULSE_SERVER="${PULSE_SERVER:-}" \
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
          ki=$(printf '00112233445566778899aabbccdd%02x%02x' "$m" "$op_id")
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

# ── SMS bridge natif : régénère sms-routing.conf + proto-smsc-daemon + relay ──
# Factorisé depuis l'ancien bloc inline du mode hybride. $1=op_id $2=n_ms.
#   • régénère /etc/osmocom/sms-routing.conf via scripts/sms-routing-setup.sh
#     (routes EXACTES op*10000+ms → opX + [local] complet : sendmt_socket, hlr_vty) ;
#   • backup l'ancien conf dans RUN_DIR (restauré par cleanup_procs) ;
#   • (re)lance scripts/smsc-start.sh → proto-smsc-daemon (MO log + sendmt socket)
#     + sms-interop-relay.py (TCP 7890). Non-fatal, gated sur proto-smsc-daemon.
# Utilisé par le mode hybride ET les modes cœur (faketrx/noproc/virtphy/hw).
# NB multi-op (netns) : NON appelé ici — /tmp/sendmt_socket + relay:7890 sont
#     partagés (pas d'isolation /tmp entre netns) → collision. Cf. run_multi_op.
setup_sms_bridge() {
    local op_id="${1:-1}" n_ms="${2:-1}"
    local sms_setup="$HERE/scripts/sms-routing-setup.sh"
    local sms_conf="/etc/osmocom/sms-routing.conf" sms_bak="${RUN_DIR}/sms-routing.conf.backup"
    if ! command -v proto-smsc-daemon >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[sms] proto-smsc-daemon absent — bridge SMS non lancé${NC}"; return 0
    fi
    if [ -f "$sms_setup" ]; then
        { [ -f "$sms_conf" ] && [ ! -f "$sms_bak" ] && cp -f "$sms_conf" "$sms_bak"; } || true
        local sms_tmp; sms_tmp=$(mktemp -d)
        # sms_routing_generate <op_id> <n_ops> <destdir> [ms_counts...] → op_id, n_ops=1, ms=n_ms
        ( set +eu; . "$sms_setup" >/dev/null 2>&1; sms_routing_generate "$op_id" 1 "$sms_tmp" "$n_ms" >/dev/null 2>&1 ) || true
        if [ -f "$sms_tmp/sms-routing-op${op_id}.conf" ]; then
            cp -f "$sms_tmp/sms-routing-op${op_id}.conf" "$sms_conf"
            echo -e "  ${GREEN}[sms] sms-routing.conf régénéré (op${op_id}, ${n_ms} MS, [local] complet)${NC}"
        else
            echo -e "  ${YELLOW}[sms] génération sms-routing.conf échouée — conf existant conservé${NC}"
        fi
        rm -rf "$sms_tmp"
    fi
    pkill -f 'proto-smsc-daemon' 2>/dev/null || true   # purge doublons résiduels
    local smsc_sh="/etc/osmocom/smsc-start.sh"; [ -x "$smsc_sh" ] || smsc_sh="$HERE/scripts/smsc-start.sh"
    if [ -x "$smsc_sh" ]; then
        echo -e "  ${GREEN}[sms] proto-smsc-daemon + sms-interop-relay (smsc-start.sh)${NC}"
        setsid env OPERATOR_ID="$op_id" HLR_IP=127.0.0.2 bash "$smsc_sh" \
            > "${LOG_DIR}/smsc-op${op_id}.log" 2>&1 < /dev/null &
        echo $! > "${RUN_DIR}/smsc-op${op_id}.pid"
        echo -e "  ${CYAN}[sms] MT local : scripts/send-mt-sms.sh <imsi> 'msg'  |  MO log : ${LOG_DIR}/mo-sms-op${op_id}.log${NC}"
    else
        echo -e "  ${YELLOW}[sms] smsc-start.sh introuvable — SMS indispo${NC}"
    fi
}

detect_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1) || true
    [ -z "$HOST_IP" ] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    HOST_IP="${HOST_IP:-127.0.0.1}"
}

# ── Auto-attach tmux ────────────────────────────────────────────────────────
# run.sh tourne en arrière-plan et crée la session tmux 'osmocom'
# (socket /tmp/osmocom_tmux). On attend qu'elle soit prête (run.sh terminé)
# puis on s'y attache dans le terminal courant. $1 = log run.sh à surveiller.
#   AUTO_ATTACH=0   → désactive (reste en arrière-plan, message manuel)
#   Désactivé aussi si pas de TTY (scripté/bg) ou déjà dans un tmux.
auto_attach_tmux() {
    local runlog="$1" sock="/tmp/osmocom_tmux" sess="osmocom"
    if [ "${AUTO_ATTACH:-1}" != "1" ] || [ ! -t 1 ] || [ -n "${TMUX:-}" ]; then
        echo -e "  ${CYAN}Attach    :${NC} tmux -S ${sock} attach -t ${sess}"
        return 0
    fi
    echo -ne "  ${GREEN}[*] Attente session tmux ${sess}${NC}"
    local r=90
    while [ $r -gt 0 ]; do
        grep -q 'run.sh terminé' "$runlog" 2>/dev/null && break
        [ -S "$sock" ] && tmux -S "$sock" has-session -t "$sess" 2>/dev/null \
            && grep -qE 'RUN_NO_PROCESS=1|no-process' "$runlog" 2>/dev/null && break
        echo -n "."; sleep 1; ((r--)) || true
    done
    echo
    if [ -S "$sock" ] && tmux -S "$sock" has-session -t "$sess" 2>/dev/null; then
        echo -e "  ${GREEN}[*] Attache à tmux (Ctrl-b d pour détacher, stack reste up)${NC}"
        exec tmux -S "$sock" attach -t "$sess"
    fi
    echo -e "  ${YELLOW}tmux pas prêt — attache manuelle : tmux -S ${sock} attach -t ${sess}${NC}"
}

# ── PulseAudio natif ────────────────────────────────────────────────────────
# La chaîne audio (asound.conf gsm_out → sink null gsm_audio → monitor →
# loopback → carte) repose sur un démon PulseAudio. En conteneur le socket de
# l'hôte était monté ; en natif on lance nous-mêmes un démon système (root) et
# on exporte PULSE_SERVER pour run.sh / gapk / pactl.
#   AUDIO=0 → désactive toute la mise en place audio.
PULSE_SOCK="/var/run/pulse/native"
# FIFO live I/Q du shunt DSP : DOIT exister avant l'init QEMU, sinon le shunt
# (stat/S_ISFIFO dans calypso_dsp_shunt.c) la voit absente -> crée un fichier
# régulier à la place. Chemin = CALYPSO_SHUNT_IQ_CFILE (calypso.env), défaut
# /dev/shm/dsp_iq.fifo. mkfifo idempotent ; on ne touche pas un fichier régulier
# préexistant (rejeu .cfile) -> on ne crée la FIFO que si le chemin est libre ou
# déjà une FIFO.
ensure_iq_fifo() {
    # Chemin = CALYPSO_SHUNT_IQ_CFILE. Pas dans notre env (posé par start-clean.sh
    # via calypso.env) -> on le relit depuis le calypso.env qui SERA sourcé, pour
    # rester en phase avec QEMU. Défaut /dev/shm/dsp_iq.fifo.
    local f="${CALYPSO_SHUNT_IQ_CFILE:-}"
    if [ -z "$f" ] && [ -f "$QEMU_SRC/calypso.env" ]; then
        f=$(sed -n 's/^[[:space:]]*CALYPSO_SHUNT_IQ_CFILE=\([^[:space:]#]*\).*/\1/p' "$QEMU_SRC/calypso.env" | tail -n1)
    fi
    [ -n "$f" ] || f="/dev/shm/dsp_iq.fifo"
    if [ -e "$f" ] && [ ! -p "$f" ]; then
        echo -e "  ${YELLOW}[dsp-shunt] $f existe et n'est PAS une FIFO — laissé tel quel${NC}"
        return 0
    fi
    [ -p "$f" ] && return 0
    if mkfifo -m 0666 "$f" 2>/dev/null; then
        echo -e "  ${GREEN}[dsp-shunt] FIFO live I/Q créée : $f${NC}"
    fi
}

ensure_pulse() {
    [ "${AUDIO:-1}" = "1" ] || { echo -e "  ${YELLOW}[audio] désactivé (AUDIO=0)${NC}"; return 0; }

    # 0. Mapping ALSA gsm_out/gsm_in → sink PulseAudio gsm_audio (REQUIS côté hôte
    #    en mode natif). Sans /etc/asound.conf, le `mobile` (io-handler gapk,
    #    alsa-output-dev gsm_out) ouvre un PCM ALSA inexistant → "Unknown PCM
    #    gsm_out" → l'audio TCH n'est jamais décodé vers gsm_audio → silence
    #    navigateur. Le sink seul ne suffit pas : ce mapping doit exister.
    if [ -f "$HERE/configs/asound.conf" ] && ! cmp -s "$HERE/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        cp -f "$HERE/configs/asound.conf" /etc/asound.conf \
            && echo -e "  ${GREEN}[audio] /etc/asound.conf déployé (ALSA gsm_out/gsm_in → pulse gsm_audio)${NC}"
    fi

    export PULSE_SERVER="unix:${PULSE_SOCK}"
    if pactl info >/dev/null 2>&1; then
        # PulseAudio déjà actif (service osmo-pulse au boot, ou un 'fake' solo
        # précédent). Le sink gsm_audio n'est PAS forcément chargé dans CE démon
        # -> on le (re)charge à la volée s'il manque. SANS ça : l'audio ne marchait
        # qu'après un 'fake' solo (qui avait posé le sink) — c'est le maillon qui
        # manquait à fake+qemu pour avoir l'audio de lui-même.
        pactl list short sinks 2>/dev/null | grep -q gsm_audio || \
            pactl load-module module-null-sink sink_name=gsm_audio \
                format=s16le rate=8000 channels=1 \
                sink_properties=device.description=GSM_Audio >/dev/null 2>&1 || true
        # Dédoublonnage : sur une PipeWire/Pulse PARTAGÉE entre containers, chaque
        # ensure_pulse charge son propre module-null-sink gsm_audio → doublons.
        # parec (flux /audio du dashboard) lit alors le monitor d'un sink que gapk
        # n'alimente PAS → audio muet pour les clients distants (navigateur/Windows ;
        # en local l'hôte entend via le module-loopback vers ses enceintes, d'où
        # « ça marche sur Linux mais pas sur Windows »). On garde UN seul gsm_audio
        # (le 1er module) et on décharge les suivants.
        pactl list short modules 2>/dev/null \
            | awk '/module-null-sink/ && /sink_name=gsm_audio/ {print $1}' \
            | tail -n +2 \
            | while read -r _m; do [ -n "$_m" ] && pactl unload-module "$_m" >/dev/null 2>&1 \
                && echo -e "  ${YELLOW}[audio] sink gsm_audio en double déchargé (module $_m)${NC}"; done
        echo -e "  ${GREEN}[audio] PulseAudio déjà actif (sink gsm_audio unique assuré)${NC}"; return 0
    fi

    # 1. Installer pulseaudio si absent (le binaire démon, pas que les clients)
    if ! command -v pulseaudio >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "  ${YELLOW}[audio] installation pulseaudio...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                pulseaudio pulseaudio-utils alsa-utils >/dev/null 2>&1 || true
        fi
    fi
    command -v pulseaudio >/dev/null 2>&1 || {
        echo -e "  ${YELLOW}[audio] pulseaudio indisponible — audio ignoré${NC}"; return 0; }

    # 2. Config system.pa : accès anonyme + sink null gsm_audio (idempotent)
    local sp=/etc/pulse/system.pa
    if [ -f "$sp" ]; then
        grep -q 'auth-anonymous=1' "$sp" || sed -i \
            's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' "$sp"
        grep -q 'sink_name=gsm_audio' "$sp" || \
            echo 'load-module module-null-sink sink_name=gsm_audio format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Audio' >> "$sp"
    fi

    # 3. Démarrer le démon système
    mkdir -p /var/run/pulse "$LOG_DIR"
    # Repartir propre : un démon résiduel (lancé avant le patch system.pa, ou un
    # doublon) tourne sans auth-anonymous → 'pactl' = "Access denied" et un
    # nouveau démon refuse de démarrer ("Daemon already running"). On ne tue
    # QUE si pactl est injoignable (on est déjà dans cette branche), donc un
    # démon sain n'est jamais touché (early-return plus haut).
    if pgrep -x pulseaudio >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[audio] démon PulseAudio résiduel/injoignable — redémarrage propre${NC}"
        pkill -x pulseaudio 2>/dev/null || true
        local _k=10; while pgrep -x pulseaudio >/dev/null 2>&1 && [ $_k -gt 0 ]; do sleep 0.3; ((_k--)) || true; done
        pkill -9 -x pulseaudio 2>/dev/null || true
    fi
    rm -f /var/run/pulse/pid /var/run/pulse/native 2>/dev/null || true
    pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 \
        --log-target="file:${LOG_DIR}/pulse-system.log" >/dev/null 2>&1 || true
    local r=10
    while [ $r -gt 0 ]; do pactl info >/dev/null 2>&1 && break; sleep 1; ((r--)) || true; done
    if pactl info >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] PulseAudio prêt (sink gsm_audio) @ ${PULSE_SOCK}${NC}"
    else
        echo -e "  ${YELLOW}[audio] PulseAudio injoignable — audio dégradé${NC}"
    fi
}

# ── Bridge audio : osmo-gapk auto (chemin réseau MGW RTP → sink gsm_audio) ────
# gapk auto poll le VTY OsmoMGW (4243) et bridge le RTP de CHAQUE appel vers
# alsa://gsm_out (= sink null PulseAudio gsm_audio). C'est ce maillon qui rend
# l'audio des appels "réseau" (ex: 600 = echo-test Asterisk via MGW) audible
# dans le dashboard web : server.js capte gsm_audio.monitor → /audio (MP3).
# Lancé en session tmux DÉTACHÉE 'gapk' : survit aux 'exec' (start-clean.sh /
# tmux attach) des modes qemu/hybride et poll jusqu'à ce que le MGW soit up.
# Idempotent (relance la session), non-fatal. AUDIO=0 → désactivé.
ensure_gapk() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    command -v tmux      >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] tmux absent — bridge audio non lancé${NC}"; return 0; }
    command -v osmo-gapk >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] osmo-gapk absent — bridge audio non lancé${NC}"; return 0; }
    ensure_pulse   # gapk écrit dans alsa://gsm_out = sink gsm_audio (idempotent)
    local gapk_sh="/etc/osmocom/gapk-start.sh"; [ -x "$gapk_sh" ] || gapk_sh="$HERE/scripts/gapk-start.sh"
    [ -x "$gapk_sh" ] || { echo -e "  ${YELLOW}[gapk] gapk-start.sh introuvable — bridge audio non lancé${NC}"; return 0; }
    tmux kill-session -t gapk 2>/dev/null || true
    tmux new-session -d -s gapk \
        "GAPK_ALSA_DEV=gsm_out PULSE_SERVER=unix:${PULSE_SOCK} bash '$gapk_sh' auto gsmfr gsm_out 2>&1 | tee ${LOG_DIR}/gapk-auto.log"
    echo -e "  ${GREEN}[gapk] auto lancé (RTP MGW → sink gsm_audio) — tmux 'gapk', log ${LOG_DIR}/gapk-auto.log${NC}"
}

# ══════════════════════════════════════════════════════════════════════════
# Modes 1 opérateur (host loopback + enp0s3) : noproc/faketrx/virtphy/qemu/combiné
# ══════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════
# Mode HYBRIDE faketrx-qemu (Approche C) : 2 osmo-bts-trx, 1 cœur
#   BTS#0 = pipeline QEMU INTOUCHÉ (run.sh : osmo-trx-ipc 5700, ARFCN 514, Calypso)
#   BTS#1 = side-car : osmo-bts-trx (unit-id 6002, base-port 5820/5720) + fake_trx
#           (-P 5720 -p 6720) + trxcon + mobile osmocom-bb (ARFCN 516, IMSI ...0002)
#   Les 2 MS s'enregistrent sur le même osmo-bsc/MSC/HLR → appel intra-MSC.
#   1 BTS = 1 horloge (clk_s par process osmo-bts-trx) → pas de conflit d'horloge :
#   une seule osmo-bts-trx 2-PHY est IMPOSSIBLE (clk_s partagé, reset ping-pong),
#   d'où 2 process distincts. On NE TOUCHE NI qemu-src/run.sh NI osmo-bts-trx.cfg.
# ══════════════════════════════════════════════════════════════════════════
build_hybrid_tmux() {
    command -v tmux >/dev/null 2>&1 || { echo -e "  ${YELLOW}[tmux] tmux absent${NC}"; return 0; }
    ( set +e
      S=hybrid
      tmux kill-session -t "$S" 2>/dev/null
      tmux new-session -d -s "$S" -n faketrx-all "bash -c 'tail -F ${LOG_DIR}/bts1.log'"
      tmux split-window -t "$S:faketrx-all" -h "bash -c 'tail -F ${LOG_DIR}/faketrx-bts1.log'"
      tmux split-window -t "$S:faketrx-all" -v "bash -c 'tail -F ${LOG_DIR}/trxcon-bts1.log'"
      tmux select-pane  -t "$S:faketrx-all.0"
      tmux split-window -t "$S:faketrx-all" -v "bash -c 'tail -F ${LOG_DIR}/mobile-bts1.log'"
      tmux select-layout -t "$S:faketrx-all" tiled
      if tmux has-session -t calypso 2>/dev/null \
          && tmux list-windows -t calypso -F '#W' 2>/dev/null | grep -qx all; then
          tmux link-window -a -s calypso:all -t "$S:faketrx-all" \
              || tmux new-window -t "$S" -n qemu-all "bash -c 'tail -F ${LOG_DIR}/run-op1.log'"
      else
          tmux new-window -t "$S" -n qemu-all "bash -c 'tail -F ${LOG_DIR}/run-op1.log'"
      fi
      tmux new-window -t "$S" -n mobile1 "bash -c 'until (exec 3<>/dev/tcp/127.0.0.1/4247) 2>/dev/null; do sleep 1; done; exec telnet 127.0.0.1 4247'"
      tmux new-window -t "$S" -n mobile2 "bash -c 'until (exec 3<>/dev/tcp/127.0.0.1/4248) 2>/dev/null; do sleep 1; done; exec telnet 127.0.0.1 4248'"
      tmux new-window -t "$S" -n asterisk "bash -c 'rm -f /var/lib/asterisk/astdb.sqlite3 2>/dev/null; exec asterisk -cvvvvvvvvvvvvvv'"
      if tmux has-session -t calypso 2>/dev/null && tmux list-windows -t calypso -F '#W' 2>/dev/null | grep -qx mobile; then
          tmux link-window -a -s calypso:mobile -t "$S:mobile2" \
              || tmux new-window -t "$S" -n app-qemu "bash -c 'tail -F ${LOG_DIR}/run-op1.log'"
      else
          tmux new-window -t "$S" -n app-qemu "bash -c 'tail -F ${LOG_DIR}/run-op1.log'"
      fi
      tmux new-window -t "$S" -n app-faketrx "bash -c 'tail -F ${LOG_DIR}/mobile-bts1.log'"
      tmux select-window -t "$S:mobile2"
    ) || true
}

handle_faketrx_qemu() {
    local bsc_cfg="/etc/osmocom/osmo-bsc.cfg"
    local bsc_bak="${RUN_DIR}/osmo-bsc.cfg.backup"
    local bts1_cfg="/etc/osmocom/osmo-bts-trx-bts1.cfg"
    local bts1_block="${RUN_DIR}/bts1.block"
    local ms2_cfg="/root/.osmocom/bb/mobile_faketrx_bts1.cfg"
    local faketrx_py="/opt/GSM/osmocom-bb/src/target/trx_toolkit/fake_trx.py"
    local bts_port=5720 bb_port=6720 l2sock="/tmp/ms2_l2"
    local r

    [ -d "$QEMU_SRC" ] || { echo -e "${RED}qemu-src introuvable : ${QEMU_SRC}${NC}"; return 1; }
    mkdir -p "$RUN_DIR" "$LOG_DIR" /root/.osmocom/bb
    echo -e "  ${CYAN}[faketrx-qemu] Approche C : BTS#0 QEMU (5700/ARFCN514) + BTS#1 faketrx (5720/ARFCN516)${NC}"

    # ── (0) Audio : MÊME init que le mode faketrx, AVANT de lancer le moindre MS ──
    #   faketrx : install_configs_native déploie /etc/asound.conf (mapping ALSA
    #   gsm_out/gsm_in → sink pulse gsm_audio) ET pose ALSA_OUTPUT/INPUT=gsm_out/gsm_in,
    #   puis ensure_pulse démarre le démon + le sink ; le mobile hérite via start_core_native.
    #   En hybride, mobile MS#2 est lancé EN DIRECT (étape l) : sans ce même init préalable
    #   son gapk ouvre 'default' → la voix TCH ne passe pas par gsm_audio (silence). Le bypass
    #   "faketrx d'abord" ne faisait QUE pré-poser cet état. Placé AVANT (e) → le pipeline
    #   QEMU (MS#1) trouve aussi asound.conf+pulse prêts.
    if [ -f "$HERE/configs/asound.conf" ]; then
        cp -f "$HERE/configs/asound.conf" /etc/asound.conf
        ALSA_OUTPUT="gsm_out"; ALSA_INPUT="gsm_in"
    fi
    ensure_pulse   # démon système + sink gsm_audio + export PULSE_SERVER (idempotent)

    # ── (a) cfg dédiée du 2e osmo-bts-trx (VTY 4250, CTRL 127.0.0.2:4239, base-port 5820/5720) ──
    cat > "$bts1_cfg" <<'BTS1CFG'
!
! OsmoBTS BTS#1 (side-car faketrx) — généré par start-direct.sh (mode faketrx-qemu)
! NE PAS confondre avec /etc/osmocom/osmo-bts-trx.cfg (= BTS#0 QEMU, INTOUCHÉ).
!
log stderr
 logging color 1
 logging print category-hex 0
 logging print category 1
 logging timestamp 0
 logging print file basename last
 logging print level 1
!
log gsmtap 172.20.1.1
 logging filter all 1
 logging color 0
 logging timestamp 0
 logging print category 1
 logging print level 1
 logging level rsl info
 logging level oml info
 logging level rr notice
 logging level trx notice
 logging level abis debug
!
vty telnet-port 4250
!
ctrl
 bind 127.0.0.2 4239
!
line vty
 no login
!
e1_input
 e1_line 0 driver ipa
 e1_line 0 port 0
 no e1_line 0 keepalive
!
phy 0
 instance 0
  osmotrx rx-gain 40
  osmotrx tx-attenuation 50
 osmotrx ip local 127.0.0.1
 osmotrx ip remote 127.0.0.1
 osmotrx base-port local 5820
 osmotrx base-port remote 5720
!
bts 0
 band DCS1800
 ipa unit-id 6002 0
 oml remote-ip 127.0.0.1
 pcu-socket /tmp/pcu_bts2
 rtp jitter-buffer 100
 paging queue-size 200
 paging lifetime 0
 min-qual-rach 50
 min-qual-norm -5
 gsmtap-sapi ccch
 gsmtap-sapi pdtch
 trx 0
  power-ramp max-initial 23000 mdBm
  power-ramp step-size 2000 mdB
  power-ramp step-interval 1
  ms-power-control osmo
  phy 0 instance 0
BTS1CFG

    # ── (b) bloc 'bts 1' à insérer dans osmo-bsc.cfg (unit-id 6002, ARFCN 516, même LAC) ──
    cat > "$bts1_block" <<'BTS1BLOCK'
 bts 1
  type osmo-bts
  band DCS1800
  cell_identity 6002
  location_area_code 0x0001
  base_station_id_code 8
  ms max power 15
  cell reselection hysteresis 4
  rxlev access min 0
  radio-link-timeout 32
  channel allocator mode chan-req ascending
  channel allocator mode assignment ascending
  channel allocator mode handover ascending
  rach tx integer 9
  rach max transmission 7
  ipa unit-id 6002 0
  oml ipa stream-id 255 line 0
  neighbor-list mode automatic
  codec-support fr
  gprs mode none
  trx 0
   rf_locked 0
   arfcn 516
   nominal power 23
   max_power_red 0
   rsl e1 tei 0
   timeslot 0
    phys_chan_config CCCH+SDCCH4
    hopping enabled 0
   timeslot 1
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 2
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 3
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 4
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 5
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 6
    phys_chan_config TCH/F
    hopping enabled 0
   timeslot 7
    phys_chan_config TCH/F
    hopping enabled 0
BTS1BLOCK

    # ── (c) backup osmo-bsc.cfg + insertion idempotente du bloc bts1 (avant 'msc 0') ──
    if [ -f "$bsc_cfg" ] && [ ! -f "$bsc_bak" ]; then
        cp -f "$bsc_cfg" "$bsc_bak"
        echo -e "  ${GREEN}[faketrx-qemu] backup osmo-bsc.cfg → ${bsc_bak}${NC}"
    fi
    if grep -qE '^[[:space:]]*ipa unit-id 6002 0' "$bsc_cfg" 2>/dev/null; then
        echo -e "  ${CYAN}[faketrx-qemu] bloc bts 1 déjà présent — skip${NC}"
    elif grep -qE '^msc 0' "$bsc_cfg" 2>/dev/null; then
        local _bsc_new
        _bsc_new=$(awk -v blk="$bts1_block" '
            /^msc 0/ && !ins { while ((getline line < blk) > 0) print line; ins=1 }
            { print }
        ' "$bsc_cfg") && printf '%s\n' "$_bsc_new" > "$bsc_cfg"
        echo -e "  ${GREEN}[faketrx-qemu] bloc 'bts 1' (unit-id 6002 0, ARFCN 516) ajouté à osmo-bsc.cfg${NC}"
    else
        echo -e "  ${YELLOW}[faketrx-qemu] 'msc 0' introuvable — bts1 non inséré dans osmo-bsc.cfg${NC}"
    fi

    # ── (d) cfg mobile MS#2 (VTY 4248, socket /tmp/ms2_l2 HORS glob, ARFCN 516, IMSI ...0002) ──
    local ms2_src="/opt/GSM/qemu-src/cfgs/mobile_group1.cfg"
    [ -f "$ms2_src" ] || ms2_src="/root/.osmocom/bb/mobile_group1.cfg"
    sed -e 's|bind 127.0.0.1 4247|bind 127.0.0.1 4248|' \
        -e 's|layer2-socket /tmp/osmocom_l2[_0-9]*|layer2-socket /tmp/ms2_l2|' \
        -e 's|sap-socket /tmp/osmocom_sap_1|sap-socket /tmp/ms2_sap|' \
        -e 's|stick 514|stick 516|' \
        -e 's|imsi 001010001000001|imsi 001010001000002|' \
        -e 's|ki comp128 00 11 22 33 44 55 66 77 88 99 aa bb cc dd 01 01|ki comp128 00 11 22 33 44 55 66 77 88 99 aa bb cc dd 02 01|' \
        "$ms2_src" > "$ms2_cfg"
    echo -e "  ${GREEN}[faketrx-qemu] cfg mobile MS#2 → ${ms2_cfg}${NC}"

    # ── (e) pipeline QEMU (BTS#0) en arrière-plan via start-clean.sh ──
    ensure_iq_fifo   # FIFO live I/Q avant l'init QEMU (sinon shunt -> fichier régulier)
    echo -e "  ${YELLOW}[faketrx-qemu] lancement pipeline QEMU (BTS#0) en arrière-plan${NC}"
    ( cd "$QEMU_SRC" && setsid env CALYPSO_NO_ATTACH=1 CALYPSO_ICOUNT=off CALYPSO_AUTO_GEN_DOC=0 \
        CALYPSO_L2_CLIENT=mobile \
        bash ./start-clean.sh > "${LOG_DIR}/run-op1.log" 2>&1 < /dev/null & echo $! > "${RUN_DIR}/qemu-sidecar.pid" )

    # ── (f) barrière : transceiver BTS#0 prêt (osmo-trx-ipc TRXD udp/5700) ──
    echo -ne "  ${GREEN}[faketrx-qemu] attente BTS#0 TRXD udp/5700${NC}"
    r=120
    while [ "$r" -gt 0 ]; do
        ss -uan 2>/dev/null | grep -qE ':5700($|[^0-9])' && break
        echo -n "."; sleep 1; r=$((r-1))
    done
    [ "$r" -gt 0 ] && echo -e " ${GREEN}✓${NC}" || echo -e " ${YELLOW}(timeout, on continue)${NC}"

    # ── (g+h) Feed HLR « comme start.sh » sur les 2 MS (attente 4258 + create/msisdn/ki) ──
    #     feed_hlr = portage natif EXACT du feed start.sh. op=1, ms∈{1,2} :
    #       IMSI 001010001000001 (MS#1 QEMU) / 001010001000002 (MS#2 faketrx)
    #       msisdn 10001 / 10002   ki …0101 / …0201 (aud2g comp128v1)
    #     'create' sur MS#1 (déjà créé par run.sh) = idempotent ; update réaligne.
    feed_hlr 1 "001" "01" 2 || true

    # ── (i) fake_trx (BTS#1) : DOIT être up AVANT osmo-bts-trx (qui poll le POWERON) ──
    echo -e "  ${GREEN}[faketrx-qemu] fake_trx BTS#1 (-P ${bts_port} -p ${bb_port})${NC}"
    setsid python3 "$faketrx_py" -b 127.0.0.1 -R 127.0.0.1 -r 127.0.0.1 -P "$bts_port" -p "$bb_port" \
        > "${LOG_DIR}/faketrx-bts1.log" 2>&1 < /dev/null &
    echo $! > "${RUN_DIR}/faketrx-bts1.pid"
    echo -ne "  ${GREEN}[faketrx-qemu] attente fake_trx udp/${bts_port}${NC}"
    r=20
    while [ "$r" -gt 0 ]; do
        ss -uan 2>/dev/null | grep -qE ":${bts_port}($|[^0-9])" && break
        kill -0 "$(cat "${RUN_DIR}/faketrx-bts1.pid")" 2>/dev/null \
            || { echo -e " ${RED}fake_trx mort${NC}"; tail -20 "${LOG_DIR}/faketrx-bts1.log" 2>/dev/null; return 1; }
        echo -n "."; sleep 1; r=$((r-1))
    done
    echo -e " ${GREEN}✓${NC}"

    # ── (j) 2e osmo-bts-trx (cfg dédiée, unit-id 6002, base-port 5820/5720) ──
    echo -e "  ${GREEN}[faketrx-qemu] osmo-bts-trx BTS#1 (cfg ${bts1_cfg})${NC}"
    #   Durci contre le race "No clock since TRX was started" : osmo-bts-trx peut
    #   mourir QUELQUES secondes après le start si fake_trx ne fournit pas l'horloge
    #   à temps. On exige une fenêtre de stabilité ; si mort (No clock / shutdown),
    #   on relance jusqu'à BTS1_RETRIES fois.
    bts1_try=0
    while :; do
        bts1_try=$((bts1_try+1))
        setsid osmo-bts-trx -c "$bts1_cfg" > "${LOG_DIR}/bts1.log" 2>&1 < /dev/null &
        echo $! > "${RUN_DIR}/bts1.pid"
        stab="${BTS1_STAB_SECS:-8}"; dead=0
        while [ "$stab" -gt 0 ]; do
            kill -0 "$(cat "${RUN_DIR}/bts1.pid")" 2>/dev/null || { dead=1; break; }
            grep -qE "No clock since TRX|BTS_SHUTDOWN.*Shutting down" "${LOG_DIR}/bts1.log" 2>/dev/null && { dead=1; break; }
            sleep 1; stab=$((stab-1))
        done
        if [ "$dead" -eq 0 ]; then
            echo -e "  ${GREEN}[faketrx-qemu] osmo-bts-trx BTS#1 stable (essai ${bts1_try})${NC}"
            break
        fi
        kill "$(cat "${RUN_DIR}/bts1.pid")" 2>/dev/null
        if [ "$bts1_try" -ge "${BTS1_RETRIES:-3}" ]; then
            echo -e "  ${RED}[faketrx-qemu] osmo-bts-trx BTS#1 KO après ${bts1_try} essais (race No clock)${NC}"
            tail -20 "${LOG_DIR}/bts1.log" 2>/dev/null; return 1
        fi
        echo -e "  ${YELLOW}[faketrx-qemu] osmo-bts-trx BTS#1 mort (No clock) — retry ${bts1_try}/${BTS1_RETRIES:-3}${NC}"
        sleep 1
    done

    # ── (k) trxcon (flags-only : PAS de 'ue2', PAS de -R/-r) ──
    echo -e "  ${GREEN}[faketrx-qemu] trxcon (-p ${bb_port} -s ${l2sock})${NC}"
    setsid trxcon -i 127.0.0.1 -b 127.0.0.1 -p "$bb_port" -s "$l2sock" -C 1 -F 100 \
        > "${LOG_DIR}/trxcon-bts1.log" 2>&1 < /dev/null &
    echo $! > "${RUN_DIR}/trxcon-bts1.pid"

    # ── (l) mobile MS#2 (après le socket L1CTL) — MÊMES variables audio que faketrx ──
    echo -ne "  ${GREEN}[faketrx-qemu] attente L1CTL ${l2sock}${NC}"
    r=30
    while [ ! -S "$l2sock" ] && [ "$r" -gt 0 ]; do echo -n "."; sleep 1; r=$((r-1)); done
    [ -S "$l2sock" ] && echo -e " ${GREEN}✓${NC}" || echo -e " ${YELLOW}(absent, on tente)${NC}"
    echo -e "  ${GREEN}[faketrx-qemu] mobile MS#2 (cfg ${ms2_cfg})${NC}"
    setsid env \
        ALSA_OUTPUT="$ALSA_OUTPUT" ALSA_INPUT="$ALSA_INPUT" \
        ALSA_CARD=gsm_out GAPK_ALSA_DEV=gsm_out \
        PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_SOCK}}" \
        mobile -c "$ms2_cfg" > "${LOG_DIR}/mobile-bts1.log" 2>&1 < /dev/null &
    echo $! > "${RUN_DIR}/mobile-bts1.pid"

    # ── (m) SMS bridge : régénère routes + proto-smsc-daemon + relay (op1, 2 MS) ──
    setup_sms_bridge 1 2

    echo ""
    echo -e "${GREEN}${BOLD}[faketrx-qemu] BTS#0 (QEMU Calypso) + BTS#1 (faketrx) prêts.${NC}"
    echo -e "  MS#1 QEMU    : IMSI 001010001000001  msisdn 10001  ARFCN 514  unit-id 6001"
    echo -e "  MS#2 faketrx : IMSI 001010001000002  msisdn 10002  ARFCN 516  unit-id 6002"
    echo -e "  Appel/SMS intra-MSC : MS#1→10002, MS#2→10001 (ex: 'sms 1 10001 hi', 'call 1 10001')."
    echo -e "  Logs : ${CYAN}${LOG_DIR}/{run-op1,bts1,faketrx-bts1,trxcon-bts1,mobile-bts1,smsc-op1}.log${NC}"
    echo -e "  Stop : ${CYAN}./start-direct.sh stop${NC}"

    ensure_gapk   # bridge audio MGW RTP → sink gsm_audio (avant l'exec tmux attach)

    build_hybrid_tmux
    if [ -t 1 ] && [ -z "${TMUX:-}" ] && [ "${AUTO_ATTACH:-1}" = "1" ]; then
        echo -e "  ${GREEN}[faketrx-qemu] attache tmux 'hybrid' (Ctrl-b d = détacher, stack reste up)${NC}"
        exec tmux attach -t hybrid
    fi
    echo -e "  ${CYAN}Attach : tmux attach -t hybrid${NC}"
}

run_single_op() {
    local mode=$1
    local op_id=1 mcc="001" mnc="01" op_name="OsmoDirect"
    local cip gw; cip=$(op_private_ip "$op_id"); gw=$(op_private_gw "$op_id")
    NETNS=""; N_MS="${MS_COUNT:-1}"
    detect_host_ip
    ensure_tun

    # PAS d'inter-STP en mono-op : il route le M3UA ENTRE opérateurs. Avec 1 op,
    # l'STP local (lancé par run.sh/osmo-start.sh) suffit ; un inter-STP entre en
    # collision (même VTY 4239 / m3ua sur loopback). L'ASP asp-to-inter du cœur
    # est mis 'shutdown' pour éviter les connect-fail vers un inter-STP absent.

    # SELF_CONTAINED : le pipeline qemu-src/run.sh fait DÉJÀ tout (osmo-start.sh
    # = cœur complet + feed HLR + radio). On ne lance NI cœur, NI HLR, NI inter-STP
    # ici, sinon double-cœur + collision STP. On passe juste la main.
    local self_contained=0 post="none"
    case "$mode" in
        noproc)        PHY_MODE="faketrx"; RUN_NO_PROCESS=1; post="none" ;;
        faketrx)       PHY_MODE="faketrx"; RUN_NO_PROCESS=0; post="none" ;;
        virtphy)       PHY_MODE="virtphy"; RUN_NO_PROCESS=0; post="none" ;;
        qemu)          self_contained=1; post="qemu" ;;
        faketrx-qemu)  handle_faketrx_qemu; return ;;   # Approche C : 2 osmo-bts-trx
        hw)            PHY_MODE="${PHY_MODE:-trx}"; RUN_NO_PROCESS=0; post="none" ;;
        *) echo -e "${RED}Mode inconnu : ${mode}${NC}"; exit 1 ;;
    esac
    INTER_STP_IP="127.0.0.1"   # mono-op : pas de backbone inter-op
    echo -e "  ${CYAN}[${mode}] self_contained=${self_contained} enc='${ENCRYPTION}'${NC}"
    echo -e "  IP hôte : ${CYAN}${HOST_IP}${NC}"

    # ── Modes qemu : passthrough pur vers le pipeline auto-suffisant ────────
    if [ "$self_contained" = "1" ]; then
        [ -d "$QEMU_SRC" ] || { echo -e "${RED}qemu-src introuvable : ${QEMU_SRC}${NC}"; exit 1; }
        ensure_gapk   # bridge audio MGW RTP → sink gsm_audio (avant l'exec start-clean.sh)
        ensure_iq_fifo   # FIFO live I/Q avant l'init QEMU (sinon shunt -> fichier régulier)
        echo -e "  ${YELLOW}[$mode] pipeline auto-suffisant : osmo-start.sh + HLR + radio gérés par qemu-src/run.sh${NC}"
        echo -e "  ${CYAN}[*] exec qemu-src/start-clean.sh (terminal courant)${NC}"
        cd "$QEMU_SRC"
        if [ "$post" = "qemu-attach" ]; then
            echo -e "  ${YELLOW}[combiné] fake_trx partagé @ ${TRX_BIND}:${TRX_BASE_PORT}${NC}"
            echo -e "  ${YELLOW}           contrat : QEMU_ATTACH_TRX/NO_LOCAL_BTS/NO_LOCAL_TRX${NC}"
            exec env \
                QEMU_ATTACH_TRX=1 NO_LOCAL_BTS=1 NO_LOCAL_TRX=1 \
                TRX_REMOTE="$TRX_BIND" TRX_BASE_PORT="$TRX_BASE_PORT" \
                ./start-clean.sh
        fi
        exec ./start-clean.sh
    fi

    # ── Modes cœur osmo_egprs (noproc/faketrx/virtphy/hw) ──────────────────
    echo -e "  ${CYAN}PHY=${PHY_MODE} no_process=${RUN_NO_PROCESS}${NC}"
    local tmpdir; tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" "$cip" "$gw" "$op_id" \
        "1.1.1" "1.1.2" "1.1.3" "$mcc" "$mnc" "$op_name" \
        "$INTER_STP_IP" "shutdown" "1"
    install_configs_native "$tmpdir" ""
    rm -rf "$tmpdir"

    ensure_pulse   # PulseAudio natif + export PULSE_SERVER (propagé à run.sh)
    start_core_native "$op_id" "$cip" "$gw"
    ensure_gapk    # bridge audio MGW RTP → sink gsm_audio (MGW up depuis start_core_native)
    feed_hlr "$op_id" "$mcc" "$mnc" "$N_MS"
    setup_sms_bridge "$op_id" "$N_MS"   # proto-smsc-daemon + sms-interop-relay (SMS local/MT)

    echo ""
    echo -e "${GREEN}${BOLD}Cœur prêt (natif) — ${N_MS} MS.${NC}"
    echo -e "  HLR VTY   @ ${CYAN}127.0.0.1:4258${NC}   BB VTY @ ${CYAN}127.0.0.1:4247${NC}"
    echo -e "  Linphone  @ ${CYAN}${HOST_IP}:$(linphone_sip_port "$op_id")${NC}"
    echo -e "  Logs      @ ${CYAN}${LOG_DIR}/run-op1.log${NC}"
    echo -e "  SMS       : ${CYAN}scripts/send-mt-sms.sh <imsi> 'msg'${NC}  (MO log ${LOG_DIR}/mo-sms-op${op_id}.log)"
    echo -e "${GREEN}Processus en arrière-plan. './start-direct.sh stop' pour tout arrêter.${NC}"

    auto_attach_tmux "${LOG_DIR}/run-op${op_id}.log"
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
        # NB : SMS bridge NON lancé par op en netns — /tmp/sendmt_socket + relay:7890
        # sont partagés (pas d'isolation /tmp) → collision. À traiter via netns /tmp
        # dédié (mount) ou ports relay distincts si besoin du SMS inter-op natif.
        echo ""
    done

    echo -e "${GREEN}${BOLD}Stack multi-op prête (${n_operators} netns).${NC}"
    echo -e "  Accès VTY op i : ${CYAN}ip netns exec $(op_netns N) <client> 127.0.0.1:42xx${NC}"
    echo -e "  Stop           : ${CYAN}./start-direct.sh stop${NC}"
}

# ── Nettoyage des process : systemd + natifs + netns + bridge ───────────────
cleanup_procs() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc \
            osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector osmo-bts-trx osmo-egprs-web 2>/dev/null || true
    fi
    if [ -d "$RUN_DIR" ]; then
        local pidf
        for pidf in "$RUN_DIR"/*.pid; do [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true; done
    fi
    local nsn
    for nsn in $(ip netns list 2>/dev/null | awk '{print $1}' | grep '^osmo-op'); do
        ip netns pids "$nsn" 2>/dev/null | xargs -r kill 2>/dev/null || true
    done
    pkill -f 'osmo-stp|osmo-hlr|osmo-msc|osmo-mgw|osmo-bsc|osmo-bts|osmo-ggsn|osmo-sgsn|osmo-sip-connector|osmo-pcu|osmo-gbproxy|osmo-hnbgw|osmo-trx|osmocon|trxcon|fake_trx|virtphy|mobile|gapk|sms-interop-relay|proto-smsc-daemon' 2>/dev/null || true
    pkill -f 'qemu-system-arm' 2>/dev/null || true
    pkill -f 'fft-web/fft_web.py' 2>/dev/null || true
    pkill -x asterisk 2>/dev/null || true
    # ── Stop explicite (demandé) : service osmo-bts-trx + tout python3 + osmo-bts-trx ──
    # python3 = fake_trx.py / bridges / fft_web : on les tue en bloc pour repartir
    # d'un état propre (les pkill -f ciblés au-dessus peuvent en laisser traîner).
    command -v systemctl >/dev/null 2>&1 && systemctl stop osmo-bts-trx 2>/dev/null || true
    pkill osmo-bts-trx 2>/dev/null || true
    pkill python3      2>/dev/null || true
    command -v tmux >/dev/null 2>&1 && { tmux kill-session -t calypso 2>/dev/null; tmux kill-session -t hybrid 2>/dev/null; tmux kill-session -t gapk 2>/dev/null; } || true
    ns_destroy_all
    ip addr del "${INTER_STP_IP}/24" dev "$IFACE" 2>/dev/null || true
    # ── [faketrx-qemu] restore osmo-bsc.cfg + purge artefacts BTS#1 (AVANT rm RUN_DIR) ──
    if [ -f "${RUN_DIR}/osmo-bsc.cfg.backup" ]; then
        cp -f "${RUN_DIR}/osmo-bsc.cfg.backup" /etc/osmocom/osmo-bsc.cfg 2>/dev/null \
            && echo -e "  ${GREEN}[cleanup] osmo-bsc.cfg restauré depuis backup${NC}" || true
    fi
    if [ -f "${RUN_DIR}/sms-routing.conf.backup" ]; then
        cp -f "${RUN_DIR}/sms-routing.conf.backup" /etc/osmocom/sms-routing.conf 2>/dev/null || true
    fi
    rm -f /tmp/ms2_l2 /tmp/ms2_sap /tmp/pcu_bts2 /tmp/sendmt_socket \
          /etc/osmocom/osmo-bts-trx-bts1.cfg /root/.osmocom/bb/mobile_faketrx_bts1.cfg 2>/dev/null || true
    rm -rf "$RUN_DIR" /etc/netns/osmo-op* 2>/dev/null || true
}

# ── Stop : process natifs + netns + bridge ──────────────────────────────────
stop_all() {
    echo -e "${YELLOW}Arrêt natif...${NC}"
    cleanup_procs
    echo -e "${GREEN}Arrêté.${NC}"
}

# ── Pré-démarrage : nettoyage résiduel + (re)lancement du cœur ──────────────
pre_start() {
    if [ "${NO_CLEAN:-0}" != "1" ]; then
        echo -e "${YELLOW}[pre-start] Nettoyage des process résiduels...${NC}"
        cleanup_procs
    fi
    if [ "${NO_OSMO_START:-0}" != "1" ] && [ -x /etc/osmocom/osmo-start.sh ]; then
        echo -e "${GREEN}[pre-start] /etc/osmocom/osmo-start.sh${NC}"
        OPERATOR_ID="${OPERATOR_ID:-1}" /etc/osmocom/osmo-start.sh || \
            echo -e "  ${YELLOW}[pre-start] osmo-start.sh a retourné une erreur (on continue)${NC}"
    fi
}

# ── Menu whiptail (optionnel) ───────────────────────────────────────────────
_validate_int() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

choose_mode() {
    export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
    case "${TERM:-}" in dumb|"") export TERM=xterm-256color ;; esac

    MODE=$(wt_menu "Mode" "Lancer en natif :" \
        "qemu"         "PoC QEMU Calypso (défaut)" \
        "faketrx"      "fake_trx + trxcon + mobile" \
        "virtphy"      "osmo-bts-virtual + virtphy" \
        "noproc"       "cœur seul (configs + HLR)" \
        "faketrx-qemu" "COMBINÉ : fake_trx vivant + Calypso QEMU" \
        "hw"           "SDR physique (net-host)" \
        "virtual"      "Multi-opérateurs SS7 (netns)") || { echo "Annulé."; exit 1; }

    case "$MODE" in
        virtual)
            N_OPERATORS=$(wt_input "Multi-op" "Nombre d'opérateurs (1-36) :" "$N_OPERATORS") || exit 1
            _validate_int "$N_OPERATORS" 1 36 || N_OPERATORS=2
            MS_PER_OP=$(wt_input "Multi-op" "MS par opérateur (1-64) :" "$MS_PER_OP") || exit 1
            _validate_int "$MS_PER_OP" 1 64 || MS_PER_OP=8
            ;;
        qemu|faketrx-qemu)
            : # pipeline auto-suffisant : le MS = le Calypso émulé, pas de prompt
            ;;
        *)  # noproc / faketrx / virtphy / hw : nombre d'abonnés HLR
            MS_COUNT=$(wt_input "MS" "Nombre de MS / abonnés HLR (1-64) :" "$MS_COUNT") || exit 1
            _validate_int "$MS_COUNT" 1 64 || MS_COUNT=1
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════
banner
[ "${1:-}" = "stop" ] && { stop_all; exit 0; }
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis${NC}"; exit 1; }

# Tout démarrage (sans argument 'stop') commence par un STOP complet, pour repartir
# d'un état propre — équivalent à './start-direct.sh stop' avant de lancer.
# NO_STARTUP_STOP=1 pour le désactiver. Comme le stop nettoie déjà tout, on passe
# NO_CLEAN=1 à pre_start pour éviter un double nettoyage.
if [ "${NO_STARTUP_STOP:-0}" != "1" ]; then
    echo -e "${YELLOW}[start] stop préalable (état propre)...${NC}"
    stop_all
    NO_CLEAN=1
fi

# Sélection du mode :
#   - arg positionnel (./start-direct.sh faketrx) → direct, sans menu
#   - NO_MENU=1 → utilise $MODE (défaut qemu), sans menu
#   - sinon → menu whiptail (mode + nombre de MS)
if [ -n "${1:-}" ]; then
    MODE="$1"
elif [ "${NO_MENU:-0}" = "1" ]; then
    :
elif command -v whiptail >/dev/null 2>&1; then
    choose_mode
else
    echo -e "${YELLOW}whiptail absent — fallback MODE=${MODE} (MS_COUNT=${MS_COUNT}). NO_MENU=1 pour masquer cet avertissement.${NC}"
fi

pre_start          # nettoyage des process résiduels + osmo-start.sh
mkdir -p "$RUN_DIR"
# prepare_host.sh = restart Linphone/Wireshark/docker via sudo (GUI/desktop) : ne le
# lancer QUE s'il peut réussir (sudo + docker + SUDO_USER), sinon il fait 'exit 1'
# avec un [FAIL] bruyant. Inutile en natif/headless → on le saute proprement.
if [ -x ./helpers/prepare_host.sh ] && command -v sudo >/dev/null 2>&1 \
        && command -v docker >/dev/null 2>&1 && [ -n "${SUDO_USER:-}" ]; then
    ./helpers/prepare_host.sh || true
else
    echo -e "${YELLOW}prepare_host.sh sauté (sudo/docker/SUDO_USER absent — non requis en natif).${NC}"
fi

# Dashboard web osmo-egprs-web : (re)démarré automatiquement (service systemd natif).
if command -v systemctl >/dev/null 2>&1 && systemctl cat osmo-egprs-web.service >/dev/null 2>&1; then
    systemctl restart osmo-egprs-web 2>/dev/null \
        && echo -e "  ${CYAN}[web] dashboard osmo-egprs-web démarré (http://<ip>:8080) — console + onglet FFT${NC}" || true
fi

# FFT (2 spectres MS/BTS depuis /dev/shm/*.cfile) — désormais NATIF dans le
# dashboard osmo-egprs-web : le calcul PSD Welch tourne en JS dans server.js et
# est servi sur /psd, affiché dans l'onglet « 📡 FFT ». Plus de serveur Python
# :8081 ni de dépendance numpy. On tue tout ancien fft_web.py résiduel.
pkill -f 'fft-web/fft_web.py' 2>/dev/null || true
rm -f "${RUN_DIR}/fft-web.pid" 2>/dev/null || true

case "$MODE" in
    qemu|faketrx|virtphy|noproc|faketrx-qemu|hw) run_single_op "$MODE" ;;
    virtual)                                     run_multi_op ;;
    *) echo -e "${RED}Mode inconnu : ${MODE}${NC}"
       echo "  modes : qemu faketrx virtphy noproc faketrx-qemu hw virtual"; exit 1 ;;
esac
