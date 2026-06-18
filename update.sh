

sed -i -e 's/a5 1/a5 0/g' /etc/osmocom/osmo-*sc.cfg
apt update && apt install git -y
rm -r /opt/osmo-egprs-web
git clone https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web

rm -r /opt/GSM/osmo_egprs
git clone https://github.com/bbaranoff/osmo_egprs /opt/GSM/osmo_egprs
