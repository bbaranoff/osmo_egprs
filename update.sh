apt install git -y
rm -r /opt/GSM/osmo_egprs
cd /opt/GSM && git clone https://github.com/bbaranoff/osmo_egprs
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
