#!/bin/bash
# update.sh — mise à jour À CHAUD du lab osmo_egprs au boot.
#
# Tiré et exécuté par /usr/local/sbin/osmo-update.sh (service osmo-update, au boot)
# depuis https://raw.githubusercontent.com/bbaranoff/osmo_egprs/refs/heads/main/update.sh
#
# Rôle : récupérer la dernière version des dépôts (osmo_egprs + osmo-egprs-web) dans
# le live, fixer les droits, (ré)installer les deps node si besoin, redémarrer le
# dashboard. Idempotent ; ne casse jamais le boot (tout en || true).
set -u

OSMO_DIR=/opt/GSM/osmo_egprs
WEB_DIR=/opt/osmo-egprs-web
OSMO_URL=https://github.com/bbaranoff/osmo_egprs
WEB_URL=https://github.com/bbaranoff/osmo-egprs-web

log(){ echo "[update.sh $(date '+%F %T')] $*"; }

# Met à jour un dépôt en place : git fetch+reset si déjà un clone, sinon clone frais.
update_repo(){   # <url> <dir>
    local url="$1" dir="$2" br
    if [ -d "$dir/.git" ]; then
        log "maj git $dir"
        git -C "$dir" remote set-url origin "$url" 2>/dev/null || true
        git -C "$dir" fetch --depth 1 origin 2>&1 | tail -1 || { log "fetch KO $dir"; return 1; }
        br="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        { [ -z "$br" ] || [ "$br" = "HEAD" ]; } && br=main
        git -C "$dir" reset --hard "origin/$br" 2>&1 | tail -1 || true
    else
        log "clone $url -> $dir"
        rm -rf "${dir}.new"
        git clone --depth 1 "$url" "${dir}.new" 2>&1 | tail -1 || { log "clone KO $url"; rm -rf "${dir}.new"; return 1; }
        rm -rf "$dir"; mv "${dir}.new" "$dir"
    fi
}

log "=== update démarré ==="
command -v git >/dev/null 2>&1 || { log "git absent — abandon"; exit 0; }

update_repo "$OSMO_URL" "$OSMO_DIR" || true
update_repo "$WEB_URL"  "$WEB_DIR"  || true

# Layout dashboard : si le dépôt range les sources sous server/ , on remonte server.js
# à la racine (le service attend /opt/osmo-egprs-web/server.js).
[ -f "$WEB_DIR/server/server.js" ] && [ ! -f "$WEB_DIR/server.js" ] && cp "$WEB_DIR/server/server.js" "$WEB_DIR/server.js"

# Droits d'exécution
chmod +x "$OSMO_DIR"/*.sh "$OSMO_DIR"/scripts/*.sh "$OSMO_DIR"/helpers/*.sh \
         "$OSMO_DIR"/fft-web/*.py 2>/dev/null || true

# Deps node du dashboard si absentes (node_modules est gitignoré)
if [ -f "$WEB_DIR/package.json" ] && [ ! -d "$WEB_DIR/node_modules" ] && command -v npm >/dev/null 2>&1; then
    log "npm install (dashboard)"; ( cd "$WEB_DIR" && npm install --omit=dev 2>&1 | tail -2 ) || true
fi

# Redémarre le dashboard web (service activé au boot)
if systemctl list-unit-files 2>/dev/null | grep -q '^osmo-egprs-web'; then
    log "restart osmo-egprs-web"
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart osmo-egprs-web 2>/dev/null || true
fi

log "=== update terminé ==="
