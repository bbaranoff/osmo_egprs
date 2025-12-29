#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31m[ERREUR] Ce script doit être lancé en tant que root (sudo).\033[0m" 
   exit 1
fi

sudo docker build . -t osmocom-nitb
