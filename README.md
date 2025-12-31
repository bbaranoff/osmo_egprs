# Osmocom Virtual GSM Network (NITB)

Ce projet déploie une pile GSM complète (2G) virtualisée.

!!! Change the ip 192.168.1.69 in cfg files with yours !!!

```
sed -i -e 's/192.168.1.69/your_ip/g' configs/*cfg
```
For Linphone : Account assistant -> Use an SIP Account -> set your IP / user : myuser / pass : tester

# 🚀 Installation & Build

```bash
sudo ./build.sh
sudo ./start.sh

```

## 📻 Simulation Radio (via Tmux)

Utilisez `tmux` pour diviser votre écran et lancer les composants :

1. **`faketrx`** : Simule l'interface physique (Air).
2. **`trxcon`** : Gère la couche L1.
3. **`mobile`** : Lance le téléphone virtuel.

---

## 🛠 Administration Telnet (VTY)

Voici les commandes pour interagir avec ton réseau une fois qu'il est "UP" :

### 1. Contrôle du Mobile (Allumer le téléphone)

Pour que le mobile tente de s'enregistrer, il doit être activé :

```bash
telnet 0 4247
# Commandes suggérées : mobile 1, unit 1, service

```

### 2. Gestion des Abonnés (HLR)

Pour vérifier si ton abonné (IMSI 001010000000000) est bien présent avec son MSISDN :

```bash
telnet 0 4258
# Commande :
show subscribers all

```

### 3. Envoi de SMS (MSC)

Une fois le mobile enregistré (Visible dans `show subscribers` du MSC), tu peux envoyer un SMS de test vers le mobile (MSISDN `89862` trouvé dans ton HLR) :

```bash
telnet 0 4254
# Commande pour envoyer un SMS :
subscriber msisdn 89862 sms sender msisdn 111 send How are you

```

---

## 📊 Architecture du Flux

* **MSC (4254)** : Gère le routage du SMS.
* **HLR (4258)** : Fournit les infos sur l'abonné.
* **Mobile (4247)** : Reçoit le message sur l'interface virtuelle.
