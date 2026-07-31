# 10-deps — paquets système.
# La liste fait autorité dans le Dockerfile : on l'en EXTRAIT au lieu de la
# recopier, pour que les deux ne divergent jamais.
INST_REGISTER deps "Dépendances système (apt)"
INST_DEPS[deps]="prereqs"

_deps_list() {
    awk '/^RUN apt-get update && apt-get install/,/[^\\]$/' "$INST_TREE/Dockerfile" 2>/dev/null \
      | sed -e 's/^RUN apt-get update && apt-get install -y --no-install-recommends//' \
            -e 's/\\$//' -e 's/#.*//' | tr -s ' \n' ' '
}

inst_deps_check() {
    have_file "$INST_TREE/Dockerfile" || { inst_fail "Dockerfile introuvable — c'est lui qui porte la liste des paquets"; return $INST_RC_FAIL; }
    inst_ok
}
inst_deps_done() {
    local p; for p in build-essential libtalloc-dev libsctp-dev; do have_pkg "$p" || return 1; done
    return 0
}
inst_deps_run() {
    local pkgs; pkgs="$(_deps_list)"
    [ -z "${pkgs// }" ] && { inst_fail "liste de paquets vide — le format du Dockerfile a changé"; return $INST_RC_FAIL; }
    inst_say "paquets : $(echo $pkgs | wc -w)"
    apt-get update -qq && apt-get install -y --no-install-recommends $pkgs
}
inst_deps_verify() {
    local missing="" p
    for p in build-essential libtalloc-dev libsctp-dev libdbi-dev; do have_pkg "$p" || missing="$missing $p"; done
    [ -n "$missing" ] && { inst_fail "paquets absents après installation :$missing"; return $INST_RC_FAIL; }
    inst_ok
}
