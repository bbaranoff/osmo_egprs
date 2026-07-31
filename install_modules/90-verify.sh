# 90-verify — contrôle d'ensemble. Distinct des `verify` de chaque étape :
# ici on regarde si la machine est utilisable, pas si une étape a réussi.
INST_REGISTER verify "Vérification de l'installation"
INST_DEPS[verify]="binaires configs"
INST_ROOT[verify]=0

inst_verify_run() {
    local missing="" b
    for b in osmo-stp osmo-hlr osmo-msc osmo-mgw osmo-bsc; do have_cmd "$b" || missing="$missing $b"; done
    if [ -n "$missing" ]; then
        inst_hint "les démons Osmocom ne sont pas dans les dépôts Ubuntu par défaut : ajoutez le dépôt Osmocom, ou utilisez Docker (./make-docker-image.sh)"
        inst_fail "démons absents :$missing"
        return $INST_RC_FAIL
    fi
    inst_ok
}
inst_verify_verify() { inst_ok; }
