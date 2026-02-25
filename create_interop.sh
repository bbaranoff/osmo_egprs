#!/bin/bash
# create_interop.sh — Génère osmo-stp-interop.cfg pour le hub SS7 central
#
# Architecture :
#   Inter-STP (PC 0.23.0, port 2908) ← hub
#     ├── as-op1 (RCTX 150) ← STP Op1 (1.23.2) se connecte en client
#     ├── as-op2 (RCTX 250) ← STP Op2 (2.23.2) se connecte en client
#     └── ...
#
#   RCTX = op_id * 100 + 50  (doit matcher osmo-stp.cfg __RCTX_INTER__)
#
#   Route-table :
#     x.23.1 (MSC), x.23.2 (STP), x.23.3 (BSC) → as-opX
#
# Usage: ./create_interop.sh <n_operators> [output_file]

set -e

N_OPERATORS=${1:-2}
OUTPUT_FILE=${2:-"osmo-stp-interop.cfg"}

if ! [[ "$N_OPERATORS" =~ ^[0-9]+$ ]] || [ "$N_OPERATORS" -lt 1 ]; then
    echo "Usage: $0 <n_operators> [output_file]"; exit 1
fi

echo "Génération de $OUTPUT_FILE pour $N_OPERATORS opérateur(s)..."

# ── En-tête ────────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << 'EOHEADER'
!
! osmo-stp-interop.cfg — Inter-STP central (hub SS7)
! Généré par create_interop.sh — ne pas éditer manuellement.
!
log stderr
 logging filter all 1
 logging color 1
 logging print category 1
 logging print extended-timestamp 1
 logging print level 1
 logging level lss7 info
 logging level lm3ua info
!
line vty
 no login
!
cs7 instance 0
 network-indicator international
 point-code 0.23.0
!
 ! Accepte les connexions des STPs opérateurs.
 ! Les ASP entrants sont mappés aux AS pré-définis via routing-key.
 listen m3ua 2908
  local-ip 172.20.0.10
  accept-asp-connections dynamic-permitted
EOHEADER

# ── AS par opérateur ───────────────────────────────────────────────────────────
for i in $(seq 1 "$N_OPERATORS"); do
    RCTX=$(( i * 100 + 50 ))
    PC_STP="${i}.23.2"

    cat >> "$OUTPUT_FILE" << EOOPERATOR
!
 ! ── Opérateur ${i} : STP ${PC_STP} @ 172.20.0.$((10+i)) — RCTX ${RCTX} ──
 as as-op${i} m3ua
  routing-key ${RCTX} ${PC_STP}
  traffic-mode override
EOOPERATOR
done

# ── Route-table ────────────────────────────────────────────────────────────────
echo "!" >> "$OUTPUT_FILE"
echo " ! ── Routes SS7 ──────────────────────────────────────────────────────" >> "$OUTPUT_FILE"
echo " route-table system" >> "$OUTPUT_FILE"

for i in $(seq 1 "$N_OPERATORS"); do
    cat >> "$OUTPUT_FILE" << EOROUTES
  ! Op${i} : MSC=${i}.23.1  STP=${i}.23.2  BSC=${i}.23.3
  update route ${i}.23.1 7.255.7 linkset as-op${i}
  update route ${i}.23.2 7.255.7 linkset as-op${i}
  update route ${i}.23.3 7.255.7 linkset as-op${i}
EOROUTES
done

echo ""
echo "✓ $OUTPUT_FILE"
for i in $(seq 1 "$N_OPERATORS"); do
    RCTX=$(( i * 100 + 50 ))
    echo "  Op${i} : STP ${i}.23.2 @ 172.20.0.$((10+i)) — RCTX ${RCTX}"
done
