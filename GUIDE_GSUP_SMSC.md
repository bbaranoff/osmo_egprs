# Intégration gsup-smsc-proto dans osmo_egprs

## Vue d'ensemble

Le module **gsup-smsc-proto** (ThemWi/FreeCalypso) implémente un SMSC externe
qui se connecte à OsmoHLR via le protocole GSUP. Cela remplace le SMSC interne
minimal d'OsmoMSC et permet un vrai routage SMS inter-opérateur via GSUP au
lieu de passer par les routes SS7/SCCP.

```
┌──────────┐     MO SMS      ┌──────────┐    GSUP     ┌─────────────────┐
│   MS     │ ──────────────► │ OsmoMSC  │ ─────────► │   OsmoHLR       │
│ (mobile) │                 │sms-over- │            │ smsc entity     │
│          │                 │  gsup    │            │ smsc route      │
└──────────┘                 └──────────┘            └────────┬────────┘
                                                              │ GSUP
     ┌────────────────────────────────────────────────────────┘
     ▼
┌─────────────────────────────┐
│   proto-smsc-daemon          │
│   IPA name: SMSC-OP<N>      │
│                              │
│   MO → /var/log/.../mo-sms  │
│   MT ← /tmp/sendmt_socket   │
└─────────────────────────────┘
     ▲
     │ socket UNIX
┌────┴────────────────────────┐
│  proto-smsc-sendmt           │
│  + sms-coding-utils          │
│  (send-mt-sms.sh)           │
└─────────────────────────────┘
```

## Fichiers modifiés/ajoutés

| Fichier | Action | Description |
|---------|--------|-------------|
| `Dockerfile` | **Modifié** | Ajout build gsup-smsc-proto + sms-coding-utils |
| `Dockerfile.run` | **Modifié** | Ajout scripts SMSC + répertoires |
| `configs/osmo-hlr.cfg` | **Modifié** | `smsc entity` + `smsc default-route` + `ipa-name` |
| `configs/osmo-msc.cfg` | **Modifié** | `sms-over-gsup` sous `msc` + `ipa-name` sous `hlr` |
| `scripts/smsc-start.sh` | **Nouveau** | Lancement proto-smsc-daemon dans tmux |
| `scripts/send-mt-sms.sh` | **Nouveau** | Helper envoi MT SMS (texte → PDU → GSUP) |
| `scripts/run.sh` | **Modifié** | Fenêtre tmux #3 pour le SMSC daemon |

## Installation

```bash
cd ~/osmo_egprs

# 1. Sauvegarder
mkdir -p backup
cp Dockerfile Dockerfile.run backup/
cp configs/osmo-hlr.cfg configs/osmo-msc.cfg backup/
cp scripts/run.sh backup/

# 2. Remplacer les fichiers
cp /path/to/output/Dockerfile .
cp /path/to/output/Dockerfile.run .
cp /path/to/output/configs/osmo-hlr.cfg configs/
cp /path/to/output/configs/osmo-msc.cfg configs/
cp /path/to/output/scripts/run.sh scripts/
cp /path/to/output/scripts/smsc-start.sh scripts/
cp /path/to/output/scripts/send-mt-sms.sh scripts/
chmod +x scripts/*.sh

# 3. Rebuild complet (gsup-smsc-proto sera compilé)
sudo docker build -t osmocom-nitb -f Dockerfile .
sudo docker build -t osmocom-run -f Dockerfile.run .

# 4. Relancer
sudo ./start.sh stop
sudo ./start.sh
```

## Utilisation

### Vérification du SMSC daemon

```bash
# Le SMSC tourne dans la fenêtre tmux #3
sudo docker exec -ti osmo-operator-1 tmux attach -t osmocom

# Basculer vers la fenêtre SMSC : Ctrl+B puis 3
# Vous devez voir :
#   [SMSC] Démarrage proto-smsc-daemon
#   HLR        : 127.0.0.2
#   IPA name   : SMSC-OP1
```

### Envoi d'un SMS MT (réseau → mobile)

```bash
# Depuis l'intérieur du container Op1
sudo docker exec -ti osmo-operator-1 /bin/bash

# Envoyer un SMS au mobile avec IMSI 001010000000001
/etc/osmocom/send-mt-sms.sh 001010000000001 "Hello depuis le réseau!"

# Avec numéro expéditeur personnalisé
/etc/osmocom/send-mt-sms.sh 001010000000001 "Test SMS" 33601000001

# Pipeline manuelle (équivalent)
sms-encode-text 'Message test' \
    | gen-sms-deliver-pdu 33601000001 \
    | proto-smsc-sendmt 19990011444 001010000000001 /tmp/sendmt_socket
```

### Réception d'un SMS MO (mobile → réseau)

```bash
# Les MO SMS sont loggés automatiquement
sudo docker exec -ti osmo-operator-1 \
    tail -f /var/log/osmocom/mo-sms-op1.log

# Décodage des PDU (depuis le container)
sudo docker exec -ti osmo-operator-1 \
    sms-pdu-decode -np /var/log/osmocom/mo-sms-op1.log
```

### SMS inter-opérateur via GSUP

Pour le SMS inter-opérateur, le flux est :

```
MS (Op1) → MO SMS → MSC Op1 (sms-over-gsup) → HLR Op1 → proto-smsc-daemon Op1
                                                                    │
                                                        (application logic)
                                                                    │
                                                                    ▼
                                              proto-smsc-sendmt → HLR Op2
                                                                    │
                                                   MSC Op2 ← GSUP MT-forwardSM
                                                      │
                                                      ▼
                                                   MS (Op2) reçoit le SMS
```

Le proto-smsc-daemon reçoit le MO SMS. Votre logique applicative (script,
programme) lit le log MO, détermine le destinataire, et utilise
proto-smsc-sendmt sur l'opérateur cible pour injecter le MT SMS.

**Exemple de bridge inter-opérateur simple :**

```bash
#!/bin/bash
# sms-bridge.sh — Exemple de bridge MO→MT inter-opérateur
# À lancer sur Op1, transfère les SMS vers Op2

MO_LOG="/var/log/osmocom/mo-sms-op1.log"
DEST_CONTAINER="osmo-operator-2"

tail -F "$MO_LOG" | while read -r line; do
    # Extraire IMSI destinataire du TPDU (logique simplifiée)
    if echo "$line" | grep -q "^SM-RP-OA:"; then
        FROM_MSISDN=$(echo "$line" | awk '{print $NF}')
    fi
    if echo "$line" | grep -q "^IMSI:"; then
        SENDER_IMSI=$(echo "$line" | awk '{print $2}')
    fi
    # Le TPDU contient le numéro destination — à décoder avec sms-pdu-decode
    # Ceci est un squelette, la logique complète nécessite le parsing du TPDU
done
```

## Configuration détaillée

### OsmoHLR (configs/osmo-hlr.cfg)

Ajouts clés :
```
hlr
 gsup
  ipa-name HLR-OP__OPERATOR_ID__
 smsc entity SMSC-OP__OPERATOR_ID__
 smsc default-route SMSC-OP__OPERATOR_ID__
```

- `ipa-name` : identifie le HLR sur le réseau GSUP
- `smsc entity` : déclare l'existence du SMSC avec ce nom IPA
- `smsc default-route` : route TOUS les MO SMS vers ce SMSC
  (alternative : `smsc route <sc-address> SMSC-OP__OPERATOR_ID__` pour un SC-address spécifique)

### OsmoMSC (configs/osmo-msc.cfg)

Ajouts clés :
```
msc
 sms-over-gsup

hlr
 ipa-name VLR-SDR-OP__OPERATOR_ID__
```

- `sms-over-gsup` : désactive le SMSC interne, redirige SM-RP vers GSUP/HLR
- `ipa-name` : nécessaire pour que les réponses MT-forwardSM soient routées
  correctement par le HLR vers le SMSC

### proto-smsc-daemon

Arguments : `<hlr_ip> <ipa_name> <mo_log> <sendmt_socket>`

| Argument | Valeur dans notre setup |
|----------|-------------------------|
| hlr_ip | `127.0.0.2` (HLR local) |
| ipa_name | `SMSC-OP1`, `SMSC-OP2`, ... |
| mo_log | `/var/log/osmocom/mo-sms-op<N>.log` |
| sendmt_socket | `/tmp/sendmt_socket` |

### proto-smsc-sendmt

Arguments : `<sc_address> <dest_imsi> <sendmt_socket>`

Le TPDU SMS-DELIVER est lu sur stdin (généré par sms-coding-utils).

## Versions requises

- **OsmoHLR** ≥ 2024-07 (commandes `smsc entity` / `smsc route`)
- **OsmoMSC** ≥ 2024-07 (directive `sms-over-gsup` fonctionnelle)
- Votre build actuel utilise osmo-hlr:1.9.2 et osmo-msc:1.15.0 — **vérifiez
  que ces versions incluent le support SMS-over-GSUP complet**. Sinon, passez
  aux tags plus récents ou à master.

## Troubleshooting

### proto-smsc-daemon ne se connecte pas

```bash
# Vérifier que le HLR écoute bien sur GSUP
ss -tln | grep 4222

# Vérifier la config HLR
cat /etc/osmocom/osmo-hlr.cfg | grep -A2 "smsc"

# Logs HLR
tail -f /var/log/osmocom/osmo-hlr.log | grep -i smsc
```

### MO SMS n'arrive pas au SMSC

```bash
# Vérifier sms-over-gsup dans MSC
docker exec osmo-operator-1 \
    grep "sms-over-gsup" /etc/osmocom/osmo-msc.cfg

# Vérifier que le SMSC est enregistré au HLR
docker exec osmo-operator-1 telnet 127.0.0.1 4258
# > show gsup-clients
```

### MT SMS échoue

```bash
# Vérifier le socket
ls -la /tmp/sendmt_socket

# Tester manuellement
echo "test" | proto-smsc-sendmt 19990011444 001010000000001 /tmp/sendmt_socket

# Vérifier l'ipa-name du MSC (nécessaire pour les réponses)
grep ipa-name /etc/osmocom/osmo-msc.cfg
```

## Références

- [gsup-smsc-proto README](https://gitea.osmocom.org/themwi/gsup-smsc-proto)
- [sms-coding-utils](https://www.freecalypso.org/pub/GSM/FreeCalypso/)
- [Osmocom SMS-over-GSUP](https://osmocom.org/issues/3587)
- [OsmoHLR SMSC config](https://downloads.osmocom.org/docs/osmo-hlr/latest/)
- [OsmoMSC sms-over-gsup](https://downloads.osmocom.org/docs/osmo-msc/latest/)
