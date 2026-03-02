#!/bin/bash
# create_interop.sh — Génère osmo-stp-interop.cfg pour le hub SS7 central
#
# Architecture inter-STP :
#   Point code  : 0.23.0
#   Port écoute : 2908 (accept-asp-connections dynamic-permitted)
#   1 AS par opérateur, SANS routing-key (AS "catch-all" par opérateur)
#   Le routage se fait sur le point code destination (MTP3 DPC)
#
# RCTX = N×100+50  (doit correspondre à __RCTX_INTER__ dans osmo-stp.cfg)
#
# Topologie (exemple 3 opérateurs) :
#   STP Op1 (1.23.2 @ 172.20.0.11) ──SCTP──► Inter-STP :2908
#   STP Op2 (2.23.2 @ 172.20.0.12) ──SCTP──► Inter-STP :2908
#   STP Op3 (3.23.2 @ 172.20.0.13) ──SCTP──► Inter-STP :2908
#
#   Routes :
#     1.23.{1,2,3} → as-op1
#     2.23.{1,2,3} → as-op2
#     3.23.{1,2,3} → as-op3
#
# Usage : ./create_interop.sh <n_operators> [output_file]

set -euo pipefail

N_OPERATORS=${1:-2}
OUTPUT_FILE=${2:-"configs/osmo-stp-interop.cfg"}

if ! [[ "$N_OPERATORS" =~ ^[0-9]+$ ]] || [ "$N_OPERATORS" -lt 1 ] || [ "$N_OPERATORS" -gt 9 ]; then
    echo "Usage: $0 <n_operators (1-9)> [output_file]"; exit 1
fi

echo "Génération ${OUTPUT_FILE} — ${N_OPERATORS} opérateur(s)..."

# ── En-tête ────────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << 'EOHEADER'
!
! osmo-stp-interop.cfg — Inter-STP central (hub SS7)
! Généré par create_interop.sh — ne pas éditer manuellement.
!
! Architecture :
!   - 1 AS par opérateur, SANS routing-key (catch-all par opérateur)
!   - Routage basé sur le DPC (point code destination)
!   - dynamic-permitted : les ASP se connectent sans être pré-déclarés
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
 ! Écoute sur 172.20.0.10:2908 — les STPs opérateurs se connectent ici.
 ! dynamic-permitted : pas besoin de pré-déclarer les ASP entrants.
 xua rkm routing-key-allocation dynamic-permitted
 listen m3ua 2908
  local-ip 172.20.0.10
  accept-asp-connections dynamic-permitted
EOHEADER

# ── AS par opérateur (SANS routing-key = catch-all) ───────────────────────────
for i in $(seq 1 "$N_OPERATORS"); do
    local_ip="172.20.0.$((10 + i))"
    cat >> "$OUTPUT_FILE" << EOOPERATOR
!
 ! ── Opérateur ${i} : STP ${i}.23.2 @ ${local_ip} ─────────────────────────
 ! AS sans routing-key : accepte tout le trafic de cet opérateur.
 ! Le routage vers l'opérateur cible se fait sur le DPC via la route-table.
 as as-op${i} m3ua
  traffic-mode override
EOOPERATOR
done

# ── Route-table (match exact /14 = 32 bits en ITU 3.8.3) ──────────────────────
echo "!" >> "$OUTPUT_FILE"
echo " ! ── Table de routage SS7 ────────────────────────────────────────────" >> "$OUTPUT_FILE"
echo " ! Masque 7.255.7 = match exact en format ITU 14-bit (3.8.3 : zone.network.node)" >> "$OUTPUT_FILE"
echo " route-table system" >> "$OUTPUT_FILE"

for i in $(seq 1 "$N_OPERATORS"); do
    cat >> "$OUTPUT_FILE" << EOROUTES
  ! Op${i} : MSC=${i}.23.1  STP=${i}.23.2  BSC=${i}.23.3 → as-op${i}
  update route ${i}.23.1 7.255.7 linkset as-op${i}
  update route ${i}.23.2 7.255.7 linkset as-op${i}
  update route ${i}.23.3 7.255.7 linkset as-op${i}
EOROUTES
done

# ── Résumé ─────────────────────────────────────────────────────────────────────
echo ""
echo "✓  ${OUTPUT_FILE} — ${N_OPERATORS} opérateur(s)"
echo "   Inter-STP PC=0.23.0  @  172.20.0.10:2908"
for i in $(seq 1 "$N_OPERATORS"); do
    rctx=$(( i * 100 + 50 ))
    echo "   Op${i} : STP ${i}.23.2 @ 172.20.0.$((10+i))  RCTX=${rctx}"
done
