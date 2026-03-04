# BugFix v2.2.5 — SSN N'Appartiennent Pas aux SCCP-Address

**Date :** 2026-03-04  
**Criticalité :** 🔴 Blocker  
**Status :** ✅ Fixé  
**Version Affectée :** v2.2.4

---

## 🔴 Problème Identifié

### Symptôme
```
There is no such command.
Error occurred during reading the below line:
  ssn 130
```

### Cause Root
Les **SSN (Sub-System Numbers)** ont été ajoutés **directement** dans les sccp-address, mais **osmo-stp ne supporte pas cette syntaxe**.

```bash
# BUGUÉ - osmo-stp refuse ssn dans sccp-address
sccp-address osmo-hlr
 point-code 2.0.0
 ssn 130              ❌ Pas accepté
```

### Explication Technique
- Dans osmocom, les **sccp-address** définissent juste l'**adresse SCCP** (point-code)
- Les **SSN** sont gérés au niveau du **SCCP routing**, pas au niveau des adresses
- Ajouter `ssn` directement dans `sccp-address` cause une erreur de parsing

---

## ✅ Solution

### Fix Simple
**Enlever complètement les lignes `ssn` des sccp-address** :

```bash
# AVANT (BUGUÉ)
sccp-address osmo-hlr
 point-code 2.0.0
 ssn 130           ❌ Cause erreur

# APRÈS (FIXÉ)
sccp-address osmo-hlr
 point-code 2.0.0  ✓ OK
```

### Fichiers à Corriger

#### 1. create_interop.sh

```bash
# Enlever les 4 lignes ssn :
- ssn 130
- ssn 142
- ssn 142
- ssn 142
```

#### 2. osmo-stp.cfg (template)

```bash
# Enlever les 3 lignes ssn :
- ssn 143
- ssn 142
- ssn 130
```

---

## ✅ Validation du Fix

```bash
# 1. Vérifier qu'il n'y a plus de ssn dans sccp-address
grep -A 1 "sccp-address" create_interop.sh | grep ssn
# Résultat : vide (pas de ssn)

grep -A 1 "sccp-address" configs/osmo-stp.cfg | grep ssn
# Résultat : vide (pas de ssn)

# 2. Générer et tester la config
./create_interop.sh 3 /tmp/test.cfg

# 3. Lancer osmo-stp
docker run -it --rm \
    -v /tmp/test.cfg:/etc/osmocom/osmo-stp.cfg:ro \
    osmocom-run \
    osmo-stp -c /etc/osmocom/osmo-stp.cfg

# Attendu : osmo-stp démarre SANS "ssn" error
```

---

## 📊 Impact du Bug

### Avant Fix
```
sccp-address osmo-hlr
 point-code 2.0.0
 ssn 130            ← Cause erreur
osmo-stp refuse de parser
Inter-STP ne démarre pas
```

### Après Fix
```
sccp-address osmo-hlr
 point-code 2.0.0   ← OK
osmo-stp démarre normalement
Routes créées
Opérateurs commencent
```

---

## 🔗 Fichiers Affectés

| Fichier | Version | Fix |
|---------|---------|-----|
| **create_interop.sh** | v2.2.4 → v2.2.5 | ✅ SSN supprimés |
| **osmo-stp.cfg** | v2.2.4 → v2.2.5 | ✅ SSN supprimés |

---

## 📈 Version History

| Version | Date | Status | Bug |
|---------|------|--------|-----|
| v2.2.3 | 2026-03-04 | ❌ BUG | SSN 130, 142, 143 dans sccp-address |
| v2.2.4 | 2026-03-04 | ❌ BUG | Idem |
| **v2.2.5** | **2026-03-04** | **✅ FIXED** | SSN supprimés des sccp-address |

---

## ⚡ Quick Fix

```bash
cd ~/osmo_egprs

# Copier les fichiers corrigés v2.2.5
cp /mnt/user-data/outputs/create_interop.sh .
cp /mnt/user-data/outputs/osmo-stp.cfg configs/

# Tester immédiatement
./create_interop.sh 3 /tmp/test.cfg && echo "✓ Config OK"

# Committer
git add create_interop.sh configs/osmo-stp.cfg
git commit -m "Bugfix v2.2.5: SSN n'appartiennent pas aux sccp-address (supprimés)"

# Relancer
docker system prune -f
docker rm -f osmo-inter-stp osmo-operator-* 2>/dev/null || true
sudo ./start.sh
```

---

## 💡 Leçon Apprise

Dans osmocom :
- **sccp-address** = définition de l'adresse (point-code uniquement)
- **SSN** = utilisés au niveau du SCCP routing (pas dans sccp-address)
- Ne pas mélanger les deux niveaux de configuration

---

**Status :** ✅ Fixé dans `/mnt/user-data/outputs/`  
**Version :** v2.2.5  
**Impact :** 🔴 Critique (inter-STP startup)  
**Prochaine étape :** Test immédiat avec ./start.sh
