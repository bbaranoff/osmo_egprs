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

# =============================================================================
#  [2026-08-27] PROPRIETAIRE UNIQUE : LE LANCEMENT DIRECT. PAS DE SERVICE.
# =============================================================================
#  Il y avait DEUX lanceurs. L'unite asterisk.service est `enabled` (vendor
#  preset) et demarre donc au boot ; a cote, ce module lance son propre
#  `asterisk -f -U asterisk`. Releve dans le journal du module sur la VM :
#      lancement direct : /usr/sbin/asterisk -f -U asterisk   (cinq fois)
#  et, au meme instant :
#      systemctl is-active asterisk  ->  inactive
#      asterisk -rx "core show uptime"  ->  repond
#  Les deux sondes designaient deux Asterisk differents. Tous se disputent
#  /var/run/asterisk/asterisk.ctl : celui qui s'installe en dernier prend la
#  socket, celui qui meurt l'emporte, et `asterisk -rx` finit par parler dans le
#  vide. La barriere expire alors sur
#      console Asterisk : toujours pas pret apres 45s
#  - un symptome qui accuse le temps de chargement des modules alors que la
#  faute est a la propriete du processus.
#
#  ON CHOISIT LE DIRECT. systemd est donc ARRETE ET DESACTIVE ici, a chaque
#  demarrage : le desactiver seulement dans l'image ne suffirait pas (une image
#  plus ancienne, un `systemctl enable` manuel, une mise a jour du paquet
#  asterisk qui re-active son unite, et le second proprietaire revient).
#
#  CE QUE LE DIRECT DOIT FAIRE A LA MAIN - et que systemd faisait pour lui :
#    - creer /var/run/asterisk. /var/run est un tmpfs : apres un boot ou
#      l'unite n'a jamais tourne, ce repertoire N'EXISTE PAS. Asterisk, qui
#      abandonne ses privileges vers l'utilisateur asterisk, ne peut alors ni
#      ecrire son PID ni ouvrir sa socket de controle : il tourne, mais aucune
#      console ne repondra jamais. C'est le mode d'echec que le passage au
#      direct a introduit sans le voir, parce qu'au debut l'unite tournait
#      encore au boot et creait le repertoire pour lui.
#    - effacer une socket de controle ORPHELINE. Un Asterisk tue -9 laisse
#      asterisk.ctl derriere lui ; `asterisk -rx` s'y connecte et echoue, sans
#      jamais dire que la socket ne mene plus nulle part.
# -----------------------------------------------------------------------------

# Ecarte systemd du chemin. Idempotent, et volontairement silencieux quand il
# n'y a rien a ecarter.
_ast_evict_systemd() {
    core_unit_exists "$ASTERISK_UNIT" || return 0
    if core_unit_active "$ASTERISK_UNIT"; then
        mod_say "systemd tenait Asterisk - on le lui retire (proprietaire : ce module)"
    fi
    systemctl disable --now "$ASTERISK_UNIT" >/dev/null 2>&1 || true
}

# Tue tout Asterisk qui n'est pas celui de notre pidfile.
_ast_kill_others() {
    local mine pid
    mine="$(cat "$(core_pidfile "$ASTERISK_UNIT")" 2>/dev/null || echo 0)"
    for pid in $(pgrep -x asterisk 2>/dev/null); do
        [ "$pid" = "$mine" ] && continue
        mod_say "Asterisk etranger (PID $pid) - on l'arrete"
        kill "$pid" 2>/dev/null
    done
    local i
    for i in 1 2 3 4 5; do
        [ -z "$(pgrep -x asterisk 2>/dev/null | grep -v "^${mine}$")" ] && break
        sleep 1
    done
    for pid in $(pgrep -x asterisk 2>/dev/null); do
        [ "$pid" = "$mine" ] && continue
        kill -9 "$pid" 2>/dev/null
    done
}

# Le repertoire d'execution et une socket de controle propre.
_ast_prepare_rundir() {
    local rundir="/var/run/asterisk"
    # L'utilisateur asterisk doit pouvoir y ecrire : le binaire est lance root
    # puis descend vers lui (-U), et c'est APRES la descente qu'il ouvre sa
    # socket. Un repertoire root-only donne un Asterisk vivant et muet.
    install -d -o asterisk -g asterisk -m 0755 "$rundir" 2>/dev/null \
        || mkdir -p "$rundir" 2>/dev/null || true
    # Socket orpheline : plus personne au bout, mais `asterisk -rx` s'y connecte
    # quand meme et echoue sans expliquer pourquoi.
    if [ -S "$rundir/asterisk.ctl" ] && ! pgrep -x asterisk >/dev/null 2>&1; then
        mod_say "socket de controle orpheline - on l'efface"
        rm -f "$rundir/asterisk.ctl"
    fi
}

mod_asterisk_check() {
    command -v asterisk >/dev/null 2>&1 || {
        mod_hint "installez asterisk, ou desactivez la voix : CORE_VOICE=0"
        mod_fail "binaire asterisk introuvable"; return $MOD_RC_FAIL; }
    [ -r "$ASTERISK_CFG" ] || {
        mod_fail "configuration illisible : $ASTERISK_CFG"; return $MOD_RC_FAIL; }
    mod_ok
}

mod_asterisk_status() { _ast_ready; }

mod_asterisk_start() {
    _ast_evict_systemd

    # Deja pret ET c'est bien le notre : on ne relance pas. Le test sur le
    # pidfile est ce qui distingue "notre Asterisk repond" de "UN Asterisk
    # repond" - c'est cette confusion qui laissait passer le double lanceur.
    local pf; pf="$(core_pidfile "$ASTERISK_UNIT")"
    if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && _ast_ready; then
        mod_say "deja actif (PID $(cat "$pf")) - on ne relance pas"; mod_ok; return 0
    fi

    _ast_kill_others
    _ast_prepare_rundir

    local bin log
    bin="$(command -v asterisk)"
    log="${LOG_DIR}/${ASTERISK_UNIT}.log"
    mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true

    # -f : reste au premier plan (pas de double fork), donc le PID qu'on note
    #      est bien celui d'Asterisk et on peut le suivre.
    # -U : abandonne les privileges vers l'utilisateur asterisk.
    # Ni -p (temps reel : refuse sans les capacites) ni -g (dump core).
    mod_say "lancement direct : $bin -f -U asterisk"
    setsid "$bin" -f -U asterisk >>"$log" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$pf"

    sleep 1
    if ! kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        mod_hint "tail -30 $log"
        mod_fail "asterisk est mort dans la seconde qui a suivi le lancement"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

# BARRIERE - Asterisk met plusieurs secondes a charger ses modules ; la socket
# de controle existe avant qu'il ne reponde. On interroge donc la CLI.
mod_asterisk_wait() {
    local pf; pf="$(core_pidfile "$ASTERISK_UNIT")"
    if ! wait_until "${MOD_TIMEOUT[asterisk]}" "console Asterisk" _ast_ready; then
        # Dire LEQUEL des deux echecs on a : un Asterisk mort et un Asterisk
        # vivant mais sans console ne se reparent pas de la meme facon.
        if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
            mod_hint "Asterisk (PID $(cat "$pf")) tourne mais n'ouvre pas sa console : verifiez /var/run/asterisk (proprietaire asterisk) et tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        else
            mod_hint "tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        fi
        return $MOD_RC_FAIL
    fi
    # NRestarts de systemd n'a plus de sens : personne ne relance Asterisk, donc
    # une mort est definitive et se voit au PID. Un Asterisk REMPLACE par un
    # autre serait invisible au seul test "la console repond".
    if [ -f "$pf" ] && ! kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        mod_hint "tail -50 ${LOG_DIR}/${ASTERISK_UNIT}.log"
        mod_fail "le PID lance n'existe plus : Asterisk est mort ou a ete remplace"
        return $MOD_RC_FAIL
    fi
    mod_ok
}

mod_asterisk_stop() {
    _ast_cli "core stop now" >/dev/null 2>&1
    core_svc_stop "$ASTERISK_UNIT" ""
}
