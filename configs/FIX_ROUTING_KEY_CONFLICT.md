# Fix : Conflit de routing-keys

## Problème identifié

**Sur STP local Op1** :
```
as-msc       AS_ACTIVE    110        1.23.1   ← MSC local
as-inter-msc AS_ACTIVE    110        1.23.1   ← CONFLIT !
```

**Erreur Inter-STP** :
```
ASP(asp-op1) Received MGMT_ERR 'No Configured AS for ASP'
```

## Explication

### Ancien osmo-stp.cfg (INCORRECT)
```
as as-msc m3ua
  routing-key 110 1.23.1    ← Pour MSC local

as as-inter-msc m3ua
  routing-key 110 1.23.1    ← CONFLIT ! Même routing-key
```

Résultat :
- Le STP local ne sait pas quel AS utiliser pour 1.23.1
- Route PROHIB sur 1.23.1/14
- Le STP local envoie ASPAC avec routing-key 110 à l'inter-STP
- L'inter-STP n'a pas d'AS configuré pour recevoir ce routing-key depuis le STP local
- Erreur "No Configured AS for ASP"

## Solution

### Nouveau osmo-stp.cfg (CORRECT)
```
as as-msc m3ua
  routing-key 110 1.23.1    ← Pour MSC local (KEEP)

as as-bsc m3ua  
  routing-key 130 1.23.3    ← Pour BSC local (KEEP)

as as-inter m3ua
  asp asp-inter
  traffic-mode override
  # PAS DE routing-key !
```

### Pourquoi ça fonctionne ?

**Routing-key sert pour les connexions ENTRANTES** :
- MSC se connecte au STP local → envoie routing-key 110
- STP local a `as-msc` avec routing-key 110 → match → OK

**Routing-key N'EST PAS nécessaire pour les connexions SORTANTES** :
- STP local se connecte à l'inter-STP en tant que client
- Pas besoin d'annoncer un routing-key
- L'inter-STP route le trafic basé sur les point-codes, pas sur les routing-keys

### Flux corrigé

```
MSC Op2 (2.23.1)
    ↓ [routing-key 210]
STP Op2 (2.23.2)
    → as-msc (routing-key 210 2.23.1) ✓
    → trafic vers 1.23.1 → route via as-inter
    ↓ [PAS de routing-key]
Inter-STP (0.23.0)
    ← ASP asp-op2 connecté
    → trafic vers 1.23.1 → route via as-op1-msc
    ↓ [PAS de routing-key]
STP Op1 (1.23.2)
    ← ASP asp-inter connecté via as-inter
    → trafic vers 1.23.1 → route via as-msc
    ↓ [routing-key 110]
MSC Op1 (1.23.1) ✓
```

## Résultat attendu

**Sur MSC Op2** :
```
1.23.1/14        acces   0 5 as-msc     avail   allowed avail   dyn  ✓
2.23.1/14        acces   0 5 as-msc     avail   allowed avail   dyn  ✓
```

Plus de PROHIB !

**Sur STP Op1** :
```
as-msc       AS_ACTIVE    110        1.23.1
as-bsc       AS_ACTIVE    130        1.23.3  
as-inter     AS_ACTIVE    (pas de routing-key)
```

Plus de conflit !

**Sur Inter-STP** :
```
Plus d'erreur "No Configured AS for ASP"
```

## Fichier corrigé

`osmo-stp.cfg` : AS `as-inter` SANS routing-key
