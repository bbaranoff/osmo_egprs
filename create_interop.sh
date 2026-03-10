#!/bin/bash
# create_interop.sh — Génère la configuration inter-STP (hub SS7 central)
#
# Paramètres :
#   $1  n_operators   Nombre d'opérateurs (1..24)
#   $2  outfile       Chemin fichier config de sortie (défaut: osmo-stp-interop.cfg)
#
# Point codes ITU 3-8-3 :
#   Inter-STP : 0.0.0
#   Op N STP  : 1.N.2    (cluster = N, 8 bits → max 255, limité à 24)
#   Op N MSC  : 1.N.1
#   Op N BSC  : 1.N.3
#
# Routes statiques avec masque exact 7.255.7 (14 bits) :
#   1.N.1 → as-opN  (MSC)
#   1.N.3 → as-opN  (BSC)

set -e

n_operators="${1:-2}"
outfile="${2:-osmo-stp-interop.cfg}"

if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 24 ]; then
    echo "Erreur : n_operators doit être 1..24" >&2
    exit 1
fi

cat > "$outfile" <<'EOFCONFIG'
!
! osmo-stp-interop.cfg — Configuration inter-STP centrale
!
! PC 0.0.0 : hub de routage SS7
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
 xua rkm routing-key-allocation dynamic-permitted

 listen m3ua 2908
  accept-asp-connections dynamic-permitted
  local-ip 0.0.0.0
!
EOFCONFIG

for i in $(seq 1 "$n_operators"); do
    rctx_inter=$(( i * 100 + 50 ))
    pc_stp="1.${i}.2"

    cat >> "$outfile" <<EOF

 as as-op${i} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
done

cat >> "$outfile" <<'EOFROUTES'

 route-table system
EOFROUTES

for i in $(seq 1 "$n_operators"); do
    cat >> "$outfile" <<EOF
  update route 1.${i}.1 7.255.7 linkset as-op${i}
  update route 1.${i}.3 7.255.7 linkset as-op${i}
EOF
done

cat >> "$outfile" <<'EOF'

!
EOF

echo "✓ Config inter-STP générée : $outfile" >&2
echo "  PC hub     : 0.0.0   Opérateurs : $n_operators" >&2
echo "  Routes     : $((n_operators * 2)) (masque 7.255.7)" >&2
