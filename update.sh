# 1) tronquer juste après la ligne Disclaimer (gardée)
awk '1; /Disclaimer/{exit}' /etc/profile.d/01-keyboard-setup.sh > /tmp/kb.new
# 2) appender l'animation — heredoc QUOTÉ => zéro échappement
apt update && apt install -y git socat
cat >> /tmp/kb.new <<'ANIM'

# ── animation : MT SMS entre deux téléphones ──
printf '\033[?25l'
ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
  printf '\r  %b %b  \033[36mscanning ARFCN…\033[0m   ' "$ph" "$b"
  sleep 0.12
done
for ((p=0; p<=20; p++)); do
  printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
  sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered — MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"
printf '\033[?25h'
ANIM
sed -i -e 's/a5 0/a5 0/g' /etc/osmocom/osmo-*sc.cfg
# 3) réécrire dans le même inode
cat /tmp/kb.new > /etc/profile.d/01-keyboard-setup.sh


apt update && apt install git tcpdump binutils-arm-none-eabi -y

# ── Rafraîchir l'arbre osmo_egprs (branche main) ─────────────────────────────
# Remplace l'ancien « cd /opt/GSM/osmo_egprs && git pull » qui ne pouvait PAS
# fonctionner sur une ISO : build-iso.sh y installe l'arbre NU, sans .git
# (« find … -name '.git*' … -exec rm -rf »). Le pull échouait silencieusement,
# donc aucun correctif du dépôt (run_modules/, scripts/…) n'atteignait jamais
# une ISO déjà gravée — update.sh ne rattrapait que ce qu'elle réécrit elle-même.
#
# Doit rester AVANT l'écriture de coeur.env plus bas : ce bloc peut remplacer
# l'arbre entier, ce qui effacerait un coeur.env posé trop tôt.
EGPRS_DIR=/opt/GSM/osmo_egprs
if [ -d "$EGPRS_DIR/.git" ]; then
    git -C "$EGPRS_DIR" fetch origin main && \
    git -C "$EGPRS_DIR" reset --hard FETCH_HEAD && \
    echo "osmo_egprs : arbre git réaligné sur origin/main"
else
    # Arbre nu de l'ISO : pas de dépôt, on retélécharge la branche main.
    egprs_stage="$(mktemp -d)"
    if curl -fsSL "https://codeload.github.com/bbaranoff/osmo_egprs/tar.gz/refs/heads/main" \
         | tar -xz -C "$egprs_stage" --strip-components=1 && [ -s "$egprs_stage/start.sh" ]; then
        # On ne détruit l'arbre en place qu'une fois le tarball vérifié complet :
        # un réseau coupé ne doit pas laisser l'ISO sans scripts.
        rm -rf "$EGPRS_DIR"
        mkdir -p /opt/GSM
        cp -a "$egprs_stage" "$EGPRS_DIR"
        find "$EGPRS_DIR" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
        echo "osmo_egprs : arbre nu rafraîchi depuis main (tarball)"
    else
        echo "osmo_egprs : récupération impossible (réseau ?) — arbre existant conservé"
    fi
    rm -rf "$egprs_stage"
fi
rm -r /opt/osmo-egprs-web
git clone https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web
cd /opt/osmo-egprs-web && git checkout main
UNIT=/etc/systemd/system/osmo-egprs-web.service

# ajoute (ou met à jour) Environment=CAP_IFACE=any sous [Service], idempotent
if grep -q '^Environment=CAP_IFACE=' "$UNIT"; then
  sed -i 's|^Environment=CAP_IFACE=.*|Environment=CAP_IFACE=any|' "$UNIT"
else
  sed -i '/^\[Service\]/a Environment=CAP_IFACE=any' "$UNIT"
fi

systemctl daemon-reload
systemctl restart osmo-egprs-web.service

# vérif
systemctl show osmo-egprs-web.service -p Environment
rm -rf /opt/osmo_egprs

# ═══════════════════════════════════════════════════════════════════════════════
# Correctifs ISO : feed HLR + routage SMS
#
# L'ISO tourne en NATIF (pas de docker au runtime), mais les deux configs
# héritées du build sont restées calibrées pour le mode docker :
#
#   1. feed HLR    build-iso.sh déclare ISO_N_MS=8, alors que run_modules/
#                  21-abonnes-hlr.sh retombe sur « : "${N_MS:=1}" ». Un seul
#                  abonné était provisionné : les MS 2 à 8 se voyaient refuser
#                  le rattachement (« IMSI unknown in HLR ») — panne lue à tort
#                  comme un défaut radio.
#
#   2. routage SMS build-iso.sh génère sms-routing.conf dans un répertoire
#                  temporaire puis le supprime sans jamais le copier dans le
#                  rootfs. L'ISO conservait donc le fallback docker :
#                  opérateur 1 = 172.20.0.11 (IP inexistante en natif, le relay
#                  n'atteignait personne) et des routes limitées à 5 MS, d'où
#                  « No route for destination » sur les MSISDN 10006 à 10008.
#
# Les deux blocs sont IDEMPOTENTS : rejouables à chaque boot sans effet de bord.
# Formules communes au dépôt (scripts/sms-routing-setup.sh, 21-abonnes-hlr.sh) :
#   IMSI   = MCC(3) MNC(2) %04d(op) %06d(ms)
#   MSISDN = op * 10000 + ms
#   Ki     = 00112233445566778899aabbccdd %02x(ms) %02x(op)
# ═══════════════════════════════════════════════════════════════════════════════

ISO_OP_ID=1        # opérateur unique de l'ISO
ISO_N_MS=2         # doit rester aligné sur ISO_N_MS de build-iso.sh
ISO_MCC=001
ISO_MNC=01
HLR_VTY_PORT=4258

iso_imsi()   { printf '%s%s%04d%06d\n' "$ISO_MCC" "$ISO_MNC" "$ISO_OP_ID" "$1"; }
iso_msisdn() { echo $(( ISO_OP_ID * 10000 + $1 )); }
iso_ki()     { printf '00112233445566778899aabbccdd%02x%02x\n' "$1" "$ISO_OP_ID"; }

# ── 1. feed HLR : N_MS persistant ────────────────────────────────────────────
# environment/load.env source « coeur.env » s'il existe, et tout le dépôt suit
# l'idiome « : "${VAR:=...}" » — poser N_MS ici laisse donc la ligne de commande
# (N_MS=2 ./run.sh) gagner. On écrit dans les deux arbres possibles : run.sh est
# résolu depuis qemu-src, mais osmo_egprs embarque le même squelette.
for envdir in /opt/GSM/qemu-src/environment /opt/GSM/osmo_egprs/environment; do
    [ -d "$envdir" ] || continue
    cat > "$envdir/coeur.env" <<COEUR
# coeur.env — généré par update.sh (ISO). Aligne le nombre d'abonnés
# provisionnés dans le HLR sur le nombre de MS embarqués par l'ISO.
: "\${N_MS:=$ISO_N_MS}"
: "\${OPERATOR_ID:=$ISO_OP_ID}"
COEUR
    echo "coeur.env écrit : $envdir (N_MS=$ISO_N_MS)"
done

# ── 2. feed HLR : provisionnement immédiat si le VTY répond déjà ─────────────
# Au boot le HLR n'est en général pas encore lancé (la pile démarre plus tard
# via start-direct.sh) : dans ce cas 21-abonnes-hlr fera le travail avec le
# N_MS corrigé ci-dessus. Si le VTY écoute déjà (update.sh rejoué à chaud), on
# provisionne tout de suite. « subscriber create » sur un IMSI existant est sans
# effet destructeur — d'où l'idempotence.
if timeout 2 bash -c "exec 9<>/dev/tcp/127.0.0.1/$HLR_VTY_PORT" 2>/dev/null; then
    {
        echo enable
        for ms in $(seq 1 "$ISO_N_MS"); do
            imsi=$(iso_imsi "$ms")
            echo "subscriber imsi $imsi create"
            echo "subscriber imsi $imsi update msisdn $(iso_msisdn "$ms")"
            echo "subscriber imsi $imsi update aud2g comp128v1 ki $(iso_ki "$ms")"
        done
        # « exit », pas « end » : au nœud enable end n'existe pas (le VTY répond
        # « % Unknown command. ») et surtout la session resterait OUVERTE —
        # telnet ne rendrait alors la main qu'au timeout.
        echo exit
        sleep 1
    } | timeout 15 telnet 127.0.0.1 "$HLR_VTY_PORT" >/dev/null 2>&1 || true
    echo "HLR alimenté : $ISO_N_MS abonnés (opérateur $ISO_OP_ID)"
else
    echo "VTY HLR $HLR_VTY_PORT muet — provisionnement délégué à 21-abonnes-hlr au démarrage de la pile"
fi

# ── 3. routage SMS : config native (127.0.0.1) couvrant les 8 MS ─────────────
# sc_address = 1999001<op>444 et [relay] port 7890 : mêmes valeurs que
# scripts/sms-routing-setup.sh, pour que le relay et proto-smsc-daemon
# s'accordent. En natif il n'y a qu'un opérateur : tout boucle sur 127.0.0.1.
SMS_ROUTING=/etc/osmocom/sms-routing.conf
mkdir -p /etc/osmocom /var/log/osmocom
{
    echo "# sms-routing.conf — généré par update.sh (ISO natif, opérateur unique)"
    echo "# Remplace le fallback docker (172.20.0.x) inatteignable sans bridge."
    echo
    echo "[local]"
    echo "operator_id = $ISO_OP_ID"
    printf 'sc_address  = 1999001%s444\n' "$ISO_OP_ID"
    echo "hlr_vty_ip  = 127.0.0.1"
    echo "hlr_vty_port = $HLR_VTY_PORT"
    echo "sendmt_socket = /tmp/sendmt_socket"
    echo "mo_log = /var/log/osmocom/mo-sms-op${ISO_OP_ID}.log"
    echo
    echo "[operators]"
    echo "# ISO native : pas de backbone docker, le relay boucle sur lui-même."
    echo "$ISO_OP_ID = 127.0.0.1"
    echo
    echo "[routes]"
    echo "# Longest-prefix match : MSISDN exact d'abord, puis repli opérateur."
    for ms in $(seq 1 "$ISO_N_MS"); do
        printf '%-8s = %s   # IMSI=%s\n' "$(iso_msisdn "$ms")" "$ISO_OP_ID" "$(iso_imsi "$ms")"
    done
    echo "# Replis (MSISDN hors liste) — préfixes courts de l'opérateur"
    printf '%-8s = %s\n' "${ISO_OP_ID}000"  "$ISO_OP_ID"
    printf '%-8s = %s\n' "${ISO_OP_ID}0000" "$ISO_OP_ID"
    printf '%-8s = %s   # E.164 +33 6%02d...\n' "$(printf '336%02d' "$ISO_OP_ID")" "$ISO_OP_ID" "$ISO_OP_ID"
    echo
    echo "[relay]"
    echo "port = 7890"
    echo "connect_timeout = 10"
    echo "retry_count = 3"
    echo "retry_delay = 5"
} > "$SMS_ROUTING"
echo "routage SMS écrit : $SMS_ROUTING ($ISO_N_MS MS, natif 127.0.0.1)"
