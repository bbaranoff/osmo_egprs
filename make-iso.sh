#!/bin/bash
# make-iso.sh — Génère une ISO bootable en utilisant make-docker-image.sh et lancement/start.sh
# Aucun docker build direct dans ce script, tout passe par les scripts existants.
set -euo pipefail

VERSION="${OSMO_ISO_VERSION:-v2}"
OUTPUT="osmo-nitb-for-calypso-${VERSION}.iso"
# Répertoire de travail SUR DISQUE (pas /tmp, souvent un tmpfs en RAM -> "No
# space left on device" car le rootfs est volumineux). Overridable via OSMO_ISO_WORK.
WORK="${OSMO_ISO_WORK:-/var/tmp}/iso-build-$$"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
LABEL="OSMO_EGPRS_V2"
DIR="$(cd "$(dirname "$0")" && pwd)"

NO_CACHE=""
for arg in "$@"; do case "$arg" in
    --output=*)  OUTPUT="${arg#*=}" ;;
    --no-cache)  NO_CACHE="--no-cache" ;;
esac; done
case "$OUTPUT" in /*) ;; *) OUTPUT="$(pwd)/$OUTPUT" ;; esac

# Propage --no-cache aux deux builds Docker : make-docker-image.sh (image osmocom-nitb) et
# build_run_image (image osmocom-run, via DOCKER_NO_CACHE).
export DOCKER_NO_CACHE="$NO_CACHE"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

cleanup() { umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true; rm -rf "$WORK"; }
trap cleanup EXIT

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Root requis.${NC}"; exit 1; }

# ── Paquets hôte requis pour fabriquer l'ISO (squashfs, grub, xorriso...) ──
# Installés ici plutôt que dans le workflow CI : `sudo ./make-iso.sh` suffit
# sur une machine Debian/Ubuntu vierge, sans étape "Install host tools" externe.
ISO_HOST_PKGS="squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools debootstrap git isolinux"
if command -v apt-get &>/dev/null; then
    echo -e "${GREEN}[0/7] Installation des paquets hôte (apt)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    # isolinux est optionnel (isohybrid) : on n'échoue pas s'il manque.
    apt-get install -y --no-install-recommends $ISO_HOST_PKGS \
        || apt-get install -y --no-install-recommends \
           squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools debootstrap git
else
    echo -e "${YELLOW}apt-get absent : vérification seule des outils hôte.${NC}"
fi

# Docker n'est pas auto-installé ici (paquet docker-ce hors apt standard).
for t in docker mksquashfs xorriso grub-mkrescue debootstrap git; do
    command -v "$t" &>/dev/null || { echo -e "${RED}Manquant: $t${NC}"; exit 1; }
done
mkdir -p "$WORK" "$ROOTFS" "$ISOROOT"

echo -e "${CYAN}${BOLD}══ osmo-nitb-for-calypso ISO builder (via make-docker-image.sh + lancement/start.sh) ══${NC}"

# ── Étape 1 : Exécuter make-docker-image.sh pour préparer l'hôte et construire osmocom-nitb ──
echo -e "${GREEN}[1/7] Exécution de make-docker-image.sh...${NC}"
if [ -f "$DIR/make-docker-image.sh" ]; then
    bash "$DIR/make-docker-image.sh" $NO_CACHE
else
    echo -e "${YELLOW}make-docker-image.sh introuvable, construction manuelle de l'image osmocom-nitb...${NC}"
    docker build $NO_CACHE -t osmocom-nitb "$DIR"
fi
echo -e "  ${GREEN}✓${NC} image osmocom-nitb prête"

load_start_lib() {
    local src="$DIR/start.sh"
    local lib="$WORK/start.lib.sh"

    awk '
        BEGIN { skip=0 }
        /^banner[[:space:]]*$/                    { exit }
        /^\[ "\$\{1:-\}" = "stop" \]/             { exit }
        /^\[ "\$\(id -u\)" -ne 0 \]/              { exit }
        /^choose_network_mode[[:space:]]*$/       { exit }
        /^\.\//                                   { exit }
        /^case "\$NETWORK_MODE" in[[:space:]]*$/  { exit }
        { print }
    ' "$src" > "$lib"

    # shellcheck disable=SC1090
    source "$lib"
}

# ── Étape 2 : Construire l'image osmocom-run via lancement/start.sh ─────────────────────
echo -e "${GREEN}[2/7] Construction de l'image osmocom-run via start.sh...${NC}"
load_start_lib
build_run_image
echo -e "  ${GREEN}✓${NC} osmocom-run construite"

echo -e "${GREEN}[2b/7] Préparation d'une image osmocom-run (net-host)...${NC}"

ISO_N_MS=8
ENCRYPTION="a5 1"   # A5/1 par defaut dans l'ISO (chiffrement bout-en-bout valide)

HOST_IP="172.20.0.11"      # ip1 : conteneur operateur (backbone docker 172.20.0.0/24)
GATEWAY_IP="172.20.0.1"    # gw  : passerelle du reseau docker

ALSA_OUTPUT="${ALSA_OUTPUT:-default}"
ALSA_INPUT="${ALSA_INPUT:-default}"
PHY_MODE="${PHY_MODE:-faketrx}"
INTER_STP_IP="172.20.1.10" # ip2 : reseau prive operateur (172.20.1.0/24)

echo -e "  Host IP    : ${CYAN}${HOST_IP}${NC}"
echo -e "  Gateway    : ${CYAN}${GATEWAY_IP}${NC}"
echo -e "  Inter-STP  : ${CYAN}${INTER_STP_IP}${NC}"
echo -e "  MS         : ${CYAN}${ISO_N_MS}${NC}"
echo -e "  Encryption : ${CYAN}${ENCRYPTION}${NC}"
echo -e "  PHY        : ${CYAN}${PHY_MODE}${NC}"

TEMP_CONFIG="$(mktemp -d)"
SMS_ROUTING_DIR="$(mktemp -d)"

if declare -f sms_routing_generate >/dev/null 2>&1; then
    sms_routing_generate 1 1 "$SMS_ROUTING_DIR" "$ISO_N_MS" || true
fi

apply_config_templates "$TEMP_CONFIG" \
    "$HOST_IP" "$GATEWAY_IP" \
    "1" "1.1.1" "1.1.2" "1.1.3" \
    "001" "01" "OsmoGSM" \
    "$INTER_STP_IP" "shutdown" "1"

ISO_RUN_IMAGE="osmocom-run-iso-net-host"
TMP_CID="$(docker create osmocom-run /bin/sh)"

docker cp "$TEMP_CONFIG/osmocom/."  "$TMP_CID:/etc/osmocom/"  2>/dev/null || true
docker cp "$TEMP_CONFIG/asterisk/." "$TMP_CID:/etc/asterisk/" 2>/dev/null || true

docker commit "$TMP_CID" "$ISO_RUN_IMAGE" >/dev/null
docker rm -f "$TMP_CID" >/dev/null 2>&1 || true
rm -rf "$TEMP_CONFIG" "$SMS_ROUTING_DIR"

echo -e "  ${GREEN}✓${NC} image ${CYAN}${ISO_RUN_IMAGE}${NC} prête"

# ── Étape 3 : (SUPPRIMÉ) — ISO NATIF : on n'embarque PAS l'image Docker ────
# L'image osmocom-run ne sert plus que de SOURCE de build (docker cp des binaires
# et configs vers le rootfs à l'étape 6). On ne la save plus dans l'ISO : pas de
# docker au runtime, pas de tar.gz de plusieurs Go embarqué.

# ── Étape 4 : Bootstrap rootfs minimal ─────────────────────────────────────
echo -e "${GREEN}[4/7] debootstrap jammy (minimal)...${NC}"
debootstrap --variant=minbase --include=\
systemd,systemd-sysv,dbus,kmod,\
ca-certificates,curl,gnupg,\
iproute2,iputils-ping,procps,less,nano \
    jammy "$ROOTFS" http://archive.ubuntu.com/ubuntu
echo -e "  ${GREEN}✓${NC} rootfs base $(du -sh "$ROOTFS"|cut -f1)"

# ── Étape 5 : Injection des binaires et libs depuis l'image osmocom-run ───
echo -e "${GREEN}[5/7] Injection stack Osmocom...${NC}"
CID=$(docker create "$ISO_RUN_IMAGE" /bin/true)
docker cp "$CID:/usr/local/bin/." "$ROOTFS/usr/local/bin/"  2>/dev/null||true
docker cp "$CID:/usr/local/lib/." "$ROOTFS/usr/local/lib/"  2>/dev/null||true
docker cp "$CID:/usr/local/include/." "$ROOTFS/usr/local/include/" 2>/dev/null||true
docker cp "$CID:/opt/GSM"             "$ROOTFS/opt/GSM"     2>/dev/null||true
# venv python (gr-gsm + bridges) attendu par ${OQC_ROOT}/start-clean.sh
docker cp "$CID:/root/.env"           "$ROOTFS/root/"       2>/dev/null||true
docker cp "$CID:/etc/osmocom/."       "$ROOTFS/etc/osmocom/" 2>/dev/null||true
docker cp "$CID:/etc/asterisk/."      "$ROOTFS/etc/asterisk/" 2>/dev/null||true
for svc in osmo-bts-trx osmo-bsc osmo-msc osmo-hlr osmo-mgw osmo-stp osmo-ggsn osmo-sgsn osmo-pcu osmo-sip-connector; do
    docker cp "$CID:/lib/systemd/system/${svc}.service" "$ROOTFS/lib/systemd/system/" 2>/dev/null||true
done
docker rm "$CID" &>/dev/null
echo -e "  ${GREEN}✓${NC} binaires + libs + configs injectés"

# ── osmo-nitb-for-calypso : SOURCE à jour depuis GitHub (branche test) ──
# La copie docker cp ci-dessus peut être périmée ; on récupère la branche test
# du repo (start-direct.sh, run.sh, scripts/, configs/, make-iso.sh…) dans l'ISO.
EGPRS_BRANCH="${OSMO_EGPRS_BRANCH:-test}"
echo -e "${GREEN}[5d/7] git clone osmo-nitb-for-calypso (branche ${EGPRS_BRANCH})...${NC}"
if git clone --depth 1 -b "$EGPRS_BRANCH" https://github.com/bbaranoff/osmo-nitb-for-calypso /tmp/osmo-nitb-for-calypso.clone 2>&1 | tail -2; then
    rm -rf "$ROOTFS${NITB_TREE}"
    mv /tmp/osmo-nitb-for-calypso.clone "$ROOTFS${NITB_TREE}"
    echo -e "  ${GREEN}✓${NC} osmo-nitb-for-calypso cloné depuis GitHub (${EGPRS_BRANCH})"
else
    rm -rf /tmp/osmo-nitb-for-calypso.clone
    echo -e "  ${YELLOW}⚠ git clone osmo-nitb-for-calypso échoué (réseau ?) — copie de l'image conservée${NC}"
fi

# ── osmo-qemu-calypso : checkout LOCAL (branche test, build/qemu-system-arm recompilé) ──
# La copie docker cp ($CID:/opt/GSM) peut être périmée / sur une autre branche. On
# écrase osmo-qemu-calypso par le checkout local de la VM, déjà sur 'test' avec le binaire
# build/ à jour. On retire .git (historique QEMU = lourd, inutile à l'exécution).
QEMU_SRC_LOCAL="${OSMO_QEMU_SRC:-${OQC_ROOT}}"
echo -e "${GREEN}[5d/7] osmo-qemu-calypso depuis checkout local (${QEMU_SRC_LOCAL})...${NC}"
if [ -x "$QEMU_SRC_LOCAL/build/qemu-system-arm" ]; then
    qbr="$(git -C "$QEMU_SRC_LOCAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    rm -rf "$ROOTFS${OQC_ROOT}"
    cp -a "$QEMU_SRC_LOCAL" "$ROOTFS${OQC_ROOT}"
    rm -rf "$ROOTFS${OQC_ROOT}/.git"
    echo -e "  ${GREEN}✓${NC} osmo-qemu-calypso copié (branche ${qbr}, build/ inclus, .git retiré)"
else
    echo -e "  ${YELLOW}⚠ ${QEMU_SRC_LOCAL}/build/qemu-system-arm absent — copie de l'image conservée${NC}"
fi
echo -e "${GREEN}[5c/7] Ajustements osmocom dans le rootfs...${NC}"
echo -e "${GREEN}[5b/7] Patch configs ISO...${NC}"

echo -e "${GREEN}[5b/7] Patch configs ISO...${NC}"

if [ -f "$ROOTFS/etc/osmocom/osmo-sgsn.cfg" ]; then
    sed -i \
        -e 's/^\([[:space:]]*gtp[[:space:]]\+local-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e 's/^\([[:space:]]*gsup[[:space:]]\+remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        -e '/^[[:space:]]*bind udp local$/,/^[[:space:]]*!$/ s/^\([[:space:]]*listen[[:space:]]\+\).*/\1127.0.0.2 23000/' \
        "$ROOTFS/etc/osmocom/osmo-sgsn.cfg"
fi

if [ -f "$ROOTFS/etc/osmocom/osmo-msc.cfg" ]; then
    sed -i \
        -e '/^hlr$/,/^!$/ s/^\([[:space:]]*remote-ip[[:space:]]\+\).*/\1127.0.0.2/' \
        "$ROOTFS/etc/osmocom/osmo-msc.cfg"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + MSC appliqué"

# run.sh: réduire toute ligne "trxcon options..." à "trxcon"
#         et toute ligne "mobile options..." à "mobile"
if [ -f "$ROOTFS/etc/osmocom/run.sh" ]; then
    sed -i \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?trxcon\([[:space:]].*\)\?$#trxcon#' \
        -e 's#^[[:space:]]*\([^[:space:]]*/\)\?mobile\([[:space:]].*\)\?$#mobile#' \
        "$ROOTFS/etc/osmocom/run.sh"
    chmod +x "$ROOTFS/etc/osmocom/run.sh"
fi

echo -e "  ${GREEN}✓${NC} patch SGSN + run.sh appliqué"
mkdir -p "$ROOTFS/usr/bin"
cp -a "$ROOTFS/usr/local/bin/." "$ROOTFS/usr/bin/" 2>/dev/null || true

mkdir -p "$ROOTFS/root/.osmocom/bb"
if [ -f "$ROOTFS/opt/osmo-nitb-for-calypso/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo-nitb-for-calypso/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/opt/osmo-nitb-for-calypso/configs/mobile.cfg" ]; then
    cp "$ROOTFS/opt/osmo-nitb-for-calypso/configs/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
elif [ -f "$ROOTFS/etc/osmocom/mobile.cfg" ]; then
    cp "$ROOTFS/etc/osmocom/mobile.cfg" "$ROOTFS/root/.osmocom/bb/mobile.cfg"
fi

if ! chroot "$ROOTFS" getent passwd osmocom >/dev/null 2>&1; then
    chroot "$ROOTFS" useradd -m -s /bin/bash osmocom 2>/dev/null || true
fi

chroot "$ROOTFS" usermod -o -u 0 -g 0 osmocom 2>/dev/null || true

mkdir -p "$ROOTFS/home/osmocom"
chown -R 0:0 "$ROOTFS/home/osmocom" "$ROOTFS/root/.osmocom" 2>/dev/null || true

echo -e "  ${GREEN}✓${NC} user osmocom + /usr/bin + mobile.cfg prêts"

chmod +x "$ROOTFS/etc/osmocom/run.sh"

# ── Étape 6 : Injection du dashboard web ───────────────────────────────────
echo -e "${GREEN}[6/7] Dashboard web (git clone)...${NC}"
WEB="$ROOTFS/opt/osmo-egprs-web"
WEB_REPO="${OSMO_WEB_REPO:-https://github.com/bbaranoff/osmo-egprs-web.git}"
WEB_BRANCH="${OSMO_WEB_BRANCH:-test}"

mkdir -p "$WEB/web"
# Source AUTORITAIRE = le VRAI git bbaranoff/osmo-egprs-web (clone ci-dessous).
# La copie locale /opt/osmo-egprs-web n'est plus utilisee que comme override
# EXPLICITE : OSMO_WEB_LOCAL=/chemin ./make-iso.sh. Sinon -> git.
# Le patch natif plus bas est idempotent (skip si server.js est deja en mode natif).
LOCAL_WEB="${OSMO_WEB_LOCAL:-}"
if [ -n "$LOCAL_WEB" ] && [ -f "$LOCAL_WEB/server.js" ]; then
    cp "$LOCAL_WEB/server.js" "$WEB/server.js"
    [ -f "$LOCAL_WEB/package.json" ] && cp "$LOCAL_WEB/package.json" "$WEB/package.json"
    [ -d "$LOCAL_WEB/web" ]          && cp -r "$LOCAL_WEB/web/."     "$WEB/web/"
    [ -f "$LOCAL_WEB/start-web.sh" ] && cp "$LOCAL_WEB/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$LOCAL_WEB/Dockerfile" ]   && cp "$LOCAL_WEB/Dockerfile"   "$WEB/Dockerfile"
    echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis source LOCALE ($LOCAL_WEB)"
else
    WEB_TMP="$WORK/osmo-egprs-web"
    rm -rf "$WEB_TMP"
    git clone --depth 1 -b "$WEB_BRANCH" "$WEB_REPO" "$WEB_TMP" 2>&1 | tail -2 || true
    # Layout REEL du repo : server.js / package.json / web/ / start-web.sh à la
    # RACINE (fallback sous server/ pour un ancien layout).
    if   [ -f "$WEB_TMP/server.js" ];        then cp "$WEB_TMP/server.js"        "$WEB/server.js"
    elif [ -f "$WEB_TMP/server/server.js" ]; then cp "$WEB_TMP/server/server.js" "$WEB/server.js"; fi
    if   [ -f "$WEB_TMP/package.json" ];        then cp "$WEB_TMP/package.json"        "$WEB/package.json"
    elif [ -f "$WEB_TMP/server/package.json" ]; then cp "$WEB_TMP/server/package.json" "$WEB/package.json"; fi
    [ -d "$WEB_TMP/web" ]          && cp -r "$WEB_TMP/web/."     "$WEB/web/"
    [ -f "$WEB_TMP/start-web.sh" ] && cp "$WEB_TMP/start-web.sh" "$WEB/" && chmod +x "$WEB/start-web.sh"
    [ -f "$WEB_TMP/Dockerfile" ]   && cp "$WEB_TMP/Dockerfile"   "$WEB/Dockerfile"
    rm -rf "$WEB_TMP"
    if [ -f "$WEB/server.js" ]; then
        echo -e "  ${GREEN}✓${NC} osmo-egprs-web depuis le git ${CYAN}$WEB_REPO${NC} ($WEB_BRANCH)"
    else
        echo -e "  ${RED}✗ clone osmo-egprs-web sans server.js — dashboard incomplet${NC}"
    fi
fi

# Patch server.js : mode natif (no-docker). VTY en telnet direct sur 127.0.0.1
# (ou ip netns exec) au lieu de docker exec. Idempotent ; n'échoue pas le build.
if [ -f "$WEB/server.js" ] && command -v python3 >/dev/null 2>&1; then
python3 - "$WEB/server.js" <<'PYEOF' || echo -e "  ${YELLOW}[web] patch natif non appliqué (server.js amont a changé ?)${NC}"
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'const NATIVE' in s:
    print('  [web] server.js déjà en mode natif — skip'); sys.exit(0)
HELPERS = """
// ─── Native (no-docker) mode ─────────────────────────────────
const NATIVE        = (process.env.OSMO_NATIVE !== '0');
const OP_IDS        = (process.env.OSMO_OP_IDS || '1').split(',')
                        .map(function(s){ return parseInt(s, 10); })
                        .filter(function(n){ return !isNaN(n); });
const NETNS_PREFIX  = process.env.OSMO_NETNS_PREFIX || '';
function vtyProc(container, port, ip, id) {
  if (NATIVE) {
    if (NETNS_PREFIX) return { bin: 'ip', args: ['netns','exec', NETNS_PREFIX + id, 'telnet', ip, String(port)] };
    return { bin: 'telnet', args: [ip, String(port)] };
  }
  return { bin: 'docker', args: ['exec','-i', container, 'telnet', ip, String(port)] };
}
function shCmd(container, id, inner) {
  if (NATIVE) {
    if (NETNS_PREFIX) return 'ip netns exec ' + NETNS_PREFIX + id + ' bash -c "' + inner + '"';
    return 'bash -c "' + inner + '"';
  }
  return 'docker exec ' + container + ' bash -c "' + inner + '"';
}
"""
n = [0]
def sub(pat, rep, flags=0):
    global s
    s, c = re.subn(pat, rep, s, flags=flags); n[0]+=c; return c
sub(r"(const VTY_RETRY_DELAY = 2000;)", r"\1\n" + HELPERS.replace('\\','\\\\'))
sub(r"(function discoverOperators\(\) \{)", r"\1\n  if (NATIVE) return Promise.resolve(OP_IDS.slice());")
sub(r"var proc = spawn\('docker', \[\s*'exec', '-i', container, 'telnet', targetIp, String\(port\)\s*\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(container, port, targetIp, String(container).replace(PREFIX, ''));\n    var proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
sub(r"return execAsync\(\s*'docker inspect.*?\)\.then\(function\(running\) \{",
    "var runningProbe = NATIVE\n    ? execAsync(shCmd(container, id, 'ss -tln 2>/dev/null | grep -q :' + VTY_PORTS.bsc + ' && echo true || echo false'), 3000)\n    : execAsync('docker inspect -f \\'{{.State.Running}}\\' ' + container + ' 2>/dev/null', 3000);\n  return runningProbe.then(function(running) {", re.DOTALL)
sub(r"execAsync\(\s*'docker exec ' \+ container \+ ' bash -c \"ss -tlnp.*?', 3000\s*\)",
    "execAsync(\n        shCmd(container, id, 'ss -tlnp 2>/dev/null | grep :7890 | wc -l'), 3000\n      )", re.DOTALL)
sub(r"log\('VTY open: docker exec.*?\], \{ stdio: \['pipe','pipe','pipe'\] \}\);",
    "var vc = vtyProc(this.container, this.port, this.ip, this.opId);\n  log('VTY open: ' + vc.bin + ' ' + vc.args.join(' ') + ' (attempt ' + (this.retries + 1) + ')');\n\n  this.proc = spawn(vc.bin, vc.args, { stdio: ['pipe','pipe','pipe'] });", re.DOTALL)
open(p,'w',encoding='utf-8').write(s)
print('  [web] server.js patché mode natif (%d remplacements)' % n[0])
sys.exit(0 if n[0] >= 6 else 2)
PYEOF
fi

# ── Étape 7 : Injection des scripts projet et création de lancement/start-in-iso.sh ──
echo -e "${GREEN}[7/7] Scripts projet et adaptation ISO...${NC}"
P="$ROOTFS/opt/osmo-nitb-for-calypso"
mkdir -p "$P"/{scripts,configs,checks,helpers}
for f in lancement/start.sh start-direct.sh make-docker-image.sh reseau/loopback.sh outils/vty-menu.sh outils/vty-connect.exp \
         reseau/firewall-wan.sh reseau/setup-wan-interop.sh reseau/setup-wan-sms.sh; do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$P/$f" && chmod +x "$P/$f"
done
ln -sf /opt/osmo-nitb-for-calypso/start-direct.sh "$ROOTFS/usr/local/bin/osmo-start-direct" 2>/dev/null || true
for d in scripts configs checks helpers; do
    [ -d "$DIR/$d" ] && cp -r "$DIR/$d/." "$P/$d/" && find "$P/$d" -name "*.sh" -exec chmod +x {} \;
done
[ -f "$DIR/Dockerfile" ]     && cp "$DIR/Dockerfile"     "$P/"
[ -f "$DIR/Dockerfile.run" ] && cp "$DIR/Dockerfile.run" "$P/"
ln -sf /opt/osmo-nitb-for-calypso/start.sh "$ROOTFS/usr/local/bin/osmo-start-lab"
[ -f "$DIR/osmo-launch.sh" ] && cp "$DIR/osmo-launch.sh" "$ROOTFS/opt/osmo-launch.sh" && chmod +x "$ROOTFS/opt/osmo-launch.sh"
ln -sf /opt/osmo-launch.sh "$ROOTFS/usr/local/bin/osmo-launch"

# Copie du script lancement/start-in-iso.sh (s'il existe)
if [ -f "$DIR/start-in-iso.sh" ]; then
    cp "$DIR/start-in-iso.sh" "$P/start-in-iso.sh"
    chmod +x "$P/start-in-iso.sh"
    echo -e "  ${GREEN}✓${NC} /opt/osmo-nitb-for-calypso/start-in-iso.sh copié"
else
    echo -e "  ${YELLOW}lancement/start-in-iso.sh non trouvé, création d'un script minimal...${NC}"
    cat > "$P/start-in-iso.sh" <<'EOF'
#!/bin/bash
# lancement/start-in-iso.sh minimal (à remplacer par votre version)
echo "Veuillez fournir un script lancement/start-in-iso.sh complet."
exit 1
EOF
    chmod +x "$P/start-in-iso.sh"
fi

# ── Étape 8 : (SUPPRIMÉ) — ISO NATIF, plus de Docker au runtime ───────────
# L'ancien load-osmocom-image.service chargeait osmocom-run.tar.gz via 'docker
# load' au boot ; son ExecStartPre 'while ! docker info' bloquait indéfiniment la
# file systemd en natif (docker jamais up) → boot figé. Le lab tourne désormais
# en natif (start-direct.sh) : pas d'image Docker à charger, pas de ce service.

# ── Étape 9 : Configuration chroot (paquets) ───────────────────────────────
echo -e "${GREEN}[8/7] Configuration chroot...${NC}"
mount --bind /proc "$ROOTFS/proc"; mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev";   mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null||true
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null||true

chroot "$ROOTFS" bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
export DPKG_OPTIONS="--force-confold --force-confdef"
APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Preseed debconf
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | debconf-set-selections
echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections

cat > /etc/apt/sources.list <<SOURCES
deb http://archive.ubuntu.com/ubuntu jammy           main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates    main universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security   main universe multiverse
SOURCES
apt-get update -qq

# deb-src + build-dep gnuradio : tire toutes les deps de GNU Radio (boost, fftw,
# gmp, log4cpp, volk...) dont depend le gnuradio/gr-gsm custom de /usr/local.
# Genere les lignes deb-src a partir des deb (tous composants), comme le Dockerfile.
sed -nE "s|^deb (http\S+) (\S+) .*|deb-src \1 \2 main restricted universe multiverse|p" \
    /etc/apt/sources.list | sort -u > /etc/apt/sources.list.d/deb-src.list
apt-get update -qq
apt-get build-dep -y $APT_OPTS gnuradio || echo "WARN: apt build-dep gnuradio a echoue"

apt-get install -y $APT_OPTS --no-install-recommends \
    linux-image-generic initramfs-tools \
    live-boot live-boot-initramfs-tools

apt-get install -y $APT_OPTS --no-install-recommends \
    libtalloc2 libtalloc-dev libpcsclite1 libsctp1 libsctp-dev libc-ares2 libgnutls30 libgnutls28-dev libmnl-dev \
    libortp-dev libdbi1 libdbd-sqlite3 sqlite3 \
    libfftw3-single3 libusb-1.0-0 \
    libgsm1 libasound2 libasound2-plugins \
    libsofia-sip-ua-glib3 libmnl0 \
    liburing2 libslirp0

apt-get install -y $APT_OPTS --no-install-recommends \
    iproute2 iptables net-tools lksctp-tools \
    tmux telnet expect whiptail netcat-openbsd \
    lsb-release pulseaudio pulseaudio-utils alsa-utils openssh-server \
    console-setup keyboard-configuration locales \
    binutils-arm-none-eabi psmisc gdb-multiarch

apt-get install -y $APT_OPTS --no-install-recommends \
    python3 python3-scapy \
    tshark wireshark-common \
    asterisk \
    ffmpeg

echo "/usr/local/lib" > /etc/ld.so.conf.d/osmocom.conf
ldconfig

# Docker NON installe dans le ISO (natif) : le lab tourne via start-direct.sh et le
# dashboard web via node natif. Le build sur le HOTE utilise le docker du HOTE pour
# extraire binaires/configs, mais le ISO final nembarque pas docker.

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y $APT_OPTS --no-install-recommends nodejs
fi

if [ -f /opt/osmo-egprs-web/package.json ]; then
    cd /opt/osmo-egprs-web && npm install --production 2>/dev/null || true
fi

setcap cap_net_raw,cap_net_admin+eip $(which dumpcap) 2>/dev/null || true

KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed "s|/boot/vmlinuz-||")
update-initramfs -u -k "$KERNEL"

apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
'

# ── Étape 8b : Rééquilibrage sur make-docker-image.sh — clôture de dépendances ldd ────────
# L'image osmocom-run (produite par make-docker-image.sh + Dockerfile) est l'environnement
# qui MARCHE. Au lieu de se fier aux versions apt du rootfs (skew -> crash
# logging libosmocore), on copie depuis le conteneur la clôture .so EXACTE de
# tous les binaires osmo + calypso-ipc-device, en écrasant les libs apt. On
# exclut la famille glibc/loader (identique en jammy, ne pas clobber ld.so).
echo -e "${GREEN}[8b/7] Clôture de dépendances COMPLÈTE depuis ${CYAN}${ISO_RUN_IMAGE}${NC}${GREEN} (toute l'install)...${NC}"
# On ldd TOUS les ELF (executables + toutes les .so) de l'install custom :
# /usr/local/bin (osmo), /opt/GSM (qemu, ipc-device, gr-gsm), /root/.env (venv
# python : bindings gnuradio/gr-gsm + leurs deps boost/log4cpp/volk/fftw...).
# => toutes les deps natives finissent dans l'ISO, plus de "import gsm" qui rate.
docker run --rm --entrypoint bash "$ISO_RUN_IMAGE" -c '
    set -e
    find /usr/local/bin /opt/GSM /root/.env -type f \( -executable -o -name "*.so*" \) 2>/dev/null \
      | while read -r b; do ldd "$b" 2>/dev/null; done \
      | grep -oE "/[^ ]+\.so[^ ]*" | sort -u \
      | grep -vE "/(ld-linux[^/]*|ld|libc|libm|libpthread|libdl|librt|libresolv)\.so" \
      | while read -r f; do realpath "$f" 2>/dev/null; done | sort -u \
      | tar -czf - -T - 2>/dev/null
' > "$WORK/closure.tar.gz" || true
if [ -s "$WORK/closure.tar.gz" ]; then
    tar -xzf "$WORK/closure.tar.gz" -C "$ROOTFS" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} $(tar -tzf "$WORK/closure.tar.gz" 2>/dev/null | wc -l) libs injectées (Docker)"
else
    echo -e "  ${YELLOW}clôture vide — on garde les libs apt${NC}"
fi

# Priorité /usr/local/lib (libosmo* custom) + purge de tout doublon système.
# NB: pas de `| grep` ici — sous set -euo pipefail un grep sans correspondance
# (cas normal: aucun doublon) renverrait 1 et tuerait le script avant l'ISO.
echo "/usr/local/lib" > "$ROOTFS/etc/ld.so.conf.d/00-osmocom-local.conf"
find "$ROOTFS/usr/lib" "$ROOTFS/lib" -maxdepth 4 -name 'libosmo*.so*' -delete 2>/dev/null || true
chroot "$ROOTFS" ldconfig 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} /usr/local/lib prioritaire + ldconfig"

# ── Configuration système ──────────────────────────────────────────────────
echo "osmo-egprs" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost osmo-egprs
::1       localhost
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-dhcp.network" <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
# IP fixes assignees au NIC par defaut (en plus du DHCP) : gw / ip1 / ip2
Address=172.20.0.1/24
Address=172.20.0.11/24
Address=172.20.1.10/24
# Couverture de tout le plan docker 172.20.0.0/16 (route connectee, PAS de route par defaut)
[Route]
Destination=172.20.0.0/16
Scope=link
EOF
# docker RETIRÉ de la liste : son service n'existe plus (ISO natif) et 'systemctl
# enable' valide tous les units d'abord → un seul manquant faisait AVORTER l'enable
# de systemd-networkd/resolved → enp3s0 sans IP au boot. On active chaque unit
# séparément pour qu'un éventuel échec n'empêche pas les autres.
chroot "$ROOTFS" systemctl enable systemd-networkd 2>/dev/null||true
chroot "$ROOTFS" systemctl enable systemd-resolved 2>/dev/null||true

# live-boot écrit /root/etc/network/interfaces dans la racine montée au boot.
# Sans ifupdown, /etc/network/ n'existe pas -> "/init: can't create
# /root/etc/network/interfaces: nonexistent directory". On crée le dossier + un
# interfaces minimal (loopback). systemd-networkd gère le réseau ; ce fichier
# n'est lu par personne (ifupdown absent), il satisfait juste le hook live-boot.
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# ── Service startup : exécute le gist maj/update.sh (bbaranoff) au démarrage ──────
cat > "$ROOTFS/usr/local/sbin/osmo-update.sh" <<'UPD'
#!/bin/bash
# osmo-update.sh — recupere et execute maj/update.sh (repo bbaranoff/osmo-nitb-for-calypso) au boot.
set -u
URL="https://raw.githubusercontent.com/bbaranoff/osmo-nitb-for-calypso/refs/heads/main/update.sh"
LOG=/var/log/osmo-update.log
exec >>"$LOG" 2>&1
echo "===== osmo-update $(date) ====="
for i in 1 2 3 4 5; do
    if curl -fsSL "$URL" -o /tmp/osmo-update.gist.sh; then
        chmod +x /tmp/osmo-update.gist.sh
        echo "--- execution maj/update.sh ---"
        bash /tmp/osmo-update.gist.sh; rc=$?
        echo "maj/update.sh termine (rc=$rc)"
        # ── Normalisation fstab : retire le doublon /tmp ré-injecté par maj/update.sh ──
        # maj/update.sh (gist) ré-ajoute 'tmpfs /tmp tmpfs nosuid,nodev 0 0' (SANS size=),
        # créant un doublon avec l'entree canonique 'tmpfs /tmp … size=2G' posee au build.
        # On supprime toute ligne 'tmpfs /tmp tmpfs …' depourvue de size= (le doublon),
        # en conservant l'entree 2G. Idempotent : sans effet si le doublon est absent.
        if [ -f /etc/fstab ]; then
            sed -i -E '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]+tmpfs[[:space:]]/d' /etc/fstab
            systemctl daemon-reload 2>/dev/null || true
            echo "fstab normalise (/tmp gere par systemd tmp.mount)"
        fi
        exit 0
    fi
    echo "curl echoue (tentative $i/5), retry dans 5s..."; sleep 5
done
echo "impossible de recuperer maj/update.sh apres 5 tentatives (pas de reseau ?)"
exit 0
UPD
chmod +x "$ROOTFS/usr/local/sbin/osmo-update.sh"

cat > "$ROOTFS/etc/systemd/system/osmo-update.service" <<'EOF'
[Unit]
Description=osmo-nitb-for-calypso startup update (gist maj/update.sh)
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/osmo-update.sh
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-update 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} osmo-update (exécute le gist maj/update.sh au démarrage)"


# Autologin root
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# Service web dashboard
cat > "$ROOTFS/etc/systemd/system/osmo-egprs-web.service" <<'EOF'
[Unit]
Description=osmo-nitb-for-calypso Web Dashboard (native)
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/osmo-egprs-web
ExecStart=/usr/bin/node /opt/osmo-egprs-web/server.js --verbose
Restart=always
RestartSec=5
Environment=HTTP_PORT=8080
# Mode natif (start-direct.sh) : VTY en telnet direct sur 127.0.0.1, pas de docker.
# Pour le mode docker (lancement/start.sh + conteneurs), mettre OSMO_NATIVE=0.
Environment=OSMO_NATIVE=1
Environment=OSMO_OP_IDS=1
Environment=CONTAINER_PREFIX=osmo-operator-
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-egprs-web 2>/dev/null||true

# ── Audio : PulseAudio système (sink gsm_audio) au boot ────────────────────
# Chaîne : osmo-gapk → ALSA gsm_out → sink null gsm_audio → monitor → loopback
# → carte. system.pa autorise l'accès anonyme + prépare le sink ; le service
# lance le démon au boot (ensure_pulse de start-direct.sh devient un no-op).
if [ -f "$ROOTFS/etc/pulse/system.pa" ]; then
    sed -i 's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' \
        "$ROOTFS/etc/pulse/system.pa"
    grep -q 'sink_name=gsm_audio' "$ROOTFS/etc/pulse/system.pa" || \
        echo 'load-module module-null-sink sink_name=gsm_audio format=s16le rate=8000 channels=1 sink_properties=device.description=GSM_Audio' \
        >> "$ROOTFS/etc/pulse/system.pa"
fi
cat > "$ROOTFS/etc/systemd/system/osmo-pulse.service" <<'EOF'
[Unit]
Description=osmo-nitb-for-calypso PulseAudio system daemon (GSM audio)
After=sound.target
[Service]
Type=forking
ExecStart=/usr/bin/pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 --log-target=file:/var/log/osmocom/pulse-system.log
ExecStartPre=/bin/mkdir -p /var/log/osmocom /var/run/pulse
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
chroot "$ROOTFS" systemctl enable osmo-pulse 2>/dev/null||true

# Modules noyau
mkdir -p "$ROOTFS/etc/modules-load.d"
printf 'sctp\ntun\n' > "$ROOTFS/etc/modules-load.d/osmocom.conf"

# Variables d'environnement
cat > "$ROOTFS/etc/environment" <<'EOF'
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
LD_LIBRARY_PATH="/usr/local/lib"
EOF

# bashrc pour root
cat >> "$ROOTFS/root/.bashrc" <<'BASH'
# Active par defaut l'environnement python (gr-gsm + bridges) utilise par
# ${NITB_TREE}/start-direct.sh. VIRTUAL_ENV_DISABLE_PROMPT pour garder le PS1.
export VIRTUAL_ENV_DISABLE_PROMPT=1
[ -f /root/.env/bin/activate ] && source /root/.env/bin/activate
alias faketrx='python3 ${GSM_ROOT}/osmocom-bb/src/target/trx_toolkit/fake_trx.py'
alias osmo-lab='cd ${NITB_TREE} && ./start-direct.sh'
alias osmo-web='systemctl status osmo-egprs-web'
alias osmo-status='/etc/osmocom/status.sh status'
export PATH="$HOME/.local/bin:$PATH"

### calypso-prompt ###
export PS1='\[\033[1;31m\]\u\[\033[0m\]@\[\033[1;34m\]\h\[\033[0m\]:\[\033[1;32m\]\w\[\033[0m\]☎️ # '
### end calypso-prompt ###
BASH

# Message du jour — bannière couleur + boîte alignée. Contenu de la boîte en
# ASCII (pas de ←/é/• multi-octets) + padding printf => bords parfaitement
# alignés. Généré à chaud pour injecter les couleurs ANSI dans /etc/motd.
{
  B=$'\033[1;36m'; T=$'\033[1;37m'; G=$'\033[1;32m'; Y=$'\033[0;33m'; N=$'\033[0m'
  W=58
  printf '\n%b' "$B"
  cat <<'LOGO'
    ___  ___ _ __ ___   ___    ___  __ _ _ __  _ __ ___
   / _ \/ __| '_ ` _ \ / _ \  / _ \/ _` | '_ \| '__/ __|
  | (_) \__ \ | | | | | (_) ||  __/ (_| | |_) | |  \__ \
   \___/|___/_| |_| |_|\___/  \___|\__, | .__/|_|  |___/
                                   |___/|_|
LOGO
  printf '%b' "$N"
  printf "${B}  ╔"; printf '═%.0s' $(seq 1 $W); printf "╗${N}\n"
  printf "${B}  ║${N} ${T}%-*s${N} ${B}║${N}\n" $((W-2)) "GSM / EGPRS  Multi-PLMN  Live System"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "SS7/SIGTRAN  -  Osmocom  -  Calypso/QEMU"
  printf "${B}  ╠"; printf '═%.0s' $(seq 1 $W); printf "╣${N}\n"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "${NITB_TREE}/start-direct.sh"
  printf "${B}  ║${N} %-*s ${B}║${N}\n"         $((W-2)) "    -> lance le lab Calypso/QEMU (A5/1)"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "Dashboard web  ->  http://<vm-ip>:8080"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "FFT spectres   ->  http://<vm-ip>:8081"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "Wiki / docs        ->  pl4y.store"
  printf "${B}  ║${N} ${G}%-*s${N} ${B}║${N}\n" $((W-2)) "ssh root@<vm-ip>   -> mot de passe : osmo"
  printf "${B}  ║${N} ${Y}%-*s${N} ${B}║${N}\n" $((W-2)) "loadkeys fr   -> changer le clavier (apres boot)"
  printf "${B}  ╚"; printf '═%.0s' $(seq 1 $W); printf "╝${N}\n\n"
} > "$ROOTFS/etc/motd"

# Mot de passe root = "osmo" (autologin console + login SSH). On NE vide PAS le
# mot de passe (sinon sshd refuse le login root).
echo 'root:osmo' | chroot "$ROOTFS" chpasswd 2>/dev/null || true

# ── Espace writable du live : 2 Go pour /dev/shm + /tmp ─────────────────────
# Le live boote en 'toram' → racine = overlay tmpfs (RAM). Les gros writers de la
# stack sont les cfiles I/Q dans /dev/shm (FFT/record, plusieurs centaines de Mo)
# et /tmp. On force 2 Go sur ces deux tmpfs via fstab (cap RAM-backed : nécessite
# autant de RAM dispo). systemd applique ces entrées au boot.
# Idempotent + anti-doublon : on purge d'abord toute entree tmpfs /tmp ou /dev/shm
# preexistante (y compris la variante 'nosuid,nodev' sans size=) et l'ancien
# commentaire de bloc, PUIS on (re)ecrit le bloc canonique size=2G. Garantit
# exactement une entree /tmp et une entree /dev/shm dans le fstab du squashfs.
touch "$ROOTFS/etc/fstab"
sed -i -E \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/tmp[[:space:]]/d' \
    -e '/^[[:space:]]*tmpfs[[:space:]]+\/dev\/shm[[:space:]]/d' \
    -e '/^# osmo-nitb-for-calypso live — espace writable/d' \
    "$ROOTFS/etc/fstab"
# /dev/shm : sizing via fstab (sans risque de doublon generateur).
cat >> "$ROOTFS/etc/fstab" <<'FSTAB'
# osmo-nitb-for-calypso live — espace writable (cfiles I/Q FFT)
tmpfs   /dev/shm   tmpfs   defaults,nosuid,nodev,size=2G   0 0
FSTAB
# /tmp : PAS dans fstab. Une entree fstab /tmp entre en collision avec l'unite
# systemd tmp.mount -> "systemd-fstab-generator: tmp.mount already exists,
# Duplicate entry in /etc/fstab" (generateur en exit 1) ; en plus maj/update.sh la
# reinjecte au boot. On gere /tmp en natif systemd via un drop-in size=2G : une
# seule source, zero doublon possible quoi que fasse update.sh.
mkdir -p "$ROOTFS/etc/systemd/system/tmp.mount.d"
cat > "$ROOTFS/etc/systemd/system/tmp.mount.d/size.conf" <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=2G
EOF
chroot "$ROOTFS" systemctl enable tmp.mount 2>/dev/null || true

# SSH : autorise le login root par mot de passe + active le service au boot.
if [ -f "$ROOTFS/etc/ssh/sshd_config" ]; then
    sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
        "$ROOTFS/etc/ssh/sshd_config"
    grep -q '^PermitRootLogin yes' "$ROOTFS/etc/ssh/sshd_config" || \
        echo 'PermitRootLogin yes' >> "$ROOTFS/etc/ssh/sshd_config"
fi
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# Script de configuration clavier au premier boot
cat > "$ROOTFS/etc/profile.d/01-keyboard-setup.sh" <<'KBSCRIPT'
#!/bin/bash
[ -f /var/lib/osmo-kb-done ] && return 0
[ "$(id -u)" -ne 0 ] && return 0

echo ""
echo -e "\033[1;36m══ Configuration clavier ══\033[0m"
echo ""
echo "  1) fr    — Français (AZERTY)"
echo "  2) us    — English (QWERTY)"
echo "  3) de    — Deutsch (QWERTZ)"
echo "  4) es    — Español"
echo "  5) it    — Italiano"
echo "  6) pt    — Português"
echo "  7) gb    — UK English"
echo "  8) be    — Belge"
echo "  9) ch    — Suisse"
echo "  0) Autre (saisie manuelle)"
echo ""
read -rp "  Choix [1] : " KB_CHOICE
KB_CHOICE="${KB_CHOICE:-1}"

case "$KB_CHOICE" in
    1) KB_LAYOUT="fr" ;;
    2) KB_LAYOUT="us" ;;
    3) KB_LAYOUT="de" ;;
    4) KB_LAYOUT="es" ;;
    5) KB_LAYOUT="it" ;;
    6) KB_LAYOUT="pt" ;;
    7) KB_LAYOUT="gb" ;;
    8) KB_LAYOUT="be" ;;
    9) KB_LAYOUT="ch" ;;
    0)
        read -rp "  Layout (ex: fr, us, de, ru, ar...) : " KB_LAYOUT
        KB_LAYOUT="${KB_LAYOUT:-us}"
        ;;
    *) KB_LAYOUT="fr" ;;
esac

echo ""
echo -e "  \033[1;32m→ Clavier : ${KB_LAYOUT}\033[0m"

loadkeys "$KB_LAYOUT" 2>/dev/null || true

cat > /etc/default/keyboard <<KBCONF
XKBMODEL="pc105"
XKBLAYOUT="${KB_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBCONF

setupcon --force 2>/dev/null || true
dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true

touch /var/lib/osmo-kb-done

echo -e "  \033[1;33mDisclaimer:\033[0m aucun service Osmocom n'est lancé automatiquement."
echo -e "  \033[1;33mPour démarrer la stack manuellement : /opt/osmo-nitb-for-calypso/start-in-iso.sh\033[0m"

echo -e "  \033[1;32m✓ Clavier configuré (${KB_LAYOUT}). Rechargez avec : loadkeys ${KB_LAYOUT}\033[0m"
echo ""
KBSCRIPT

chmod +x "$ROOTFS/etc/profile.d/01-keyboard-setup.sh"
umount "$ROOTFS"/{dev/pts,proc,sys,dev} 2>/dev/null||true

echo -e "  ${GREEN}✓${NC} config terminée"

# ── Création du squashfs et de l'ISO ───────────────────────────────────────
echo -e "${GREEN}[9/7] Squashfs et ISO...${NC}"
mkdir -p "$ISOROOT/live" "$ISOROOT/boot/grub"

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-*|sort -V|tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-*|sort -V|tail -1)
[ -z "$VMLINUZ" ]||[ -z "$INITRD" ] && { echo -e "${RED}Kernel absent${NC}"; exit 1; }
echo -e "  Kernel: ${CYAN}$(basename "$VMLINUZ")${NC}"

mksquashfs "$ROOTFS" "$ISOROOT/live/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 1M \
    -e 'boot/vmlinuz-*' -e 'boot/initrd*' \
    -e 'var/cache/apt' -e 'var/lib/apt/lists' \
    -no-progress
echo -e "  ${GREEN}✓${NC} squashfs $(du -sh "$ISOROOT/live/filesystem.squashfs"|cut -f1)"

cp "$VMLINUZ" "$ISOROOT/boot/vmlinuz"
cp "$INITRD"  "$ISOROOT/boot/initrd.img"

cat > "$ISOROOT/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5
menuentry "osmo-nitb-for-calypso — Live (toram — RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram quiet
    initrd /boot/initrd.img
}
menuentry "osmo-nitb-for-calypso — Live USB sans toram (RAM ~3 Go, lit depuis le medium)" {
    linux  /boot/vmlinuz boot=live quiet
    initrd /boot/initrd.img
}
menuentry "osmo-nitb-for-calypso — Live verbose (toram — RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram
    initrd /boot/initrd.img
}
menuentry "osmo-nitb-for-calypso — Copy to RAM (toram — RAM ~6 Go)" {
    linux  /boot/vmlinuz boot=live toram copytoram quiet
    initrd /boot/initrd.img
}
GRUB

# Wrapper: inject -iso-level 3 (multi-extent, lifts the 4 GiB single-file cap)
# into grub-mkrescue's internal `xorriso -as mkisofs` call.
XORRISO_WRAP="$WORK/xorriso-iso-level3"
cat > "$XORRISO_WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = "-as" ] && [ "$2" = "mkisofs" ]; then
    shift 2
    exec xorriso -as mkisofs -iso-level 3 "$@"
fi
exec xorriso "$@"
EOF
chmod +x "$XORRISO_WRAP"

grub-mkrescue --xorriso="$XORRISO_WRAP" -o "$OUTPUT" "$ISOROOT" \
    --product-name "osmo-nitb-for-calypso $VERSION" -- -volid "$LABEL"
    if command -v isohybrid &>/dev/null; then
    isohybrid --uefi "$OUTPUT"
fi

if [ ! -f "$OUTPUT" ]; then
    echo -e "${RED}grub-mkrescue a échoué — ISO non créée${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}═══ ISO prête : ${OUTPUT} ($(du -sh "$OUTPUT"|cut -f1)) ═══${NC}"
echo -e "  Chemin absolu : $(readlink -f "$OUTPUT")"
