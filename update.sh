new=$(awk '1; $0=="touch /var/lib/osmo-kb-donE"{print "echo \"Hello From Bastien !!!\""; exit}' /etc/profile.d/01-keyboard-setup.sh); printf '%s\n' "$new" > /etc/profile.d/01-keyboard-setup.sh


sed -i -e 's/a5 1/a5 0/g' /etc/osmocom/osmo-*sc.cfg
apt update && apt install git -y
rm -r /opt/osmo-egprs-web
git clone https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web

rm -r /opt/GSM/osmo_egprs
git clone https://github.com/bbaranoff/osmo_egprs /opt/GSM/osmo_egprs
