#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# update.sh - met a jour les trois depots de la machine, a l'ouverture de session
#
# C'est CE fichier, et lui seul, que l'ISO va chercher au demarrage :
# /usr/local/sbin/osmo-update.sh telecharge .../osmo_egprs/refs/heads/main/update.sh
# et l'execute. Il a existe un tools/update.sh, seconde copie divergente : chacune
# des deux ne faisait que la moitie du travail (l'une clonait osmo_egprs, l'autre
# le dashboard) et l'animation SMS y etait ecrite deux fois. Il est supprime -
# les lignes de journal de build-iso.sh qui le nomment encore visent en realite
# ce fichier-ci.
#
# ── CE QU'IL FAIT ────────────────────────────────────────────────────────────
# Il n'update rien lui-meme : il POSE /usr/local/sbin/osmo-sync.sh et l'accroche
# a la fin de /etc/profile.d/01-keyboard-setup.sh. L'enchainement vu par
# l'utilisateur, a sa premiere session :
#
#     clavier fr  →  animation SMS  →  mise a jour des 3 depots (logs a l'ecran)
#
# ── POURQUOI A LA SESSION ET PAS AU BOOT ─────────────────────────────────────
# osmo-update.service tourne avant qu'un terminal existe, et sa sortie part dans
# /var/log/osmo-update.log. Un clone de qemu qui prend deux minutes y est
# indiscernable d'un blocage : l'ecran reste noir, sans un mot. Joue a la
# session, le meme clone defile sous les yeux de celui qui attend.
#
# ── LES TROIS DEPOTS ─────────────────────────────────────────────────────────
#   /opt/GSM/osmo_egprs     bbaranoff/osmo_egprs      la pile et ses scripts
#   /opt/osmo-egprs-web     bbaranoff/osmo-egprs-web  le dashboard (service systemd)
#   /opt/GSM/qemu-src       bbaranoff/qemu            l'emulation Calypso
# Ce sont les chemins que cherchent deja launch/start-oqc.sh, start-direct.sh et
# le Dockerfile - en changer un ici ne deplacerait pas ceux qui les lisent.
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

# ── Outils dont dependent les scripts poses ──────────────────────────────────
#   git  la synchro des depots, evidemment.
#   nc   le VTY. start-interstp.sh --status, checks/ss7_check.sh et
#        checks/wan_ss7_check.sh interrogent les demons par "nc 127.0.0.1 4239" :
#        c'est la SEULE source de verite sur qui est reellement attache, un ASP
#        pouvant avoir ouvert sa SCTP sans jamais passer ASP-ACTIVE. Sans nc, ces
#        scripts ne se plaignent pas - ils affichent un diagnostic vide, ce qui
#        se lit comme "rien n'est attache" alors que tout va bien.
#        netcat-openbsd : c'est ce que pose deja le build, et son -q est celui
#        qu'attendent les appels du depot.
#   tcpdump  les captures GSMTAP/M3UA (run_modules et diag). Sans lui, la
#        capture demarree en arriere-plan echoue en silence et le pcap reste
#        vide - on croit a une capture faite alors qu'il n'y a rien dedans.
need_pkg() {   # $1=commande  $2..=paquets candidats, dans l'ordre
    local cmd="$1"; shift
    command -v "$cmd" >/dev/null 2>&1 && { echo "  ✓ ${cmd} deja present"; return 0; }
    [ "${APT_REFRESHED:-0}" = "1" ] || { echo "  apt-get update"; apt-get update || true; APT_REFRESHED=1; }
    local p
    for p in "$@"; do
        echo "  apt-get install ${p}"
        apt-get install -y "$p" && command -v "$cmd" >/dev/null 2>&1 && {
            echo "  ✓ ${cmd} (${p})"; return 0; }
    done
    echo "  ⚠ ${cmd} introuvable - paquets essayes : $*" >&2
    return 1
}

APT_REFRESHED=1
need_pkg socat socat

# ══════════════════════════════════════════════════════════════════════════════
# /usr/local/sbin/osmo-sync.sh - animation puis synchro, ecrit UNE fois
# ══════════════════════════════════════════════════════════════════════════════
# Heredoc quote : rien n'est interprete ici, le script est pose tel quel. C'est
# aussi ce qui permet a l'animation de n'exister qu'en un seul exemplaire -
# l'ancienne version la recopiait a l'identique dans update.sh ET dans le profil.
cat > "$SYNC" <<'SYNCEOF'
#!/bin/bash
# osmo-sync.sh - animation SMS, puis mise a jour des trois depots.
# Pose par update.sh ; appele a l'ouverture de session depuis
# /etc/profile.d/01-keyboard-setup.sh, et executable a la main :
#   sudo osmo-sync.sh            les trois depots en clair, puis l'animation
#   sudo osmo-sync.sh --quiet    sans l'animation finale
#   sudo osmo-sync.sh qemu-src   un seul depot
set -u

LOG=/var/log/osmo-update.log
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

ANIM=1
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)   ANIM=0 ;;
        -y|--yes)  ;;   # accepte et ignore : plus de question a confirmer
        *) break ;;
    esac
    shift
done
ONLY="${1:-}"

# ── L'animation ─────────────────────────────────────────────────────────────
# Sur un tty seulement : les sequences de curseur (\033[?25l) ecrites dans un
# fichier de log le rendent illisible, et l'attente ne sert plus personne.
sms_anim() {
    [ "$ANIM" = "1" ] && [ -t 1 ] || return 0
    local ph b p
    printf '\033[?25l'
    ph='\033[1;33m☎\033[0m'
    local bars=('\033[2m▁▁▁\033[0m' '\033[1;32m▃\033[0m\033[2m▁▁\033[0m' '\033[1;32m▃▅\033[0m\033[2m▁\033[0m' '\033[1;32m▃▅▇\033[0m')
    for b in "${bars[@]}"; do
        printf '\r  %b %b  \033[36mscanning ARFCN...\033[0m   ' "$ph" "$b"
        sleep 0.12
    done
    for ((p=0; p<=20; p++)); do
        printf '\r\033[K  %b %*s\033[1;36m✉\033[0m%*s %b' "$ph" "$p" '' "$((20-p))" '' "$ph"
        sleep 0.04
    done
    printf '\r\033[K  %b%21s%b  \033[1;32m✓ SMS delivered - MT end-to-end Message : Bastien phone home\033[0m\n' "$ph" '' "$ph"
    printf '\033[?25h'
}

# ── Un depot ────────────────────────────────────────────────────────────────
# Deux regimes, parce que les trois depots n'ont pas le meme poids ni le meme
# usage :
#
#   wipe=1  osmo_egprs, osmo-egprs-web - on EFFACE et on reclone.
#           Ce sont des arbres legers, et ce sont eux que les sessions
#           precedentes ont pu salir : un fichier genere, un .pyc, un patch
#           essaye a la main. Un fetch les laisserait en place ; le rm garantit
#           que ce qui tourne est exactement ce que le depot decrit.
#   wipe=0  qemu-src - incremental. L'historique de qemu pese plusieurs
#           gigaoctets ; le recloner a chaque session, en live-boot toram,
#           c'est le remplir de RAM pour rien.
#
# --depth 1 partout : ces depots sont la pour etre EXECUTES, pas fouilles.
#
# CE QUE LE rm COUTE, puisqu'il est demande : entre l'effacement et la fin du
# clone, la machine n'a plus ses scripts. Reseau coupe pile a ce moment-la et
# /opt/GSM/osmo_egprs reste vide jusqu'au prochain boot. Le clone se fait donc
# dans un temporaire VOISIN quand la place le permet - l'effacement n'a lieu
# qu'une fois l'arbre neuf sur le disque, et la fenetre se reduit a un mv.
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
        printf "    ${Y}⚠${N} fetch impossible - copie existante conservee\n"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp -d "$(dirname "$dest")/.sync-XXXXXX" 2>/dev/null)" || tmp="$(mktemp -d)"
    printf "    ${C}git clone --depth 1 %s${N}\n" "$url"
    if git clone --depth 1 --single-branch --progress "$url" "$tmp/repo"; then
        # L'annonce du rm est ici, et pas avant le clone : un clone qui echoue
        # n'efface rien, et un journal qui dit "rm" puis "inchange" laisse
        # croire a une machine a moitie detruite.
        [ -d "$dest" ] && printf "    ${Y}rm${N} %s\n" "$dest"
        rm -rf "$dest"
        mv "$tmp/repo" "$dest"
        rm -rf "$tmp"
        printf "    ${G}✓${N} clone frais - %s\n" "$(git -C "$dest" log -1 --format='%h %s')"
        return 0
    fi
    rm -rf "$tmp"
    printf "    ${R}✗${N} clone impossible (reseau ?) - %s inchange\n" "$dest"
    return 1
}

# ── Le dashboard : dependances et service ───────────────────────────────────
# Separe de sync_repo parce que c'est le seul des trois qui tourne en service :
# le depot a jour sur le disque ne change rien tant que le demon fait tourner
# l'ancien code.
web_service() {
    local unit=/etc/systemd/system/osmo-egprs-web.service
    [ -d /opt/osmo-egprs-web ] || return 0

    if command -v npm >/dev/null 2>&1 && [ -f /opt/osmo-egprs-web/package.json ]; then
        printf "    ${C}npm install --omit=dev${N}\n"
        if (cd /opt/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund); then
            printf "    ${G}✓${N} npm install\n"
        else
            printf "    ${Y}⚠${N} npm install en echec - le dashboard peut ne pas demarrer\n"
        fi
    fi

    [ -f "$unit" ] || return 0
    # CAP_IFACE=any : sans lui la capture se lie a une interface nommee qui
    # n'existe pas forcement sur cette machine, et le dashboard demarre muet.
    if grep -q '^Environment=CAP_IFACE=' "$unit"; then
        sed -i 's|^Environment=CAP_IFACE=.*|Environment=CAP_IFACE=any|' "$unit"
    else
        sed -i '/^\[Service\]/a Environment=CAP_IFACE=any' "$unit"
    fi
    printf "    ${C}systemctl daemon-reload && systemctl restart osmo-egprs-web${N}\n"
    systemctl daemon-reload || true
    if systemctl restart osmo-egprs-web.service; then
        printf "    ${G}✓${N} osmo-egprs-web relance (CAP_IFACE=any)\n"
    else
        printf "    ${Y}⚠${N} osmo-egprs-web n'a pas redemarre - journalctl -u osmo-egprs-web\n"
    fi
}

# ── Deroule ─────────────────────────────────────────────────────────────────
# Pas de question : la synchro part d'elle-meme. Pour ne pas mettre a jour,
# on ne lance pas osmo-sync.sh (ou on retire /etc/profile.d/99-osmo-sync.sh).

mkdir -p /opt/GSM "$(dirname "$LOG")" 2>/dev/null || true
echo "===== osmo-sync $(date '+%F %T') =====" >> "$LOG" 2>/dev/null || true

echo ""
printf "${B}${C}══ Mise a jour des depots ══${N}\n"
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
    *) printf "${R}depot inconnu : %s${N}  (osmo_egprs | osmo-egprs-web | qemu-src)\n" "$ONLY" >&2; exit 2 ;;
esac

echo ""
# L'animation ferme la marche : elle ne sert plus a faire patienter - tout ce qui
# precede a defile en clair - mais a dire que c'est fini, d'un coup d'oeil et de
# l'autre bout de la piece.
sms_anim
if [ "$rc" = "0" ]; then
    printf "  ${G}✓ depots a jour${N}\n"
else
    printf "  ${Y}⚠ au moins un depot n'a pas pu etre mis a jour - la machine garde l'existant${N}\n"
fi
printf "  Relancer a la main : ${C}sudo osmo-sync.sh${N}\n"
echo ""
exit 0
SYNCEOF
chmod +x "$SYNC"
echo "  ✓ ${SYNC}"

# ══════════════════════════════════════════════════════════════════════════════
# Accrochage a la session : un fichier A PART, pas une greffe sur le clavier
# ══════════════════════════════════════════════════════════════════════════════
# POURQUOI PAS DANS 01-keyboard-setup.sh - c'est la raison pour laquelle on ne
# voyait plus rien au reboot. Ce fichier commence par :
#
#     [ -f /var/lib/osmo-kb-done ] && return 0
#
# et sa derniere action est "touch /var/lib/osmo-kb-done". Une fois le clavier
# choisi, le script entier retourne a sa deuxieme ligne - donc TOUT ce qu'on lui
# ajoute a la fin, animation comprise, ne se joue qu'une seule fois dans la vie
# de la machine. Premier demarrage : on voit le SMS. Deuxieme : plus rien, et
# rien n'indique pourquoi.
#
# Un fichier separe n'a pas ce garde-fou. /etc/profile.d est source dans l'ordre
# alphabetique : 01-keyboard-setup.sh d'abord, 99-osmo-sync.sh ensuite -
# l'animation reste donc bien APRES le choix du clavier, sans dependre de lui.
#
# Au passage, on ne decoupe plus 01-keyboard-setup.sh : l'ancienne methode le
# tronquait apres la ligne "Disclaimer", ce qui lui faisait perdre ses deux
# dernieres lignes a chaque passage.
if [ "$SYNC_ONLY" = "0" ]; then
    # Nettoyage de l'ancienne greffe, si un passage precedent l'a posee : sinon
    # l'animation reste ecrite a deux endroits, et le premier boot la joue deux
    # fois.
    if [ -f "$PROFILE" ] && grep -q 'osmo-sync\|scanning ARFCN' "$PROFILE"; then
        tmp="$(mktemp)"
        awk '/^# ── osmo-sync ──/{exit} /^# ── animation : MT SMS/{exit} 1' "$PROFILE" > "$tmp"
        cat "$tmp" > "$PROFILE"; rm -f "$tmp"
        echo "  ✓ ${PROFILE} - ancienne greffe retiree"
    fi

    # ── Une fois par DEMARRAGE, pas par session ──────────────────────────────
    # Le temoin vit dans /run, un tmpfs que le noyau recree vide a chaque boot :
    # la synchro se rejoue donc a chaque reboot, et une seule fois. Sans lui,
    # ouvrir un second tty ou faire "su -" relancerait le rm et le clone des
    # depots sous les pieds de ce qui tourne.
    cat > "$HOOK" <<'HOOKEOF'
# 99-osmo-sync.sh - pose par update.sh (depot osmo_egprs)
# Source APRES 01-keyboard-setup.sh (ordre alphabetique de /etc/profile.d) :
# clavier → animation SMS → mise a jour des 3 depots, logs sur CE terminal.
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac      # session interactive seulement
[ "$(id -u)" -eq 0 ] || return 0
[ -x /usr/local/sbin/osmo-sync.sh ] || return 0
[ -e /run/osmo-sync.done ] && return 0      # /run : vide a chaque demarrage
: > /run/osmo-sync.done
/usr/local/sbin/osmo-sync.sh
HOOKEOF
    chmod +x "$HOOK"
    echo "  ✓ ${HOOK} - clavier → animation → depots, a chaque demarrage"
fi

[ "$ANIM" = "1" ] || sed -i 's|osmo-sync\.sh$|osmo-sync.sh --quiet|' "$HOOK" 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════════
# Declenchement sur la console - la course que le profil ne peut pas gagner
# ══════════════════════════════════════════════════════════════════════════════
# Sur l'ISO deja gravee, deux unites demarrent en parallele et une seule attend
# le reseau :
#
#   osmo-update.service   After=network-online.target  ← nous, donc EN RETARD
#   getty@tty1 (autologin) n'attend rien               ← le shell, donc EN AVANCE
#
# Le shell source /etc/profile - et son "for i in /etc/profile.d/*.sh" developpe
# le motif UNE fois, au debut - bien avant que ce script n'ait pose quoi que ce
# soit. Un fichier cree apres coup n'entre pas dans une boucle deja lancee : le
# profil, greffe ou separe, ne peut donc rien afficher au premier passage. Et
# comme /etc revient du squashfs a chaque demarrage sur un live, ce n'est pas
# "la premiere fois", c'est TOUTES les fois.
#
# D'ou ce declencheur, qui ne depend d'aucun ordre de demarrage : on attend le
# temoin que pose la fin de la configuration clavier, puis on ecrit sur le tty ou
# l'utilisateur se trouve. L'enchainement demande tient sans toucher a l'ISO :
#
#     clavier fr → animation SMS → les 3 depots
#
# Detache (setsid ... &) : le service est un oneshot, le bloquer le temps du
# clavier retarderait multi-user.target et tout ce qui en depend.
console_trigger() {
    local waiter=/usr/local/sbin/osmo-sync-console.sh
    cat > "$waiter" <<'WAITEOF'
#!/bin/bash
# Attend la fin du choix clavier, puis joue la synchro sur le tty de session.
# Pose par update.sh ; lance detache depuis osmo-update.service.
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
    echo "  ✓ declencheur console arme (attend la fin du choix clavier)"
}

if [ "$RUN_NOW" = "1" ]; then
    echo ""
    "$SYNC"
elif [ -t 1 ]; then
    # Lance a la main depuis un shell : l'utilisateur est la, il n'a pas besoin
    # qu'on lui arme un declencheur pour dans trente secondes.
    echo ""
    echo "  Tout de suite : sudo osmo-sync.sh"
else
    # Lance par osmo-update.service : personne ne lit cette sortie, elle part
    # dans /var/log/osmo-update.log. C'est le declencheur qui portera la suite
    # jusqu'a l'ecran.
    console_trigger
fi
