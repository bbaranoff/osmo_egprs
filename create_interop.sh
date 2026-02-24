#!/bin/bash
# create_interop.sh — Génère osmo-stp-interop.cfg dynamiquement
# Usage: ./create_interop.sh <n_operators> <output_file>

set -e

N_OPERATORS=${1:-2}
OUTPUT_FILE=${2:-"osmo-stp-interop.cfg"}

if ! [[ "$N_OPERATORS" =~ ^[0-9]+$ ]] || [ "$N_OPERATORS" -lt 1 ]; then
    echo "Usage: $0 <n_operators> [output_file]"
    echo "  n_operators: nombre d'opérateurs (minimum 1)"
    exit 1
fi

echo "Génération de $OUTPUT_FILE pour $N_OPERATORS opérateur(s)..."

# ── En-tête ────────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << 'EOHEADER'
log stderr
 logging filter all 1
 logging color 1
 logging print category 1
 logging level lss7 debug
 logging level lsccp notice
 logging level lm3ua debug

line vty
 no login

cs7 instance 0
 network-indicator international
 point-code 0.23.0
EOHEADER

# ── ASP/AS pour chaque opérateur ───────────────────────────────────────────────
# Pour chaque opérateur :
#   - 1 ASP (connexion SCTP depuis le STP de l'opérateur)
#   - 1 AS avec routing-key 999 (correspond au STP local as-inter)
for i in $(seq 1 "$N_OPERATORS"); do
    OP_IP="172.20.0.$((10 + i))"

    cat >> "$OUTPUT_FILE" << EOOPERATOR

 ! ─────────────────────────────────────────────
 ! Opérateur ${i} @ ${OP_IP}
 ! AS avec routing-key 999 (correspond as-inter)
 ! ─────────────────────────────────────────────
 asp asp-op${i} 2910 2908 m3ua
  remote-ip ${OP_IP}
  local-ip  172.20.0.10
  role sg
  sctp-role server
  no shutdown

 as as-op${i} m3ua
  asp asp-op${i}
  routing-key 999 0.0.0
  traffic-mode override
EOOPERATOR
done

# ── Listener ───────────────────────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'EOFOOTER'

 ! ─────────────────────────────────────────────
 ! Serveur M3UA : écoute sur port 2908
 ! Routes créées via routing-key 999
 ! ─────────────────────────────────────────────
 listen m3ua 2908
  local-ip 172.20.0.10
EOFOOTER

echo "✓ Config générée : $OUTPUT_FILE"
echo ""
echo "Résumé :"
for i in $(seq 1 "$N_OPERATORS"); do
    echo "  Op${i} @ 172.20.0.$((10 + i))"
    echo "    - AS as-op${i} : routing-key 999 0.0.0"
done
echo ""
echo "Routing context 999 = trafic inter-opérateur"
