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

# ── Mode WAN ─────────────────────────────────────────────────────────────────
#   create_interop.sh --wan <n_noeuds> <ops_par_noeud> <outfile>
#
# Le hub d'origine ne dessert qu'UNE machine : ses point codes 1.<op>.<role> se
# recalculent à l'identique sur chaque noeud d'un WAN, donc trois noeuds reliés
# au même hub présenteraient trois fois 1.1.2. Un point code est une ADRESSE :
# la collision n'est pas un détail de nommage, elle rend le routage SS7 faux.
#
# Le plan WAN encode le noeud DANS le point code :
#   PC = 1.<noeud><op>.<role>     noeud 1 op 1 → 1.11.2 ; noeud 3 op 2 → 1.32.2
#   RCTX = noeud*1000 + op*100 + 50
# Lisible à l'oeil (le premier chiffre est le noeud), unique, et le champ
# central du 3-8-3 tient jusqu'à 9 noeuds × 9 opérateurs.
WAN_MODE=0
if [ "${1:-}" = "--wan" ]; then
    WAN_MODE=1
    n_nodes="${2:-3}"
    ops_per_node="${3:-1}"
    outfile="${4:-osmo-stp-interop.cfg}"
    if ! [[ "$n_nodes" =~ ^[1-9]$ ]] || ! [[ "$ops_per_node" =~ ^[1-9]$ ]]; then
        echo "Erreur : --wan <1-9 noeuds> <1-9 opérateurs>" >&2; exit 1
    fi
else
    n_operators="${1:-2}"
    outfile="${2:-osmo-stp-interop.cfg}"
    if ! [[ "$n_operators" =~ ^[0-9]+$ ]] || [ "$n_operators" -lt 1 ] || [ "$n_operators" -gt 24 ]; then
        echo "Erreur : n_operators doit être 1..24" >&2
        exit 1
    fi
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

if [ "$WAN_MODE" = "1" ]; then
    for n in $(seq 1 "$n_nodes"); do
        for o in $(seq 1 "$ops_per_node"); do
            rctx_inter=$(( n * 1000 + o * 100 + 50 ))
            pc_stp="1.${n}${o}.2"
            cat >> "$outfile" <<EOF

 as as-n${n}op${o} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
        done
    done
else
for i in $(seq 1 "$n_operators"); do
    rctx_inter=$(( i * 100 + 50 ))
    pc_stp="1.${i}.2"

    cat >> "$outfile" <<EOF

 as as-op${i} m3ua
  routing-key ${rctx_inter} ${pc_stp}
  traffic-mode override
EOF
done
fi

cat >> "$outfile" <<'EOFROUTES'

 route-table system
EOFROUTES

if [ "$WAN_MODE" = "1" ]; then
    for n in $(seq 1 "$n_nodes"); do
        for o in $(seq 1 "$ops_per_node"); do
            cat >> "$outfile" <<EOF
  update route 1.${n}${o}.1 7.255.7 linkset as-n${n}op${o}
  update route 1.${n}${o}.3 7.255.7 linkset as-n${n}op${o}
EOF
        done
    done
else
for i in $(seq 1 "$n_operators"); do
    cat >> "$outfile" <<EOF
  update route 1.${i}.1 7.255.7 linkset as-op${i}
  update route 1.${i}.3 7.255.7 linkset as-op${i}
EOF
done
fi

cat >> "$outfile" <<'EOF'

!
EOF

if [ "$WAN_MODE" = "1" ]; then
    echo "✓ Config inter-STP WAN générée : $outfile" >&2
    echo "  PC hub  : 0.0.0   Noeuds : $n_nodes × $ops_per_node opérateur(s)" >&2
    echo "  PC noeuds : 1.<noeud><op>.<role>   RCTX : noeud*1000 + op*100 + 50" >&2
    echo "  Routes  : $(( n_nodes * ops_per_node * 2 )) (masque 7.255.7)" >&2
else
    echo "✓ Config inter-STP générée : $outfile" >&2
    echo "  PC hub     : 0.0.0   Opérateurs : $n_operators" >&2
    echo "  Routes     : $((n_operators * 2)) (masque 7.255.7)" >&2
fi
