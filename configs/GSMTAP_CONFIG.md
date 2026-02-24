# Configuration GSMTAP pour Wireshark

GSMTAP permet de capturer les trames GSM en temps réel et de les visualiser dans Wireshark.

## Qu'est-ce que GSMTAP ?

**GSMTAP** (GSM Tap) est un protocole d'encapsulation qui envoie les trames GSM via UDP vers une application de capture (typiquement Wireshark).

```
┌──────────────┐
│   OsmoBTS    │  Capture trames Um (air interface)
│              │  → UDP:4729 (GSMTAP)
└──────┬───────┘
       │
       ↓ UDP
┌──────────────┐
│  Wireshark   │  Décode et affiche les trames GSM
│  0.0.0.0:4729│
└──────────────┘
```

## Composants supportant GSMTAP

| Composant   | Interface capturée | GSMTAP supporté |
|-------------|-------------------|-----------------|
| **OsmoBTS** | Um (air)          | ✅ OUI          |
| **OsmoBSC** | Abis (BTS-BSC)    | ✅ OUI          |
| **OsmoPCU** | GPRS/EGPRS        | ✅ OUI          |
| OsmoMSC     | A (BSC-MSC)       | ❌ Non          |
| OsmoSTP     | SS7/M3UA          | ❌ Non          |
| OsmoHLR     | GSUP              | ❌ Non          |

## Configuration ajoutée

### OsmoBTS & OsmoBTS-TRX

```
log gsmtap 0.0.0.0
 logging filter all 1
 logging color 0
 logging timestamp 0
 logging print category 1
 logging print level 1
!
bts 0
 # ... (config existante)
 gsmtap-sapi ccch      # Common Control Channel
 gsmtap-sapi bcch      # Broadcast Control Channel
 gsmtap-sapi rach      # Random Access Channel
 gsmtap-sapi agch      # Access Grant Channel
 gsmtap-sapi pch       # Paging Channel
 gsmtap-sapi sdcch     # Stand-alone Dedicated Control Channel
 gsmtap-sapi sacch     # Slow Associated Control Channel
 gsmtap-sapi facch-f   # Fast Associated Control Channel (Full-rate)
 gsmtap-sapi facch-h   # Fast Associated Control Channel (Half-rate)
 gsmtap-sapi tch-f     # Traffic Channel (Full-rate)
 gsmtap-sapi tch-h     # Traffic Channel (Half-rate)
```

**Capture** : Toutes les trames de l'interface radio (Um)

### OsmoBSC

```
log gsmtap 0.0.0.0
 logging filter all 1
 logging color 0
 logging timestamp 0
 logging print category 1
 logging print level 1
```

**Capture** : Trames de l'interface Abis (BTS ↔ BSC)

### OsmoPCU

```
log gsmtap 0.0.0.0
 logging filter all 1
 logging color 0
 logging timestamp 0
 logging print category 1
 logging print level 1
```

**Capture** : Trames GPRS/EGPRS

## SAPIs (Service Access Point Identifiers)

Les SAPIs définissent les types de canaux GSM à capturer :

| SAPI        | Description                              | Contenu typique                    |
|-------------|------------------------------------------|------------------------------------|
| **CCCH**    | Common Control Channel                   | System Information, Paging         |
| **BCCH**    | Broadcast Control Channel                | System Information Blocks          |
| **RACH**    | Random Access Channel                    | Channel Request (MS → BTS)         |
| **AGCH**    | Access Grant Channel                     | Immediate Assignment               |
| **PCH**     | Paging Channel                           | Paging Request                     |
| **SDCCH**   | Standalone Dedicated Control Channel     | Location Update, CM Service Req    |
| **SACCH**   | Slow Associated Control Channel          | Measurement Reports                |
| **FACCH-F** | Fast Associated Control Channel (FR)    | Handover Command                   |
| **FACCH-H** | Fast Associated Control Channel (HR)    | Handover Command                   |
| **TCH-F**   | Traffic Channel Full-rate                | Voice (13 kbps)                    |
| **TCH-H**   | Traffic Channel Half-rate                | Voice (5.6 kbps)                   |

## Utilisation avec Wireshark

### Méthode 1 : Capture automatique (start.sh)

Le script `start.sh` lance déjà Wireshark automatiquement :

```bash
sudo ./start.sh
# Wireshark se lance et capture sur UDP:4729
```

### Méthode 2 : Lancement manuel

```bash
# Lancer Wireshark en capture GSMTAP
sudo wireshark -k -i lo -f "udp port 4729" &
```

**Options** :
- `-k` : Start capturing immediately
- `-i lo` : Interface loopback (pour Docker avec net-host)
- `-f "udp port 4729"` : Filtre de capture

### Méthode 3 : Via interface Wireshark

1. Lancer Wireshark
2. Capture → Options
3. Interface : `Loopback: lo`
4. Capture Filter : `udp port 4729`
5. Start

## Filtres Wireshark utiles

### Filtres d'affichage

```
# Tous les messages GSMTAP
gsmtap

# Messages de paging
gsm_a.rr.msg_type == 0x21

# Location Update Request
gsm_a.dtap.msg_mm_type == 0x08

# CM Service Request
gsm_a.dtap.msg_mm_type == 0x24

# SMS
gsm_sms

# Appels vocaux (Call Control)
gsm_a.dtap.msg_cc_type

# Measurement Reports
gsm_a.rr.msg_type == 0x15

# RACH (Channel Request)
gsmtap.channel == 17

# SDCCH
gsmtap.channel == 4

# TCH/F (Traffic Full-rate)
gsmtap.channel == 8
```

### Filtres par IMSI

```
# Filtrer par IMSI
gsm_a.imsi == "001010000000001"

# Filtrer par TMSI
gsm_a.tmsi == 0x12345678
```

### Filtres par type de canal

```
# BCCH (System Information)
gsmtap.channel == 128

# CCCH (Paging, Access Grant)
gsmtap.channel == 129

# RACH (Random Access)
gsmtap.channel == 17

# SDCCH/4
gsmtap.channel == 4

# SDCCH/8
gsmtap.channel == 5

# TCH/F (Full-rate traffic)
gsmtap.channel == 8

# TCH/H (Half-rate traffic)
gsmtap.channel == 9
```

## Analyse typique

### 1. Attachement d'un mobile (Location Update)

Filtrer : `gsm_a.dtap.msg_mm_type == 0x08 || gsm_a.rr.msg_type == 0x21`

Séquence visible :
1. **RACH** : Channel Request du MS
2. **AGCH** : Immediate Assignment
3. **SDCCH** : Location Update Request
4. **SDCCH** : Authentication Request/Response
5. **SDCCH** : Location Update Accept

### 2. SMS Mobile Terminated

Filtrer : `gsm_sms || gsm_a.rr.msg_type == 0x21`

Séquence :
1. **PCH** : Paging Request (pour le MS destinataire)
2. **RACH** : Channel Request (réponse du MS)
3. **AGCH** : Immediate Assignment
4. **SDCCH** : CP-DATA (SMS)
5. **SDCCH** : RP-DATA (contenu SMS)

### 3. Appel vocal

Filtrer : `gsm_a.dtap.msg_cc_type`

Séquence :
1. **SDCCH** : CM Service Request (type=1 MO call)
2. **SDCCH** : Setup
3. **SDCCH** : Call Proceeding
4. **SDCCH** : Assignment Command
5. **TCH/F** : Connect
6. **TCH/F** : Voice frames (AMR)

## Troubleshooting

### Pas de trames GSMTAP dans Wireshark

**Vérifier que GSMTAP est activé** :
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4241  # OsmoBTS VTY
show bts 0
# Chercher "gsmtap-sapi"
```

**Vérifier le listener UDP** :
```bash
sudo netstat -uln | grep 4729
# Doit montrer : 0.0.0.0:4729
```

**Vérifier que Wireshark capture** :
```bash
ps aux | grep wireshark
# Doit montrer : wireshark -k -i lo -f "udp port 4729"
```

### Trames capturées mais pas décodées

**Installer dissecteurs GSM** :
```bash
sudo apt install wireshark
# Wireshark inclut déjà les dissecteurs GSM/GSMTAP
```

**Vérifier protocole** :
- Edit → Preferences → Protocols → GSMTAP
- Cocher : "Dissect GSMTAP messages"

### Performance Wireshark

**Réduire les SAPIs capturés** :

Au lieu de tout capturer, ne garder que l'essentiel :
```
bts 0
 gsmtap-sapi ccch      # Control channels
 gsmtap-sapi rach      # Access requests
 gsmtap-sapi sdcch     # Signaling
 # Commenter tch-f et tch-h si pas besoin de la voix
```

**Utiliser des filtres de capture** :
```bash
wireshark -k -i lo -f "udp port 4729 and udp[8:2] != 0x0101"
# Exclut certains messages répétitifs
```

## Fichiers modifiés

- ✅ `configs/osmo-bts.cfg`
- ✅ `configs/osmo-bts-trx.cfg`
- ✅ `configs/osmo-bsc.cfg`
- ✅ `configs/osmo-pcu.cfg`

## Ressources

- [Osmocom GSMTAP Wiki](https://osmocom.org/projects/baseband/wiki/GSMTAP)
- [Wireshark GSM Dissectors](https://wiki.wireshark.org/GSM)
- [3GPP TS 44.004](https://www.3gpp.org/DynaReport/44004.htm) - Layer 1 specification
- [3GPP TS 24.008](https://www.3gpp.org/DynaReport/24008.htm) - MM/CC/SMS protocols
