# =============================================================================
#  31-hlr-feed - l'abonne de test dans le HLR (IMSI + Ki comp128v1)
# =============================================================================
#
#  ROLE        Injecte, via le VTY du HLR, l'IMSI et la cle Ki lus dans la
#              configuration du mobile. Legacy : run.sh.legacy L1567-1586.
#
#  POURQUOI    Sans Ki dans le HLR, la MSC ne peut pas authentifier : pas de
#              triplet, donc pas de Kc, donc CIPHER MODE COMMAND rejete et
#              Location Update chiffre KO. En clair (a5/0, sans authentification)
#              le LU passe quand meme - c'est ce qui rendait la panne si
#              trompeuse : "ca marchait" jusqu'au jour ou le reseau exigeait
#              le chiffrement.
#
#  PREREQUIS   Coeur demarre (VTY HLR 4258 ouvert) et cfg mobile lisible.
#
#  SUCCES      `subscriber imsi <IMSI> show` repond avec la fiche de l'abonne.
#              C'est l'etat FINAL qu'on verifie, pas le fait d'avoir ecrit :
#              une commande VTY refusee renvoie "% ..." sans code d'erreur.
#
#  JOURNAL     $LOG_DIR/mod/hlr-feed.log (echanges VTY recopies par mod_say).
#
#  NON OBLIGATOIRE : un echec ici n'empeche pas de camper ni de faire un LU en
#  clair ; il ne casse que le chiffrement. On le signale, on ne bloque pas.
# -----------------------------------------------------------------------------

MOD_REGISTER hlr-feed "Abonne de test dans le HLR"
MOD_REQUIRED[hlr-feed]=0
MOD_DEPS[hlr-feed]="core $(modb_dep_known mobile-cfg)"
MOD_PROFILES[hlr-feed]="calypso hybrid core"
MOD_TIMEOUT[hlr-feed]=20

# DOUBLON DE ROLE - 21-abonnes-hlr provisionne les abonnes du HLR sur le meme
# VTY. Deux modules qui ecrivent la meme fiche, c'est un verdict de trop et une
# course a l'ecriture. On cede la place quand il est enregistre ; s'il disparait
# de l'arbre, ce module reprend son role sans modification. Meme porte que
# 30-core, meme raison.
MOD_ENABLED_IF[hlr-feed]='[ -z "${MOD_DESC[abonnes-hlr]+x}" ]'

: "${CALYPSO_HLR_VTY_IP:=127.0.0.1}"
: "${OSMO_VTY_HLR:=4258}"

# Resolus (lecture seule) par mod_hlr_feed_check.
_HLRF_CFG=""
_HLRF_IMSI=""
_HLRF_KI=""

# _hlrf_vty <commande...> - ouvre le VTY, envoie, rend la reponse sur stdout.
# bash /dev/tcp plutot que telnet/nc : aucune dependance a installer, et c'est
# deja l'idiome du legacy (L1579). `enable` d'abord : `subscriber ... create`
# est une commande privilegiee.
_hlrf_vty() {
    local out=""
    exec 9<>"/dev/tcp/${CALYPSO_HLR_VTY_IP}/${OSMO_VTY_HLR}" 2>/dev/null || return 1
    { printf 'enable\n'; printf '%s\n' "$@"; } >&9
    out="$(timeout 3 cat <&9 2>/dev/null)"
    exec 9>&- 2>/dev/null
    exec 9<&- 2>/dev/null
    printf '%s\n' "$out"
}

# L'abonne est-il DANS la base ? osmo-hlr repond "% No subscriber ..." quand
# il ne l'est pas ; on exige en plus de retrouver l'IMSI dans la fiche, pour ne
# pas prendre un message d'erreur inattendu pour un succes.
_hlrf_present() {
    [ -n "$_HLRF_IMSI" ] || return 1
    local out; out="$(_hlrf_vty "subscriber imsi $_HLRF_IMSI show")" || return 1
    case "$out" in *"No subscriber"*|*"% "*) return 1;; esac
    printf '%s' "$out" | grep -q "$_HLRF_IMSI"
}

mod_hlr_feed_check() {
    # Ou est la cfg mobile : celle deployee par le module mobile-cfg, sinon la
    # version du depot. Lecture seule dans les deux cas.
    local c
    for c in "${MOBILE_CFG:-}" \
             "${OSMOCOM_HOME:-$HOME/.osmocom}/bb/mobile_group1.cfg" \
             "${QEMU_CFGS:-${QEMU_TREE:-${OQC_ROOT}}/cfgs}/mobile_group1.cfg"; do
        [ -n "$c" ] && [ -r "$c" ] && { _HLRF_CFG="$c"; break; }
    done
    [ -n "$_HLRF_CFG" ] || {
        mod_hint "deployez la cfg mobile (module mobile-cfg) ou posez MOBILE_CFG=<chemin>"
        mod_fail "configuration du mobile introuvable : impossible d'en tirer IMSI/Ki"
        return $MOD_RC_FAIL
    }

    # Format attendu (cfgs/mobile_group1.cfg L84-85) :
    #    imsi 001010001000001
    #    ki comp128 00 11 22 ...
    _HLRF_IMSI="$(awk '$1=="imsi"{print $2; exit}' "$_HLRF_CFG" 2>/dev/null)"
    _HLRF_KI="$(awk '$1=="ki" && $2=="comp128"{s=""; for(i=3;i<=NF;i++) s=s $i; print s; exit}' "$_HLRF_CFG" 2>/dev/null)"

    [ -n "$_HLRF_IMSI" ] || {
        mod_hint "ajoutez une ligne "imsi <15 chiffres>" dans $_HLRF_CFG"
        mod_fail "aucun IMSI dans $_HLRF_CFG"
        return $MOD_RC_FAIL
    }
    [ -n "$_HLRF_KI" ] || {
        mod_hint "ajoutez "ki comp128 <16 octets hex>" dans $_HLRF_CFG - sans Ki, pas de Kc, CIPHER MODE rejete"
        mod_fail "aucune cle Ki comp128 dans $_HLRF_CFG"
        return $MOD_RC_FAIL
    }
    mod_say "cfg=$_HLRF_CFG imsi=$_HLRF_IMSI ki=${#_HLRF_KI} caracteres hex"
    mod_ok
}

mod_hlr_feed_status() { _hlrf_present; }

mod_hlr_feed_start() {
    # Le legacy attendait ici le VTY 90 × 2 s en tache de fond (L1578) : le HLR
    # pouvait ne pas etre pret. Ce sleep n'a plus lieu d'etre - la barriere du
    # module `core` garantit deja que 4258 ecoute, sinon ce module est saute.
    local msisdn="${_HLRF_IMSI: -5}" out
    out="$(_hlrf_vty \
        "subscriber imsi $_HLRF_IMSI create" \
        "subscriber imsi $_HLRF_IMSI update msisdn $msisdn" \
        "subscriber imsi $_HLRF_IMSI update aud2g comp128v1 ki $_HLRF_KI")" || {
        mod_hint "verifiez que osmo-hlr ecoute : ./run.sh --status"
        mod_fail "VTY HLR ${CALYPSO_HLR_VTY_IP}:${OSMO_VTY_HLR} injoignable"
        return $MOD_RC_FAIL
    }
    mod_say "$out"
    mod_ok
}

# BARRIERE - on relit la base : "la commande est partie" ne prouve rien, le
# VTY accepte la connexion puis refuse la commande sans code d'erreur.
mod_hlr_feed_wait() {
    wait_until "${MOD_TIMEOUT[hlr-feed]}" "abonne $_HLRF_IMSI dans le HLR" _hlrf_present && { mod_ok; return $MOD_RC_OK; }
    mod_hint "a la main : telnet ${CALYPSO_HLR_VTY_IP} ${OSMO_VTY_HLR} puis "subscriber imsi $_HLRF_IMSI show""
    mod_fail "l'abonne $_HLRF_IMSI n'apparait pas dans le HLR apres injection"
    return $MOD_RC_FAIL
}

# Volontairement SANS effet : arreter la pile ne doit pas detruire la base des
# abonnes. Supprimer l'abonne rendrait le run suivant dependant de ce module,
# alors qu'il est optionnel.
mod_hlr_feed_stop() { return 0; }
