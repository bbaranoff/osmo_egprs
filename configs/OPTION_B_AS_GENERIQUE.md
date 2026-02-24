# Option B : AS Générique Inter-STP

## Architecture

L'inter-STP accepte **tous les routing contexts** (MSC, BSC, etc.) d'un opérateur via **un seul AS générique par opérateur**.

### Ancien design (INCORRECT) - AS spécifiques

```
Inter-STP:
  as-op1-msc  routing-key 110 1.23.1
  as-op1-bsc  routing-key 130 1.23.3
  as-op2-msc  routing-key 210 2.23.1
  as-op2-bsc  routing-key 230 2.23.3
```

**Problème** :
- Le STP local envoie des messages mais n'annonce pas de routing-key spécifique
- L'inter-STP rejette : "No Configured AS for ASP"

### Nouveau design (CORRECT) - AS générique

```
Inter-STP:
  as-op1  SANS routing-key (accepte tous les messages de Op1)
  as-op2  SANS routing-key (accepte tous les messages de Op2)
```

**Avantage** :
- L'inter-STP accepte tous les messages du STP local
- Le routage se fait automatiquement basé sur les **point-codes destination**
- Plus simple, plus robuste

## Flux de routing

```
MSC Op2 (2.23.1) → message vers 1.23.1
    ↓
STP Op2 (2.23.2)
    → Route locale : 2.23.1, 2.23.3
    → Autres destinations → as-inter (vers inter-STP)
    ↓
Inter-STP (0.23.0)
    ← Reçoit via as-op2 (SANS routing-key)
    → Regarde point-code destination : 1.23.1
    → Route via as-op1 (tout trafic vers Op1)
    ↓
STP Op1 (1.23.2)
    ← Reçoit via as-inter (SANS routing-key)
    → Regarde point-code destination : 1.23.1
    → Route via as-msc (routing-key 110 1.23.1)
    ↓
MSC Op1 (1.23.1) ✓
```

## Configuration inter-STP (générée)

```
cs7 instance 0
 point-code 0.23.0

 asp asp-op1 2910 2908 m3ua
  remote-ip 172.20.0.11
  role sg
  sctp-role server

 as as-op1 m3ua
  asp asp-op1
  traffic-mode override
  # PAS de routing-key !

 asp asp-op2 2910 2908 m3ua
  remote-ip 172.20.0.12
  role sg
  sctp-role server

 as as-op2 m3ua
  asp asp-op2
  traffic-mode override
  # PAS de routing-key !
```

## Configuration STP local (inchangée)

```
cs7 instance 0
 point-code 1.23.2

 as as-msc m3ua
  routing-key 110 1.23.1    ← Accepte MSC local

 as as-bsc m3ua
  routing-key 130 1.23.3    ← Accepte BSC local

 as as-inter m3ua
  traffic-mode override
  # PAS de routing-key !  ← Connexion vers inter-STP
```

## Routes automatiques créées

### Sur Inter-STP

Routes créées automatiquement par **analyse du trafic** :
```
1.23.x → as-op1 (tout trafic vers Op1)
2.23.x → as-op2 (tout trafic vers Op2)
```

### Sur STP Op1

Routes créées par routing-keys locaux :
```
1.23.1/14 → as-msc (routing-key 110)
1.23.3/14 → as-bsc (routing-key 130)
```

Routes vers autres opérateurs : via `as-inter` (default)

## Résultat attendu

### MSC Op1 - Routes
```
1.23.1/14        acces   avail   ✓ (local)
1.23.3/14        acces   avail   ✓ (local)
2.23.1/14        acces   avail   ✓ (via inter-STP)
2.23.3/14        acces   avail   ✓ (via inter-STP)
0.0.0/0          acces   avail   ✓ (default)
```

Plus de route `0.0.0/14 PROHIB` !

### Inter-STP - Logs
```
Plus d'erreur "No Configured AS for ASP"
```

### Inter-STP - AS
```
as-op1       AS_ACTIVE    (pas de routing-key)
as-op2       AS_ACTIVE    (pas de routing-key)
```

## Pourquoi ça marche ?

1. **AS sans routing-key = AS "catch-all"**
   - Accepte tous les messages de l'ASP associé
   - Pas de filtrage par routing context

2. **Routing basé sur point-codes**
   - L'inter-STP regarde le point-code destination
   - Route automatiquement vers le bon opérateur
   - Pas besoin de routing-keys spécifiques

3. **Simplicité**
   - 1 AS par opérateur sur inter-STP
   - Scalable pour N opérateurs
   - Configuration générée automatiquement

## Installation

Remplacer `create_interop.sh` et relancer :
```bash
cp create_interop.sh ~/osmo_egprs/
chmod +x ~/osmo_egprs/create_interop.sh
sudo ~/osmo_egprs/start.sh stop
sudo ~/osmo_egprs/start.sh
```
