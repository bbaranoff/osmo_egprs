# BugFix v2.2.1 — Erreur "nombre entier attendu" (start.sh ligne 462)

**Date :** 2026-03-04  
**Criticalité :** 🔴 Blocker  
**Status :** ✅ Fixé  
**Version Affectée :** v2.2 (start.sh original)

---

## 🔴 Problème Identifié

### Symptôme
```
./start.sh: ligne 462 : [: 0
0 : nombre entier attendu comme expression
```

### Cause Root
La variable `$routes_ok` dans la fonction `wait_inter_stp_ready()` contient **2 lignes** au lieu d'un seul nombre :
```
0
0
```

Cela provient de la chaîne de commandes :
```bash
routes_ok=$(docker exec ... | grep -c "linkset as-op" 2>/dev/null || echo 0)
```

Quand `grep -c` ne trouve rien, il retourne "0\n" (zéro + newline), et le `|| echo 0` ajoute un autre "0", résultant en "0\n0".

### Ligne Problématique
```bash
if [ "$routes_ok" -ge "$min_routes" ]; then  # Ligne 462
    # ERROR: "0\n0" n'est pas un nombre entier valide
```

---

## ✅ Solution

### Changements à Apporter

**Dans la fonction `wait_inter_stp_ready()` (ligne ~220-245) :**

#### AVANT (BUGUÉ)
```bash
wait_inter_stp_ready() {
    local n_operators=$1
    local timeout=90
    local elapsed=0

    echo -ne "${GREEN}[*] Vérification stabilisation inter-STP (routes SS7)${NC}"

    while [ $elapsed -lt $timeout ]; do
        local routes_ok
        routes_ok=$(docker exec "$INTER_STP_CONTAINER" bash -c \
            'echo "show cs7 instance 0 route" | \
             timeout 5 telnet 127.0.0.1 4239 2>/dev/null | \
             grep -c "linkset as-op"' 2>/dev/null || echo 0)

        local min_routes=$(( n_operators * 3 ))
        if [ "$routes_ok" -ge "$min_routes" ]; then  # ❌ ERREUR : $routes_ok = "0\n0"
```

#### APRÈS (FIXÉ)
```bash
wait_inter_stp_ready() {
    local n_operators=$1
    local timeout=90
    local elapsed=0

    echo -ne "${GREEN}[*] Vérification stabilisation inter-STP (routes SS7)${NC}"

    while [ $elapsed -lt $timeout ]; do
        # Vérifier que l'inter-STP a créé les routes via VTY
        # [FIX] Nettoyer la variable : prendre la première ligne seulement
        local routes_ok
        routes_ok=$(docker exec "$INTER_STP_CONTAINER" bash -c \
            'echo "show cs7 instance 0 route" | \
             timeout 5 telnet 127.0.0.1 4239 2>/dev/null | \
             grep -c "linkset as-op"' 2>/dev/null | head -1 || echo 0)
        
        # Assurer que routes_ok est un nombre entier valide
        routes_ok=${routes_ok:-0}
        if ! [[ "$routes_ok" =~ ^[0-9]+$ ]]; then
            routes_ok=0
        fi

        local min_routes=$(( n_operators * 3 ))
        if [ "$routes_ok" -ge "$min_routes" ]; then  # ✓ FIXÉ : $routes_ok = "0" ou "3", etc.
```

### Explications des Fixes

1. **`| head -1`** — Prend uniquement la première ligne de la sortie
   ```
   Avant : "0\n0"
   Après : "0"
   ```

2. **`${routes_ok:-0}`** — Assigne 0 si routes_ok est vide
   ```
   routes_ok= → routes_ok=0
   ```

3. **`if ! [[ "$routes_ok" =~ ^[0-9]+$ ]]`** — Valide que c'est un nombre entier
   ```
   "abc" → routes_ok=0
   "0"   → routes_ok=0 (ok)
   "3"   → routes_ok=3 (ok)
   ```

---

## 📋 Comment Appliquer le Fix

### Option 1 : Télécharger le start.sh Corrigé
Le fichier `start.sh` dans les outputs a déjà été corrigé. Simplement :
```bash
cp /mnt/user-data/outputs/start.sh .
chmod +x start.sh
```

### Option 2 : Appliquer manuellement
Éditer `start.sh`, chercher la fonction `wait_inter_stp_ready()` (ligne ~220), et remplacer toute la fonction par :

```bash
wait_inter_stp_ready() {
    local n_operators=$1
    local timeout=90
    local elapsed=0

    echo -ne "${GREEN}[*] Vérification stabilisation inter-STP (routes SS7)${NC}"

    while [ $elapsed -lt $timeout ]; do
        # Vérifier que l'inter-STP a créé les routes via VTY
        # [FIX] Nettoyer la variable : prendre la première ligne seulement
        local routes_ok
        routes_ok=$(docker exec "$INTER_STP_CONTAINER" bash -c \
            'echo "show cs7 instance 0 route" | \
             timeout 5 telnet 127.0.0.1 4239 2>/dev/null | \
             grep -c "linkset as-op"' 2>/dev/null | head -1 || echo 0)
        
        # Assurer que routes_ok est un nombre entier valide
        routes_ok=${routes_ok:-0}
        if ! [[ "$routes_ok" =~ ^[0-9]+$ ]]; then
            routes_ok=0
        fi

        # Doit avoir au minimum N opérateurs × 3 destinations = 3N lignes
        local min_routes=$(( n_operators * 3 ))
        if [ "$routes_ok" -ge "$min_routes" ]; then
            echo -e " ${GREEN}✓ (${routes_ok} routes)${NC}"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done

    echo -e " ${YELLOW}[timeout après ${elapsed}s, on continue]${NC}"
    return 1
}
```

---

## ✅ Validation du Fix

### Test 1 : Syntaxe bash
```bash
bash -n start.sh
# Résultat attendu : aucune erreur
```

### Test 2 : Vérifier la fonction est bien présente
```bash
grep -A 5 "routes_ok=.*head -1" start.sh
# Résultat attendu : trouvé (ligne avec "head -1")
```

### Test 3 : Lancer le script
```bash
sudo ./start.sh
# Attendre que "wait_inter_stp_ready" s'exécute
# Résultat attendu : pas d'erreur "nombre entier attendu"
```

---

## 📊 Impact du Bug

### Avant Fix
```
[*] Vérification stabilisation inter-STP (routes SS7)...
./start.sh: ligne 462 : [: 0
0 : nombre entier attendu comme expression
./start.sh: ligne 462 : [: 0
0 : nombre entier attendu comme expression
... (boucle infinie d'erreurs)
[timeout...]
(Mais PEUT marcher par chance si timeout assez long)
```

### Après Fix
```
[*] Vérification stabilisation inter-STP (routes SS7).....✓ (6 routes)
(Continue immédiatement sans erreur)
```

---

## 🔗 Fichiers Affectés

| Fichier | Version | Fix Appliqué |
|---------|---------|-------------|
| **start.sh** | v2.2 → v2.2.1 | ✅ Oui (ligne ~220-245) |
| create_interop.sh | v2.2 | ✓ OK |
| run.sh | v2.2 | ✓ OK |
| Other files | v2.2 | ✓ OK |

---

## 🎯 Commande Rapide pour Appliquer le Fix

```bash
cd ~/osmo_egprs

# Télécharger le start.sh v2.2.1 (avec fix)
cp /mnt/user-data/outputs/start.sh .
chmod +x start.sh

# Vérifier la syntaxe
bash -n start.sh && echo "✓ Syntaxe OK"

# Committer
git add start.sh
git commit -m "Bugfix v2.2.1: Fix 'nombre entier attendu' start.sh ligne 462

Cause: Variable \$routes_ok contenait '0\\n0' au lieu de '0'
Symptôme: ./start.sh: ligne 462 : [: 0\\n0 : nombre entier attendu
Solution: Ajouter | head -1 + validation regex

Fichier affecté: start.sh (fonction wait_inter_stp_ready)"
```

---

## 📞 Si le Problème Persiste

### Diagnostic
```bash
# Vérifier manuellement que la fonction est correcte
grep -B2 -A20 "wait_inter_stp_ready()" start.sh | head -30

# Chercher la ligne "head -1"
grep "head -1" start.sh
# Doit trouver : "grep -c \"linkset as-op\"' 2>/dev/null | head -1 || echo 0)"

# Chercher la validation regex
grep "\^[0-9]\+\$" start.sh
# Doit trouver : "if ! [[ \"$routes_ok\" =~ ^[0-9]+$ ]]"
```

### Test du Script
```bash
# Lancer le script et capturer les erreurs
sudo bash -x ./start.sh 2>&1 | grep -E "ligne 462|nombre entier" | head -5

# Si pas d'erreur, c'est bon ✓
```

---

## 📈 Version History

| Version | Status | Notes |
|---------|--------|-------|
| **v2.0** | ✅ OK | Initial PROHIB routes fix |
| **v2.1** | ✅ OK | Documentation + timing |
| **v2.2** | ❌ BUG | start.sh ligne 462 error |
| **v2.2.1** | ✅ FIXED | wait_inter_stp_ready fix |

---

**Status :** ✅ Fixé dans `/mnt/user-data/outputs/start.sh`  
**Version :** v2.2.1  
**Date :** 2026-03-04  
**Urgence :** 🔴 Critique (bloquant)
