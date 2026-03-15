#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# setup-wan-interop.sh — Interconnexion WAN entre deux instances osmo_egprs
#
# FIX : supporte N_LOCAL ≠ N_REMOTE
#
# Architecture :
#
#   Serveur A (3 ops)                    Serveur B (2 ops)
#   ┌──────────────────────┐             ┌──────────────────────┐
#   │ Op1 :5060 @.0.11     │             │ Op1 :5060 @.0.11     │
#   │ Op2 :5060 @.0.12     │             │ Op2 :5060 @.0.12     │
#   │ Op3 :5060 @.0.13     │             └──────────┬───────────┘
#   └──────────┬───────────┘                        │
#              │                                    │
#   Host iptables DNAT (inbound)        Host iptables DNAT (inbound)
#   :5080 → .0.11:5060  (pour Op1)     :5080 → .0.11:5060  (pour Op1)
#   :5082 → .0.12:5060  (pour Op2)     :5082 → .0.12:5060  (pour Op2)
#   :5084 → .0.13:5060  (pour Op3)
#              │                                    │
#              └──── SIP/RTP over WAN ──────────────┘
#
# Principe :
#   • Les ports INBOUND (DNAT) sont basés sur le nombre d'ops LOCAUX
#   • Les trunks OUTBOUND (PJSIP) sont basés sur le nombre d'ops DISTANTS
#   • Chaque local op crée N_REMOTE trunks vers le serveur distant
#   • Le préfixe d'appel encode l'op distant : 66 + numéro (1er chiffre = op distant)
#
# Usage :
#   sudo ./setup-wan-interop.sh <local_ip> <remote_ip> <n_local_ops> <n_remote_ops>
#
# Exemples :
#   Serveur A (3 ops) → Serveur B (2 ops) :
#     A: sudo ./setup-wan-interop.sh 82.66.231.141 37.59.111.84 3 2
#     B: sudo ./setup-wan-interop.sh 37.59.111.84 82.66.231.141 2 3
#
#   Serveur A (2 ops) → Serveur B (2 ops) (ancien comportement) :
#     A: sudo ./setup-wan-interop.sh 82.66.231.141 37.59.111.84 2 2
#     B: sudo ./setup-wan-interop.sh 37.59.111.84 82.66.231.141 2 2
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Paramètres ────────────────────────────────────────────────────────────────
LOCAL_IP="${1:-}"
REMOTE_IP="${2:-}"
N_LOCAL="${3:-}"
N_REMOTE="${4:-$N_LOCAL}"          # fallback : même nombre si omis (rétrocompat)
WAN_PREFIX="${WAN_PREFIX:-66}"
SIP_WAN_BASE=5080
RTP_WAN_BASE=20000
RTP_PER_OP=500
CONTAINER_PREFIX="osmo-operator-"

if [ -z "$LOCAL_IP" ] || [ -z "$REMOTE_IP" ] || [ -z "$N_LOCAL" ]; then
    echo -e "${RED}Usage: sudo $0 <local_ip> <remote_ip> <n_local_ops> [n_remote_ops]${NC}"
    echo ""
    echo "  Serveur A (3 ops local, 2 ops distant) :"
    echo "    A: sudo $0 82.66.231.141 37.59.111.84 3 2"
    echo "    B: sudo $0 37.59.111.84 82.66.231.141 2 3"
    echo ""
    echo "  Si n_remote_ops omis → supposé = n_local_ops"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Doit être lancé en root (sudo).${NC}"; exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# Port SIP WAN pour un opérateur donné (utilisé par les DEUX côtés)
# Op1 → :5080, Op2 → :5082, Op3 → :5084, ...
op_wan_sip_port()  { echo $(( SIP_WAN_BASE + ($1 - 1) * 2 )); }
op_wan_rtp_start() { echo $(( RTP_WAN_BASE + ($1 - 1) * RTP_PER_OP )); }
op_wan_rtp_end()   { echo $(( RTP_WAN_BASE + $1 * RTP_PER_OP - 1 )); }
op_backbone_ip()   { echo "172.20.0.$((10 + $1))"; }
op_container()     { echo "${CONTAINER_PREFIX}$1"; }

# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        WAN Interop — Interconnexion osmo_egprs distante         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Local        : ${CYAN}${LOCAL_IP}${NC}  (${BOLD}${N_LOCAL}${NC} opérateurs)"
echo -e "  Remote       : ${CYAN}${REMOTE_IP}${NC}  (${BOLD}${N_REMOTE}${NC} opérateurs)"
echo -e "  Préfixe WAN  : ${CYAN}${WAN_PREFIX}${NC}"
echo ""

# ── Vérification des containers locaux ────────────────────────────────────────
echo -e "${GREEN}[1/5] Vérification containers locaux...${NC}"
for i in $(seq 1 "$N_LOCAL"); do
    cname=$(op_container "$i")
    if ! docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
        echo -e "  ${RED}✗ ${cname} non trouvé${NC}"; exit 1
    fi
    echo -e "  ${GREEN}✓${NC} ${cname}"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [2/5] iptables DNAT — pour le trafic ENTRANT depuis le serveur distant
#
# On crée des DNAT pour les N_LOCAL opérateurs locaux.
# Le distant envoie vers LOCAL_IP:5080+(N-1)*2 pour joindre notre Op N.
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[2/5] iptables DNAT (${N_LOCAL} ops locaux)...${NC}"

sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

# Nettoyer
iptables -t nat -D PREROUTING -j OSMO_WAN_INTEROP 2>/dev/null || true
iptables -t nat -F OSMO_WAN_INTEROP 2>/dev/null || true
iptables -t nat -X OSMO_WAN_INTEROP 2>/dev/null || true
iptables -t nat -N OSMO_WAN_INTEROP

for i in $(seq 1 "$N_LOCAL"); do
    bb_ip=$(op_backbone_ip "$i")
    sip_port=$(op_wan_sip_port "$i")
    rtp_start=$(op_wan_rtp_start "$i")
    rtp_end=$(op_wan_rtp_end "$i")

    # SIP UDP
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p udp --dport "$sip_port" \
        -j DNAT --to-destination "${bb_ip}:5060"
    # SIP TCP
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p tcp --dport "$sip_port" \
        -j DNAT --to-destination "${bb_ip}:5060"
    # RTP
    iptables -t nat -A OSMO_WAN_INTEROP \
        -s "$REMOTE_IP" -p udp --dport "${rtp_start}:${rtp_end}" \
        -j DNAT --to-destination "${bb_ip}"

    echo -e "  ${CYAN}Local Op${i}${NC} DNAT :${sip_port} → ${bb_ip}:5060  RTP ${rtp_start}-${rtp_end}"
done

iptables -t nat -I PREROUTING -j OSMO_WAN_INTEROP
if ! iptables -t nat -C POSTROUTING -d 172.20.0.0/24 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -d 172.20.0.0/24 -j MASQUERADE
fi

echo -e "  ${GREEN}✓ iptables configuré${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [3/5] RTP config dans chaque container local
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[3/5] Configuration RTP WAN...${NC}"
for i in $(seq 1 "$N_LOCAL"); do
    cname=$(op_container "$i")
    rtp_start=$(op_wan_rtp_start "$i")
    rtp_end=$(op_wan_rtp_end "$i")

    docker exec "$cname" bash -c "cat > /etc/asterisk/rtp.conf << RTPEOF
[general]
rtpstart=${rtp_start}
rtpend=${rtp_end}
strictrtp=no
icesupport=no
RTPEOF"
    echo -e "  ${CYAN}Op${i}${NC} RTP ${rtp_start}-${rtp_end}"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [4/5] PJSIP trunks + Dialplan WAN
#
# Chaque opérateur LOCAL crée N_REMOTE trunks vers les ops DISTANTS.
# Le port SIP du distant est calculé avec la formule du distant :
#   Remote Op J écoute sur REMOTE_IP:op_wan_sip_port(J)
#
# Le dialplan route le préfixe WAN :
#   66 + JXXXX → wan_trunk_op{J}  (J = premier chiffre = op distant)
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[4/5] PJSIP trunks WAN (${N_REMOTE} ops distants)...${NC}"

for i in $(seq 1 "$N_LOCAL"); do
    cname=$(op_container "$i")

    # ── Patch transport-udp avec external addresses ──
    docker exec "$cname" bash -c "
        if ! grep -q 'external_media_address' /etc/asterisk/pjsip.conf; then
            cp /etc/asterisk/pjsip.conf /tmp/_pj.work
            sed -i '/^\[transport-udp\]/,/^\$/ {
                /^\$/i\\
external_media_address=${LOCAL_IP}\\
external_signaling_address=${LOCAL_IP}\\
local_net=172.20.0.0/24\\
local_net=127.0.0.0/8
            }' /tmp/_pj.work
            cp /tmp/_pj.work /etc/asterisk/pjsip.conf
            rm -f /tmp/_pj.work
        fi
    "

    # ── Trunks PJSIP : 1 inbound + N outbound par op distant ──
    pjsip_wan="
; ══════════════════════════════════════════════════════════════════════════════
; WAN INTEROP — Local ${N_LOCAL} ops, Remote ${N_REMOTE} ops @ ${REMOTE_IP}
; Généré $(date '+%Y-%m-%d %H:%M:%S')
; ══════════════════════════════════════════════════════════════════════════════

; ── INBOUND : 1 seul endpoint pour TOUT le trafic venant de REMOTE_IP ────
; Tous les appels entrants du distant arrivent ici (peu importe quel op distant)
; Le dialplan [wan_in] route ensuite selon le numéro appelé.
[wan-identify-inbound]
type=identify
endpoint=wan_inbound
match=${REMOTE_IP}

[wan_inbound]
type=endpoint
transport=transport-udp
context=wan_in
disallow=all
allow=gsm
allow=ulaw
aors=wan_inbound
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
ice_support=no
media_encryption=no

[wan_inbound]
type=aor
max_contacts=10
qualify_frequency=0
"

    # ── OUTBOUND : 1 endpoint par opérateur distant (port SIP distinct) ──
    for j in $(seq 1 "$N_REMOTE"); do
        remote_sip_port=$(op_wan_sip_port "$j")

        pjsip_wan+="
; ── Outbound → Remote Op${j} (${REMOTE_IP}:${remote_sip_port}) ──
[wan_trunk_op${j}]
type=endpoint
transport=transport-udp
context=wan_in
disallow=all
allow=gsm
allow=ulaw
aors=wan_trunk_op${j}
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
ice_support=no
media_encryption=no

[wan_trunk_op${j}]
type=aor
contact=sip:${REMOTE_IP}:${remote_sip_port}
qualify_frequency=30
qualify_timeout=5.0
"
    done

    # Retirer ancien bloc WAN + ajouter le nouveau
    docker exec "$cname" bash -c "
        cp /etc/asterisk/pjsip.conf /tmp/_pj.work
        sed -i '/; ══.*WAN INTEROP/,\$d' /tmp/_pj.work 2>/dev/null || true
        cp /tmp/_pj.work /etc/asterisk/pjsip.conf
        rm -f /tmp/_pj.work
    "
    docker exec "$cname" bash -c "cat >> /etc/asterisk/pjsip.conf << 'PJSIPEOF'
${pjsip_wan}
PJSIPEOF"

    echo -e "  ${CYAN}Op${i}${NC} PJSIP: ${N_REMOTE} trunk(s) WAN"

    # ── Dialplan WAN ──
    # [wan_out] : route 66+JXXXX vers wan_trunk_opJ (J = op distant)
    # [wan_in]  : reçoit les appels du distant et route vers le MSC local

    wan_dialplan="
; ══════════════════════════════════════════════════════════════════════════════
; WAN INTEROP — Routage (prefix ${WAN_PREFIX})
; Local: ${N_LOCAL} ops (ici Op${i})  Remote: ${N_REMOTE} ops
; Généré $(date '+%Y-%m-%d %H:%M:%S')
;
; Composer ${WAN_PREFIX}JXXXX = appeler numéro JXXXX sur l'op distant J
; Ex: ${WAN_PREFIX}10001 → Remote Op1, MS 10001
;     ${WAN_PREFIX}20001 → Remote Op2, MS 20001
; ══════════════════════════════════════════════════════════════════════════════

[wan_out]
"

    # Une extension par opérateur DISTANT
    for j in $(seq 1 "$N_REMOTE"); do
        wan_dialplan+="
; → Remote Op${j}
exten => _${j}XXXX,1,NoOp(=== WAN OUT → Remote Op${j}: \${EXTEN} via ${REMOTE_IP}:$(op_wan_sip_port "$j") ===)
 same => n,Dial(PJSIP/\${EXTEN}@wan_trunk_op${j},,rT)
 same => n,Congestion()
 same => n,Hangup()

exten => _${j}XXXXX,1,NoOp(=== WAN OUT → Remote Op${j} 5d: \${EXTEN} ===)
 same => n,Dial(PJSIP/\${EXTEN}@wan_trunk_op${j},,rT)
 same => n,Congestion()
 same => n,Hangup()
"
    done

    wan_dialplan+="
; Fallback
exten => _X.,1,NoOp(=== WAN OUT: inconnu \${EXTEN} ===)
 same => n,Congestion()
 same => n,Hangup()

; ══════════════════════════════════════════════════════════════════════════════
; [wan_in] — Appels entrants depuis le serveur distant
; ══════════════════════════════════════════════════════════════════════════════
[wan_in]

; Distant → MS local (cet opérateur)
exten => _${i}XXXX,1,NoOp(=== WAN IN → GSM local Op${i}: \${EXTEN} ===)
 same => n,Set(CALLERID(all)=<\${CALLERID(num)}>)
 same => n,Dial(PJSIP/\${EXTEN}@gsm_msc,,rT)
 same => n,Congestion()
 same => n,Hangup()

exten => _${i}XXXXX,1,NoOp(=== WAN IN → GSM local Op${i}: \${EXTEN} ===)
 same => n,Set(CALLERID(all)=<\${CALLERID(num)}>)
 same => n,Dial(PJSIP/\${EXTEN}@gsm_msc,,rT)
 same => n,Congestion()
 same => n,Hangup()

; Distant → autre op local (re-route)
exten => _X.,1,NoOp(=== WAN IN → routage local: \${EXTEN} ===)
 same => n,Goto(interop_out,\${EXTEN},1)

exten => 600,1,NoOp(=== WAN ECHO ===)
 same => n,Answer()
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Playback(demo-echodone)
 same => n,Hangup()
"

    # Retirer ancien dialplan WAN + ajouter
    docker exec "$cname" bash -c '
        cp /etc/asterisk/extensions.conf /tmp/_ext.work
        sed -i "/; ══.*WAN INTEROP.*Routage/,\$d" /tmp/_ext.work 2>/dev/null || true
        cp /tmp/_ext.work /etc/asterisk/extensions.conf
        rm -f /tmp/_ext.work
    '
    docker exec "$cname" bash -c "cat >> /etc/asterisk/extensions.conf << 'EXTEOF'
${wan_dialplan}
EXTEOF"

    # ── Injection du préfixe WAN dans [gsm_in] et [internal] ──
    docker exec "$cname" bash -c '
        EXT="/etc/asterisk/extensions.conf"
        if ! grep -q "_'"${WAN_PREFIX}"'\." "$EXT"; then
            cp "$EXT" /tmp/_ext.work
            sed -i "/^\[gsm_in\]$/a\\
\\
; -- WAN: prefix '"${WAN_PREFIX}"' → serveur distant --\\
exten => _'"${WAN_PREFIX}"'.,1,NoOp(=== GSM -> WAN: strip '"${WAN_PREFIX}"' ===)\\
 same => n,Goto(wan_out,\${EXTEN:'"${#WAN_PREFIX}"'},1)" /tmp/_ext.work

            sed -i "/^\[internal\]$/a\\
\\
; -- WAN: prefix '"${WAN_PREFIX}"' → serveur distant --\\
exten => _'"${WAN_PREFIX}"'.,1,NoOp(=== SIP -> WAN: strip '"${WAN_PREFIX}"' ===)\\
 same => n,Goto(wan_out,\${EXTEN:'"${#WAN_PREFIX}"'},1)" /tmp/_ext.work

            cp /tmp/_ext.work "$EXT"
            rm -f /tmp/_ext.work
        fi
    '

    echo -e "  ${CYAN}Op${i}${NC} Dialplan: wan_out(${N_REMOTE} distants) + wan_in"
done

echo -e "  ${GREEN}✓ PJSIP + Dialplan configurés${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# [5/5] Restart Asterisk
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}[5/5] Reload Asterisk...${NC}"
for i in $(seq 1 "$N_LOCAL"); do
    cname=$(op_container "$i")
    docker exec "$cname" bash -c "
        asterisk -rx 'pjsip reload' 2>/dev/null
        asterisk -rx 'dialplan reload' 2>/dev/null
        asterisk -rx 'core reload' 2>/dev/null
    " 2>/dev/null || true
    echo -e "  ${CYAN}Op${i}${NC} Asterisk rechargé"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Résumé
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              WAN Interop configuré avec succès !                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Local  :${NC} ${CYAN}${LOCAL_IP}${NC}  (${N_LOCAL} opérateurs)"
echo -e "  ${BOLD}Remote :${NC} ${CYAN}${REMOTE_IP}${NC}  (${N_REMOTE} opérateurs)"
echo ""

echo -e "  ${BOLD}Ports WAN LOCAUX (DNAT inbound — ${N_LOCAL} ops) :${NC}"
for i in $(seq 1 "$N_LOCAL"); do
    echo -e "    Op${i}: SIP ${CYAN}:$(op_wan_sip_port "$i")${NC}  RTP ${CYAN}$(op_wan_rtp_start "$i")-$(op_wan_rtp_end "$i")${NC}"
done
echo ""

echo -e "  ${BOLD}Trunks vers le DISTANT (${N_REMOTE} ops) :${NC}"
for j in $(seq 1 "$N_REMOTE"); do
    echo -e "    → Remote Op${j}: ${CYAN}${REMOTE_IP}:$(op_wan_sip_port "$j")${NC}"
done
echo ""

echo -e "  ${BOLD}Comment appeler :${NC}"
echo -e "    Depuis un MS local, composer ${CYAN}${WAN_PREFIX}${NC} + numéro distant"
for j in $(seq 1 "$N_REMOTE"); do
    echo -e "    ${CYAN}${WAN_PREFIX}${j}0001${NC} → MS ${j}0001 sur Remote Op${j}"
done
echo ""

echo -e "  ${BOLD}Firewall (à ouvrir sur CHAQUE serveur) :${NC}"
echo ""
echo -e "    ${YELLOW}# Inbound SIP/RTP pour nos ${N_LOCAL} ops locaux :${NC}"
for i in $(seq 1 "$N_LOCAL"); do
    echo -e "    ufw allow from ${REMOTE_IP} to any port $(op_wan_sip_port "$i") proto udp"
    echo -e "    ufw allow from ${REMOTE_IP} to any port $(op_wan_rtp_start "$i"):$(op_wan_rtp_end "$i") proto udp"
done
echo ""

echo -e "  ${BOLD}Diagnostic :${NC}"
echo -e "    docker exec osmo-operator-1 asterisk -rx 'pjsip show endpoints'"
echo -e "    docker exec osmo-operator-1 asterisk -rx 'pjsip show aors'"
echo ""

# ── Sauvegarde ────────────────────────────────────────────────────────────────
CONFIG_SAVE="/etc/osmo-wan-interop.conf"
cat > "$CONFIG_SAVE" << EOF
# osmo-wan-interop.conf — $(date)
LOCAL_IP=${LOCAL_IP}
REMOTE_IP=${REMOTE_IP}
N_LOCAL=${N_LOCAL}
N_REMOTE=${N_REMOTE}
WAN_PREFIX=${WAN_PREFIX}
SIP_WAN_BASE=${SIP_WAN_BASE}
RTP_WAN_BASE=${RTP_WAN_BASE}
RTP_PER_OP=${RTP_PER_OP}
EOF

echo -e "  Config sauvegardée : ${CYAN}${CONFIG_SAVE}${NC}"
echo -e "  Relancer : ${CYAN}sudo $0 ${LOCAL_IP} ${REMOTE_IP} ${N_LOCAL} ${N_REMOTE}${NC}"
echo ""
