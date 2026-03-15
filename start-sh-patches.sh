#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# CORRECTIF start.sh — Linphone host IP + gapk l1phy + fix sed
#
# CE FICHIER N'EST PAS start.sh — c'est un guide de copier-coller.
# Chaque section indique OÙ coller le code dans start.sh.
#
# Le bug "sed: pas de fichier d'entrée" vient du patch précédent
# qui a cassé la continuation de ligne dans le bloc sed.
# ══════════════════════════════════════════════════════════════════════════════

# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 1 — HELPERS (après wan_rtp_end, ~ligne 35 de start.sh)
# │ COLLER APRÈS la ligne :  wan_rtp_end()   { echo ... }
# └─────────────────────────────────────────────────────────────────────────────

# Linphone SIP/RTP port per operator (host-side mapping)
# Op1 → :5060, Op2 → :5061, etc.
linphone_sip_port()  { echo $(( 5060 + ($1 - 1) )); }
linphone_rtp_start() { echo $(( 30000 + ($1 - 1) * 200 )); }
linphone_rtp_end()   { echo $(( 30000 + $1 * 200 - 1 )); }


# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 2 — REMPLACER LE BLOC SED COMPLET dans apply_config_templates()
# │
# │ CHERCHER :  for f in "$dest/osmocom"/*.cfg "$dest/asterisk"/*.conf
# │ REMPLACER TOUT le bloc (du 'for' au 'done') par ceci :
# └─────────────────────────────────────────────────────────────────────────────

    # ── rtp.conf (si présent) ─────────────────────────────────────────────
    if [ -f "configs/rtp.conf" ]; then
        cp "configs/rtp.conf" "$dest/asterisk/"
    fi

    # ── Calcul plage RTP pour cet opérateur ───────────────────────────────
    local rtp_start rtp_end
    rtp_start=$(( 30000 + (op_id - 1) * 200 ))
    rtp_end=$(( 30000 + op_id * 200 - 1 ))

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
            -e "s|__HOST_IP__|${HOST_IP:-127.0.0.1}|g" \
            -e "s|__SIP_HOST_PORT__|${SIP_HOST_PORT:-5060}|g" \
            -e "s|__ALSA_OUTPUT__|${ALSA_OUTPUT:-default}|g" \
            -e "s|__ALSA_INPUT__|${ALSA_INPUT:-default}|g" \
            -e "s|__RTP_START__|${rtp_start}|g" \
            -e "s|__RTP_END__|${rtp_end}|g" \
            "$f"
    done

# ─── FIN DU BLOC SED ─── (le reste de apply_config_templates continue normalement)


# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 3 — DÉTECTION IP HÔTE (dans start_bridge_mode)
# │
# │ COLLER AVANT la ligne :  # ── Démarrage séquentiel des opérateurs
# │ (c'est-à-dire APRÈS wait_inter_stp_ready et le bloc all_subscribers_file)
# └─────────────────────────────────────────────────────────────────────────────

    # ── Détection IP hôte pour Linphone ─────────────────────────────────
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
        | head -1) || true
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    HOST_IP="${HOST_IP:-127.0.0.1}"
    ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
    ALSA_INPUT="${ALSA_INPUT:-default}"
    echo -e "${GREEN}IP hôte : ${CYAN}${HOST_IP}${NC}  (Linphone: ${HOST_IP}:5060+)${NC}"
    echo ""


# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 4 — PORT EXPOSURE LINPHONE (dans la boucle opérateurs)
# │
# │ CHERCHER :  local port_args=""
# │ REMPLACER PAR tout le bloc ci-dessous (jusqu'au commentaire FIN)
# └─────────────────────────────────────────────────────────────────────────────

        local port_args=""

        # Linphone SIP/RTP — toujours exposé
        local lsip_port lrtp_s lrtp_e
        lsip_port=$(linphone_sip_port "$i")
        lrtp_s=$(linphone_rtp_start "$i")
        lrtp_e=$(linphone_rtp_end "$i")
        port_args="-p ${lsip_port}:5060/udp -p ${lrtp_s}-${lrtp_e}:${lrtp_s}-${lrtp_e}/udp"
        SIP_HOST_PORT="$lsip_port"
        echo -e "  Linphone   : ${CYAN}${HOST_IP}:${lsip_port}${NC}  RTP ${lrtp_s}-${lrtp_e}"

        # WAN ports (en plus, si activé)
        if [ "$WAN_ENABLED" = "true" ]; then
            local sip_port rtp_start rtp_end
            sip_port=$(wan_sip_port "$i")
            rtp_start=$(wan_rtp_start "$i")
            rtp_end=$(wan_rtp_end "$i")
            port_args="${port_args} -p ${sip_port}:5060/tcp -p ${rtp_start}-${rtp_end}:${rtp_start}-${rtp_end}/udp"
            echo -e "  WAN        : SIP ${sip_port} RTP ${rtp_start}-${rtp_end}"
        fi

# ─── FIN SECTION 4 ───


# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 5 — VARIABLES DOCKER (dans le docker run)
# │
# │ CHERCHER :  -e INTER_STP_IP="$INTER_STP_IP"
# │ AJOUTER JUSTE APRÈS (sur les lignes suivantes) :
# └─────────────────────────────────────────────────────────────────────────────

            -e HOST_IP="${HOST_IP}" \
            -e SIP_HOST_PORT="${SIP_HOST_PORT}" \
            -e ALSA_OUTPUT="${ALSA_OUTPUT}" \
            -e ALSA_INPUT="${ALSA_INPUT}" \


# ┌─────────────────────────────────────────────────────────────────────────────
# │ SECTION 6 — RÉSUMÉ LINPHONE (dans le résumé final)
# │
# │ CHERCHER :  if [ "$WAN_ENABLED" = "true" ]; then
# │ COLLER JUSTE AVANT cette ligne :
# └─────────────────────────────────────────────────────────────────────────────

    echo ""
    echo -e "  ${BOLD}Linphone (depuis l'hôte) :${NC}"
    for i in $(seq 1 "$n_operators"); do
        local lsip bb_ip
        lsip=$(linphone_sip_port "$i")
        bb_ip=$(op_backbone_ip "$i")
        echo -e "    Op${i}: ${CYAN}${HOST_IP}:${lsip}${NC} (ou direct ${bb_ip}:5060)"
    done
    echo -e "    Comptes : linphone_A / tester → 100  |  linphone_B / testerB → 200"
    echo -e "    Codecs  : GSM-FR, μ-law"


# ══════════════════════════════════════════════════════════════════════════════
# VÉRIFICATION — après édition, tester la syntaxe :
#   bash -n start.sh && echo "Syntaxe OK"
# ══════════════════════════════════════════════════════════════════════════════
