# Instructions d'installation - Fix complet

## Problèmes résolus

1. ✅ Routing contexts (RCTX) incorrects → variables `__RCTX_MSC__` et `__RCTX_BSC__`
2. ✅ Point-code inter-STP incorrect (0.23.2 → 0.23.0)
3. ✅ Commande `point-code override dpc` inexistante → supprimée
4. ✅ Fichier temporaire non trouvé → utilisation de `$inter_cfg`
5. ✅ **Conflit de routing-keys** → `as-inter` SANS routing-key

## Fichiers à remplacer

### 1. configs/osmo-stp.cfg
**IMPORTANT** : `as-inter` n'a **PAS de routing-key** (c'est une connexion sortante client)
```
as as-inter m3ua
  asp asp-inter
  traffic-mode override
```

### 2. configs/osmo-msc.cfg
Utilise `__RCTX_MSC__` au lieu de `110` hardcodé

### 3. configs/osmo-bsc.cfg  
Utilise `__RCTX_BSC__` au lieu de `3` hardcodé

### 4. create_interop.sh (nouveau fichier)
Script qui génère `osmo-stp-interop.cfg` dynamiquement

### 5. start.sh
Fonction `start_inter_stp()` modifiée pour appeler `create_interop.sh`

### 6. Supprimer configs/osmo-stp-interop.cfg
Ce fichier est maintenant généré dynamiquement

## Installation

```bash
cd ~/osmo_egprs

# 1. Sauvegarder les anciens fichiers
mkdir -p backup
cp configs/*.cfg start.sh backup/

# 2. Remplacer les fichiers
cp /path/to/osmo-stp.cfg configs/
cp /path/to/osmo-msc.cfg configs/
cp /path/to/osmo-bsc.cfg configs/
cp /path/to/create_interop.sh .
chmod +x create_interop.sh
cp /path/to/start.sh .
chmod +x start.sh

# 3. Supprimer l'ancien config inter-STP (sera généré)
rm configs/osmo-stp-interop.cfg

# 4. Arrêter les containers
sudo ./start.sh stop

# 5. Relancer
sudo ./start.sh
```

## Vérification

### 1. Routes sur MSC Op2 (plus de PROHIB !)
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4254
show cs7 instance 0 route
```

Attendu :
```
1.23.1/14        acces   0 5 as-msc     avail   allowed avail   dyn  ✓
2.23.1/14        acces   0 5 as-msc     avail   allowed avail   dyn  ✓
```

### 2. AS sur STP Op1 (plus de conflit !)
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4239
show cs7 instance 0 as all
```

Attendu :
```
as-msc       AS_ACTIVE    110        1.23.1
as-bsc       AS_ACTIVE    130        1.23.3
as-inter     AS_ACTIVE    (pas de routing-key)
```

### 3. Logs Inter-STP (plus d'erreur !)
```bash
sudo docker exec -ti osmo-inter-stp cat /tmp/osmo-stp.log | grep "ERROR\|No Configured"
```

Attendu : **aucune erreur**

## Explication technique

### Pourquoi `as-inter` n'a pas de routing-key ?

**Routing-key sert uniquement pour les connexions ENTRANTES (server)** :
- MSC → STP local : MSC envoie routing-key 110 → STP accepte via `as-msc`
- BSC → STP local : BSC envoie routing-key 130 → STP accepte via `as-bsc`

**Pour les connexions SORTANTES (client), pas besoin de routing-key** :
- STP local → Inter-STP : connexion client, pas de routing-key
- Inter-STP route le trafic basé sur les point-codes

### Flux complet

```
MSC Op2 (2.23.1)
    ↓ ASPAC routing-key 210
STP Op2 (2.23.2) → as-msc accepte (routing-key 210 2.23.1)
    ↓ Trafic vers 1.23.1 → route via as-inter
Inter-STP (0.23.0)
    ↓ Reçoit via as-op2-msc
    ↓ Trafic vers 1.23.1 → route via as-op1-msc
STP Op1 (1.23.2)
    ↓ Reçoit via as-inter (pas de routing-key)
    ↓ Trafic vers 1.23.1 → route via as-msc
MSC Op1 (1.23.1) ✓
```

## Résumé des corrections

| Fichier | Changement | Raison |
|---------|-----------|--------|
| osmo-stp.cfg | `as-inter` SANS routing-key | Éviter conflit avec `as-msc` |
| osmo-msc.cfg | `__RCTX_MSC__` au lieu de 110 | Variables dynamiques |
| osmo-bsc.cfg | `__RCTX_BSC__` au lieu de 3 | Variables dynamiques |
| create_interop.sh | Nouveau script | Génération dynamique inter-STP |
| start.sh | Appel create_interop.sh | Utiliser config générée |

Tous les fichiers sont dans `/mnt/user-data/outputs/`
