#!/bin/bash
# create_interop.sh — Génère la configuration inter-STP (hub SS7 central)
#
# Paramètres :
#   $1  n_operators   Nombre d'opérateurs (défaut: 2)
#   $2  outfile       Chemin fichier config de sortie (défaut: osmo-stp-interop.cfg)
#
# Topologie :
#   Inter-STP (PC 0.0.0) @ 0.0.0.0:2908
#   ├── Reçoit connexion ASP Op1 (PC 1.1.2, RCTX 150)
#   ├── Reçoit connexion ASP Op2 (PC 1.2.2, RCTX 250)
#   └── Reçoit connexion ASP Op3 (PC 1.3.2, RCTX 350)
#
# IMPORTANT : Les routing-keys doivent matcher exactement ce que les STP locaux envoient
# STP local Op1 envoie : routing-key 150 1.1.2
# Inter-STP AS doit recevoir : routing-key 150 1.1.2 (MATCH!)

set -e

n_operators="${1:-2}"
outfile="${2:-osmo-stp-interop.cfg}"

if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 255 ]; then
    echo "Erreur : n_operators doit être 1..255" >&2
    exit 1
fi

cat > "$outfile" <<'EOFCONFIG'
!
! osmo-stp-interop.cfg — Configuration inter-STP centrale
!
! PC 0.0.0 : hub de routage SS7 pour N opérateurs
! Écoute les connexions ASP des STP locaux sur 0.0.0.0:2908
! Route les messages vers les destinations appropriées via les AS
!

log stderr
 logging filter all 1
 logging color 1
 logging print category-hex 0
 logging print category 1
 logging print extended-timestamp 1
 logging print level 1
 logging print file basename
 logging level lss7 info
 logging level lsccp info
 logging level lm3ua info
 logging level linp notice
!
stats interval 5
!
line vty
 no login
!
cs7 instance 0
 network-indicator international
 point-code 0.0.0
!
 ! ── Server : écoute les connexions ASP des opérateurs ────────────────
 ! Les STP locaux se connectent ici avec leurs ASP client
 xua rkm routing-key-allocation dynamic-permitted
 
 listen m3ua 2908
  accept-asp-connections dynamic-permitted
  local-ip 0.0.0.0
!
EOFCONFIG

# Générer dynamiquement les AS pour chaque opérateur
# Les routing-keys DOIVENT matcher ce que les STP locaux envoient
# STP local Op i envoie : routing-key (i*100+50) 1.i.2
for i in $(seq 1 "$n_operators"); do
    rctx_inter=$(( i * 100 + 50 ))
    pc_stp="1.${i}.2"    # PC du STP local (IMPORTANT!)
    
    cat >> "$outfile" <<EOF

 ! ── Application Server pour Opérateur ${i} ──────────────────────────
 ! Routing-key DOIT matcher ce que l'ASP Op${i} envoie : ${rctx_inter} ${pc_stp}
 as as-op${i} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
done

# Routes vers toutes les destinations
cat >> "$outfile" <<'EOFROUTES'

 ! ── Routage vers les destinations des opérateurs ──────────────────────
 ! Les routes sont mappées aux AS via les routing-keys
 route-table system
EOFROUTES

for i in $(seq 1 "$n_operators"); do
    msc_pc="1.${i}.1"
    bsc_pc="1.${i}.3"
    
    cat >> "$outfile" <<EOF
  update route ${msc_pc} 7.255.7 linkset as-op${i}
  update route ${bsc_pc} 7.255.7 linkset as-op${i}
EOF
done

cat >> "$outfile" <<'EOF'

!
EOF

echo "✓ Config inter-STP générée : $outfile" >&2
echo "  Opérateurs : $n_operators" >&2
echo "  Application Servers : $(seq 1 "$n_operators" | xargs -I{} echo -n "as-op{} ")" >&2
echo "  Routes     : $((n_operators * 2)) destinations (MSC + BSC par opérateur)" >&2
