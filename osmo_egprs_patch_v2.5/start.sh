#!/bin/bash
# start.sh — Lance la stack Osmocom GSM multi-opérateurs
#
# Modes : net-host (1 opérateur, SDR physique) | bridge (N opérateurs SS7 inter-op)
#
# Topologie SS7 en mode bridge (exemple 3 opérateurs) :
#
#         ┌──────────── Inter-STP (PC 0.23.0) ──────────────┐
#         │  172.20.0.10:2908 (dynamic-permitted)            │
#         └─────────────────────────────────────────────────┘
#              ▲ RCTX 150    ▲ RCTX 250    ▲ RCTX 350
#   ┌──────────┴───┐  ┌──────┴───────┐  ┌──┴────────────┐
#   │ Op1:172.20.0.11│  │Op2:172.20.0.12│  │Op3:172.20.0.13│
#   │ STP 1.23.2    │  │ STP 2.23.2   │  │ STP 3.23.2   │
#   │ MSC 1.23.1    │  │ MSC 2.23.1   │  │ MSC 3.23.1   │
#   │ BSC 1.23.3    │  │ BSC 2.23.3   │  │ BSC 3.23.3   │
#   └───────────────┘  └──────────────┘  └──────────────┘
#
# Réseau backbone : gsm-inter (172.20.0.0/24)
# Réseau privé   : gsm-net-opN (172.20.N.0/24)
# Intra-container : 127.0.0.1 (MSC/BSC → STP local)
# Inter-container : 172.20.0.X (STP → inter-STP)

set -e

IMAGE_BASE="osmocom-nitb"
IMAGE_RUN="osmocom-run"

INTER_NET="gsm-inter"
INTER_NET_SUBNET="172.20.0.0/24"
INTER_NET_GATEWAY="172.20.0.1"

INTER_STP_CONTAINER="osmo-inter-stp"
INTER_STP_IP="172.20.0.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── SMS Routing — chargement du module dédié ───────────────────────────────────
SMS_ROUTING_SCRIPT="$(dirname "$0")/scripts/sms-routing-setup.sh"
if [ -f "$SMS_ROUTING_SCRIPT" ]; then
    # shellcheck source=scripts/sms-routing-setup.sh
    source "$SMS_ROUTING_SCRIPT"
else
    echo -e "${YELLOW}[WARN] sms-routing-setup.sh introuvable — routing SMS basique${NC}" >&2
fi

# Répertoire global pour les configs SMS (initialisé dans start_bridge_mode /
# start_host_mode, utilisé par build_vol_args)
SMS_ROUTING_DIR=""

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

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Osmocom GSM/EGPRS Virtual Network            ║"
    echo "║        Multi-Operator SS7 + osmo-gapk Audio          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# ALSA — construit les arguments Docker pour le passthrough audio
# ══════════════════════════════════════════════════════════════════════════════
build_alsa_args() {
    local alsa_args=""
    local alsa_card="${ALSA_CARD:-default}"
    local target_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

    if [ -d /dev/snd ]; then
        alsa_args="--device /dev/snd"
        if getent group audio &>/dev/null; then
            alsa_args="${alsa_args} --group-add $(getent group audio | cut -d: -f3)"
        fi
        echo -e "  ALSA      : ${GREEN}/dev/snd passthrough${NC}  (carte: ${CYAN}${alsa_card}${NC})" >&2
    else
        echo -e "  ALSA      : ${YELLOW}absent${NC} (gapk en mode RTP/fichier uniquement)" >&2
    fi

    local asoundrc="/home/${target_user}/.asoundrc"
    if [ -f "$asoundrc" ]; then
        alsa_args="${alsa_args} -v ${asoundrc}:/root/.asoundrc:ro"
    fi

    local pulse_socket="/run/user/$(id -u "${target_user}" 2>/dev/null || echo 1000)/pulse/native"
    if [ -S "$pulse_socket" ]; then
        alsa_args="${alsa_args} -v ${pulse_socket}:${pulse_socket}"
        alsa_args="${alsa_args} -e PULSE_SERVER=unix:${pulse_socket}"
        echo -e "  PulseAudio: ${GREEN}socket disponible${NC}" >&2
    fi

    alsa_args="${alsa_args} -e ALSA_CARD=${alsa_card} -e GAPK_ALSA_DEV=${alsa_card}"
    echo "$alsa_args"
}

# ══════════════════════════════════════════════════════════════════════════════
# Build
# ══════════════════════════════════════════════════════════════════════════════
build_run_image() {
    echo -e "${GREEN}Build de l'image run (Dockerfile.run)...${NC}"
    docker build -f Dockerfile.run -t "$IMAGE_RUN" .
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

; ── Trunk inter-op → Opérateur ${remote_op} (${remote_ip}) ──────────────────────────────
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
rewrite_contact=yes
from_user=interop_op${op_id}

[interop_trunk_op${remote_op}]
type=aor
contact=sip:${remote_ip}:5060
qualify_frequency=15
qualify_timeout=5.0
EOF
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Génération dynamique — contexte [interop_out] du dialplan Asterisk
# ══════════════════════════════════════════════════════════════════════════════
generate_extensions_interop_out() {
    local op_id=$1
    local n_operators=$2

    cat <<'EOF'
; =============================================================================
; [interop_out] — Sortie vers un opérateur distant (SIP trunk inter-op)
; =============================================================================
[interop_out]

EOF

    for remote_op in $(seq 1 "$n_operators"); do
        [ "$remote_op" -eq "$op_id" ] && continue
        cat <<EOF
; → Opérateur ${remote_op}
exten => _${remote_op}XXXX,1,NoOp(=== INTEROP OUT Op${remote_op}: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@interop_trunk_op${remote_op},,rT)
 same => n,NoOp(Échec inter-op: \${DIALSTATUS})
 same => n,Congestion()
 same => n,Hangup()

EOF
    done

    cat <<'EOF'
; Destination inconnue → congestion
exten => _X.,1,NoOp(=== INTEROP OUT: destination inconnue ${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# Génération dynamique — sms-routing.conf
#
# Délégué à scripts/sms-routing-setup.sh (sms_routing_generate_all).
# Cette fonction de secours est utilisée uniquement si le module est absent.
# ══════════════════════════════════════════════════════════════════════════════
_generate_sms_routing_conf_fallback() {
    local op_id=$1 n_operators=$2
    echo -e "  ${YELLOW}[SMS] Fallback basique op${op_id} (sms-routing-setup.sh absent)${NC}" >&2
    printf '# sms-routing.conf — Fallback (routes courtes)\n\n[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n[operators]\n' \
        "$op_id" "$op_id"
    for i in $(seq 1 "$n_operators"); do
        printf '%s = %s\n' "$i" "$(op_backbone_ip "$i")"
    done
    printf '\n[routes]\n'
    for i in $(seq 1 "$n_operators"); do
        printf '%s0000 = %s\n' "$i" "$i"
        for j in 001 002 003 004 005; do printf '%s%s = %s\n' "$i" "$j" "$i"; done
        printf '336%s0 = %s\n\n' "$i" "$i"
    done
    printf '[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
}

# ══════════════════════════════════════════════════════════════════════════════
# Substitution des placeholders
#
# Paramètres :
#   $1  dest           Répertoire de sortie temporaire
#   $2  container_ip   IP privée (172.20.N.10)
#   $3  gateway_ip     Passerelle réseau privé (172.20.N.1)
#   $4  op_id          Identifiant opérateur (1…N)
#   $5  pc_msc         Point code MSC (N.23.1)
#   $6  pc_stp         Point code STP (N.23.2)
#   $7  pc_bsc         Point code BSC (N.23.3)
#   $8  mcc            Mobile Country Code (ex: 001)
#   $9  mnc            Mobile Network Code (ex: 01)
#   $10 op_name        Nom opérateur
#   $11 inter_stp      IP inter-STP (172.20.0.10 en bridge)
#   $12 inter_stp_shutdown  "no shutdown" ou "shutdown"
#   $13 n_operators    Nombre total d'opérateurs
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

    for f in configs/*.cfg; do
        [ "$(basename "$f")" = "osmo-stp-interop.cfg" ] && continue
        cp "$f" "$dest/osmocom/"
    done

    for f in configs/*.conf; do
        local bn
        bn=$(basename "$f")
        [ "$bn" = "sms-routing.conf" ] && continue
        cp "$f" "$dest/asterisk/"
    done

    for s in entrypoint.sh osmo-start.sh status.sh run.sh gapk-start.sh; do
        [ -f "scripts/$s" ] && cp "scripts/$s" "$dest/osmocom/$s" && chmod +x "$dest/osmocom/$s"
    done

    if [ -f "configs/mobile.cfg.template" ]; then
        cp "configs/mobile.cfg.template" "$dest/bb/mobile.cfg"
    elif [ -f "configs/mobile.cfg" ]; then
        cp "configs/mobile.cfg" "$dest/bb/mobile.cfg"
    fi

    local rctx_msc rctx_stp rctx_bsc rctx_inter
    rctx_msc=$(op_rctx_msc "$op_id")
    rctx_stp=$(op_rctx_stp "$op_id")
    rctx_bsc=$(op_rctx_bsc "$op_id")
    rctx_inter=$(op_rctx_inter "$op_id")

    local arfcn=$(( 512 + op_id * 2 ))
    local ipa_unit_id=$(( 6000 + op_id ))
    local cell_id=$(( 6000 + op_id ))
    local bsic=$(( 60 + op_id ))
    local bvci=$(( op_id * 10 + 2 ))
    local nsei=$(( op_id * 10 ))
    local nsvci=$(( op_id * 10 ))
    local imsi="${mcc}${mnc}$(printf '%010d' "${op_id}")"
    local imei="3589250059$(printf '%04d' "${op_id}")0"
    local ki="00 11 22 33 44 55 66 77 88 99 aa bb cc dd $(printf '%02x' "${op_id}") ff"
    local sms_sc="+336661234$(printf '%04d' "${op_id}")"
    local inter_local_ip
    inter_local_ip=$(op_backbone_ip "$op_id")

    for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf "$dest/bb"/*.cfg; do
        [ -f "$f" ] || continue
        sed -i \
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
            "$f"
    done

    generate_pjsip_interop_trunks "$op_id" "$n_operators" \
        >> "$dest/asterisk/pjsip.conf"

    generate_extensions_interop_out "$op_id" "$n_operators" \
        >> "$dest/asterisk/extensions.conf"

    # ── SMS Routing ─────────────────────────────────────────────────────────
    # Si sms_routing_generate (module externe) est disponible ET que
    # SMS_ROUTING_DIR est défini, la config a déjà été générée globalement :
    # on la copie simplement dans le tmpdir de cet opérateur.
    # Sinon : fallback inline basique.
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
# Inter-STP — hub SS7 central
# ══════════════════════════════════════════════════════════════════════════════
start_inter_stp() {
    local n_operators=$1
    local tmpdir
    tmpdir=$(mktemp -d)
    local inter_cfg="${tmpdir}/osmo-stp-interop.cfg"

    echo -e "${GREEN}Génération config inter-STP (${n_operators} opérateurs)...${NC}"
    bash ./create_interop.sh "$n_operators" "$inter_cfg" > /dev/null

    if [ ! -f "$inter_cfg" ]; then
        echo -e "${RED}Échec génération config inter-STP${NC}"; exit 1
    fi

    echo -e "${GREEN}Lancement inter-STP @ ${INTER_STP_IP}:2908 (PC 0.23.0)...${NC}"
    docker rm -f "$INTER_STP_CONTAINER" &>/dev/null || true

    docker run -d \
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

# ══════════════════════════════════════════════════════════════════════════════
# [PATCH] wait_inter_stp_ready — Attendre que l'inter-STP soit prêt
#
# osmo-stp démarre rapidement (~1-2s). On attend 15s pour être sûr.
# ══════════════════════════════════════════════════════════════════════════════
wait_inter_stp_ready() {
    local n_operators=$1
    
    echo -ne "${GREEN}[*] Vérification stabilisation inter-STP (routes SS7)${NC}"
    
    # osmo-stp crée les routes rapidement
    # Attendre 15s pour stabilisation complète
    for i in {1..15}; do
        sleep 1
        echo -n "."
    done
    
    echo -e " ${GREEN}✓${NC}"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Démarrage d'un opérateur
#
# Paramètres :
#   $1  op_id
#   $2  mcc
#   $3  mnc
#   $4  op_name
#   $5  n_operators   Nombre total d'opérateurs
#   $6  n_ms          Nombre de Mobile Stations pour cet opérateur (défaut: 1)
# ══════════════════════════════════════════════════════════════════════════════
start_operator() {
    local op_id=$1 mcc=$2 mnc=$3 op_name=$4 n_operators=$5 n_ms=${6:-1}
    local container_name net_name subnet gateway container_ip inter_local_ip

    container_name=$(op_container "$op_id")
    net_name="gsm-net-op${op_id}"
    subnet=$(op_private_net "$op_id")
    gateway=$(op_private_gw "$op_id")
    container_ip=$(op_private_ip "$op_id")
    inter_local_ip=$(op_backbone_ip "$op_id")
    local rctx_inter
    rctx_inter=$(op_rctx_inter "$op_id")

    echo -e "${CYAN}── Opérateur ${op_id} : ${op_name} (MCC=${mcc} MNC=${mnc}) ──${NC}"
    echo -e "  Backbone   : ${CYAN}${inter_local_ip}${NC}  Privé : ${CYAN}${container_ip}${NC}"
    echo -e "  STP PC     : ${op_id}.23.2  RCTX inter : ${rctx_inter}  MS : ${CYAN}${n_ms}${NC}"

    # Réseau privé par opérateur
    docker network inspect "$net_name" &>/dev/null || \
        docker network create --subnet="$subnet" --gateway="$gateway" "$net_name" &>/dev/null

    # Génération des configs
    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$container_ip" "$gateway" \
        "$op_id" "${op_id}.23.1" "${op_id}.23.2" "${op_id}.23.3" \
        "$mcc" "$mnc" "$op_name" \
        "$INTER_STP_IP" "no shutdown" \
        "$n_operators"

    local vol_args
    vol_args=$(build_vol_args "$tmpdir")
    local alsa_args
    alsa_args=$(build_alsa_args)

    docker rm -f "$container_name" &>/dev/null || true

    # shellcheck disable=SC2086
    docker run -d \
        --name "$container_name" \
        --network "$INTER_NET" \
        --ip "$inter_local_ip" \
        --cap-add NET_ADMIN \
        --cap-add SYS_ADMIN \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        $alsa_args \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -e OPERATOR_ID="$op_id" \
        -e N_MS="$n_ms" \
        -e CONTAINER_IP="$container_ip" \
        -e GATEWAY_IP="$gateway" \
        -e INTER_STP_IP="$INTER_STP_IP" \
        $vol_args \
        "$IMAGE_RUN" \
        /etc/osmocom/run.sh > /dev/null

    # Attacher le réseau privé (après démarrage — évite la race condition)
    docker network connect --ip "$container_ip" "$net_name" "$container_name"
    echo -e "  ${GREEN}✓${NC} ${container_name} démarré  (${n_ms} MS)"

    # Lancer l'orchestrateur tmux en background avec délai.
    #
    # /etc/osmocom/run.sh (CMD docker run) = boot systemd + services Osmocom.
    # /root/run.sh                         = orchestrateur tmux (notre script).
    # On attend 8s que systemd ait stabilisé les services Osmocom avant tmux.
    local _cname="$container_name"
    local _opid="$op_id"
    local _nms="$n_ms"
    (
        sleep 8
        docker exec -d "$_cname" bash -c \
            "OPERATOR_ID=${_opid} N_MS=${_nms} /root/run.sh \
             >> /var/log/osmocom/run-orchestrator.log 2>&1"
    ) &
}


# ══════════════════════════════════════════════════════════════════════════════
# Mode net-host (1 opérateur, SDR physique)
# ══════════════════════════════════════════════════════════════════════════════
start_host_mode() {
    echo -e "${GREEN}Démarrage en mode net-host (1 opérateur)...${NC}"

    local src_ip gw_ip
    gw_ip=$(ip route get 1 | awk '{print $3; exit}')
    src_ip=$(ip route get 1 | awk '{print $7; exit}')
    [ -z "$src_ip" ] && { echo -e "${RED}Impossible de détecter l'IP hôte.${NC}"; exit 1; }
    echo -e "  IP hôte : ${CYAN}${src_ip}${NC}  GW : ${CYAN}${gw_ip}${NC}"

    local n_ms
    read -rp "Nombre de MS [1] : " n_ms
    n_ms=${n_ms:-1}
    if ! [[ "$n_ms" =~ ^[0-9]+$ ]] || [ "$n_ms" -lt 1 ] || [ "$n_ms" -gt 9 ]; then
        echo -e "${YELLOW}Valeur invalide, forcée à 1${NC}"
        n_ms=1
    fi

    prepare_host_tun
    docker rm -f egprs &>/dev/null || true

    # ── Génération config SMS routing (mode host, 1 opérateur) ────────────
    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate > /dev/null 2>&1; then
        echo -e "${GREEN}Génération table SMS routing (1 op, ${n_ms} MS)...${NC}"
        sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$n_ms"
        sms_routing_summary  1 "$n_ms"
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    apply_config_templates "$tmpdir" \
        "$src_ip" "$gw_ip" \
        "1" "1.23.1" "1.23.2" "1.23.3" \
        "001" "01" "OsmoGSM" \
        "127.0.0.1" "shutdown" \
        "1"

    local vol_args
    vol_args=$(build_vol_args "$tmpdir")
    local alsa_args
    alsa_args=$(build_alsa_args)

    # shellcheck disable=SC2086
    docker run -d \
        --rm \
        --name egprs \
        --net host \
        --cap-add NET_ADMIN \
        --cap-add SYS_ADMIN \
        --cgroupns host \
        --device /dev/net/tun:/dev/net/tun \
        $alsa_args \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
        -e CONTAINER_IP="$src_ip" \
        -e GATEWAY_IP="$gw_ip" \
        -e OPERATOR_ID="1" \
        -e N_MS="$n_ms" \
        -e INTER_STP_IP="127.0.0.1" \
        $vol_args \
        "$IMAGE_RUN" \
        /etc/osmocom/run.sh > /dev/null

    echo -e "${GREEN}[*] Attente démarrage (5 s)...${NC}"
    sleep 5
    docker exec -it egprs /bin/bash -c "/root/run.sh"
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode bridge (N opérateurs avec inter-STP central)
# ══════════════════════════════════════════════════════════════════════════════
start_bridge_mode() {
    # ── Saisie du nombre d'opérateurs ──────────────────────────────────────
    local n_operators
    read -rp "Nombre d'opérateurs [2] : " n_operators
    n_operators=${n_operators:-2}
    if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 9 ]; then
        echo -e "${RED}Nombre invalide (1–9).${NC}"; exit 1
    fi

    # ── Saisie des paramètres par opérateur (MCC / MNC / Nom / MS count) ──
    declare -A OP_MCC OP_MNC OP_NAME OP_MS
    for i in $(seq 1 "$n_operators"); do
        echo -e "${CYAN}── Opérateur ${i} ──${NC}"
        read -rp "  MCC   [001]      : " mcc;  OP_MCC[$i]=${mcc:-001}
        read -rp "  MNC   [0${i}]     : " mnc;  OP_MNC[$i]=${mnc:-"0${i}"}
        read -rp "  Nom   [OsmoOP${i}]: " name; OP_NAME[$i]=${name:-"OsmoOP${i}"}
        read -rp "  MS    [1]         : " n_ms; OP_MS[$i]=${n_ms:-1}
        if ! [[ "${OP_MS[$i]}" =~ ^[0-9]+$ ]] || \
           [ "${OP_MS[$i]}" -lt 1 ] || [ "${OP_MS[$i]}" -gt 9 ]; then
            echo -e "  ${YELLOW}Nombre de MS invalide, forcé à 1${NC}"
            OP_MS[$i]=1
        fi
        echo -e "  → MCC=${OP_MCC[$i]}  MNC=${OP_MNC[$i]}  Nom=${OP_NAME[$i]}  MS=${CYAN}${OP_MS[$i]}${NC}"
    done

    # ── Réseau backbone partagé ────────────────────────────────────────────
    echo -e "${GREEN}Création du réseau backbone ${INTER_NET}...${NC}"
    docker network inspect "$INTER_NET" &>/dev/null || \
        docker network create \
            --subnet="$INTER_NET_SUBNET" \
            --gateway="$INTER_NET_GATEWAY" \
            "$INTER_NET" &>/dev/null

    # ── Génération des configs SMS routing (avant le démarrage des containers)
    # Construit un sms-routing-op<N>.conf par opérateur avec les routes exactes
    # par MSISDN (pas seulement des préfixes courts) et les méta-données relay.
    SMS_ROUTING_DIR=$(mktemp -d)
    if declare -f sms_routing_generate_all > /dev/null 2>&1; then
        echo -e "${GREEN}Génération tables SMS routing (${n_operators} ops)...${NC}"
        # Construire le tableau des MS counts dans l'ordre op1..opN
        local _ms_counts=()
        for i in $(seq 1 "$n_operators"); do
            _ms_counts+=("${OP_MS[$i]}")
        done
        sms_routing_generate_all "$n_operators" "$SMS_ROUTING_DIR" "${_ms_counts[@]}"
        #sms_routing_validate "${SMS_ROUTING_DIR}/sms-routing-op1.conf"
        sms_routing_summary  "$n_operators" "${_ms_counts[@]}"
    else
        echo -e "  ${YELLOW}[SMS] sms-routing-setup.sh non chargé — fallback basique${NC}"
    fi

    # ── Inter-STP — doit être UP avant les opérateurs ─────────────────────
    start_inter_stp "$n_operators"

    # [PATCH] Vérifier que l'inter-STP est vraiment prêt avant les opérateurs
    wait_inter_stp_ready "$n_operators"

    # ── Opérateurs ────────────────────────────────────────────────────────
    for i in $(seq 1 "$n_operators"); do
        start_operator "$i" \
            "${OP_MCC[$i]}" "${OP_MNC[$i]}" "${OP_NAME[$i]}" \
            "$n_operators" "${OP_MS[$i]}"
    done
    sudo bash hlr-feed-subscribers.sh

    # ── Attente relays SMS ─────────────────────────────────────────────────
    if declare -f sms_routing_wait_ready > /dev/null 2>&1; then
        echo -e "${GREEN}Vérification relays SMS (port 7890)...${NC}"
        for i in $(seq 1 "$n_operators"); do
            sms_routing_wait_ready "$(op_container "$i")" 90 || true
        done
    fi

    # ── Résumé ────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}Stack multi-opérateurs démarrée !${NC}"
    echo ""
    echo -e "  Inter-STP @ ${CYAN}${INTER_STP_IP}:2908${NC}  PC=0.23.0"
    for i in $(seq 1 "$n_operators"); do
        local rctx
        rctx=$(op_rctx_inter "$i")
        local bb_ip
        bb_ip=$(op_backbone_ip "$i")
        echo -e "  Op${i} ${OP_NAME[$i]}  STP ${i}.23.2 @ ${bb_ip}  ──RCTX ${rctx}──►  inter-STP  [MS: ${OP_MS[$i]}]"
    done
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
        echo -e "  Wireshark lancé sur ${CYAN}br-${bridge_if}${NC}"
    fi

    # ── Terminaux xterm ───────────────────────────────────────────────────
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
    DISPLAY="${DISPLAY:-:0}"
    XAUTHORITY="${XAUTHORITY:-/home/$TARGET_USER/.Xauthority}"

    # Ouvre un xterm à partir d'un script tmp → évite tout problème de quoting/
    # évaluation prématurée des variables (WAIT, etc.) dans les chaînes inline.
    _open_term_script() {
        local title="$1" script_file="$2"
        chmod +x "$script_file"
        DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
        xterm -title "$title" \
              -fa 'Monospace' -fs 10 \
              -bg '#1e1e1e' -fg '#d4d4d4' \
              -e bash "$script_file" \
        2>/dev/null &
        sleep 0.3
    }

    for i in $(seq 1 "$n_operators"); do
        local cname
        cname=$(op_container "$i")
        local tmpscript="/tmp/osmo-xterm-op${i}.sh"

        # Le heredoc écrit le script tel quel ; les variables du shell courant
        # (cname, OP_NAME, etc.) sont interpolées maintenant (sans $).
        # Les variables exécutées DANS xterm (WAIT) sont échappées avec \$.
        cat > "$tmpscript" << XTERM_SCRIPT

#!/bin/bash
echo "=== Op${i} — ${OP_NAME[$i]} (${OP_MS[$i]} MS) ==="
echo ""
echo "  STP  : sudo docker exec -it ${cname} telnet 127.0.0.1 4239"
echo "  MSC  : sudo docker exec -it ${cname} telnet 127.0.0.1 4254"
echo "  BSC  : sudo docker exec -it ${cname} telnet 127.0.0.1 4242"
echo "  HLR  : sudo docker exec -it ${cname} telnet 127.0.0.1 4258"
echo ""
echo "En attente de la session tmux (max 120s)..."
WAIT=0
until sudo docker exec ${cname} tmux has-session 2>/dev/null; do
    sleep 2
    WAIT=\$((WAIT + 2))
    if [ "\$WAIT" -ge 120 ]; then
        echo "TIMEOUT : tmux non disponible apres 120s."
        echo "Verifier : sudo docker logs ${cname}"
        break
    fi
    echo "  ... \${WAIT}s"
done
exec sudo docker exec -ti ${cname} tmux attach

XTERM_SCRIPT

        _open_term_script "Op${i} — ${OP_NAME[$i]}  [${OP_MS[$i]} MS]" "$tmpscript"
    done

    # Inter-STP
    local tmpscript_stp="/tmp/osmo-xterm-stp.sh"
    cat > "$tmpscript_stp" << XTERM_STP
#!/bin/bash
echo "=== Inter-STP 0.23.0 @ ${INTER_STP_IP}:2908 ==="
echo "  VTY : sudo docker exec -it ${INTER_STP_CONTAINER} telnet 127.0.0.1 4239"
echo ""
sleep 3
exec sudo docker exec -ti ${INTER_STP_CONTAINER} tmux attach -t stp
XTERM_STP

    _open_term_script "Inter-STP (PC 0.23.0)" "$tmpscript_stp"
}


# Arrêt
# ══════════════════════════════════════════════════════════════════════════════
stop_all() {
    echo -e "${YELLOW}Arrêt de tous les containers Osmocom...${NC}"
    docker ps -a --filter "name=osmo-" --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    docker ps -a --filter "name=egprs"  --format "{{.Names}}" | xargs -r docker rm -f 2>/dev/null || true
    echo -e "${GREEN}Arrêté.${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Mode réseau
# ══════════════════════════════════════════════════════════════════════════════
choose_network_mode() {
    echo -e "${BOLD}Mode réseau :${NC}"
    echo "  1) net-host  — SDR physique, 1 opérateur, accès direct au hardware"
    echo "  2) bridge    — Multi-opérateurs (N≥1), SS7 inter-op via inter-STP"
    echo ""
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
banner

[ "${1:-}" = "stop" ] && { stop_all; exit 0; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Doit être lancé en root (sudo).${NC}"; exit 1
fi

build_run_image
check_image
choose_network_mode
./prepare_host.sh

case "$NETWORK_MODE" in
    host)   start_host_mode ;;
    bridge) start_bridge_mode ;;
esac
