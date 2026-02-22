# Osmocom GSM/EGPRS — Multi-Operator Edition

## Architecture

### Mode net-host (1 opérateur, accès SDR physique)
```
Host OS
 └── Container osmo-operator-1 (--network host)
      ├── osmo-hlr   (127.0.0.2:4222)
      ├── osmo-msc   (PC 1.23.1)
      ├── osmo-stp   (PC 1.23.2)  ← écoute 127.0.0.1:2905
      ├── osmo-bsc   (PC 1.23.3)
      ├── osmo-sgsn
      ├── osmo-ggsn
      └── osmo-bts-trx
```

### Mode bridge (N opérateurs, SS7 inter-op)
```
gsm-inter (172.20.0.0/24)
 └── osmo-inter-stp (172.20.0.10)  ← STP central inter-opérateurs

gsm-net-op1 (172.20.1.0/24)
 └── osmo-operator-1 (172.20.1.10) — aussi sur gsm-inter:172.20.0.11
      ├── osmo-stp (PC 1.23.2) → connecté à inter-STP
      └── stack complète MCC=001 MNC=01

gsm-net-op2 (172.20.2.0/24)
 └── osmo-operator-2 (172.20.2.10) — aussi sur gsm-inter:172.20.0.12
      ├── osmo-stp (PC 2.23.2) → connecté à inter-STP
      └── stack complète MCC=001 MNC=02
```

## Placeholders dans les configs

| Placeholder       | Valeur résolue                                  |
|-------------------|-------------------------------------------------|
| `__CONTAINER_IP__`| IP du container sur son réseau opérateur        |
| `__GATEWAY_IP__`  | Passerelle Docker (DNS data plane)              |
| `__HLR_IP__`      | 127.0.0.2 (toujours local dans Osmocom)         |
| `__INTER_STP_IP__`| 172.20.0.10 (inter-STP) ou 127.0.0.1 (host)    |
| `__OPERATOR_ID__` | Numéro de l'opérateur (1, 2, 3…)               |
| `__PC_MSC__`      | Point Code MSC (N.23.1)                         |
| `__PC_STP__`      | Point Code STP (N.23.2)                         |
| `__PC_BSC__`      | Point Code BSC (N.23.3)                         |
| `__MCC__`         | Mobile Country Code                             |
| `__MNC__`         | Mobile Network Code                             |
| `__OP_NAME__`     | Nom réseau affiché sur le mobile                |

## Utilisation

```bash
# Build
sudo ./build.sh

# Démarrage (interactif)
sudo ./start.sh

# Arrêt
sudo ./start.sh stop
```

## Plan SS7 inter-opérateurs

```
Opérateur N :
  BSC  PC = N.23.3
  MSC  PC = N.23.1
  STP  PC = N.23.2  ──► Inter-STP (PC 0.0.1) via 172.20.0.10:2905
```

L'inter-STP route les messages MAP entre opérateurs via les AS dynamiques.

## Ports utilisés (par container)

| Port  | Service         |
|-------|-----------------|
| 2905  | STP M3UA        |
| 2906  | MSC local SCTP  |
| 2907  | BSC local SCTP  |
| 2909  | STP → inter-STP |
| 4222  | HLR GSUP        |
| 4243  | osmo-stp VTY    |
| 4242  | osmo-bsc VTY    |
| 4254  | osmo-msc VTY    |
| 4258  | osmo-hlr VTY    |
| 23000 | SGSN NS UDP     |
| 23001 | BSC NSVC UDP    |
