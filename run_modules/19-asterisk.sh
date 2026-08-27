# =============================================================================
#  19-asterisk - le PBX SIP qui porte les appels
# =============================================================================
#  ROLE      terminaison des appels : osmo-sip-connector traduit le MNCC du MSC
#            en SIP et le pousse vers Asterisk. Sans PBX, un appel MS→MS n'est
#            jamais raccorde. Optionnel : ni le rattachement ni le SMS n'en
#            dependent.
#  PREREQUIS binaire asterisk ; /etc/asterisk/asterisk.conf.
#  SUCCES    la console de controle REPOND ("core show uptime") - c'est le
#            seul critere qui prouve qu'Asterisk a fini de charger ses modules,
#            la ou "actif" ne prouve que le fork. Plus : aucun redemarrage.
#  JOURNAL   journalctl -u asterisk ; /var/log/asterisk/
#
#  NOTE l'ancien lancement supprimait /var/lib/asterisk/astdb.sqlite3 a chaque
#  demarrage (scripts/run.sh:455). Ce module ne le fait PAS : detruire une base
#  n'est pas une etape de demarrage.
# -----------------------------------------------------------------------------
: "${MODDIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$MODDIR/_lib/core.sh"

MOD_REGISTER asterisk "Coeur - Asterisk (PBX SIP)"
MOD_REQUIRED[asterisk]=0
MOD_PROFILES[asterisk]="calypso faketrx hybrid core"
MOD_JOURNAL[asterisk]="asterisk"
MOD_TIMEOUT[asterisk]=45
MOD_ENABLED_IF[asterisk]='[ "${NO_OSMO_START:-0}" != 1 ] && [ "${CORE_VOICE:-1}" = 1 ]'

: "${ASTERISK_UNIT:=asterisk}"
: "${ASTERISK_CFG:=/etc/asterisk/asterisk.conf}"

_ast_cli() { asterisk -rx "$1" 2>/dev/null; }
_ast_ready() { _ast_cli "core show uptime" | grep -qi 'uptime'; }
# NB : wait_until execute "$@" - il lui faut un NOM de commande, pas une
# condition composee ecrite en chaine (elle serait cherchee comme un binaire et
# echouerait a chaque tour, jusqu'au timeout). D'ou cette fonction.
_ast_up() { core_unit_active "$ASTERISK_UNIT" && _ast_ready; }

mod_asterisk_check() {
    command -v asterisk >/dev/null 2>&1 || {
        mod_hint "installez asterisk, ou desactivez la voix : CORE_VOICE=0"
        mod_fail "binaire asterisk introuvable"; return $MOD_RC_FAIL; }
    [ -r "$ASTERISK_CFG" ] || {
        mod_fail "configuration illisible : $ASTERISK_CFG"; return $MOD_RC_FAIL; }
    # [2026-08-27] L'unite est OBLIGATOIRE - voir le bloc PROPRIETAIRE UNIQUE
    # dans mod_asterisk_start. Sans elle, core_svc_start retomberait tout seul
    # sur un lancement direct : exactement le second proprietaire qu'on refuse.
    core_unit_exists "$ASTERISK_UNIT" || {
        mod_hint "unite absente : installez le paquet asterisk, ou CORE_VOICE=0"
        mod_fail "unite systemd introuvable : $ASTERISK_UNIT"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_asterisk_status() { _ast_up; }

# Tue les Asterisk qui ne sont PAS sous systemd (cgroup hors asterisk.service).
# Un rescape du lancement direct garde /var/run/asterisk/asterisk.ctl : l'unite
# ne peut plus s'installer, et `asterisk -rx` parle a la mauvaise instance.
_ast_kill_strays() {
    local pid cg i
    for pid in $(pgrep -x asterisk 2>/dev/null); do
        cg="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
        case "$cg" in *asterisk.service*) continue ;; esac
        mod_say "Asterisk hors systemd (PID $pid) - on l'arrete"
        kill "$pid" 2>/dev/null
    done
    for i in 1 2 3 4 5; do
        pgrep -x asterisk >/dev/null 2>&1 || return 0
        sleep 1
    done
    for pid in $(pgrep -x asterisk 2>/dev/null); do
        cg="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
        case "$cg" in *asterisk.service*) continue ;; esac
        kill -9 "$pid" 2>/dev/null
    done
}

mod_asterisk_start() {
    # [2026-08-27] PROPRIETAIRE UNIQUE : systemd. ON NE LANCE PLUS RIEN SOI-MEME.
    #
    # CE QUI SE PASSAIT. Deux lanceurs coexistaient. L'unite asterisk.service est
    # `enabled` (vendor preset) et demarre donc au boot ; a cote, le module
    # lancait sa propre instance des que l'unite paraissait absente - et une
    # variante de ce module lancait meme systematiquement `asterisk -f -U
    # asterisk` en direct. Releve sur la VM :
    #     13:02:45  systemd  Started Asterisk PBX       -> PID 580
    #     13:04:03  systemd  Deactivated successfully   <- notre teardown
    #     13:11:34  (hors systemd) second Asterisk      -> PID 7422
    # Deux proprietaires pour un seul /etc/asterisk et une seule socket de
    # controle /var/run/asterisk/asterisk.ctl. Celui qui meurt en dernier emporte
    # la socket : `asterisk -rx` parle alors dans le vide et la barriere expire
    #     console Asterisk : toujours pas pret apres 45s
    # - un symptome qui accuse le temps de chargement des modules alors que la
    # faute est a la propriete du processus.
    #
    # POURQUOI systemd PLUTOT QUE LE DIRECT. L'unite est Type=notify : elle sait
    # dire quand Asterisk a FINI de charger, ce que la barriere ne fait que
    # deviner. Elle cree le rundir, descend les privileges vers l'utilisateur
    # asterisk et porte la politique de redemarrage. Le lancement direct devait
    # tout ca a la main - pendant que l'unite continuait de tourner derriere lui.
    if _ast_up; then
        mod_say "deja actif sous systemd - on ne relance pas"; mod_ok; return 0
    fi

    # Une unite MASQUEE n'est pas "absente" : `systemctl start` echoue dessus.
    # Puisque systemd est le seul proprietaire, on leve le masque au lieu de
    # retomber sur un second lanceur.
    if [ "$(systemctl is-enabled "$ASTERISK_UNIT" 2>/dev/null)" = masked ]; then
        mod_say "unite masquee - demasquage (systemd est le seul proprietaire)"
        systemctl unmask "$ASTERISK_UNIT" >/dev/null 2>&1 || {
            mod_hint "systemctl unmask $ASTERISK_UNIT"
            mod_fail "unite masquee et demasquage refuse"; return $MOD_RC_FAIL; }
    fi

    _ast_kill_strays

    # NB : core_svc_start memorise NRestarts avant le start - c'est la reference
    # dont la barriere se sert plus bas. Les arguments du binaire ne servent
    # qu'au repli direct, que mod_asterisk_check vient d'interdire ; l'unite
    # impose les siens (-g -f -p -U asterisk).
    core_svc_start "$ASTERISK_UNIT" "$(command -v asterisk)" -g -f -p -U asterisk \
        || { mod_fail "systemctl start $ASTERISK_UNIT a echoue"
             mod_hint "journalctl -u $ASTERISK_UNIT -n 30"; return $MOD_RC_FAIL; }
    mod_ok
}

# BARRIERE - Asterisk met plusieurs secondes a charger ses modules ; la socket
# de controle existe avant qu'il ne reponde. On interroge donc la CLI.
mod_asterisk_wait() {
    # Deux conditions, pas une. "unite active" seul ne prouve que le fork ; la
    # console seule ne dit pas QUI repond - c'est precisement ce qui laissait le
    # double lanceur passer inapercu tant qu'une des deux instances repondait.
    if ! wait_until "${MOD_TIMEOUT[asterisk]}" "console Asterisk" _ast_up; then
        mod_hint "systemctl status $ASTERISK_UNIT ; journalctl -u $ASTERISK_UNIT -n 40"
        return $MOD_RC_FAIL
    fi
    if core_restarted_since "$ASTERISK_UNIT"; then
        mod_hint "journalctl -u $ASTERISK_UNIT -n 50 : module ou conf en faute"
        mod_fail "Asterisk a redemarre depuis le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_asterisk_stop() {
    # `core stop now` d'abord : Asterisk raccroche proprement les appels en
    # cours. systemd fait le reste - et il est le seul a avoir quelque chose a
    # arreter, puisque plus personne ne lance d'instance a cote.
    _ast_cli "core stop now" >/dev/null 2>&1
    core_svc_stop "$ASTERISK_UNIT" ""
}
