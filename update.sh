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

command -v git >/dev/null 2>&1 || {
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq git >/dev/null 2>&1 || apt install git -y
}

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
#   sudo osmo-sync.sh            animation + les trois dépôts
#   sudo osmo-sync.sh --quiet    sans animation
#   sudo osmo-sync.sh qemu-src   un seul dépôt
set -u

LOG=/var/log/osmo-update.log
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

ANIM=1
[ "${1:-}" = "--quiet" ] && { ANIM=0; shift; }
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
        if git -C "$dest" fetch --depth 1 --quiet origin "$br" 2>/dev/null \
           || git -C "$dest" fetch --depth 1 --quiet origin main 2>/dev/null; then
            git -C "$dest" reset --hard --quiet FETCH_HEAD \
                && git -C "$dest" clean -qfd \
                && printf "    ${G}✓${N} %s\n" "$(git -C "$dest" log -1 --format='%h %s' 2>/dev/null)" \
                && return 0
        fi
        printf "    ${Y}⚠${N} fetch impossible — copie existante conservée\n"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp -d "$(dirname "$dest")/.sync-XXXXXX" 2>/dev/null)" || tmp="$(mktemp -d)"
    if git clone --depth 1 --single-branch --quiet "$url" "$tmp/repo" 2>/dev/null; then
        # L'annonce du rm est ici, et pas avant le clone : un clone qui échoue
        # n'efface rien, et un journal qui dit « rm » puis « inchangé » laisse
        # croire à une machine à moitié détruite.
        [ -d "$dest" ] && printf "    ${Y}rm${N} %s\n" "$dest"
        rm -rf "$dest"
        mv "$tmp/repo" "$dest"
        rm -rf "$tmp"
        printf "    ${G}✓${N} clone frais — %s\n" "$(git -C "$dest" log -1 --format='%h %s' 2>/dev/null)"
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
        (cd /opt/osmo-egprs-web && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1) \
            && printf "    ${G}✓${N} npm install\n" \
            || printf "    ${Y}⚠${N} npm install en échec — le dashboard peut ne pas démarrer\n"
    fi

    [ -f "$unit" ] || return 0
    # CAP_IFACE=any : sans lui la capture se lie à une interface nommée qui
    # n'existe pas forcément sur cette machine, et le dashboard démarre muet.
    if grep -q '^Environment=CAP_IFACE=' "$unit"; then
        sed -i 's|^Environment=CAP_IFACE=.*|Environment=CAP_IFACE=any|' "$unit"
    else
        sed -i '/^\[Service\]/a Environment=CAP_IFACE=any' "$unit"
    fi
    systemctl daemon-reload 2>/dev/null || true
    if systemctl restart osmo-egprs-web.service 2>/dev/null; then
        printf "    ${G}✓${N} osmo-egprs-web relancé (CAP_IFACE=any)\n"
    else
        printf "    ${Y}⚠${N} osmo-egprs-web n'a pas redémarré — journalctl -u osmo-egprs-web\n"
    fi
}

# ── Déroulé ─────────────────────────────────────────────────────────────────
sms_anim

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
if [ "$rc" = "0" ]; then
    printf "  ${G}✓ dépôts à jour${NC}\n"
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
# Accrochage au profil : après le clavier, avant la main
# ══════════════════════════════════════════════════════════════════════════════
# On tronque juste après la ligne Disclaimer, puis on ajoute — c'est l'idiome
# déjà en place, et c'est lui qui rend l'opération rejouable : un second passage
# ne peut pas empiler deux blocs. Le clavier est configuré au-dessus de cette
# ligne, donc l'animation et la synchro tombent bien APRÈS le set du clavier.
#
# La ligne appelle un script externe plutôt que d'inclure le code : le profil
# est SOURCÉ par le shell, et un `exit` égaré dedans ferme la session de
# l'utilisateur. Un appel externe ne peut pas faire ça.
if [ "$SYNC_ONLY" = "0" ]; then
    if [ -f "$PROFILE" ]; then
        tmp="$(mktemp)"
        if grep -q 'Disclaimer' "$PROFILE"; then
            awk '1; /Disclaimer/{exit}' "$PROFILE" > "$tmp"
        else
            # Pas de Disclaimer (profil déjà réécrit) : on repart du fichier
            # amputé de tout bloc osmo-sync antérieur, sinon on en empile un
            # deuxième à chaque passage.
            awk '/^# ── osmo-sync ──/{exit} 1' "$PROFILE" > "$tmp"
        fi
        {
            echo ''
            echo '# ── osmo-sync ── (posé par update.sh)'
            echo '# clavier configuré ci-dessus → animation SMS → mise à jour des 3 dépôts,'
            echo '# logs sur CE terminal.'
            echo '[ -x /usr/local/sbin/osmo-sync.sh ] && /usr/local/sbin/osmo-sync.sh'
        } >> "$tmp"
        # cat plutôt que mv : sur l'ISO ce fichier peut être un point de montage,
        # et rename() y échoue.
        cat "$tmp" > "$PROFILE"; rm -f "$tmp"
        chmod +x "$PROFILE"
        echo "  ✓ ${PROFILE} — clavier → animation → dépôts"
    else
        echo "  ⚠ ${PROFILE} absent — synchro non accrochée à la session"
    fi
fi

[ "$ANIM" = "1" ] || sed -i 's|osmo-sync.sh$|osmo-sync.sh --quiet|' "$PROFILE" 2>/dev/null

if [ "$RUN_NOW" = "1" ]; then
    echo ""
    "$SYNC"
else
    echo ""
    echo "  La mise à jour se joue à l'ouverture de session."
    echo "  Tout de suite : sudo osmo-sync.sh"
fi
