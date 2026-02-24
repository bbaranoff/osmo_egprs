# Troubleshooting Wireshark GSMTAP

Guide complet pour débugger la capture GSMTAP avec Wireshark en mode Docker bridge.

## Problème : "Je ne vois rien dans Wireshark"

### Cause racine

En mode **bridge Docker**, les containers sont sur un réseau isolé (172.20.0.0/24).

```
┌──────────────────────────────────────────┐
│        Hôte (votre machine)              │
│  Interface: any, lo, eth0, wlan0         │
│  Wireshark écoute ici ❌                 │
└──────────────────────────────────────────┘
              ↑ Pas de trafic !
              │
┌─────────────┴────────────────────────────┐
│    Réseau Docker Bridge (gsm-inter)      │
│    172.20.0.0/24                         │
│    Gateway: 172.20.0.1                   │
│                                          │
│  ┌────────────────┐  ┌────────────────┐ │
│  │ osmo-operator-1│  │ osmo-operator-2│ │
│  │  172.20.0.11   │  │  172.20.0.12   │ │
│  │                │  │                │ │
│  │ GSMTAP → ???   │  │ GSMTAP → ???   │ │
│  └────────────────┘  └────────────────┘ │
└──────────────────────────────────────────┘
```

Si GSMTAP envoie vers `0.0.0.0` depuis le container, **le trafic ne sort pas** !

---

## Solution 1 : Utiliser __GATEWAY_IP__ (RECOMMANDÉ)

### Modifier les configs

**Dans osmo-bts.cfg, osmo-bts-trx.cfg, osmo-bsc.cfg, osmo-pcu.cfg** :

```
# AVANT (ne fonctionne pas en bridge)
log gsmtap 0.0.0.0

# APRÈS (fonctionne en bridge)
log gsmtap __GATEWAY_IP__
```

La variable `__GATEWAY_IP__` est automatiquement remplacée par `172.20.0.1` par start.sh.

### Wireshark sur l'hôte

```bash
# Capturer sur ANY (inclut le bridge)
sudo wireshark -k -i any -f "udp port 4729" &

# OU capturer spécifiquement sur le bridge Docker
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
sudo wireshark -k -i br-${BRIDGE_IF} -f "udp port 4729" &
```

### Vérification

```bash
# 1. Vérifier que GSMTAP sort du container
sudo tcpdump -i any -n udp port 4729
# Vous devez voir : 172.20.0.11 > 172.20.0.1

# 2. Vérifier dans les logs BTS
sudo docker exec -ti osmo-operator-1 grep -i gsmtap /var/log/osmocom/osmo-bts.log
```

---

## Solution 2 : Capturer sur l'interface bridge Docker

### Sans modifier les configs

**Identifier l'interface bridge** :

```bash
# Méthode 1 : Via docker network
docker network inspect gsm-inter | grep -i "com.docker.network.bridge.name"

# Méthode 2 : Via ip addr
ip addr show | grep "br-"
# Exemple de sortie : br-a1b2c3d4e5f6

# Méthode 3 : Automatique
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
echo "Interface bridge: br-${BRIDGE_IF}"
```

**Capturer avec tcpdump** :

```bash
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
sudo tcpdump -i br-${BRIDGE_IF} -n udp port 4729 -w /tmp/gsmtap.pcap
```

**Capturer avec Wireshark** :

```bash
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
sudo wireshark -k -i br-${BRIDGE_IF} -f "udp port 4729" &
```

Ou manuellement dans Wireshark :
1. Capture → Options
2. Interface : Sélectionner `br-xxxxx`
3. Capture Filter : `udp port 4729`
4. Start

---

## Solution 3 : Mode net-host (Alternatif)

### Pour 1 seul opérateur avec SDR physique

En mode **net-host**, les containers partagent le réseau de l'hôte.

```bash
# Lancer en mode net-host
sudo ./start.sh
# Choix : 1) net-host

# Wireshark sur loopback fonctionne directement
sudo wireshark -k -i lo -f "udp port 4729" &
```

**Limitation** : Mode net-host ne supporte qu'**1 seul opérateur**.

---

## Diagnostic étape par étape

### Étape 1 : Vérifier la config GSMTAP

```bash
# Entrer dans le container BTS
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4241

# Vérifier config
show bts 0

# Chercher :
# gsmtap-sapi ccch
# gsmtap-sapi bcch
# ... (doit avoir 11 lignes)
```

### Étape 2 : Vérifier le réseau Docker

```bash
# Inspecter le réseau gsm-inter
sudo docker network inspect gsm-inter

# Trouver :
# - "Gateway": "172.20.0.1"  ← IP du gateway
# - Containers avec leurs IPs (172.20.0.11, 172.20.0.12, etc.)
```

### Étape 3 : Vérifier les paquets UDP sortants

```bash
# Capturer TOUT le trafic UDP 4729 (toutes interfaces)
sudo tcpdump -i any -n udp port 4729 -v

# Vous devez voir :
# 172.20.0.11.xxxxx > 172.20.0.1.4729: UDP, length 60
```

Si rien → GSMTAP n'est pas activé ou mal configuré.

Si paquets visibles → Wireshark doit capturer sur la bonne interface.

### Étape 4 : Vérifier Wireshark

```bash
# Vérifier que Wireshark tourne
ps aux | grep wireshark

# Redémarrer Wireshark avec la bonne interface
sudo killall wireshark dumpcap

BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
sudo wireshark -k -i br-${BRIDGE_IF} -f "udp port 4729" &
```

### Étape 5 : Générer du trafic GSM

```bash
# Lancer un mobile OsmocomBB
sudo docker exec -ti osmo-operator-1 /bin/bash
cd /root/.osmocom/bb/
mobile -i 127.0.0.1

# Dans mobile VTY
enable
sim insert 001010000000001
network search
network select 001 01
```

Vous devriez voir dans Wireshark :
- **BCCH** : System Information messages
- **RACH** : Channel Request
- **AGCH** : Immediate Assignment
- **SDCCH** : Location Update Request

---

## Vérifications rapides

### Est-ce que GSMTAP fonctionne ?

```bash
# Test 1 : tcpdump sur ANY
sudo timeout 10 tcpdump -i any -c 5 udp port 4729
# Doit capturer des paquets

# Test 2 : Vérifier config dans container
sudo docker exec -ti osmo-operator-1 cat /etc/osmocom/osmo-bts.cfg | grep -A 5 "log gsmtap"
# Doit montrer : log gsmtap 172.20.0.1
```

### Quelle interface Wireshark doit capturer ?

```bash
# Trouver l'interface bridge
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
echo "Capturer sur : br-${BRIDGE_IF}"

# Lancer Wireshark
sudo wireshark -k -i br-${BRIDGE_IF} -f "udp port 4729" &
```

### Pourquoi "any" ne fonctionne pas toujours ?

En mode bridge Docker, l'interface `any` peut ne pas inclure le trafic du bridge.

**Solution** : Capturer **spécifiquement** sur `br-xxxxx`.

---

## Scripts de diagnostic automatique

### Script complet de vérification

```bash
#!/bin/bash
# check_gsmtap.sh

echo "=== Diagnostic GSMTAP ==="

# 1. Réseau Docker
echo -e "\n[1] Réseau Docker gsm-inter :"
docker network inspect gsm-inter --format '{{.IPAM.Config}}' 2>/dev/null || echo "❌ Réseau non trouvé"

# 2. Interface bridge
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' 2>/dev/null | cut -c1-12)
if [ -n "$BRIDGE_IF" ]; then
    echo -e "\n[2] Interface bridge : br-${BRIDGE_IF}"
    ip addr show br-${BRIDGE_IF} | grep "inet "
else
    echo -e "\n[2] ❌ Interface bridge non trouvée"
fi

# 3. Config GSMTAP dans container
echo -e "\n[3] Config GSMTAP BTS Op1 :"
docker exec osmo-operator-1 cat /etc/osmocom/osmo-bts.cfg 2>/dev/null | grep -A 3 "log gsmtap" || echo "❌ Config non trouvée"

# 4. Trafic UDP 4729
echo -e "\n[4] Test capture UDP 4729 (5 secondes) :"
timeout 5 sudo tcpdump -i any -c 3 udp port 4729 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Trafic GSMTAP détecté"
else
    echo "❌ Aucun trafic GSMTAP"
fi

# 5. Wireshark
echo -e "\n[5] Wireshark :"
if pgrep wireshark > /dev/null; then
    echo "✅ Wireshark actif"
    ps aux | grep wireshark | grep -v grep
else
    echo "❌ Wireshark non lancé"
fi

echo -e "\n=== Recommandation ==="
if [ -n "$BRIDGE_IF" ]; then
    echo "Lancer Wireshark avec :"
    echo "  sudo wireshark -k -i br-${BRIDGE_IF} -f 'udp port 4729' &"
fi
```

Sauvegarder ce script et lancer :
```bash
chmod +x check_gsmtap.sh
./check_gsmtap.sh
```

---

## Résumé des solutions

| Problème                           | Solution                                          |
|------------------------------------|---------------------------------------------------|
| Configs utilisent `0.0.0.0`       | Remplacer par `__GATEWAY_IP__`                    |
| Wireshark sur `lo` ou `eth0`      | Capturer sur `br-xxxxx` (interface bridge)        |
| Wireshark ne voit rien             | Capturer avec `sudo wireshark -i any`             |
| Trafic détecté mais pas décodé     | Vérifier protocole GSMTAP activé dans Wireshark   |
| Mode net-host avec 1 opérateur     | Capturer sur `lo` fonctionne directement          |

---

## Fichiers corrigés

Les fichiers suivants ont été modifiés pour utiliser `__GATEWAY_IP__` :

- ✅ `osmo-bts.cfg`
- ✅ `osmo-bts-trx.cfg`
- ✅ `osmo-bsc.cfg`
- ✅ `osmo-pcu.cfg`

**Installation** :

```bash
cp osmo-bts.cfg ~/osmo_egprs/configs/
cp osmo-bts-trx.cfg ~/osmo_egprs/configs/
cp osmo-bsc.cfg ~/osmo_egprs/configs/
cp osmo-pcu.cfg ~/osmo_egprs/configs/

# Relancer
sudo ~/osmo_egprs/start.sh

# Capturer avec Wireshark
BRIDGE_IF=$(docker network inspect gsm-inter -f '{{.Id}}' | cut -c1-12)
sudo wireshark -k -i br-${BRIDGE_IF} -f "udp port 4729" &
```

Après cela, vous devriez voir les trames GSMTAP dans Wireshark ! ✅
