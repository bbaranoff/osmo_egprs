# Osmocom EGPRS/GPRS Stack for Docker

Ce projet fournit une infrastructure complète **Osmocom** (BSC, MSC, HLR, STP, GGSN, SGSN) conteneurisée pour simuler ou opérer un réseau mobile avec support **EGPRS**. La solution est optimisée pour fonctionner avec **Systemd** à l'intérieur de Docker et gère automatiquement la configuration des interfaces réseau (TUN/apn0).

## 🚀 Fonctionnalités

* **Pile Osmocom complète** : Tous les services nécessaires au cœur de réseau (Core Network).
* **Support EGPRS** : Configuration spécifique pour le débit de données amélioré.
* **Gestion Systemd** : Les services sont gérés proprement via des unités systemd dans le conteneur.
* **Auto-Configuration** : Scripts inclus pour le NAT, le routage IP et la création de l'interface `apn0`.

## 🛠 Prérequis (Hôte Acer)

Le système hôte doit être sous Linux (Ubuntu recommandé) avec Docker installé.

```bash
# Charger le module TUN/TAP
sudo modprobe tun

# S'assurer que les cgroups sont accessibles (nécessaire pour systemd)
sudo mkdir -p /sys/fs/cgroup

```

## 📦 Installation

1. **Cloner le dépôt :**
```bash
git clone https://github.com/bbaranoff/osmo_egprs.git
cd osmo_egprs

```


2. **Builder l'image :**
```bash
docker build -t sdr-stack .

```



## 🚦 Démarrage

Pour lancer l'infrastructure, utilise le script `start-gsm.sh` fourni (ou la commande Docker directe ci-dessous). Ce script vérifie les droits root et configure le périphérique TUN.

```bash
sudo ./start-gsm.sh

```

**Commande Docker manuelle :**

```bash
sudo docker run -ti --rm \
    --name sdr-egprs \
    --privileged \
    --cap-add SYS_ADMIN --cap-add NET_ADMIN \
    --security-opt apparmor=unconfined \
    --cgroupns host \
    --net host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --device /dev/net/tun:/dev/net/tun \
    sdr-stack

```

## 📂 Structure du projet

* `entrypoint.sh` : Prépare le nœud `/dev/net/tun` et lance Systemd comme PID 1.
* `osmo-start.sh` : Script d'orchestration qui démarre les services Osmocom dans le bon ordre.
* `osmo-config.sh` : Configure le routage IP, les règles `iptables` et l'interface `apn0`.
* `configs/` : Contient les fichiers `.cfg` pour chaque composant Osmocom.

## 🔍 Débogage

Une fois le conteneur lancé, tu peux vérifier le statut des services :

```bash
# Vérifier si l'interface apn0 est active
ip addr show apn0

# Voir les logs d'un service spécifique
docker exec -it sdr-egprs journalctl -u osmo-ggsn -f

# Accéder au terminal VTY (ex: BSC)
telnet localhost 4242

```

## ⚠️ Notes importantes

* **Permissions** : Le conteneur nécessite `--privileged` pour que Systemd puisse gérer les ressources et que le GGSN puisse créer l'interface tunnel.
* **Réseau** : Le mode `--net host` est utilisé pour faciliter la communication avec le matériel radio externe.
