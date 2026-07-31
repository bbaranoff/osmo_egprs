# =============================================================================
#  lib/gabarits.sh — le moteur de gabarits de configuration d'osmo_egprs
# =============================================================================
#
#  CE FICHIER EST UNE EXTRACTION, PAS UNE RÉÉCRITURE.
#  Les fonctions ci-dessous viennent telles quelles de start-direct.sh.legacy
#  (L65-76, L106-258, L499-511). Elles n'ont pas été retouchées : le jour où
#  un gabarit change, on veut pouvoir comparer ligne à ligne avec l'ancien.
#
#  POURQUOI LES SORTIR DU POINT D'ENTRÉE.
#  Elles sont la SEULE chose que start-direct.sh faisait et que personne
#  d'autre ne fait : substituer __ENCRYPTION__, __MCC__, __KI__, __ARFCN__ …
#  dans configs/*.cfg puis les déposer dans /etc/osmocom, /etc/asterisk et
#  ~/.osmocom/bb. Sans elles, les démons du cœur démarrent sur les fichiers
#  qu'un run précédent a laissés — et `ENCRYPTION=a5 1` n'a aucun effet, en
#  silence. Le reste de start-direct.sh (lancer vingt processus) est repris
#  par le moteur ; ceci ne l'est pas, donc on le préserve à l'identique et on
#  le rend appelable depuis un module.
#
#  CE FICHIER NE FAIT RIEN AU SOURCE : il ne définit que des fonctions.
#  Le seul appelant attendu est run_modules/08-gabarits.sh.
#
#  DÉPENDANCES D'ENVIRONNEMENT (posées par l'appelant, valeurs de l'ancien
#  script en défaut) : ENCRYPTION, HOST_IP, ALSA_OUTPUT, ALSA_INPUT.
#  Le répertoire courant doit être celui d'osmo_egprs : les fonctions lisent
#  `configs/*.cfg` et `scripts/*` en chemin RELATIF, comme dans l'original.
# -----------------------------------------------------------------------------

: "${ENCRYPTION:=a5 0}"
: "${HOST_IP:=127.0.0.1}"
: "${ALSA_OUTPUT:=default}"
: "${ALSA_INPUT:=default}"

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
        # Préfixe à CINQ chiffres : la maquette numérote les abonnés i0001,
        # i0002… (MS#1 = 10001, MS#2 = 10002). Sans lui, aucun préfixe ne
        # couvrait ces numéros et le relais rejetait tout SMS local avec
        # « No route for destination ». Constaté le 2026-07-29.
        printf '%s000 = %s\n' "$i" "$i"
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
