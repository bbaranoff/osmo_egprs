# Guide : SMS Inter-Opérateur (Option 2)

## 📋 Fichiers à remplacer

1. `configs/osmo-msc.cfg` → Ajoute adresse SCCP MSC distant
2. `start.sh` → Ajoute substitution __INTEROP_OPERATOR_ID__

## 🚀 Installation

```bash
cd ~/osmo_egprs

# Sauvegarder
cp configs/osmo-msc.cfg configs/osmo-msc.cfg.backup
cp start.sh start.sh.backup

# Remplacer
cp /path/to/osmo-msc.cfg configs/
cp /path/to/start.sh .
chmod +x start.sh

# Relancer
sudo ./start.sh stop
sudo ./start.sh
```

## 📱 Configuration des abonnés

### Abonné MS1 - Opérateur 1 (MSISDN 33601000001)

**HLR Op1** (local - complet) :
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258
enable
subscriber imsi 001010000000001 create
subscriber imsi 001010000000001 update msisdn 33601000001
subscriber imsi 001010000000001 update aud2g comp128v1 ki 00112233445566778899aabbccddeeff
exit
```

**HLR Op2** (distant - routing uniquement) :
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
enable
subscriber imsi 001010000000001 create
subscriber imsi 001010000000001 update msisdn 33601000001
subscriber imsi 001010000000001 update vlr-number +33102030401
exit
```

### Abonné MS2 - Opérateur 2 (MSISDN 33602000002)

**HLR Op2** (local - complet) :
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
enable
subscriber imsi 001020000000002 create
subscriber imsi 001020000000002 update msisdn 33602000002
subscriber imsi 001020000000002 update aud2g comp128v1 ki 00112233445566778899aabbccddeeff
exit
```

**HLR Op1** (distant - routing uniquement) :
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258
enable
subscriber imsi 001020000000002 create
subscriber imsi 001020000000002 update msisdn 33602000002
subscriber imsi 001020000000002 update vlr-number +33102030402
exit
```

## 📨 Test SMS Inter-Opérateur

### Test 1 : MS1 (Op1) → MS2 (Op2)

```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4254
enable
subscriber imsi 001010000000001 sms sender msisdn 33601000001 send 33602000002 Hello from Op1!
exit
```

**Vérification logs MSC Op1** :
```bash
sudo docker exec -ti osmo-operator-1 tail -20 /var/log/osmocom/osmo-msc.log | grep -i "33602000002"
```

Chercher : `SCCP` vers `2.23.1` (PC MSC Op2)

**Vérification logs MSC Op2** :
```bash
sudo docker exec -ti osmo-operator-2 tail -20 /var/log/osmocom/osmo-msc.log | grep -i sms
```

Chercher : SMS reçu pour `33602000002`

### Test 2 : MS2 (Op2) → MS1 (Op1)

```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4254
enable
subscriber imsi 001020000000002 sms sender msisdn 33602000002 send 33601000001 Hello from Op2!
exit
```

## 🔍 Debugging

### Vérifier adresses SCCP configurées

**MSC Op1** :
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4254
enable
show cs7 instance 0 sccp addressbook
```

Attendu :
```
addr-bsc         PC:1.23.3  SSN:254
addr-msc-gt      GT:+33102030401  PC:1.23.1
addr-msc-interop GT:+33102030402  PC:2.23.1  ← DOIT être là !
```

**MSC Op2** :
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4254
enable
show cs7 instance 0 sccp addressbook
```

Attendu :
```
addr-bsc         PC:2.23.3  SSN:254
addr-msc-gt      GT:+33102030402  PC:2.23.1
addr-msc-interop GT:+33102030401  PC:1.23.1  ← DOIT être là !
```

### Vérifier abonnés dans HLR

**HLR Op1** :
```bash
sudo docker exec -ti osmo-operator-1 telnet 127.0.0.1 4258
enable
show subscriber imsi 001010000000001
show subscriber imsi 001020000000002
```

Les deux doivent exister !

**HLR Op2** :
```bash
sudo docker exec -ti osmo-operator-2 telnet 127.0.0.1 4258
enable
show subscriber imsi 001010000000001
show subscriber imsi 001020000000002
```

Les deux doivent exister !

### Logs en temps réel

**Terminal 1** - MSC Op1 :
```bash
sudo docker exec -ti osmo-operator-1 tail -f /var/log/osmocom/osmo-msc.log
```

**Terminal 2** - Inter-STP :
```bash
sudo docker exec -ti osmo-inter-stp tail -f /tmp/osmo-stp.log
```

**Terminal 3** - MSC Op2 :
```bash
sudo docker exec -ti osmo-operator-2 tail -f /var/log/osmocom/osmo-msc.log
```

Puis envoyer le SMS et observer le flux !

## ✅ Flux attendu

```
MSC Op1 : SMS de 33601000001 vers 33602000002
    ↓
HLR Op1 : Lookup 33602000002 → VLR +33102030402 (MSC Op2)
    ↓
MSC Op1 : Route SCCP vers addr-msc-interop (GT +33102030402, PC 2.23.1)
    ↓
STP Op1 : Route M3UA vers 2.23.1 → as-inter (RK 999)
    ↓
Inter-STP : Reçoit via as-op1, route vers as-op2
    ↓
STP Op2 : Route M3UA vers 2.23.1 → as-msc (RK 210)
    ↓
MSC Op2 : Reçoit SMS pour 33602000002 ✓
```

## ⚠️ Limitations

- Chaque abonné doit être dans **tous** les HLR
- Gestion manuelle, pas scalable
- Pas de synchronisation automatique

## 💡 Alternative

Pour un vrai réseau multi-opérateur, utiliser **HLR Central unique** est bien meilleur.
