# Osmocom Multi-Operator GSM/EGPRS Network

Simulation complète d'un réseau GSM/EGPRS multi-opérateur avec interconnexion SS7, utilisant la stack Osmocom dans des containers Docker.

## 📋 Table des matières

- [Vue d'ensemble](#vue-densemble)
- [Fonctionnalités](#fonctionnalités)
- [Architecture](#architecture)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration](#configuration)
- [Utilisation](#utilisation)
- [SMS Inter-Opérateur](#sms-inter-opérateur)
- [Troubleshooting](#troubleshooting)
- [Structure du projet](#structure-du-projet)
- [Documentation technique](#documentation-technique)
- [Licence](#licence)

---

## 🌐 Vue d'ensemble

Ce projet implémente un **réseau GSM/EGPRS complet** avec :
- Support **multi-opérateur** (jusqu'à N opérateurs configurables)
- Interconnexion **SS7/SIGTRAN** (M3UA over SCTP)
- Architecture **STP hiérarchique** avec Signal Transfer Point central
- Support **EGPRS** (Enhanced GPRS)
- Routage **inter-opérateur** pour SMS et appels
- Déploiement **Docker** complet

### Cas d'usage

- 📚 **Éducation** : Apprentissage des réseaux mobiles 2G/2.5G
- 🔬 **Recherche** : Test de protocoles GSM/SS7/SIGTRAN
- 🛠️ **Développement** : Test d'applications télécoms
- 🔐 **Sécurité** : Analyse de vulnérabilités réseaux mobiles

---

## ✨ Fonctionnalités

### Réseau Core

- ✅ **MSC** (Mobile Switching Center) - OsmoMSC
- ✅ **BSC** (Base Station Controller) - OsmoBSC  
- ✅ **HLR** (Home Location Register) - OsmoHLR
- ✅ **STP** (Signal Transfer Point) - OsmoSTP
- ✅ **Inter-STP** - Point de transfert SS7 centralisé
- ✅ **MGW** (Media Gateway) - OsmoMGW
- ✅ **SGSN** (Serving GPRS Support Node) - OsmoSGSN
- ✅ **GGSN** (Gateway GPRS Support Node) - OsmoGGSN

### BTS & RAN

- ✅ **OsmoBTS** - Station de base virtuelle
- ✅ **Support EGPRS** - Enhanced GPRS avec MCS1-9
- ✅ **OsmocomBB** - Mobile station virtuel

### Protocoles SS7

- ✅ **M3UA** - MTP3 User Adaptation Layer
- ✅ **SCCP** - Signalling Connection Control Part
- ✅ **SCTP** - Stream Control Transmission Protocol
- ✅ **Routing Contexts** - Isolation par opérateur (110, 130, 210, 230, 999)

### Modes de déploiement

- 🔌 **Mode net-host** - 1 opérateur avec SDR physique
- 🌉 **Mode bridge** - N opérateurs isolés avec inter-STP

---

## 🏗️ Architecture

### Mode Bridge (Multi-Opérateur)

```
┌─────────────────────────────────────────────────────────────────┐
│                         Inter-STP (0.23.0)                      │
│                        172.20.0.10:2908                         │
│                                                                 │
│  AS:                                                            │
│    as-op1  routing-key 999  0.0.0  ← Opérateur 1                │
│    as-op2  routing-key 999  0.0.0  ← Opérateur 2                │
│                                                                 │
│  Routes:                                                        │
│    0.0.0/14 → as-op1, as-op2  (load-balanced)                   │
└─────────────────────────────────────────────────────────────────┘
                ▲                            ▲
                │ SCTP:2910                  │ SCTP:2910
                │ RK:999                     │ RK:999
                │                            │
┌───────────────┴──────────┐   ┌─────────────┴────────────┐
│   Opérateur 1            │   │   Opérateur 2            │
│   172.20.0.11            │   │   172.20.0.12            │
│   Network: gsm-inter     │   │   Network: gsm-inter     │
│                          │   │                          │
│  ┌────────────────────┐  │   │  ┌────────────────────┐  │
│  │ STP (1.23.2)       │  │   │  │ STP (2.23.2)       │  │
│  │  RK 110: MSC       │  │   │  │  RK 210: MSC       │  │
│  │  RK 130: BSC       │  │   │  │  RK 230: BSC       │  │
│  │  RK 999: Inter-STP │  │   │  │  RK 999: Inter-STP │  │
│  └────────────────────┘  │   │  └────────────────────┘  │
│         │       │        │   │         │        │       │
│  ┌──────┴──┐ ┌──┴─────┐  │   │  ┌──────┴──┐ ┌──┴─────┐  │
│  │MSC      │ │BSC     │  │   │  │MSC      │ │BSC     │  │
│  │1.23.1   │ │1.23.3  │  │   │  │2.23.1   │ │2.23.3  │  │
│  │RK:110   │ │RK:130  │  │   │  │RK:210   │ │RK:230  │  │
│  └─────────┘ └────────┘  │   │  └─────────┘ └────────┘  │
│       │          │       │   │       │         │        │
│  ┌────┴──┐  ┌───┴────┐   │   │  ┌────┴──┐  ┌───┴────┐   │
│  │ HLR   │  │OsmoBTS │   │   │  │ HLR   │  │OsmoBTS │   │
│  │       │  │ARFCN   │   │   │  │       │  │ARFCN   │   │
│  │       │  │512     │   │   │  │       │  │514     │   │
│  └───────┘  └────────┘   │   │  └───────┘  └────────┘   │
│                          │   │                          │
│  MCC: 001  MNC: 01       │   │  MCC: 001  MNC: 02       │
│  Name: OsmoOP1           │   │  Name: OsmoOP2           │
└──────────────────────── ─┘   └──────────────────────────┘
```

### Point Codes SS7

| Composant      | Op1     | Op2     | Inter-STP |
|----------------|---------|---------|-----------|
| **STP**        | 1.23.2  | 2.23.2  | 0.23.0    |
| **MSC**        | 1.23.1  | 2.23.1  | N/A       |
| **BSC**        | 1.23.3  | 2.23.3  | N/A       |

### Routing Contexts

| Routing Context | Utilisation              | Point Code |
|-----------------|--------------------------|------------|
| **110**         | MSC Op1                  | 1.23.1     |
| **130**         | BSC Op1                  | 1.23.3     |
| **210**         | MSC Op2                  | 2.23.1     |
| **230**         | BSC Op2                  | 2.23.3     |
| **999**         | Inter-STP (tous les ops) | 0.0.0      |

### Global Titles

| MSC   | Global Title      | Utilisation                    |
|-------|-------------------|--------------------------------|
| Op1   | +33102030401      | Adressage SCCP du MSC Op1      |
| Op2   | +33102030402      | Adressage SCCP du MSC Op2      |

---

## 📦 Prérequis

### Système

- **OS** : Ubuntu 22.04+ / Debian 12+
- **Docker** : Version 20.10+
- **Docker Compose** : Version 2.0+ (optionnel)
- **RAM** : 4GB minimum, 8GB recommandé
- **CPU** : 4 cores recommandé
- **Stockage** : 10GB espace disque

### Logiciels

```bash
sudo apt update
sudo apt install -y \
    docker.io \
    tmux \
    wireshark \
    telnet \
    git
```

### Permissions

```bash
# Ajouter l'utilisateur au groupe docker
sudo usermod -aG docker $USER

# Autoriser GSMTAP (port UDP 4729)
sudo ufw allow 4729/udp
```

---

## 🚀 Installation

### 1. Cloner le repository

```bash
git clone https://github.com/bbaranoff/osmo_egprs
cd osmo_egprs
```

### 2. Build de l'image Docker

```bash
chmod +x build.sh && sudo ./build.sh
```

```bash
# Build de l'image de base (Osmocom + dépendances)
sudo docker build -f Dockerfile.build -t osmocom-build .

# Build de l'image runtime
sudo docker build -f Dockerfile.run -t osmocom-run .
```

### 3. Lancer le réseau

```bash
chmod +x ./start.sh && sudo ./start.sh
```

#### Choix du mode réseau

```
Mode réseau :
  1) net-host  — SDR physique, 1 opérateur, accès direct
  2) bridge    — Multi-opérateurs, SS7 inter-op via inter-STP
Choix [1/2] : 2
```

#### Configuration des opérateurs

```
Nombre d'opérateurs [2] : 2

── Opérateur 1 ──
  MCC [001] : 001
  MNC [01] : 01
  Nom [OsmoOP1] : Orange

── Opérateur 2 ──
  MCC [001] : 001
  MNC [02] : 02
  Nom [OsmoOP2] : SFR
```

### 4. Vérification

```bash
# Lister les containers
sudo docker ps

# Vérifier les routes SS7
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4239
show cs7 instance 0 route
show cs7 instance 0 as all
```

---

## ⚙️ Configuration

### Structure des fichiers

```
osmo_egprs/
├── configs/
│   ├── osmo-msc.cfg        # Configuration MSC (templates)
│   ├── osmo-bsc.cfg        # Configuration BSC
│   ├── osmo-stp.cfg        # Configuration STP local
│   ├── osmo-hlr.cfg        # Configuration HLR
│   ├── osmo-bts.cfg        # Configuration BTS
│   └── ...
├── create_interop.sh       # Générateur config inter-STP
├── start.sh                # Script de lancement principal
├── Dockerfile.build        # Image de build Osmocom
├── Dockerfile.run          # Image runtime
└── README.md               # Ce fichier
```

### Variables de substitution

Les fichiers de config utilisent des variables remplacées par `start.sh` :

| Variable                | Description                  | Exemple      |
|-------------------------|------------------------------|--------------|
| `__OPERATOR_ID__`       | ID opérateur (1, 2, ...)     | `1`          |
| `__MCC__`               | Mobile Country Code          | `001`        |
| `__MNC__`               | Mobile Network Code          | `01`         |
| `__PC_MSC__`            | Point Code MSC               | `1.23.1`     |
| `__PC_STP__`            | Point Code STP               | `1.23.2`     |
| `__PC_BSC__`            | Point Code BSC               | `1.23.3`     |
| `__RCTX_MSC__`          | Routing Context MSC          | `110`        |
| `__RCTX_BSC__`          | Routing Context BSC          | `130`        |
| `__CONTAINER_IP__`      | IP du container              | `172.20.0.11`|
| `__INTEROP_PC_MSC__`    | Point Code MSC distant       | `2.23.1`     |
| `__INTEROP_OPERATOR_ID__`| ID opérateur distant        | `2`          |

---

## 📱 Utilisation

### Enregistrer un abonné

```bash
# Se connecter au HLR
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258

# Créer un abonné
enable
subscriber imsi 001010000000001 create
subscriber imsi 001010000000001 update msisdn 33601000001
subscriber imsi 001010000000001 update aud2g comp128v1 ki 00112233445566778899aabbccddeeff
exit
```

### Lancer un mobile OsmocomBB

```bash
# Entrer dans le container
sudo docker exec -ti osmo-operator-1 /bin/bash

# Lancer le mobile
cd /root/.osmocom/bb/
mobile -i 127.0.0.1

# Configuration
enable
sim insert 001010000000001
network search
network select 001 01
```

### Consulter les logs

```bash
# Logs MSC
sudo docker exec -ti osmo-operator-1 tail -f /var/log/osmocom/osmo-msc.log

# Logs BSC
sudo docker exec -ti osmo-operator-1 tail -f /var/log/osmocom/osmo-bsc.log

# Logs Inter-STP
sudo docker exec -ti osmo-inter-stp tail -f /tmp/osmo-stp.log

# Logs BTS
sudo docker exec -ti osmo-operator-1 tail -f /var/log/osmocom/osmo-bts.log
```

### Accéder au VTY

Chaque composant Osmocom expose une interface VTY (telnet) :

| Composant | Port | Commande                                               |
|-----------|------|--------------------------------------------------------|
| MSC       | 4254 | `sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4254` |
| BSC       | 4242 | `sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4242` |
| HLR       | 4258 | `sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258` |
| STP       | 4239 | `sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4239` |
| BTS       | 4241 | `sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4241` |
| Inter-STP | 4239 | `sudo docker exec -ti osmo-inter-stp telnet 127.0.0.1 4239`  |

---

## 💬 SMS Inter-Opérateur

### Principe

Le routing SMS entre opérateurs utilise :
1. **Routes SS7** via Inter-STP (routing-key 999)
2. **Adresses SCCP Global Title** pour cibler le MSC distant
3. **Enregistrement dans les HLR** pour connaître la localisation

### Configuration

#### 1. Fichiers déjà configurés

- `configs/osmo-msc.cfg` : Contient `sccp-address addr-msc-interop`
- `configs/osmo-stp.cfg` : AS `as-inter` avec routing-key 999
- `create_interop.sh` : Génère inter-STP avec routing-key 999

#### 2. Enregistrer les abonnés

**Abonné MS1 - Opérateur 1 (33601000001)** :

```bash
# HLR Op1 (local - complet)
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258
enable
subscriber imsi 001010000000001 create
subscriber imsi 001010000000001 update msisdn 33601000001
subscriber imsi 001010000000001 update aud2g comp128v1 ki 00112233445566778899aabbccddeeff
exit

# HLR Op2 (distant - routing seulement)
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
enable
subscriber imsi 001010000000001 create
subscriber imsi 001010000000001 update msisdn 33601000001
subscriber imsi 001010000000001 update vlr-number +33102030401
exit
```

**Abonné MS2 - Opérateur 2 (33602000002)** :

```bash
# HLR Op2 (local - complet)
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
enable
subscriber imsi 001020000000002 create
subscriber imsi 001020000000002 update msisdn 33602000002
subscriber imsi 001020000000002 update aud2g comp128v1 ki 00112233445566778899aabbccddeeff
exit

# HLR Op1 (distant - routing seulement)
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258
enable
subscriber imsi 001020000000002 create
subscriber imsi 001020000000002 update msisdn 33602000002
subscriber imsi 001020000000002 update vlr-number +33102030402
exit
```

#### 3. Envoyer un SMS

```bash
# MS1 (Op1) → MS2 (Op2)
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4254
enable
subscriber imsi 001010000000001 sms sender msisdn 33601000001 send 33602000002 Hello from Op1!
exit
```

### Flux SMS inter-opérateur

```
MS1 (33601000001 @ Op1) envoie SMS vers 33602000002
    ↓
MSC Op1 → HLR Op1 : "Où est 33602000002 ?"
    ↓
HLR Op1 : "VLR +33102030402 (MSC Op2, PC 2.23.1)"
    ↓
MSC Op1 → Route SCCP vers addr-msc-interop (GT +33102030402, PC 2.23.1)
    ↓
STP Op1 → Route M3UA vers 2.23.1 → as-inter (RK 999)
    ↓
Inter-STP → Reçoit via as-op1, route vers as-op2
    ↓
STP Op2 → Route M3UA vers 2.23.1 → as-msc (RK 210)
    ↓
MSC Op2 → Délivre SMS à MS2 (33602000002) ✓
```

---

## 🔧 Troubleshooting

### Routes PROHIB sur les MSC

**Symptôme** : Routes marquées `PROHIB UNAVAIL`

**Diagnostic** :
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4254
show cs7 instance 0 route
```

**Cause** : Conflit de routing-keys sur le STP local

**Solution** : Vérifier que `as-inter` utilise routing-key 999 (pas 110 ou 130)

```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4239
show cs7 instance 0 as all
```

### Erreur "No Configured AS for ASP"

**Symptôme** : Logs inter-STP montrent cette erreur

**Diagnostic** :
```bash
sudo docker exec -ti osmo-inter-stp cat /tmp/osmo-stp.log | grep "No Configured"
```

**Cause** : Inter-STP ne connaît pas le routing-key envoyé par le STP local

**Solution** : Vérifier que `create_interop.sh` génère bien `routing-key 999 0.0.0`

### SMS inter-opérateur ne fonctionne pas

**Symptôme** : SMS local OK, SMS vers autre opérateur échoue

**Diagnostic** :
```bash
# Vérifier adresses SCCP
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4254
show cs7 instance 0 sccp addressbook
# Doit contenir addr-msc-interop

# Vérifier abonné dans HLR distant
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
show subscriber msisdn 33601000001
# Doit exister avec vlr-number
```

**Solution** : Suivre le guide [SMS Inter-Opérateur](#sms-inter-opérateur)

### Container ne démarre pas

**Diagnostic** :
```bash
sudo docker logs osmo-operator-1
```

**Causes fréquentes** :
- Port déjà utilisé → Arrêter les autres instances Osmocom
- Réseau Docker inexistant → `sudo docker network ls`
- Config invalide → Vérifier la syntaxe des .cfg

### Wireshark ne capture pas GSMTAP

**Solution** :
```bash
# Vérifier listener UDP/4729
sudo netstat -uln | grep 4729

# Relancer capture
sudo killall dumpcap
sudo wireshark -k -i lo -f "udp port 4729" &
```

---

## 📂 Structure du projet

```
osmo_egprs/
│
├── configs/                    # Fichiers de configuration (templates)
│   ├── osmo-msc.cfg           # MSC
│   ├── osmo-bsc.cfg           # BSC
│   ├── osmo-stp.cfg           # STP local
│   ├── osmo-hlr.cfg           # HLR
│   ├── osmo-bts.cfg           # BTS
│   ├── osmo-mgw.cfg           # Media Gateway
│   ├── osmo-sgsn.cfg          # SGSN
│   ├── osmo-ggsn.cfg          # GGSN
│   └── osmo-pcu.cfg           # PCU
│
├── skills/                     # (Optionnel) Skills pour automation
│
├── scripts/                    # Scripts utilitaires
│   └── (à venir)

│
├── Dockerfile.build            # Image de build (compilation Osmocom)
├── Dockerfile.run              # Image runtime (exécution)
├── create_interop.sh           # Générateur config inter-STP
├── start.sh                    # Script de lancement principal
├── .gitignore                  # Fichiers ignorés par git
├── LICENSE                     # Licence du projet
└── README.md                   # Ce fichier
```

---

## 📚 Documentation technique

### Guides disponibles

- **SOLUTION_RK999.md** : Explication du routing-key 999 pour inter-STP
- **GUIDE_SMS_INTEROP.md** : Configuration complète SMS inter-opérateur
- **OPTION2_SMS_INTEROP.md** : Alternative avec HLR distribués

### Références Osmocom

- [Osmocom Wiki](https://osmocom.org/projects/cellular-infrastructure/wiki)
- [OsmoMSC Documentation](https://osmocom.org/projects/osmomsc/wiki)
- [OsmoBSC Documentation](https://osmocom.org/projects/osmobsc/wiki)
- [SS7/SIGTRAN Guide](https://osmocom.org/projects/osmo-stp/wiki)

### Spécifications 3GPP

- **TS 24.007** : Mobile radio interface signalling layer 3
- **TS 23.003** : Numbering, addressing and identification
- **TS 29.002** : MAP (Mobile Application Part)
- **TS 48.008** : A-Interface (BSC-MSC)

---

## 🤝 Contribution

Les contributions sont les bienvenues !

### Comment contribuer

1. Fork le projet
2. Créer une branche (`git checkout -b feature/AmazingFeature`)
3. Commit les changements (`git commit -m 'Add AmazingFeature'`)
4. Push vers la branche (`git push origin feature/AmazingFeature`)
5. Ouvrir une Pull Request

### Roadmap

- [ ] Support N > 2 opérateurs
- [ ] Interface web de monitoring
- [ ] Roaming automatique
- [ ] Support LTE (eNodeB)
- [ ] Intégration IMS
- [ ] Scripts d'automatisation des tests
- [ ] Métriques Prometheus/Grafana

---

## 📄 Licence

Ce projet est sous licence **GPL-3.0** - voir le fichier [LICENSE](LICENSE) pour détails.

Les composants Osmocom sont sous licence **AGPLv3+** - voir [Osmocom License](https://osmocom.org/projects/cellular-infrastructure/wiki/LicensingInformation).

---

## 👨‍💻 Auteur

**Bastien** - Telecommunications & Embedded Systems Engineer

- Expertise : GSM/UMTS/LTE, SS7/SIGTRAN, Osmocom ecosystem
- GitHub : [@votre-username](https://github.com/votre-username)

---

## 🙏 Remerciements

- **Osmocom Project** - Pour la stack GSM/GPRS open-source
- **Communauté Osmocom** - Support et documentation
- **Harald Welte** - Créateur d'Osmocom
- **Sylvain Munaut** - Contributions OsmocomBB

---

## 📞 Support

- **Issues** : [GitHub Issues](https://github.com/votre-username/osmo_egprs/issues)
- **Discussions** : [GitHub Discussions](https://github.com/votre-username/osmo_egprs/discussions)
- **Osmocom Mailing List** : [osmocom-net-gprs@lists.osmocom.org](mailto:osmocom-net-gprs@lists.osmocom.org)

---

<p align="center">
  <img src="https://osmocom.org/attachments/download/4652/osmocom_logo.png" alt="Osmocom Logo" width="200"/>
</p>

<p align="center">
  <b>Osmocom Multi-Operator GSM/EGPRS Network</b><br>
  Made with ❤️ for telecommunications research and education
</p>
