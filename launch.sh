#!/usr/bin/env bash
# launch_stack.sh
# À lancer en root (sudo). Lance :
#  - Linphone en USER (non-root)
#  - Wireshark en ROOT sur GSMTAP UDP/4729
#  - Un tcpdump ROOT sur UDP/4729 (utile si Wireshark a la flemme)
#  - Un docker restart (container/service au choix)
# Et affiche "OK" + attend Enter à chaque étape.

set -euo pipefail

GSMTAP_PORT="${GSMTAP_PORT:-4729}"

die() { echo "[!] $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Commande manquante: $1"; }

wait_ok() {
  echo
  echo "=============================="
  echo "OK : $1"
  echo "Appuie sur Entrée pour continuer..."
  read -r _
}

# --- Préflight ---
if [[ "${EUID}" -ne 0 ]]; then
  die "Lance ce script en root: sudo $0"
fi

need sudo
need ss
need docker

# On détermine un user "normal" (celui qui a invoqué sudo) ou on demande.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  echo "[?] Aucun SUDO_USER détecté. Donne le user qui doit lancer Linphone :"
  read -r TARGET_USER
fi

# Vérifs soft
command -v linphone >/dev/null 2>&1 || echo "[!] linphone introuvable (paquet linphone-desktop/linphone ?)"
command -v wireshark >/dev/null 2>&1 || echo "[!] wireshark introuvable"
command -v tcpdump >/dev/null 2>&1 || echo "[!] tcpdump introuvable"

echo "[+] User Linphone = ${TARGET_USER}"
echo "[+] GSMTAP port   = ${GSMTAP_PORT}"

# --- Étape 1 : Afficher l’état du port 4729 ---
wait_ok "Pré-check : qui écoute déjà sur UDP/${GSMTAP_PORT} ?"
ss -lunp | awk -v p=":${GSMTAP_PORT}" '$0 ~ p {print}'

# --- Étape 2 : Lancer Linphone en user ---
wait_ok "Lancer Linphone en user (${TARGET_USER})"
# Détaché de la session root, conserve DISPLAY/XDG si présent
sudo -u "${TARGET_USER}" -H bash -lc '
  echo "[linphone] user=$(id -un) uid=$(id -u)"
  nohup linphone >/tmp/linphone.log 2>&1 &
  echo "[linphone] PID=$!"
  echo "[linphone] log=/tmp/linphone.log"
'

# --- Étape 3 : Lancer Wireshark en root sur UDP/4729 (GSMTAP) ---
wait_ok "Lancer Wireshark en root (filtre udp.port==${GSMTAP_PORT})"
if command -v wireshark >/dev/null 2>&1; then
  # -k start capture, -i any capture sur toutes interfaces, -f filtre BPF, -Y filtre d'affichage
  nohup wireshark -k -i any -f "udp port ${GSMTAP_PORT}" -Y "udp.port==${GSMTAP_PORT}" >/tmp/wireshark.log 2>&1 &
  echo "[wireshark] PID=$!"
  echo "[wireshark] log=/tmp/wireshark.log"
else
  echo "[!] Wireshark non trouvé, étape sautée."
fi

# --- Étape 4 : Fallback tcpdump (toujours pratique) ---
wait_ok "Lancer tcpdump fallback sur UDP/${GSMTAP_PORT} (optionnel mais utile)"
if command -v tcpdump >/dev/null 2>&1; then
  nohup tcpdump -ni any "udp port ${GSMTAP_PORT}" -vv >/tmp/gsmtap_4729.tcpdump.log 2>&1 &
  echo "[tcpdump] PID=$!"
  echo "[tcpdump] log=/tmp/gsmtap_4729.tcpdump.log"
else
  echo "[!] tcpdump non trouvé, étape sautée."
fi

# --- Étape 5 : Docker restart ---
wait_ok "Docker restart (container ou service)."
echo "Tape le NOM du container à restart (ou vide pour choisir via liste) :"
read -r DOCKER_TARGET || true

if [[ -z "${DOCKER_TARGET}" ]]; then
  echo
  echo "[+] Containers en cours :"
  docker ps --format '  - {{.Names}}\t{{.Image}}\t{{.Status}}' || true
  echo
  echo "Tape maintenant le NOM du container à restart :"
  read -r DOCKER_TARGET
fi

wait_ok "Restart docker: ${DOCKER_TARGET}"
docker restart "${DOCKER_TARGET}"
echo "[docker] restart OK : ${DOCKER_TARGET}"

wait_ok "Terminé (Linphone/Wireshark/tcpdump tournent en arrière-plan)."
echo "[+] PIDs:"
pgrep -a linphone 2>/dev/null || true
pgrep -a wireshark 2>/dev/null || true
pgrep -a tcpdump 2>/dev/null | grep -E "udp port ${GSMTAP_PORT}" || true
