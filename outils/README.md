# `outils/` — Diagnostic et analyse


Scripts autonomes, lancés à la main, sans rôle dans le démarrage. Chacun documente
une méthode de mesure — c'est pourquoi ils sont rangés plutôt que supprimés.

| Fichier | |
|---|---|
| `daram_sweep.sh` | balaye CALYPSO_BSP_DARAM_ADDR en full mode et compare |
| `fft.sh` | outils/fft.sh — FFT "jolie" du flux I/Q Calypso, lue DIRECTEMENT dans le docker. |
| `fft2.sh` | outils/fft2.sh — FFT du 2e cfile. Reutilise outils/fft.sh avec un autre CFILE. |
| `fft_global.sh` | FFT "jolie" d'un cfile LOCAL passe en argument (fichier statique). |
| `grgsm_relay_decode.py` | -*- coding: utf-8 -*- |
| `matrix.sh` | matrix.sh <burst|si> — MATRICE DYNAMIQUE du treillis 51-multiframe (cote mobile) |
| `qemu_bcch_grgsm.py` |  |
| `radio_if_udp.py` | -*- coding: utf-8 -*- |
| `status.sh` |  |
| `vty-connect.exp` | On récupère l'IP du groupe, par défaut 127.0.0.1 |
| `vty-menu.sh` | Sauvegarde de la configuration actuelle du terminal |
