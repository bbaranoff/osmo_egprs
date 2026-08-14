#!/usr/bin/env bash
# update.sh — rafraîchit l'arbre osmo_egprs et le dashboard, puis applique les
# correctifs ISO (feed HLR, routage SMS).
#
# [2026-08-14] PAS de `set -e`, VOLONTAIREMENT : ce script enchaîne des étapes
# « au mieux » (apt, systemctl, VTY HLR) dont l'échec ne doit pas interrompre
# les suivantes. Les endroits réellement dangereux sont gardés UN PAR UN
# ci-dessous — un `set -e` global changerait le comportement de tout le reste
# sans qu'on puisse le tester ailleurs que sur une ISO gravée.

# Branche suivie par les dépôts maison. Surchargeable : OSMO_BRANCH=x ./update.sh
OSMO_BRANCH="${OSMO_BRANCH:-main}"

# 1) tronquer juste après la ligne Disclaimer (gardée)
# [2026-08-14] GARDE : sans le test d'existence, `awk` sur un fichier absent
# produisait un /tmp/kb.new VIDE, et le `cat > …` de l'étape 3 TRONQUAIT alors
# /etc/profile.d/01-keyboard-setup.sh au lieu de le compléter. Sur une machine
# qui n'est pas l'ISO, ça effaçait le fichier au lieu de ne rien faire.
KB=/etc/profile.d/01-keyboard-setup.sh
if [ -s "$KB" ]; then
awk '1; /Disclaimer/{exit}' "$KB" > /tmp/kb.new
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
# 3) réécrire dans le même inode
cat /tmp/kb.new > "$KB"
else
    echo "01-keyboard-setup.sh absent ou vide — animation non posée (machine hors ISO)"
fi
