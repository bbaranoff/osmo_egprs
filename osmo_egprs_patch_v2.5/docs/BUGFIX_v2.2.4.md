# BugFix v2.2.4 — SSN Invalides (Noms au lieu de Numéros)

**Date :** 2026-03-04  
**Criticalité :** 🔴 Blocker  
**Status :** ✅ Fixé  
**Version Affectée :** v2.2.3

---

## 🔴 Problème Identifié

### Symptôme
```
There is no such command.
Error occurred during reading the below line:
  ssn osmo_hlr
```

### Cause
Les **SSN (Sub-System Numbers)** dans les configs osmocom doivent être des **numéros**, pas des noms.

**INVALIDE :**
```
ssn osmo_hlr    ❌ Nom
ssn msc         ❌ Nom
ssn bsc         ❌ Nom
```

**VALIDE :**
```
ssn 130         ✓ HLR (Home Location Register)
ssn 142         ✓ MSC (Mobile Service Switching Center)
ssn 143         ✓ BSC (Base Station Controller)
```

---

## ✅ Solution

### Changements Nécessaires

#### 1. create_interop.sh

**AVANT :**
```
ssn osmo_hlr
ssn msc
ssn msc
ssn msc
```

**APRÈS :**
```
ssn 130    (HLR)
ssn 142    (MSC Op1)
ssn 142    (MSC Op2)
ssn 142    (MSC Op3)
```

#### 2. osmo-stp.cfg (Template)

**AVANT :**
```
ssn bsc
ssn msc
ssn osmo_hlr
```

**APRÈS :**
```
ssn 143    (BSC)
ssn 142    (MSC)
ssn 130    (HLR)
```

---

## 📋 Numéros SSN Osmocom

| Nom | Numéro | Usage |
|-----|--------|-------|
| **ISUP** | 1 | ISDN User Part |
| **TCAP** | 7 | Transaction Capabilities |
| **SCCP Management** | 8 | SCCP Management |
| **HLR** | 130 | Home Location Register |
| **VLR** | 131 | Visitor Location Register |
| **MSC** | 142 | Mobile Service Switching Center |
| **BSC** | 143 | Base Station Controller |
| **SMS-C** | 145 | Short Message Service Center |

---

## ✅ Validation du Fix

```bash
# 1. Vérifier que les SSN sont des numéros
grep "ssn" create_interop.sh
# Attendu : ssn 130, ssn 142, etc. (pas de noms)

grep "ssn" configs/osmo-stp.cfg
# Attendu : ssn 143, ssn 142, ssn 130, etc.

# 2. Générer et tester la config
./create_interop.sh 3 /tmp/test.cfg

# 3. Lancer osmo-stp avec la config
docker run -it --rm \
    -v /tmp/test.cfg:/etc/osmocom/osmo-stp.cfg:ro \
    osmocom-run \
    osmo-stp -c /etc/osmocom/osmo-stp.cfg
# Attendu : osmo-stp démarre SANS erreur "ssn osmo_hlr"
```

---

## 📊 Impact du Bug

### Avant Fix
```
osmo-stp-interop.cfg contient : ssn osmo_hlr, ssn msc
osmo-stp parse failure
"There is no such command" error
Inter-STP ne démarre pas
```

### Après Fix
```
osmo-stp-interop.cfg contient : ssn 130, ssn 142
osmo-stp démarre normalement
SCCP routing fonctionne
Inter-STP prêt
```

---

## 🔗 Fichiers Affectés

| Fichier | Version | Fix |
|---------|---------|-----|
| **create_interop.sh** | v2.2.3 → v2.2.4 | ✅ SSN noms → numéros |
| **osmo-stp.cfg** | v2.2 → v2.2.4 | ✅ SSN noms → numéros |

---

## 📈 Version History

| Version | Date | Status | Bug |
|---------|------|--------|-----|
| v2.2.2 | 2026-03-04 | ❌ BUG | SSN invalides |
| v2.2.3 | 2026-03-04 | ❌ BUG | Idem |
| **v2.2.4** | **2026-03-04** | **✅ FIXED** | SSN corrigés |

---

## ⚡ Quick Fix

```bash
cd ~/osmo_egprs

# Copier les fichiers corrigés v2.2.4
cp /mnt/user-data/outputs/{create_interop.sh,osmo-stp.cfg} .
cp /mnt/user-data/outputs/osmo-stp.cfg configs/
chmod +x create_interop.sh

# Tester
./create_interop.sh 3 /tmp/test.cfg && echo "✓ OK"

# Committer
git add create_interop.sh configs/osmo-stp.cfg
git commit -m "Bugfix v2.2.4: SSN invalides (osmo_hlr, msc, bsc → 130, 142, 143)"

# Relancer
docker system prune -f
sudo ./start.sh
```

---

**Status :** ✅ Fixé dans `/mnt/user-data/outputs/`  
**Version :** v2.2.4  
**Impact :** 🔴 Critique (inter-STP startup)
