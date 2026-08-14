#!/usr/bin/env bash
# update.sh — rafraîchit l'arbre osmo_egprs et le dashboard, puis applique les
# correctifs ISO (feed HLR, routage SMS).
#
# [2026-08-14] PAS de `set -e`, VOLONTAIREMENT : ce script enchaîne des étapes
# « au mieux » (apt, systemctl, VTY HLR) dont l'échec ne doit pas interrompre
# les suivantes. Les endroits réellement dangereux sont gardés UN PAR UN
# ci-dessous — un `set -e` global changerait le comportement de tout le reste
# sans qu'on puisse le tester ailleurs que sur une ISO gravée.

# Branche suivie par les dépôts maison. Surchargeable : OSMO_BRANCH=x ./update.sh
OSMO_BRANCH="${OSMO_BRANCH:-main}"

# 1) tronquer juste après la ligne Disclaimer (gardée)
# [2026-08-14] GARDE : sans le test d'existence, `awk` sur un fichier absent
# produisait un /tmp/kb.new VIDE, et le `cat > …` de l'étape 3 TRONQUAIT alors
# /etc/profile.d/01-keyboard-setup.sh au lieu de le compléter. Sur une machine
# qui n'est pas l'ISO, ça effaçait le fichier au lieu de ne rien faire.
KB=/etc/profile.d/01-keyboard-setup.sh
if [ -s "$KB" ]; then
awk '1; /Disclaimer/{exit}' "$KB" > /tmp/kb.new
# 2) appender l'animation — heredoc QUOTÉ => zéro échappement
apt update && apt install -y git socat
cat >> /tmp/kb.new <<'ANIM'

# ── animation : MT SMS entre deux téléphones ──
printf '\033[?25l'
ph='\033[1;33m☎\033[0m'
bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
for b in "${bars[@]}"; do
  printf '\r  %b %b  \033[36mscanning ARFCN…\033[0m   ' "$ph" "$b"
  sleep 0.12
done
for ((p=0; p<=20; p++)); do
  printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
  sleep 0.04
done
printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered — MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"
printf '\033[?25h'
ANIM
# 3) réécrire dans le même inode
cat /tmp/kb.new > "$KB"
else
    echo "01-keyboard-setup.sh absent ou vide — animation non posée (machine hors ISO)"
fi

# [2026-08-14] NEUTRALISÉE : `sed -i -e 's/a5 0/a5 0/g'` remplaçait « a5 0 » par
# « a5 0 » — un no-op qui ne changeait que la date des fichiers. L'intention
# était probablement 's/a5 1/a5 0/' (forcer A5/0), mais je ne devine pas un
# réglage de chiffrement : décommente en corrigeant le motif si c'est bien ça.
# sed -i -e 's/a5 1/a5 0/g' /etc/osmocom/osmo-*sc.cfg


apt update && apt install git tcpdump binutils-arm-none-eabi -y

# ── Rafraîchir l'arbre osmo_egprs (branche main) ─────────────────────────────
# Remplace l'ancien « cd /opt/GSM/osmo_egprs && git pull » qui ne pouvait PAS
# fonctionner sur une ISO : build-iso.sh y installe l'arbre NU, sans .git
# (« find … -name '.git*' … -exec rm -rf »). Le pull échouait silencieusement,
# donc aucun correctif du dépôt (run_modules/, scripts/…) n'atteignait jamais
# une ISO déjà gravée — update.sh ne rattrapait que ce qu'elle réécrit elle-même.
#
# Doit rester AVANT l'écriture de coeur.env plus bas : ce bloc peut remplacer
# l'arbre entier, ce qui effacerait un coeur.env posé trop tôt.
# [2026-08-14] EGPRS_DIR n'est PLUS codé en dur sur /opt/GSM/osmo_egprs. Ce
# chemin est celui de l'ISO et du conteneur ; sur une machine de dev le dépôt
# vit ailleurs (ex. /home/nirvana/osmo_egprs). update.sh y créait alors un
# SECOND arbre dans /opt/GSM au lieu de mettre à jour celui d'où on l'avait
# lancé — « mise à jour » silencieusement sans effet sur le bon arbre.
# On prend d'abord l'arbre qui CONTIENT ce script, et on retombe sur le chemin
# historique sinon. Surchargeable : EGPRS_DIR=/chemin ./update.sh
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${EGPRS_DIR:-}" ]; then
    if [ -d "$_here/.git" ] && [ -s "$_here/start.sh" ]; then
        EGPRS_DIR="$_here"
    else
        EGPRS_DIR=/opt/GSM/osmo_egprs
    fi
fi
echo "osmo_egprs : arbre ciblé = $EGPRS_DIR (branche $OSMO_BRANCH)"
if [ -d "$EGPRS_DIR/.git" ]; then
    # [2026-08-14] GARDE : `reset --hard` DÉTRUIT tout travail non commité. Tant
    # que EGPRS_DIR valait /opt/GSM (arbre jetable), c'était sans conséquence ;
    # depuis qu'il peut désigner l'arbre de développement d'où l'on lance le
    # script, ça effacerait les modifications en cours — y compris celles de
    # update.sh lui-même, en pleine exécution. On refuse au lieu d'écraser.
    # `--untracked-files=no` est ESSENTIEL, et pas un détail de confort :
    #   1. `reset --hard` ne touche QUE les fichiers suivis. Les non suivis ne
    #      risquent rien, les compter serait refuser pour un danger inexistant.
    #   2. update.sh génère lui-même un fichier non suivi ($envdir/coeur.env,
    #      plus bas). Sans cette option, le tout premier passage rendait l'arbre
    #      « sale » DÉFINITIVEMENT et le pull était refusé à chaque exécution
    #      suivante — le script se bloquait lui-même. Constaté au test.
    if [ -n "$(git -C "$EGPRS_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "osmo_egprs : fichiers SUIVIS modifiés non commités — reset --hard REFUSÉ" >&2
        git -C "$EGPRS_DIR" status --short --untracked-files=no >&2
        echo "  commite ou remise (git stash) d'abord, ou : EGPRS_DIR=/autre/chemin $0" >&2
    elif git -C "$EGPRS_DIR" fetch origin "$OSMO_BRANCH" \
      && git -C "$EGPRS_DIR" reset --hard FETCH_HEAD; then
        echo "osmo_egprs : arbre git réaligné sur origin/$OSMO_BRANCH"
    else
        # [2026-08-14] ÉCHEC DU PULL → on repart d'un clone neuf.
        #
        # ⚠️ RÉSERVÉ À L'ARBRE JETABLE /opt/GSM/osmo_egprs. Depuis que EGPRS_DIR
        #    est auto-détecté, il peut désigner un arbre de DÉVELOPPEMENT : y
        #    supprimer le dépôt sur une simple coupure réseau détruirait du
        #    travail. Ailleurs, on refuse et on le dit.
        #
        # ⚠️ ORDRE : on clone À CÔTÉ d'abord, on ne supprime qu'une fois le clone
        #    réussi. C'est la règle déjà appliquée deux fois dans ce fichier (le
        #    tarball juste en dessous, et osmo-egprs-web plus bas) : un `rm` posé
        #    AVANT le clone laisse l'ISO SANS SCRIPTS si le réseau lâche entre
        #    les deux — et sans scripts, plus rien ne peut la réparer.
        echo "osmo_egprs : pull ÉCHOUÉ sur $EGPRS_DIR" >&2
        if [ "$EGPRS_DIR" = /opt/GSM/osmo_egprs ]; then
            egprs_fresh="$(mktemp -d)/osmo_egprs"
            if git clone --branch "$OSMO_BRANCH" \
                   https://github.com/bbaranoff/osmo_egprs "$egprs_fresh"; then
                rm -rf "$EGPRS_DIR"
                mkdir -p /opt/GSM
                mv "$egprs_fresh" "$EGPRS_DIR"
                find "$EGPRS_DIR" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
                echo "osmo_egprs : arbre reconstruit par clone neuf ($OSMO_BRANCH)"
            else
                echo "osmo_egprs : clone de secours ÉCHOUÉ — arbre existant CONSERVÉ" >&2
            fi
            rm -rf "$(dirname "$egprs_fresh")"
        else
            echo "  arbre NON jetable ($EGPRS_DIR) — aucune suppression." >&2
            echo "  répare-le à la main, ou relance avec EGPRS_DIR=/opt/GSM/osmo_egprs" >&2
        fi
    fi
else
    # Arbre nu de l'ISO : pas de dépôt, on retélécharge la branche.
    egprs_stage="$(mktemp -d)"
    if curl -fsSL "https://codeload.github.com/bbaranoff/osmo_egprs/tar.gz/refs/heads/$OSMO_BRANCH" \
         | tar -xz -C "$egprs_stage" --strip-components=1 && [ -s "$egprs_stage/start.sh" ]; then
        # On ne détruit l'arbre en place qu'une fois le tarball vérifié complet :
        # un réseau coupé ne doit pas laisser l'ISO sans scripts.
        rm -rf "$EGPRS_DIR"
        mkdir -p /opt/GSM
        cp -a "$egprs_stage" "$EGPRS_DIR"
        find "$EGPRS_DIR" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
        echo "osmo_egprs : arbre nu rafraîchi depuis $OSMO_BRANCH (tarball)"
    else
        echo "osmo_egprs : récupération impossible (réseau ?) — arbre existant conservé"
    fi
    rm -rf "$egprs_stage"
fi
# [2026-08-14] Le `rm -r /opt/osmo-egprs-web` suivi d'un `git clone` n'était
# protégé par RIEN : réseau coupé = dashboard détruit et rien pour le remplacer.
# Le bloc osmo_egprs juste au-dessus prend pourtant exactement cette précaution
# (« on ne détruit l'arbre en place qu'une fois le tarball vérifié complet ») —
# la ligne suivante l'avait oubliée. On clone À CÔTÉ, on ne remplace qu'en cas
# de succès.
web_stage="$(mktemp -d)/osmo-egprs-web"
if git clone --branch "$OSMO_BRANCH" https://github.com/bbaranoff/osmo-egprs-web "$web_stage"; then
    rm -rf /opt/osmo-egprs-web
    mv "$web_stage" /opt/osmo-egprs-web
    echo "osmo-egprs-web : rafraîchi sur $OSMO_BRANCH"
else
    echo "osmo-egprs-web : clone impossible (réseau ?) — arbre existant CONSERVÉ" >&2
fi
rm -rf "$(dirname "$web_stage")"

UNIT=/etc/systemd/system/osmo-egprs-web.service

# ajoute (ou met à jour) Environment=CAP_IFACE=any sous [Service], idempotent
# [2026-08-14] GARDE : sans le test d'existence, sur une machine sans l'unité
# (tout ce qui n'est pas l'ISO) le `sed -i` échouait puis `systemctl restart`
# aussi — sans `set -e`, deux erreurs qui défilaient sans rien arrêter et sans
# que personne ne comprenne pourquoi le dashboard ne redémarrait pas.
if [ -f "$UNIT" ]; then
    if grep -q '^Environment=CAP_IFACE=' "$UNIT"; then
      sed -i 's|^Environment=CAP_IFACE=.*|Environment=CAP_IFACE=any|' "$UNIT"
    else
      sed -i '/^\[Service\]/a Environment=CAP_IFACE=any' "$UNIT"
    fi
    systemctl daemon-reload
    systemctl restart osmo-egprs-web.service
    # vérif
    systemctl show osmo-egprs-web.service -p Environment
else
    echo "$UNIT absent — service non configuré ici (machine hors ISO)"
fi

# Ancien emplacement, sans le /GSM/ : nettoyage d'héritage. À NE PAS confondre
# avec $EGPRS_DIR (/opt/GSM/osmo_egprs) — deux chemins qui ne diffèrent que par
# « GSM/ », avec un rm -rf dessus.
rm -rf /opt/osmo_egprs

# ═══════════════════════════════════════════════════════════════════════════════
# Correctifs ISO : feed HLR + routage SMS
#
# L'ISO tourne en NATIF (pas de docker au runtime), mais les deux configs
# héritées du build sont restées calibrées pour le mode docker :
#
#   1. feed HLR    run_modules/21-abonnes-hlr.sh retombe sur « : "${N_MS:=1}" ».
#                  Un seul abonné était provisionné quelle que soit la valeur
#                  d'ISO_N_MS : les MS suivants se voyaient refuser le
#                  rattachement (« IMSI unknown in HLR ») — panne lue à tort
#                  comme un défaut radio.
#
#   2. routage SMS le fallback de lib/gabarits.sh pointe [operators] sur
#                  172.20.0.11 (plan docker, personne en natif) et énumère des
#                  préfixes fixes (i000, i0000, i001..i005) qui ne suivent pas
#                  N_MS, d'où « No route for destination » au-delà du 5e MS.
#
# Les deux blocs sont IDEMPOTENTS : rejouables à chaque boot sans effet de bord.
# Formules communes au dépôt (scripts/sms-routing-setup.sh, 21-abonnes-hlr.sh) :
#   IMSI   = MCC(3) MNC(2) %04d(op) %06d(ms)
#   MSISDN = op * 10000 + ms
#   Ki     = 00112233445566778899aabbccdd %02x(ms) %02x(op)
# ═══════════════════════════════════════════════════════════════════════════════

ISO_OP_ID=1        # opérateur unique de l'ISO
ISO_N_MS=2         # doit rester aligné sur ISO_N_MS de build-iso.sh
ISO_MCC=001
ISO_MNC=01
HLR_VTY_PORT=4258

iso_imsi()   { printf '%s%s%04d%06d\n' "$ISO_MCC" "$ISO_MNC" "$ISO_OP_ID" "$1"; }
iso_msisdn() { echo $(( ISO_OP_ID * 10000 + $1 )); }
iso_ki()     { printf '00112233445566778899aabbccdd%02x%02x\n' "$1" "$ISO_OP_ID"; }

# ── 1. feed HLR : N_MS persistant ────────────────────────────────────────────
# environment/load.env source « coeur.env » s'il existe, et tout le dépôt suit
# l'idiome « : "${VAR:=...}" » — poser N_MS ici laisse donc la ligne de commande
# (N_MS=2 ./run.sh) gagner. On écrit dans les deux arbres possibles : run.sh est
# résolu depuis qemu-src, mais osmo_egprs embarque le même squelette.
for envdir in /opt/GSM/qemu-src/environment /opt/GSM/osmo_egprs/environment; do
    [ -d "$envdir" ] || continue
    cat > "$envdir/coeur.env" <<COEUR
# coeur.env — généré par update.sh (ISO). Aligne le nombre d'abonnés
# provisionnés dans le HLR sur le nombre de MS embarqués par l'ISO.
: "\${N_MS:=$ISO_N_MS}"
: "\${OPERATOR_ID:=$ISO_OP_ID}"
COEUR
    echo "coeur.env écrit : $envdir (N_MS=$ISO_N_MS)"
done

# ── 2. feed HLR : provisionnement immédiat si le VTY répond déjà ─────────────
# Au boot le HLR n'est en général pas encore lancé (la pile démarre plus tard
# via start-direct.sh) : dans ce cas 21-abonnes-hlr fera le travail avec le
# N_MS corrigé ci-dessus. Si le VTY écoute déjà (update.sh rejoué à chaud), on
# provisionne tout de suite. « subscriber create » sur un IMSI existant est sans
# effet destructeur — d'où l'idempotence.
if timeout 2 bash -c "exec 9<>/dev/tcp/127.0.0.1/$HLR_VTY_PORT" 2>/dev/null; then
    {
        echo enable
        for ms in $(seq 1 "$ISO_N_MS"); do
            imsi=$(iso_imsi "$ms")
            echo "subscriber imsi $imsi create"
            echo "subscriber imsi $imsi update msisdn $(iso_msisdn "$ms")"
            echo "subscriber imsi $imsi update aud2g comp128v1 ki $(iso_ki "$ms")"
        done
        # « exit », pas « end » : au nœud enable end n'existe pas (le VTY répond
        # « % Unknown command. ») et surtout la session resterait OUVERTE —
        # telnet ne rendrait alors la main qu'au timeout.
        echo exit
        sleep 1
    } | timeout 15 telnet 127.0.0.1 "$HLR_VTY_PORT" >/dev/null 2>&1 || true
    echo "HLR alimenté : $ISO_N_MS abonnés (opérateur $ISO_OP_ID)"
else
    echo "VTY HLR $HLR_VTY_PORT muet — provisionnement délégué à 21-abonnes-hlr au démarrage de la pile"
fi

# ── 3. routage SMS : config native (127.0.0.1), une route par MS ─────────────
# sc_address = 1999001<op>444 et [relay] port 7890 : mêmes valeurs que
# scripts/sms-routing-setup.sh, pour que le relay et proto-smsc-daemon
# s'accordent. En natif il n'y a qu'un opérateur : tout boucle sur 127.0.0.1.
SMS_ROUTING=/etc/osmocom/sms-routing.conf
mkdir -p /etc/osmocom /var/log/osmocom
# Strictement le meme fichier que celui grave par build-iso.sh : update.sh
# repasse APRES le build (elle reecrit /etc/osmocom/sms-routing.conf a chaque
# boot), donc toute divergence ici deviendrait l'etat final de l'ISO. Structure
# du gabarit lib/gabarits.sh, avec UNE route par MS (MSISDN = op*10000 + ms) au
# lieu des prefixes fixes i000/i0000/i001..i005 qui ne suivaient pas N_MS.
{
    printf '# sms-routing.conf — Fallback\n\n'
    printf '[local]\noperator_id = %s\nsc_address  = 1999001%s444\n\n' "$ISO_OP_ID" "$ISO_OP_ID"
    printf '[operators]\n%s = %s\n\n' "$ISO_OP_ID" "127.0.0.1"
    printf '[routes]\n'
    for ms in $(seq 1 "$ISO_N_MS"); do
        printf '%s = %s\n' "$(iso_msisdn "$ms")" "$ISO_OP_ID"
    done
    printf '\n[relay]\nport = 7890\nconnect_timeout = 10\nretry_count = 3\nretry_delay = 5\n'
} > "$SMS_ROUTING"
echo "routage SMS écrit : $SMS_ROUTING ($ISO_N_MS MS, natif 127.0.0.1)"
