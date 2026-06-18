awk '1; /Disclaimer/{print "# ── animation : MT SMS entre deux téléphones ──
printf '\033[?25l'                                   # curseur off
ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')

for b in "${bars[@]}"; do                            # phase 1 : attach réseau
  printf '\r  %b %b  \033[36mscanning ARFCN…\033[0m   ' "$ph" "$b"
  sleep 0.12
done

for ((p=0; p<=20; p++)); do                          # phase 2 : le SMS traverse A → B
  printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
  sleep 0.04
done

printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered — MT end-to-end\033[0m\n' "$ph" '' "$ph"
printf '\033[?25h'                                   # curseur on"; exit}' /etc/profile.d/01-keyboard-setup.sh > /tmp/kb.new
cat /tmp/kb.new > /etc/profile.d/01-keyboard-setup.sh
sed -i -e 's/a5 1/a5 0/g' /etc/osmocom/osmo-*sc.cfg
apt update && apt install git -y
rm -r /opt/osmo-egprs-web
git clone https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web

rm -r /opt/GSM/osmo_egprs
git clone https://github.com/bbaranoff/osmo_egprs /opt/GSM/osmo_egprs
