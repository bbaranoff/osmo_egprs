#!/bin/bash

# Sauvegarde de la configuration actuelle du terminal
OLD_SETTINGS=$(stty -g)
# Sauvegarde des couleurs initiales (si supporté)
INITIAL_BG=$(printf '\e]11;?\a')

# Palette de couleurs "Nord Theme" (Plus élégant)
set_kernel_profile() {
    # On change le fond et le texte
    echo -ne "\e]11;#2E3440\a" # Fond bleu-gris foncé
    echo -ne "\e]10;#D8DEE9\a" # Texte blanc cassé
    clear
}

reset_terminal_profile() {
    # 1. Restauration des couleurs d'origine du profil utilisateur
    echo -ne "\e]110\a" # Reset Foreground
    echo -ne "\e]111\a" # Reset Background
    echo -ne "\e]112\a" # Reset cursor color
    
    # 2. Commande système pour reset le terminal
    tput reset
    tput sgr0
    
    # 3. Restauration des paramètres stty
    stty "$OLD_SETTINGS"
    
    clear
    echo "--- Session SDR terminée, profil restauré ---"
}

# Thème Whiptail harmonisé
export NEWT_COLORS='
  root=,rgb:2e/34/40
  window=rgb:d8/de/e9,rgb:3b/42/52
  shadow=,rgb:1a/1c/23
  title=rgb:88/c0/d0,rgb:3b/42/52
  button=rgb:2e/34/40,rgb:81/a1/c1
  actbutton=rgb:d8/de/e9,rgb:5e/81/ac
  listbox=rgb:d8/de/e9,rgb:3b/42/52
  actlistbox=rgb:88/c0/d0,rgb:43/4c/5e
'

set_kernel_profile
trap reset_terminal_profile EXIT

connect_vty() {
    tput cnorm # S'assure que le curseur est visible
    expect ./vty-connect.exp "$1" "$3" "$4"
    [[ $? -ne 0 ]] && { echo -e "\n[!] Service hors ligne."; sleep 1; }
}

# ... (garder le début du fichier identique) ...

menu_services() {
    local OP=$1
    while true; do
        # Ajout de l'option 7 pour le Baseband
        CHOICE=$(whiptail --title " OPERATOR CONTROL : $OP " --menu "" 18 60 8 \
            "1" "MSC (4254)" "2" "BSC (4242)" "3" "HLR (4258)" \
            "4" "MGW (4243)" "5" "GGSN (4260)" "6" "SGSN (4245)" \
            "7" "STP (4239)" "8" "BASEBAND (4247)" \
            "R" "<< BACK" 3>&1 1>&2 2>&3)

        [[ -z "$CHOICE" || "$CHOICE" == "R" ]] && break
        
        case $CHOICE in
            1) connect_vty "$OP" "MSC" 4254 "msc" ;;
            2) connect_vty "$OP" "BSC" 4242 "bsc" ;;
            3) connect_vty "$OP" "HLR" 4258 "hlr" ;;
            4) connect_vty "$OP" "MGW" 4243 "mgw" ;;
            5) connect_vty "$OP" "GGSN" 4260 "gg" ;;
            6) connect_vty "$OP" "SGSN" 4245 "sg" ;;
            7) connect_vty "$OP" "STP" 4239 "stp" ;;
            8) 
                # Gestion multi-groupes Baseband (127.0.0.1, 127.0.0.2, etc.)
                local GRP_IP
                GRP_IP=$(whiptail --title " BASEBAND GROUP SELECT " --inputbox "Target IP (127.0.0.X) :" 10 40 "127.0.0.1" 3>&1 1>&2 2>&3)
                if [[ -n "$GRP_IP" ]]; then
                    # On passe l'IP du groupe au script expect
                    tput cnorm
                    expect ./vty-connect.exp "$OP" 4247 "bb" "$GRP_IP"
                fi
                ;;
        esac
    done
}

# --- BOUCLE PRINCIPALE SÉCURISÉE ---
while true; do
    MAIN_TYPE=$(whiptail --title " OSMO-SDR STACK MANAGER " --menu "Select Category :" 15 60 3 \
        "CORE" "Global Infrastructure (Inter-STP)" \
        "OPS"  "Network Operators (MSC/BSC/STP...)" \
        "EXIT" "Quit Manager" 3>&1 1>&2 2>&3)

    [[ -z "$MAIN_TYPE" || "$MAIN_TYPE" == "EXIT" ]] && break

    if [[ "$MAIN_TYPE" == "CORE" ]]; then
        # Vérification si l'inter-stp est en vie
        if docker ps --format '{{.Names}}' | grep -q "osmo-inter-stp"; then
            docker exec -ti osmo-inter-stp telnet 127.0.0.1 4239
        else
            whiptail --msgbox "Erreur : osmo-inter-stp n'est pas lancé." 10 50
        fi
    else
        # On récupère les opérateurs actifs
        OPS=$(docker ps --format "{{.Names}}" | grep "osmo-operator" | sort)
        
        if [[ -z "$OPS" ]]; then
            whiptail --msgbox "Aucun opérateur détecté ! Vérifiez start.sh" 10 50
            continue
        fi

        MENU_LIST=()
        while read -r line; do MENU_LIST+=("$line" "Status: Active"); done <<< "$OPS"

        OP_CHOICE=$(whiptail --title " OPERATOR SELECTION " --menu "Select Operator Node :" 20 70 10 \
            "${MENU_LIST[@]}" 3>&1 1>&2 2>&3)

        [[ -n "$OP_CHOICE" ]] && menu_services "$OP_CHOICE"
    fi
done

reset_terminal_profile
