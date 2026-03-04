# BugFix v2.2.3 — Point Code Invalide + Placeholders

**Date :** 2026-03-04  
**Criticalité :** 🔴 Blocker  
**Status :** ✅ Fixé  
**Version Affectée :** v2.2.2

---

## 🔴 Problème 1 : Point Code Invalide

### Symptôme
```
Error parsing Pointcode '127.0.0.2'
Invalid point code (127.0.0.2)
Failed to parse the config file 'osmo-stp-interop.cfg'
```

### Cause
La ligne `point-code 127.0.0.2` dans `create_interop.sh` n'est **pas un format valide** pour osmocom.

Les point codes osmocom doivent être au format décimal `X.Y.Z` (exemple: `0.23.0`, `1.23.1`), pas une adresse IP.

### Solution
Remplacer `127.0.0.2` par un **point code osmocom valide** :

```bash
# AVANT (BUGUÉ)
sccp-address osmo-hlr
 point-code 127.0.0.2    ❌ Format IP invalide

# APRÈS (FIXÉ)
sccp-address osmo-hlr
 point-code 2.0.0        ✓ Point code valide
```

---

## 🔴 Problème 2 : Placeholders Non Remplacés

### Symptôme
```
Error parsing Pointcode '__PC_STP__'
Invalid point code (__PC_STP__)
```

### Cause
Les fichiers `osmo-stp.cfg` et `osmo-stp-interop.cfg` contiennent des **placeholders** (`__PC_STP__`, `__OPERATOR_ID__`, etc.) qui ne sont pas remplacés.

Cela arrive quand :
1. Les fichiers sont utilisés directement du repo (sans interpolation)
2. L'étape `apply_config_templates()` ne s'est pas exécutée
3. Les fichiers sont copiés avant la substitution

### Solution
**S'assurer que les placeholders sont remplacés** dans le workflow :

```
1. start.sh lance apply_config_templates()
2. apply_config_templates() copie les templates de configs/
3. Les placeholders sont remplacés (sed) dans le tmpdir
4. Les fichiers interpolés sont montés dans le container via -v
```

**Vérification :**
```bash
# Les fichiers du repo DOIVENT contenir les placeholders
cat configs/osmo-stp.cfg | grep "__PC_STP__"
# Résultat : __PC_STP__ (non remplacé dans le repo)

# Les fichiers montés dans le container doivent être interpolés
docker exec osmo-operator-1 cat /etc/osmocom/osmo-stp.cfg | grep "__PC_STP__"
# Résultat : vide (remplacé dans le container)
```

---

## ✅ Changements à Apporter

### 1. create_interop.sh — Corriger le point code HLR

**Ligne 46 :**

```bash
# AVANT
point-code 127.0.0.2

# APRÈS
point-code 2.0.0
```

### 2. osmo-stp.cfg — Vérifier les placeholders

**Le fichier DOIT contenir :**
```
point-code __PC_STP__          ✓ Placeholder (sera remplacé)
point-code __PC_MSC__          ✓ Placeholder
point-code __PC_BSC__          ✓ Placeholder
```

**Ne PAS avoir :**
```
point-code 0.23.0              ❌ Valeur hardcoded
point-code 127.0.0.2           ❌ Format invalide
```

### 3. Vérifier que start.sh applique les templates

La fonction `apply_config_templates()` DOIT être appelée pour chaque opérateur :

```bash
apply_config_templates "$tmpdir" \
    "$container_ip" "$gateway_ip" \
    "$op_id" "${PC_MSC}" "${PC_STP}" "${PC_BSC}" \
    ...
```

---

## 📋 Comment Appliquer le Fix

### Option 1 : Télécharger la version corrigée

```bash
cp /mnt/user-data/outputs/create_interop.sh .
chmod +x create_interop.sh
```

### Option 2 : Appliquer manuellement

**Éditer create_interop.sh ligne 46 :**
```bash
sed -i 's/point-code 127\.0\.0\.2/point-code 2.0.0/' create_interop.sh
```

---

## ✅ Validation du Fix

```bash
# 1. Vérifier le point code est valide
grep "point-code" create_interop.sh
# Attendu : point-code 2.0.0 (pas 127.0.0.2)

# 2. Vérifier que osmo-stp-interop.cfg génère sans erreur
./create_interop.sh 3 /tmp/test.cfg
# Attendu : pas d'erreur

# 3. Vérifier le contenu du fichier généré
grep "point-code" /tmp/test.cfg | head -3
# Attendu : 
#  point-code 0.23.0  (inter-STP)
#  point-code 2.0.0   (HLR)
#  point-code 1.23.1  (MSC Op1)

# 4. Lancer osmo-stp avec la config générée
docker run -it --rm \
    -v /tmp/test.cfg:/etc/osmocom/osmo-stp.cfg:ro \
    osmocom-run \
    osmo-stp -c /etc/osmocom/osmo-stp.cfg
# Attendu : osmo-stp démarre sans "Failed to parse"
```

---

## 📊 Impact du Bug

### Avant Fix
```
osmo-stp-interop.cfg contient : point-code 127.0.0.2
osmo-stp parse failure
Inter-STP ne démarre pas
wait_inter_stp_ready() timeout
Démarrage bloqué
```

### Après Fix
```
osmo-stp-interop.cfg contient : point-code 2.0.0 ✓
osmo-stp démarre normalement
Routes créées
Inter-STP prêt
Opérateurs démarrent
```

---

## 🔗 Fichiers Affectés

| Fichier | Version | Fix |
|---------|---------|-----|
| **create_interop.sh** | v2.2.2 → v2.2.3 | ✅ Point code 127.0.0.2 → 2.0.0 |
| **osmo-stp.cfg** | v2.2 | ✓ OK (contient placeholders) |

---

## 📈 Version History

| Version | Date | Status | Bug |
|---------|------|--------|-----|
| v2.2 | 2026-03-04 | ❌ BUG | Point code 127.0.0.2 invalide |
| v2.2.1 | 2026-03-04 | ❌ BUG | Idem |
| v2.2.2 | 2026-03-04 | ❌ BUG | Idem |
| **v2.2.3** | **2026-03-04** | **✅ FIXED** | Point code corrigé |

---

## ⚡ Quick Fix

```bash
cd ~/osmo_egprs

# Copier create_interop.sh v2.2.3
cp /mnt/user-data/outputs/create_interop.sh .

# Tester
./create_interop.sh 3 /tmp/test.cfg && echo "✓ OK"

# Committer
git add create_interop.sh
git commit -m "Bugfix v2.2.3: Point code invalide (127.0.0.2 → 2.0.0)"

# Relancer
docker system prune -f
sudo ./start.sh
```

---

**Status :** ✅ Fixé dans `/mnt/user-data/outputs/create_interop.sh`  
**Version :** v2.2.3  
**Impact :** 🔴 Critique (inter-STP startup)
