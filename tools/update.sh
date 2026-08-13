# 1) tronquer juste après la ligne Disclaimer (gardée)
awk '1; /Disclaimer/{exit}' /etc/profile.d/01-keyboard-setup.sh > /tmp/kb.new

# 2) appender l'animation — heredoc QUOTÉ => zéro échappement
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


apt update && apt install git -y
# ── Branche des depots maison ────────────────────────────────────────────────
# Meme convention que l'ARG OSMO_BRANCH des Dockerfile/Dockerfile.run de cette
# branche : les trois depots (osmo_egprs, osmo-egprs-web, qemu-src) suivent la
# MEME branche. Avant ce correctif, ce script ramenait osmo_egprs ET
# osmo-egprs-web sur "main" a chaque execution — la branche se sabordait
# elle-meme. Surchargeable :  OSMO_BRANCH=main ./update.sh
OSMO_BRANCH="${OSMO_BRANCH:-sms_voice_mt_mo_a50}"
rm -r /opt/osmo-egprs-web
git clone --branch "$OSMO_BRANCH" https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web
cd /opt/osmo-egprs-web && git checkout "$OSMO_BRANCH"
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

