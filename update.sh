#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# update.sh — met à jour les trois dépôts de la machine, à l'ouverture de session
#
# C'est CE fichier, et lui seul, que l'ISO va chercher au démarrage :
# /usr/local/sbin/osmo-update.sh télécharge .../osmo_egprs/refs/heads/main/update.sh
# et l'exécute. Il a existé un tools/update.sh, seconde copie divergente : chacune
# des deux ne faisait que la moitié du travail (l'une clonait osmo_egprs, l'autre
# le dashboard) et l'animation SMS y était écrite deux fois. Il est supprimé —
# les lignes de journal de build-iso.sh qui le nomment encore visent en réalité
# ce fichier-ci.
#
# ── CE QU'IL FAIT ────────────────────────────────────────────────────────────
# Il n'update rien lui-même : il POSE /usr/local/sbin/osmo-sync.sh et l'accroche
# à la fin de /etc/profile.d/01-keyboard-setup.sh. L'enchaînement vu par
# l'utilisateur, à sa première session :
#
#     clavier fr  →  animation SMS  →  mise à jour des 3 dépôts (logs à l'écran)
#
# ── POURQUOI À LA SESSION ET PAS AU BOOT ─────────────────────────────────────
# osmo-update.service tourne avant qu'un terminal existe, et sa sortie part dans
# /var/log/osmo-update.log. Un clone de qemu qui prend deux minutes y est
# indiscernable d'un blocage : l'écran reste noir, sans un mot. Joué à la
# session, le même clone défile sous les yeux de celui qui attend.
#
# ── LES TROIS DÉPÔTS ─────────────────────────────────────────────────────────
#   /opt/GSM/osmo_egprs     bbaranoff/osmo_egprs      la pile et ses scripts
#   /opt/osmo-egprs-web     bbaranoff/osmo-egprs-web  le dashboard (service systemd)
#   /opt/GSM/qemu-src       bbaranoff/qemu            l'émulation Calypso
# Ce sont les chemins que cherchent déjà launch/start-oqc.sh, start-direct.sh et
# le Dockerfile — en changer un ici ne déplacerait pas ceux qui les lisent.
#
# Usage :
#   sudo ./update.sh              pose l'animation + la synchro, ne synchronise pas
#   sudo ./update.sh --now        pose, puis synchronise tout de suite
#   sudo ./update.sh --sync-only  synchronise sans toucher au profil
#   sudo ./update.sh --no-anim    pose la synchro sans l'animation
# ══════════════════════════════════════════════════════════════════════════════
set -u

SYNC=/usr/local/sbin/osmo-sync.sh
PROFILE=/etc/profile.d/01-keyboard-setup.sh
HOOK=/etc/profile.d/99-osmo-sync.sh
RUN_NOW=0
SYNC_ONLY=0
ANIM=1

while [ $# -gt 0 ]; do
    case "$1" in
        --now)       RUN_NOW=1 ;;
        --sync-only) SYNC_ONLY=1; RUN_NOW=1 ;;
        --no-anim)   ANIM=0 ;;
        -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Root requis." >&2; exit 1; }

# ── Outils dont dépendent les scripts posés ──────────────────────────────────
#   git  la synchro des dépôts, évidemment.
#   nc   le VTY. start-interstp.sh --status, checks/ss7_check.sh et
#        checks/wan_ss7_check.sh interrogent les démons par « nc 127.0.0.1 4239 » :
#        c'est la SEULE source de vérité sur qui est réellement attaché, un ASP
#        pouvant avoir ouvert sa SCTP sans jamais passer ASP-ACTIVE. Sans nc, ces
#        scripts ne se plaignent pas — ils affichent un diagnostic vide, ce qui
#        se lit comme « rien n'est attaché » alors que tout va bien.
#        netcat-openbsd : c'est ce que pose déjà le build, et son -q est celui
#        qu'attendent les appels du dépôt.
need_pkg() {   # $1=commande  $2..=paquets candidats, dans l'ordre
    local cmd="$1"; shift
    command -v "$cmd" >/dev/null 2>&1 && { echo "  ✓ ${cmd} déjà présent"; return 0; }
    [ "${APT_REFRESHED:-0}" = "1" ] || { echo "  apt-get update"; apt-get update || true; APT_REFRESHED=1; }
    local p
    for p in "$@"; do
        echo "  apt-get install ${p}"
        apt-get install -y "$p" && command -v "$cmd" >/dev/null 2>&1 && {
            echo "  ✓ ${cmd} (${p})"; return 0; }
    done
    echo "  ⚠ ${cmd} introuvable — paquets essayés : $*" >&2
    return 1
}

APT_REFRESHED=0
need_pkg git git
need_pkg nc  netcat-openbsd netcat-traditional netcat

# ══════════════════════════════════════════════════════════════════════════════
# /usr/local/sbin/osmo-sync.sh — animation puis synchro, écrit UNE fois
# ══════════════════════════════════════════════════════════════════════════════
# Heredoc quoté : rien n'est interprété ici, le script est posé tel quel. C'est
# aussi ce qui permet à l'animation de n'exister qu'en un seul exemplaire —
# l'ancienne version la recopiait à l'identique dans update.sh ET dans le profil.
cat > "$SYNC" <<'SYNCEOF'
#!/bin/bash
# osmo-sync.sh — animation SMS, puis mise à jour des trois dépôts.
# Posé par update.sh ; appelé à l'ouverture de session depuis
# /etc/profile.d/01-keyboard-setup.sh, et exécutable à la main :
#   sudo osmo-sync.sh            les trois dépôts en clair, puis l'animation
#   sudo osmo-sync.sh --quiet    sans l'animation finale
#   sudo osmo-sync.sh qemu-src   un seul dépôt
set -u

LOG=/var/log/osmo-update.log
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

ANIM=1
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)   ANIM=0 ;;
        -y|--yes)  ;;   # accepté et ignoré : plus de question à confirmer
        *) break ;;
    esac
    shift
done
ONLY="${1:-}"

# ── L'animation ─────────────────────────────────────────────────────────────
# Sur un tty seulement : les séquences de curseur (\033[?25l) écrites dans un
# fichier de log le rendent illisible, et l'attente ne sert plus personne.
sms_anim() {
    [ "$ANIM" = "1" ] && [ -t 1 ] || return 0
    local ph b p
    printf '\033[?25l'
    ph='\033[1;33m☎\033[0m'
    local bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
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
}

# ── Un dépôt ────────────────────────────────────────────────────────────────
# Deux régimes, parce que les trois dépôts n'ont pas le même poids ni le même
# usage :
#
#   wipe=1  osmo_egprs, osmo-egprs-web — on EFFACE et on reclone.
#           Ce sont des arbres légers, et ce sont eux que les sessions
#           précédentes ont pu salir : un fichier généré, un .pyc, un patch
#           essayé à la main. Un fetch les laisserait en place ; le rm garantit
#           que ce qui tourne est exactement ce que le dépôt décrit.
#   wipe=0  qemu-src — incrémental. L'historique de qemu pèse plusieurs
#           gigaoctets ; le recloner à chaque session, en live-boot toram,
#           c'est le remplir de RAM pour rien.
#
# --depth 1 partout : ces dépôts sont là pour être EXÉCUTÉS, pas fouillés.
#
# CE QUE LE rm COÛTE, puisqu'il est demandé : entre l'effacement et la fin du
# clone, la machine n'a plus ses scripts. Réseau coupé pile à ce moment-là et
# /opt/GSM/osmo_egprs reste vide jusqu'au prochain boot. Le clone se fait donc
# dans un temporaire VOISIN quand la place le permet — l'effacement n'a lieu
# qu'une fois l'arbre neuf sur le disque, et la fenêtre se réduit à un mv.
sync_repo() {   # $1=nom  $2=url  $3=destination  $4=1 pour effacer et recloner
    local name="$1" url="$2" dest="$3" wipe="${4:-0}" br tmp
    printf "  ${B}%-16s${N} ${C}%s${N}\n" "$name" "$dest"

    if [ "$wipe" != "1" ] && [ -d "$dest/.git" ]; then
        br="$(git -C "$dest" symbolic-ref --quiet --short HEAD 2>/dev/null)"
        [ -n "$br" ] || br=main
        printf "    ${C}git fetch --depth 1 origin %s${N}\n" "$br"
        if git -C "$dest" fetch --depth 1 --progress origin "$br" \
           || git -C "$dest" fetch --depth 1 --progress origin main; then
            git -C "$dest" reset --hard FETCH_HEAD \
                && git -C "$dest" clean -fd \
                && printf "    ${G}✓${N} %s\n" "$(git -C "$dest" log -1 --format='%h %s')" \
                && return 0
        fi
        printf "    ${Y}⚠${N} fetch impossible — copie existante conservée\n"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp -d "$(dirname "$dest")/.sync-XXXXXX" 2>/dev/null)" || tmp="$(mktemp -d)"
    printf "    ${C}git clone --depth 1 %s${N}\n" "$url"
    if git clone --depth 1 --single-branch --progress "$url" "$tmp/repo"; then
        # L'annonce du rm est ici, et pas avant le clone : un clone qui échoue
        # n'efface rien, et un journal qui dit « rm » puis « inchangé » laisse
        # croire à une machine à moitié détruite.
        [ -d "$dest" ] && printf "    ${Y}rm${N} %s\n" "$dest"
        rm -rf "$dest"
        mv "$tmp/repo" "$dest"
        rm -rf "$tmp"
        printf "    ${G}✓${N} clone frais — %s\n" "$(git -C "$dest" log -1 --format='%h %s')"
        return 0
    fi
    rm -rf "$tmp"
    printf "    ${R}✗${N} clone impossible (réseau ?) — %s inchangé\n" "$dest"
    return 1
}

# ── Le dashboard : dépendances et service ───────────────────────────────────
# Séparé de sync_repo parce que c'est le seul des trois qui tourne en service :
# le dépôt à jour sur le disque ne change rien tant que le démon fait tourner
# l'ancien code.
web_service() {
    local unit=/etc/systemd/system/osmo-egprs-web.service
    [ -d /opt/osmo-egprs-web ] || return 0

    if command -v npm >/dev/null 2>&1 && [ -f /opt/osmo-egprs-web/package.json ]; then
        printf "    ${C}npm install --omit=dev${N}\n"
        if (cd /opt/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund); then
            printf "    ${G}✓${N} npm install\n"
        else
            printf "    ${Y}⚠${N} npm install en échec — le dashboard peut ne pas démarrer\n"
        fi
    fi

    [ -f "$unit" ] || return 0
    # CAP_IFACE=any : sans lui la capture se lie à une interface nommée qui
    # n'existe pas forcément sur cette machine, et le dashboard démarre muet.
    if grep -q '^Environment=CAP_IFACE=' "$unit"; then
        sed -i 's|^Environment=CAP_IFACE=.*|Environment=CAP_IFACE=any|' "$unit"
    else
        sed -i '/^\[Service\]/a Environment=CAP_IFACE=any' "$unit"
    fi
    printf "    ${C}systemctl daemon-reload && systemctl restart osmo-egprs-web${N}\n"
    systemctl daemon-reload || true
    if systemctl restart osmo-egprs-web.service; then
        printf "    ${G}✓${N} osmo-egprs-web relancé (CAP_IFACE=any)\n"
    else
        printf "    ${Y}⚠${N} osmo-egprs-web n'a pas redémarré — journalctl -u osmo-egprs-web\n"
    fi
}

# ── Déroulé ─────────────────────────────────────────────────────────────────
# Pas de question : la synchro part d'elle-même. Pour ne pas mettre à jour,
# on ne lance pas osmo-sync.sh (ou on retire /etc/profile.d/99-osmo-sync.sh).

mkdir -p /opt/GSM "$(dirname "$LOG")" 2>/dev/null || true
echo "===== osmo-sync $(date '+%F %T') =====" >> "$LOG" 2>/dev/null || true

echo ""
printf "${B}${C}══ Mise à jour des dépôts ══${N}\n"
echo ""

rc=0
case "$ONLY" in
    ""|all)
        sync_repo osmo_egprs     https://github.com/bbaranoff/osmo_egprs     /opt/GSM/osmo_egprs 1   || rc=1
        sync_repo osmo-egprs-web https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web 1   || rc=1
        web_service
        sync_repo qemu-src       https://github.com/bbaranoff/qemu           /opt/GSM/qemu-src 0     || rc=1
        ;;
    osmo_egprs)     sync_repo osmo_egprs     https://github.com/bbaranoff/osmo_egprs     /opt/GSM/osmo_egprs 1 || rc=1 ;;
    osmo-egprs-web) sync_repo osmo-egprs-web https://github.com/bbaranoff/osmo-egprs-web /opt/osmo-egprs-web 1 || rc=1; web_service ;;
    qemu-src|qemu)  sync_repo qemu-src       https://github.com/bbaranoff/qemu           /opt/GSM/qemu-src 0 || rc=1 ;;
    *) printf "${R}dépôt inconnu : %s${N}  (osmo_egprs | osmo-egprs-web | qemu-src)\n" "$ONLY" >&2; exit 2 ;;
esac

echo ""
# L'animation ferme la marche : elle ne sert plus à faire patienter — tout ce qui
# précède a défilé en clair — mais à dire que c'est fini, d'un coup d'oeil et de
# l'autre bout de la pièce.
sms_anim
if [ "$rc" = "0" ]; then
    printf "  ${G}✓ dépôts à jour${N}\n"
else
    printf "  ${Y}⚠ au moins un dépôt n'a pas pu être mis à jour — la machine garde l'existant${N}\n"
fi
printf "  Relancer à la main : ${C}sudo osmo-sync.sh${N}\n"
echo ""
exit 0
SYNCEOF
chmod +x "$SYNC"
echo "  ✓ ${SYNC}"

# ══════════════════════════════════════════════════════════════════════════════
# Accrochage à la session : un fichier À PART, pas une greffe sur le clavier
# ══════════════════════════════════════════════════════════════════════════════
# POURQUOI PAS DANS 01-keyboard-setup.sh — c'est la raison pour laquelle on ne
# voyait plus rien au reboot. Ce fichier commence par :
#
#     [ -f /var/lib/osmo-kb-done ] && return 0
#
# et sa dernière action est « touch /var/lib/osmo-kb-done ». Une fois le clavier
# choisi, le script entier retourne à sa deuxième ligne — donc TOUT ce qu'on lui
# ajoute à la fin, animation comprise, ne se joue qu'une seule fois dans la vie
# de la machine. Premier démarrage : on voit le SMS. Deuxième : plus rien, et
# rien n'indique pourquoi.
#
# Un fichier séparé n'a pas ce garde-fou. /etc/profile.d est sourcé dans l'ordre
# alphabétique : 01-keyboard-setup.sh d'abord, 99-osmo-sync.sh ensuite —
# l'animation reste donc bien APRÈS le choix du clavier, sans dépendre de lui.
#
# Au passage, on ne découpe plus 01-keyboard-setup.sh : l'ancienne méthode le
# tronquait après la ligne « Disclaimer », ce qui lui faisait perdre ses deux
# dernières lignes à chaque passage.
if [ "$SYNC_ONLY" = "0" ]; then
    # Nettoyage de l'ancienne greffe, si un passage précédent l'a posée : sinon
    # l'animation reste écrite à deux endroits, et le premier boot la joue deux
    # fois.
    if [ -f "$PROFILE" ] && grep -q 'osmo-sync\|scanning ARFCN' "$PROFILE"; then
        tmp="$(mktemp)"
        awk '/^# ── osmo-sync ──/{exit} /^# ── animation : MT SMS/{exit} 1' "$PROFILE" > "$tmp"
        cat "$tmp" > "$PROFILE"; rm -f "$tmp"
        echo "  ✓ ${PROFILE} — ancienne greffe retirée"
    fi

    # ── Une fois par DÉMARRAGE, pas par session ──────────────────────────────
    # Le témoin vit dans /run, un tmpfs que le noyau recrée vide à chaque boot :
    # la synchro se rejoue donc à chaque reboot, et une seule fois. Sans lui,
    # ouvrir un second tty ou faire « su - » relancerait le rm et le clone des
    # dépôts sous les pieds de ce qui tourne.
    cat > "$HOOK" <<'HOOKEOF'
# 99-osmo-sync.sh — posé par update.sh (dépôt osmo_egprs)
# Sourcé APRÈS 01-keyboard-setup.sh (ordre alphabétique de /etc/profile.d) :
# clavier → animation SMS → mise à jour des 3 dépôts, logs sur CE terminal.
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac      # session interactive seulement
[ "$(id -u)" -eq 0 ] || return 0
[ -x /usr/local/sbin/osmo-sync.sh ] || return 0
[ -e /run/osmo-sync.done ] && return 0      # /run : vidé à chaque démarrage
: > /run/osmo-sync.done
/usr/local/sbin/osmo-sync.sh
HOOKEOF
    chmod +x "$HOOK"
    echo "  ✓ ${HOOK} — clavier → animation → dépôts, à chaque démarrage"
fi

[ "$ANIM" = "1" ] || sed -i 's|osmo-sync\.sh$|osmo-sync.sh --quiet|' "$HOOK" 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════════
# Déclenchement sur la console — la course que le profil ne peut pas gagner
# ══════════════════════════════════════════════════════════════════════════════
# Sur l'ISO déjà gravée, deux unités démarrent en parallèle et une seule attend
# le réseau :
#
#   osmo-update.service   After=network-online.target  ← nous, donc EN RETARD
#   getty@tty1 (autologin) n'attend rien               ← le shell, donc EN AVANCE
#
# Le shell source /etc/profile — et son « for i in /etc/profile.d/*.sh » développe
# le motif UNE fois, au début — bien avant que ce script n'ait posé quoi que ce
# soit. Un fichier créé après coup n'entre pas dans une boucle déjà lancée : le
# profil, greffé ou séparé, ne peut donc rien afficher au premier passage. Et
# comme /etc revient du squashfs à chaque démarrage sur un live, ce n'est pas
# « la première fois », c'est TOUTES les fois.
#
# D'où ce déclencheur, qui ne dépend d'aucun ordre de démarrage : on attend le
# témoin que pose la fin de la configuration clavier, puis on écrit sur le tty où
# l'utilisateur se trouve. L'enchaînement demandé tient sans toucher à l'ISO :
#
#     clavier fr → animation SMS → les 3 dépôts
#
# Détaché (setsid … &) : le service est un oneshot, le bloquer le temps du
# clavier retarderait multi-user.target et tout ce qui en dépend.
console_trigger() {
    local waiter=/usr/local/sbin/osmo-sync-console.sh
    cat > "$waiter" <<'WAITEOF'
#!/bin/bash
# Attend la fin du choix clavier, puis joue la synchro sur le tty de session.
# Posé par update.sh ; lancé détaché depuis osmo-update.service.
for _ in $(seq 1 300); do
    [ -e /var/lib/osmo-kb-done ] && break
    sleep 1
done
sleep 1
[ -e /run/osmo-sync.done ] && exit 0
: > /run/osmo-sync.done
# tty1 est la console d'autologin de l'ISO ; /dev/console si elle manque.
tty=/dev/tty1
[ -w "$tty" ] && [ -r "$tty" ] || tty=/dev/console
exec /usr/local/sbin/osmo-sync.sh <"$tty" >"$tty" 2>&1
WAITEOF
    chmod +x "$waiter"
    setsid "$waiter" >/dev/null 2>&1 &
    echo "  ✓ déclencheur console armé (attend la fin du choix clavier)"
}

if [ "$RUN_NOW" = "1" ]; then
    echo ""
    "$SYNC"
elif [ -t 1 ]; then
    # Lancé à la main depuis un shell : l'utilisateur est là, il n'a pas besoin
    # qu'on lui arme un déclencheur pour dans trente secondes.
    echo ""
    echo "  Tout de suite : sudo osmo-sync.sh"
else
    # Lancé par osmo-update.service : personne ne lit cette sortie, elle part
    # dans /var/log/osmo-update.log. C'est le déclencheur qui portera la suite
    # jusqu'à l'écran.
    console_trigger
fi
