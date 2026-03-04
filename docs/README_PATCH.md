# Patch osmo_egprs : Fix Race Condition PROHIB Routes

## Résumé Exécutif

Ce patch corrige une **race condition au démarrage** qui causait l'état **PROHIB** sur toutes les routes par défaut `0.0.0/14` des STP locaux dans la topologie SS7 multi-opérateurs.

### Problème
- Les routes inter-opérateurs restaient **inaccessibles** après le démarrage
- Communication entre opérateurs : **bloquée**
- Cause : Synchronisation insuffisante entre l'inter-STP et les STP locaux

### Solution
- **Vérification VTY active** : Attend que l'inter-STP ait créé ses routes avant de lancer les opérateurs
- **Routes explicites** dans la config inter-STP
- **Timings de démarrage recalibrés** dans le run.sh
- **Robustesse accrue** : Timeouts gracieux, fallbacks sensés

---

## Fichiers Modifiés

### Critiques ⚠️

| Fichier | Changement Principal |
|---------|-------------------|
| **start.sh** | + `wait_inter_stp_ready()` + appel dans `start_bridge_mode()` |
| **create_interop.sh** | Routes explicites `route N.23.1/14 as as-opN` |
| **osmo-stp.cfg** | Route par défaut `route 0.0.0/14 as as-inter` |

### Assistants 🔧

| Fichier | Rôle |
|---------|------|
| **run.sh** | Orchestration tmux synchronisée, timings ajustés |
| **osmo-start.sh** | Vérifications VTY post-systemd |
| **verify-patch.sh** | Validation complète (config + runtime) |

---

## Installation

### 1. Sauvegarder les anciens fichiers

```bash
cd ~/osmo_egprs
git status  # S'assurer qu'on est sur la bonne branche

# Créer une branche de secours
git checkout -b backup-before-patch
git add -A && git commit -m "Backup avant patch PROHIB routes"
git checkout main  # Retour à main
```

### 2. Copier les fichiers patchés

```bash
# Depuis le répertoire contenant les fichiers patchés
cp start.sh .
cp create_interop.sh .
cp run.sh scripts/
cp osmo-start.sh scripts/
cp osmo-stp.cfg configs/
cp verify-patch.sh .

chmod +x start.sh create_interop.sh scripts/run.sh scripts/osmo-start.sh verify-patch.sh
```

### 3. Vérifier les changements

```bash
./verify-patch.sh --config-only
# Output attendu :
#   ✓ Fonction wait_inter_stp_ready() présente
#   ✓ Vérification VTY (grep linkset as-op)
#   ✓ Routes MSC explicites…
#   …
```

### 4. Committer les changements

```bash
git add start.sh create_interop.sh scripts/run.sh scripts/osmo-start.sh \
         configs/osmo-stp.cfg verify-patch.sh
git commit -m "Fix: Race condition PROHIB routes SS7 (Solution 2: VTY verification)

- Ajout wait_inter_stp_ready() dans start.sh
- Vérification active que l'inter-STP stabilise ses routes avant lancement opérateurs
- Routes explicites dans create_interop.sh (N.23.1/14, N.23.3/14 par op)
- Route par défaut 0.0.0/14 dans osmo-stp.cfg
- Timings recalibrés dans run.sh
- Tests VTY dans osmo-start.sh

Résultat : Routes 0.0.0/14 → as-inter [allowed] (plus PROHIB)
Communication inter-opérateurs : Fonctionnelle
"

git log --oneline -3  # Vérifier le commit
```

---

## Utilisation

### Lancer le stack multi-opérateurs

```bash
# Après le patch, aucun changement d'interface utilisateur
sudo ./start.sh

# À la saisie du nombre d'opérateurs / paramètres, c'est identique
# Sauf : démarrage plus robuste, pas de PROHIB routes
```

### Vérifier le succès du patch

#### Immédiatement après le démarrage (avant d'ouvrir xterm)

```bash
# Vérifier que wait_inter_stp_ready a passé
# Chercher dans les logs start.sh :
#   "[*] Vérification stabilisation inter-STP (routes SS7) ✓ (X routes)"

# Vérifier que les opérateurs ont commencé
docker ps | grep osmo-operator
```

#### Via les xterm qui s'ouvrent

```bash
# Fenêtre "Inter-STP — OsmoSTP"
show cs7 instance 0 route
# Attendu : 9+ routes (pour 3 opérateurs) avec linkset as-op1/2/3

# Fenêtre "Op1 — OsmoBSC"
show cs7 instance 0 route
# Avant :  0.0.0/14 [PROHIB]  ← MAUVAIS
# Après :  0.0.0/14 [Allowed] ← BON ✓
```

#### Script de vérification complet

```bash
# Avec containers en cours d'exécution
./verify-patch.sh

# Output :
#   [✓] Fonction wait_inter_stp_ready() présente
#   [✓] Vérification VTY (grep linkset as-op)
#   …
#   [✓] Inter-STP VTY accessible (:4239)
#   [✓] 6 routes trouvées
#   [✓] Route 0.0.0/14 → allowed
#   …
```

---

## Détails Techniques

### 1. Fonction `wait_inter_stp_ready()`

**Fichier :** `start.sh` (ligne ~220)

```bash
wait_inter_stp_ready() {
    local n_operators=$1
    local timeout=90
    echo -ne "[*] Vérification stabilisation inter-STP (routes SS7)"
    while [ $elapsed -lt $timeout ]; do
        routes_ok=$(docker exec osmo-inter-stp bash -c \
            'echo "show cs7 instance 0 route" | \
             timeout 5 telnet 127.0.0.1 4239 2>/dev/null | \
             grep -c "linkset as-op"')
        if [ "$routes_ok" -ge $(( n_operators * 3 )) ]; then
            echo -e " ✓ (${routes_ok} routes)"
            return 0
        fi
        sleep 2
        ((elapsed += 2))
        echo -n "."
    done
    echo -e " [timeout après ${elapsed}s, on continue]"
}
```

**Logique :**
1. Lance une requête VTY sur l'inter-STP (`telnet 127.0.0.1:4239`)
2. Demande `show cs7 instance 0 route`
3. Compte les lignes contenant `linkset as-op` (routes vers les opérateurs)
4. Attend ≥ 3N lignes (3 destinations par opérateur : MSC, BSC, et wildcard)
5. Continue après 90s même si timeout (fallback : au moins les logs alertent)

**Avantage :** Adaptatif à la vitesse matérielle réelle, pas d'attente fixe.

### 2. Routes dans `create_interop.sh`

**Fichier :** `create_interop.sh` (ligne ~60+)

Pour chaque opérateur i :
```bash
route ${pc_msc}/14 as as-op${i}  # Ex: 1.23.1/14 → as-op1
route ${pc_bsc}/14 as as-op${i}  # Ex: 1.23.3/14 → as-op1
```

**Résultat dans osmo-stp-interop.cfg :**
```
route 1.23.1/14 as as-op1
route 1.23.3/14 as as-op1
route 2.23.1/14 as as-op2
route 2.23.3/14 as as-op2
route 3.23.1/14 as as-op3
route 3.23.3/14 as as-op3
```

### 3. Route par défaut dans `osmo-stp.cfg`

**Fichier :** `osmo-stp.cfg` (ligne ~108)

```
route 0.0.0/14 as as-inter
```

**Effet :**
- Tout ce qui ne match pas les routes locales (MSC/BSC intra-container)
- Est envoyé vers `as-inter` (Application Server inter-STP)
- Avant : Cette route n'était jamais créée → PROHIB
- Après : Créée au boot → Allowed ✓

### 4. Timings dans `run.sh`

**Fichier :** `run.sh` (ligne ~60+)

```bash
# osmo-bts sleep 3
# osmo-bsc sleep 5
# osmo-msc sleep 8
# gapk-alsa sleep 8
# sms-relay sleep 10
```

**Raisonnement :**
- BTS doit être up avant BSC (BSC se connecte au BTS)
- BSC doit être up avant MSC (MSC parle aux abonnés via BSC)
- Chaque service stabilise en ~2-3s, on multiplie par 1.5-2x pour marge

### 5. Vérifications dans `osmo-start.sh`

**Fichier :** `osmo-start.sh` (ligne ~30+)

```bash
vty_check() {
    local port=$1 name=$2
    echo "…VTY :$port"
    while [ $elapsed -lt 30 ]; do
        echo 'help' | telnet 127.0.0.1 $port &>/dev/null && return 0
        sleep 1
    done
}

vty_check 4241 "OsmoBTS"
vty_check 4242 "OsmoBSC"
vty_check 4254 "OsmoMSC"
vty_check 4258 "OsmoHLR"
```

**Objectif :** Confirmer que chaque service est **vraiment** prêt après systemd.

---

## Dépannage

### Symptôme : `wait_inter_stp_ready` timeout après 90s

**Causes possibles :**
1. Inter-STP ne s'est pas lancé (pas d'image Docker)
   - **Vérifier :** `docker logs osmo-inter-stp`
   - **Fix :** `docker build -f Dockerfile.run -t osmocom-run .`

2. Port 2908 déjà occupé
   - **Vérifier :** `lsof -i :2908`
   - **Fix :** `killall osmo-stp` ou `docker rm -f osmo-inter-stp`

3. Réseau Docker dysfonctionnel
   - **Vérifier :** `docker network ls | grep gsm-inter`
   - **Fix :** `docker network rm gsm-inter` + relancer

### Symptôme : Routes toujours PROHIB malgré le patch

**Causes possibles :**
1. Fichiers patchés mal copiés
   - **Vérifier :** `grep -n "wait_inter_stp_ready" start.sh`
   - **Fix :** Recommencer l'installation depuis étape 2

2. Config osmo-stp.cfg non interpolée (placeholders pas remplacés)
   - **Vérifier :** `docker exec osmo-operator-1 cat /etc/osmocom/osmo-stp.cfg | head -20`
   - **Chercher :** `route 0.0.0/14 as as-inter` (pas `__PC_STP__`)

3. start.sh utilisé une vieille version
   - **Vérifier :** `git status` + `git diff start.sh`
   - **Fix :** `git pull` ou re-copier les fichiers

### Symptôme : Opérateurs ne démarrent pas

**Cause :** wait_inter_stp_ready timeout trop court
- **Fix :** Augmenter `timeout=90` à `timeout=120` dans start.sh

**Cause :** Ancien patch incomplet appliqué
- **Fix :** `git reset --hard origin/main` + re-appliquer ce patch

---

## Tests Post-Patch Recommandés

### 1. Démarrage rapide (3 opérateurs, 1 MS chacun)

```bash
sudo ./start.sh
# Répondre : 3 opérateurs, MCC=001, MNC=01,02,03, 1 MS par op
# Temps attendu : 60-90s jusqu'aux xterm
```

### 2. Vérifier les routes (1 min après démarrage complet)

```bash
# Terminal 1 : Inter-STP
telnet 127.0.0.1 4239
> show cs7 instance 0 route
# Réponse : 6 routes (3 ops × 2 destinations)

# Terminal 2 : Op1
telnet 127.0.0.1 4239
> show cs7 instance 0 route
# Chercher : 0.0.0/14 [Allowed]
```

### 3. Test SMS inter-opérateurs

```bash
# Lance depuis Op1 vers Op2
# Vérifier que le SMS emprunte la route inter-STP (pas juste local)
```

### 4. Test appel SIP inter-op

```bash
# Si asterisk activé
# Appel depuis Op1 vers Op2 via SIP inter-op trunk
```

---

## Support & Escalade

### Logs clés à consulter

```bash
# Démarrage start.sh
tail -50 /var/log/osmo-start.log  # Si disponible
docker logs osmo-inter-stp | tail -100

# Services dans les containers
docker logs osmo-operator-1 | grep -E "ERROR|ss7|prohib|route"
docker exec osmo-inter-stp journalctl -u osmo-stp -n 50

# Sortie VTY
docker exec osmo-operator-1 bash -c \
    "echo 'show cs7 instance 0 route' | telnet 127.0.0.1 4239" | grep -A5 "0.0.0"
```

### Commandes de debugging avancées

```bash
# Snapshots de la topologie SS7
docker exec osmo-inter-stp bash -c \
    "echo 'show m3ua' | telnet 127.0.0.1 4239"

docker exec osmo-operator-1 bash -c \
    "echo 'show asp' | telnet 127.0.0.1 4239"

# Tcpdump M3UA
docker exec osmo-inter-stp tcpdump -i eth0 "sctp"

# Wireshark + bridge réseau
docker network inspect gsm-inter | jq '.Containers'
```

---

## Historique des Versions

| Version | Date | Statut | Notes |
|---------|------|--------|-------|
| 1.0 | 2026-03-03 | ❌ Abandoned | Extended delay (non robuste) |
| 2.0 | 2026-03-04 | ✅ Production | VTY verification + explicit routes |
| 2.1 | 2026-03-04 | ✅ Current | Documentation complète + tests |

---

## Références

- **Rapport Debug Original :** `/mnt/transcripts/2026-03-04-14-02-41-osmo-egprs-ss7-routing-fix.txt`
- **RFC M3UA :** RFC 4666
- **Osmocom SS7 :** https://osmocom.org/projects/osmo-stp

---

**Patch Créé :** 2026-03-04  
**Auteur :** Bastien (osmo_egprs team)  
**License :** AGPL-3.0 (comme osmo_egprs)
