#!/bin/bash

# 1. Vérification root
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit être lancé en tant que root (sudo).\033[0m" 
   exit 1
fi

# 2. Nettoyage (Optionnel mais conseillé pour ton setup SDR)
echo "--- Préparation du build Osmocom ---"

# 3. Lancement du build (On retire le "sudo" inutile car le script est déjà root)
docker build . -t osmocom-nitb

# 4. Vérification du succès
if [ $? -eq 0 ]; then
    echo -e "\033[0;32m[OK] Image osmocom-nitb construite avec succès.\033[0m"
else
    echo -e "\033[0;31m[ERREUR] Le build Docker a échoué.\033[0m"
    exit 1
fi
