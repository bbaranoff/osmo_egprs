# =============================================================================
#  lib/audio.sh — la chaîne audio d'osmo_egprs (PulseAudio + pont GAPK)
# =============================================================================
#
#  CE FICHIER EST UNE EXTRACTION, PAS UNE RÉÉCRITURE.
#  ensure_pulse / ensure_host_audio / ensure_gapk viennent telles quelles de
#  start-direct.sh.legacy (L566-722). Aucune ligne n'a été retouchée.
#
#  POURQUOI LES PRÉSERVER.
#  Le mode `qemu` de start-direct.sh appelait ensure_gapk JUSTE AVANT de passer
#  la main à qemu-src/start-clean.sh (legacy L1077). C'est ce qui branche le RTP
#  du MGW sur le sink `gsm_audio` : sans lui, la pile monte, l'appel s'établit,
#  et personne n'entend rien. Le chemin `qemu` devant continuer à marcher à
#  l'identique, cette précondition devait survivre au découpage — on la déplace,
#  on ne la réinvente pas.
#
#  CE FICHIER NE FAIT RIEN AU SOURCE : il ne définit que des fonctions.
#  Appelant attendu : run_modules/25-audio.sh.
#
#  AUDIO=0 désactive toute la mise en place, exactement comme dans l'original.
# -----------------------------------------------------------------------------

: "${HERE:=/opt/GSM/osmo_egprs}"
: "${LOG_DIR:=/root}"
: "${AUDIO:=1}"
: "${PULSE_SOCK:=/var/run/pulse/native}"
# L'original colorait ses messages ; sous `set -u` une couleur non définie
# ferait échouer la fonction avant même d'avoir agi. On les neutralise.
RED='' GREEN='' YELLOW='' CYAN='' NC='' BOLD=''

# Les DEUX null-sinks de la chaîne GSM, déclarés au même endroit : gsm_audio
# (= alsa gsm_out, la voix qui SORT) et gsm_mic (= alsa gsm_in via
# gsm_mic.monitor, le micro silencieux qui ENTRE).
#
# [2026-08-12] gsm_mic n'était créé QUE par scripts/pulse-gsm-setup.sh, que
# run.sh appelle ligne 422 — soit APRÈS osmo-start.sh (ligne 307). Un HLR qui ne
# démarre pas fait `exit 1` dans osmo-start.sh, le `set -euo pipefail` de run.sh
# tue tout, et le sink n'est jamais créé. Or gapk_io ABANDONNE LES DEUX SENS
# quand la capture échoue :
#     pq_alsa.c:168  Couldn't init ALSA device 'gsm_in': Input/output error
#     gapk_io.c:468  Failed to initialize GAPK I/O
# → appel parfaitement établi mais TOTALEMENT muet, et l'erreur est enterrée
# dans mobile.log. C'est le "ça marche sur un PC, pas sur l'autre" : le tirage
# au sort, c'est de savoir si le HLR est monté avant.
#
# Les deux sinks sont désormais SOLIDAIRES — ici, dans system.pa et dans le
# Dockerfile. Aucun ordre de script ne peut plus en perdre un.
GSM_SINKS="gsm_audio:GSM_Audio gsm_mic:GSM_Mic"

load_gsm_sinks() {
    local entry name desc
    for entry in $GSM_SINKS; do
        name="${entry%%:*}"; desc="${entry##*:}"
        pactl list short sinks 2>/dev/null | grep -qw "$name" || \
            pactl load-module module-null-sink sink_name="$name" \
                format=s16le rate=8000 channels=1 \
                sink_properties=device.description="$desc" >/dev/null 2>&1 || true
    done
}

# ── Loopback local : gsm_audio.monitor → la carte son de la machine ──────────
# [2026-08-14] CE MAILLON N'EXISTAIT NULLE PART. Le commentaire de ensure_pulse
# (« en local l'hôte entend via le module-loopback vers ses enceintes ») le
# SUPPOSE déjà présent, mais aucun chemin du dépôt ne le chargeait :
#   - enable_user_loopback() de start.sh n'est appelée par personne ;
#   - network/loopback.sh n'est lancé que sciemment, à la main.
# Résultat mesuré dans la VM osmo-egprs : gsm_audio RUNNING (mobile écrit
# dedans), gsm_audio.monitor IDLE (personne ne lit), sortie ALSA SUSPENDED,
# /proc/asound/card0/pcm0p/sub0/status = "closed". Appel établi, zéro son.
# gsm_audio est un module-null-sink : sans consommateur, la voix descendante est
# jetée PAR CONSTRUCTION. Ce n'est pas une panne, c'est un maillon manquant.
#
# ⚠️ Le choix du sink n'est pas cosmétique : reboucler sur gsm_audio ou gsm_mic
# recrée la boucle fermée du 08/08 (cf. ensure_gapk : « les mobiles écrivent
# dans gsm_out, on les rejouerait dans leur propre uplink »). On exclut donc
# explicitement les deux null-sinks et on ne garde qu'une sortie matérielle.
LOOPBACK_LATENCY_MSEC="${LOOPBACK_LATENCY_MSEC:-20}"

ensure_local_loopback() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    [ "${AUDIO_LOCAL_LOOPBACK:-1}" = "1" ] || {
        echo -e "  ${YELLOW}[audio] loopback local désactivé (AUDIO_LOCAL_LOOPBACK=0)${NC}"; return 0; }
    pactl info >/dev/null 2>&1 || return 0

    pactl list short sources 2>/dev/null | grep -qw 'gsm_audio.monitor' || {
        echo -e "  ${YELLOW}[audio] gsm_audio.monitor absent — loopback local ignoré${NC}"; return 0; }

    # Sortie matérielle = le sink par défaut, SAUF si c'est un de nos null-sinks.
    local sink
    sink="$(pactl get-default-sink 2>/dev/null || true)"
    case "$sink" in
        ''|gsm_audio|gsm_mic|@*)
            sink="$(pactl list short sinks 2>/dev/null \
                    | awk '$2 != "gsm_audio" && $2 != "gsm_mic" { print $2; exit }')" ;;
    esac
    [ -n "$sink" ] || {
        echo -e "  ${YELLOW}[audio] aucune sortie matérielle — loopback local ignoré${NC}"; return 0; }

    # Idempotent : ne pas empiler un 2e loopback (voix doublée + écho).
    if pactl list short modules 2>/dev/null | grep -F 'module-loopback' \
         | grep -F 'source=gsm_audio.monitor' | grep -qF "sink=${sink}"; then
        echo -e "  ${GREEN}[audio] loopback local déjà en place → ${sink}${NC}"
        return 0
    fi

    if pactl load-module module-loopback \
            source=gsm_audio.monitor sink="$sink" \
            latency_msec="$LOOPBACK_LATENCY_MSEC" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[audio] loopback local chargé : gsm_audio.monitor → ${sink} (${LOOPBACK_LATENCY_MSEC} ms)${NC}"
    else
        echo -e "  ${YELLOW}[audio] échec du loopback local vers ${sink}${NC}"
    fi
}

# Post-condition : les PCM que `mobile` va réellement ouvrir s'ouvrent-ils ?
# Tester le sink avec `pactl list sinks` ne suffit pas — c'est le mapping ALSA
# de /etc/asound.conf qui casse (gsm_in → gsm_mic.monitor). On ouvre pour de
# vrai, 1 s de chaque côté, et on gueule si ça rate. Sans ça la panne est
# silencieuse jusqu'au premier appel muet.
assert_audio_devices() {
    command -v aplay >/dev/null 2>&1 || return 0
    local ko=0
    timeout 5 aplay  -D gsm_out -f S16_LE -r 8000 -c 1 -d 1 /dev/zero >/dev/null 2>&1 || {
        echo -e "  ${RED}[audio] KO : lecture 'gsm_out' impossible (sink gsm_audio ?)${NC}"; ko=1; }
    timeout 5 arecord -D gsm_in  -f S16_LE -r 8000 -c 1 -d 1 /dev/null  >/dev/null 2>&1 || {
        echo -e "  ${RED}[audio] KO : capture 'gsm_in' impossible (sink gsm_mic ?)${NC}"; ko=1; }
    if [ "$ko" = "1" ]; then
        echo -e "  ${RED}       → gapk_io va échouer et l'appel sera MUET DANS LES DEUX SENS.${NC}"
        echo -e "  ${RED}       → pactl list short sinks  (attendu : gsm_audio ET gsm_mic)${NC}"
        return 1
    fi
    echo -e "  ${GREEN}[audio] gsm_out (lecture) + gsm_in (capture) ouverts — chaîne OK${NC}"
    return 0
}

ensure_pulse() {
    [ "${AUDIO:-1}" = "1" ] || { echo -e "  ${YELLOW}[audio] désactivé (AUDIO=0)${NC}"; return 0; }

    # 0. Mapping ALSA gsm_out/gsm_in → sink PulseAudio gsm_audio (REQUIS côté hôte
    #    en mode natif). Sans /etc/asound.conf, le `mobile` (io-handler gapk,
    #    alsa-output-dev gsm_out) ouvre un PCM ALSA inexistant → "Unknown PCM
    #    gsm_out" → l'audio TCH n'est jamais décodé vers gsm_audio → silence
    #    navigateur. Le sink seul ne suffit pas : ce mapping doit exister.
    if [ -f "$HERE/configs/asound.conf" ] && ! cmp -s "$HERE/configs/asound.conf" /etc/asound.conf 2>/dev/null; then
        cp -f "$HERE/configs/asound.conf" /etc/asound.conf \
            && echo -e "  ${GREEN}[audio] /etc/asound.conf déployé (ALSA gsm_out/gsm_in → pulse gsm_audio)${NC}"
    fi

    export PULSE_SERVER="unix:${PULSE_SOCK}"
    if pactl info >/dev/null 2>&1; then
        # PulseAudio déjà actif (service osmo-pulse au boot, ou un 'fake' solo
        # précédent). Le sink gsm_audio n'est PAS forcément chargé dans CE démon
        # -> on le (re)charge à la volée s'il manque. SANS ça : l'audio ne marchait
        # qu'après un 'fake' solo (qui avait posé le sink) — c'est le maillon qui
        # manquait à fake+qemu pour avoir l'audio de lui-même.
        load_gsm_sinks
        # Dédoublonnage : sur une PipeWire/Pulse PARTAGÉE entre containers, chaque
        # ensure_pulse charge son propre module-null-sink gsm_audio → doublons.
        # parec (flux /audio du dashboard) lit alors le monitor d'un sink que gapk
        # n'alimente PAS → audio muet pour les clients distants (navigateur/Windows ;
        # en local l'hôte entend via le module-loopback vers ses enceintes, d'où
        # « ça marche sur Linux mais pas sur Windows »). On garde UN seul gsm_audio
        # (le 1er module) et on décharge les suivants.
        # (le dédoublonnage vaut pour gsm_mic autant que pour gsm_audio : un
        #  gsm_mic en double et gapk capture le monitor du mauvais sink)
        local _entry _name
        for _entry in $GSM_SINKS; do
            _name="${_entry%%:*}"
            pactl list short modules 2>/dev/null \
                | awk -v s="$_name" '/module-null-sink/ && $0 ~ ("sink_name=" s "([ \t]|$)") {print $1}' \
                | tail -n +2 \
                | while read -r _m; do [ -n "$_m" ] && pactl unload-module "$_m" >/dev/null 2>&1 \
                    && echo -e "  ${YELLOW}[audio] sink ${_name} en double déchargé (module $_m)${NC}"; done
        done
        echo -e "  ${GREEN}[audio] PulseAudio déjà actif (sinks gsm_audio + gsm_mic uniques assurés)${NC}"
        assert_audio_devices || true
        ensure_local_loopback
        return 0
    fi

    # 1. Installer pulseaudio si absent (le binaire démon, pas que les clients)
    if ! command -v pulseaudio >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "  ${YELLOW}[audio] installation pulseaudio...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
                pulseaudio pulseaudio-utils alsa-utils >/dev/null 2>&1 || true
        fi
    fi
    command -v pulseaudio >/dev/null 2>&1 || {
        echo -e "  ${YELLOW}[audio] pulseaudio indisponible — audio ignoré${NC}"; return 0; }

    # 2. Config system.pa : accès anonyme + les DEUX sinks null (idempotent).
    #    Les déclarer ici plutôt que de compter sur un load-module au runtime
    #    est ce qui rend la chaîne robuste : ils existent dès le démarrage du
    #    démon, y compris si le démon redémarre tout seul plus tard.
    local sp=/etc/pulse/system.pa
    if [ -f "$sp" ]; then
        grep -q 'auth-anonymous=1' "$sp" || sed -i \
            's|^load-module module-native-protocol-unix.*|load-module module-native-protocol-unix auth-anonymous=1 socket=/var/run/pulse/native|' "$sp"
        local _entry _name _desc
        for _entry in $GSM_SINKS; do
            _name="${_entry%%:*}"; _desc="${_entry##*:}"
            grep -q "sink_name=${_name}\b" "$sp" || \
                echo "load-module module-null-sink sink_name=${_name} format=s16le rate=8000 channels=1 sink_properties=device.description=${_desc}" >> "$sp"
        done
    fi

    # 3. (Re)démarrer le démon système — SÉRIALISÉ
    mkdir -p /var/run/pulse "$LOG_DIR"
    # ensure_pulse est appelé en parallèle (flux principal + ensure_gapk via la
    # session tmux 'gapk') → deux 'pulseaudio --system' se lançaient en même
    # temps et se disputaient /var/run/pulse/native → "bind(): Address already
    # in use" → le module socket échoue → démon mort → injoignable.
    # flock garantit UN SEUL (re)démarrage à la fois ; un démon résiduel détenant
    # un socket périmé (parfois sous un autre uid) est tué et le socket effacé
    # par root avant le bind.
    (
        flock 9
        if ! pactl info >/dev/null 2>&1; then
            pkill -x pulseaudio 2>/dev/null || true
            local _k=10
            while pgrep -x pulseaudio >/dev/null 2>&1 && [ $_k -gt 0 ]; do sleep 0.3; ((_k--)) || true; done
            pkill -9 -x pulseaudio 2>/dev/null || true
            rm -f /var/run/pulse/pid /var/run/pulse/native 2>/dev/null || true
            chown -R pulse:pulse /var/run/pulse 2>/dev/null || true
            pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 \
                --log-target="file:${LOG_DIR}/pulse-system.log" >/dev/null 2>&1 || true
            local r=10
            while [ $r -gt 0 ]; do pactl info >/dev/null 2>&1 && break; sleep 1; ((r--)) || true; done
        fi
    ) 9>/run/osmo-pulse.lock

    if pactl info >/dev/null 2>&1; then
        load_gsm_sinks
        echo -e "  ${GREEN}[audio] PulseAudio prêt (sinks gsm_audio + gsm_mic) @ ${PULSE_SOCK}${NC}"
        assert_audio_devices || true
        ensure_local_loopback
    else
        echo -e "  ${YELLOW}[audio] PulseAudio injoignable — audio dégradé${NC}"
        echo -e "  ${YELLOW}        → voir ${LOG_DIR}/pulse-system.log${NC}"
    fi
}

# ── Bridge audio : osmo-gapk auto (chemin réseau MGW RTP → sink gsm_audio) ────
# gapk auto poll le VTY OsmoMGW (4243) et bridge le RTP de CHAQUE appel vers
# alsa://gsm_out (= sink null PulseAudio gsm_audio). C'est ce maillon qui rend
# l'audio des appels "réseau" (ex: 600 = echo-test Asterisk via MGW) audible
# dans le dashboard web : server.js capte gsm_audio.monitor → /audio (MP3).
# Lancé en session tmux DÉTACHÉE 'gapk' : survit aux 'exec' (start-clean.sh /
# tmux attach) des modes qemu/hybride et poll jusqu'à ce que le MGW soit up.
# Idempotent (relance la session), non-fatal. AUDIO=0 → désactivé.
# Pont voix conteneur → hôte : parec(gsm_audio.monitor) | paplay(--server=relai).
# run.sh (no-process) tente ce pont AVANT que PulseAudio soit prêt (course →
# "PulseAudio injoignable après 30s" → pont jamais lancé → VOIX MUETTE dans docker).
# On le (re)lance ICI, après ensure_pulse (sink gsm_audio garanti up). Idempotent,
# gated sur HOST_AUDIO_RELAY (posé par start.sh = tcp:<gw>:4713).
ensure_host_audio() {
    local relay="${HOST_AUDIO_RELAY:-}"
    [ -n "$relay" ] || return 0
    if ! pactl --server="$relay" info >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[host-audio] relai ${relay} injoignable — pont voix non lancé${NC}"; return 0
    fi
    pkill -f "paplay --server=${relay}" 2>/dev/null || true          # idempotent
    [ -f /run/host-audio.pid ] && kill -- "-$(cat /run/host-audio.pid)" 2>/dev/null || true
    # parec lit le pulse LOCAL (gsm_audio.monitor) ; paplay pousse vers l'hôte.
    # --latency-msec : capture courte (30ms) + lecture TAMPONNÉE (250ms) pour
    # absorber la gigue (ordonnancement/TCP/2 horloges pulse) — sinon voix HACHÉE.
    setsid env PULSE_SERVER="unix:${PULSE_SOCK}" sh -c '
      while true; do
        parec -d gsm_audio.monitor --latency-msec=30 --format=s16le --rate=8000 --channels=1 \
          | paplay --server='"${relay}"' --latency-msec=250 --raw --format=s16le --rate=8000 --channels=1
        sleep 1
      done' >"${LOG_DIR}/host-audio.log" 2>&1 &
    echo $! > /run/host-audio.pid
    echo -e "  ${GREEN}[host-audio] pont voix parec|paplay → hôte (${relay})${NC}"
}

ensure_gapk() {
    [ "${AUDIO:-1}" = "1" ] || return 0
    command -v tmux      >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] tmux absent — bridge audio non lancé${NC}"; return 0; }
    command -v osmo-gapk >/dev/null 2>&1 || { echo -e "  ${YELLOW}[gapk] osmo-gapk absent — bridge audio non lancé${NC}"; return 0; }
    ensure_pulse   # gapk écrit dans alsa://gsm_out = sink gsm_audio (idempotent)
    local gapk_sh="/etc/osmocom/gapk-start.sh"; [ -x "$gapk_sh" ] || gapk_sh="$HERE/scripts/gapk-start.sh"
    [ -x "$gapk_sh" ] || { echo -e "  ${YELLOW}[gapk] gapk-start.sh introuvable — bridge audio non lancé${NC}"; return 0; }
    tmux kill-session -t gapk 2>/dev/null || true
    # [2026-08-10] Le format etait code en dur a « gsmfr », un nom qui n'existe
    # pas dans osmo-gapk : les deux process mouraient a l'analyse des arguments
    # (« Unsupported format: gsmfr ») et le pont n'a jamais rien transporte.
    # Le nom du GSM FR est « gsm ». Le 3e argument est le peripherique de
    # CAPTURE : il doit rester gsm_in (moniteur du null-sink gsm_mic). Le
    # pointer sur gsm_out rebranche la boucle fermee du 08/08 — les mobiles
    # ecrivent dans gsm_out, on les rejouerait dans leur propre uplink.
    tmux new-session -d -s gapk \
        "GAPK_ALSA_DEV=gsm_out GAPK_ALSA_DEV_IN=gsm_in PULSE_SERVER=unix:${PULSE_SOCK} bash '$gapk_sh' auto gsm gsm_out gsm_in 2>&1 | tee ${LOG_DIR}/gapk-auto.log"
    echo -e "  ${GREEN}[gapk] auto lancé (RTP MGW → sink gsm_audio) — tmux 'gapk', log ${LOG_DIR}/gapk-auto.log${NC}"
    ensure_host_audio   # (re)lance le pont voix → hôte maintenant que pulse+sink sont up
}

# ══════════════════════════════════════════════════════════════════════════
# Modes 1 opérateur (host loopback + enp0s3) : noproc/faketrx/virtphy/qemu/combiné
# ══════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════
# Mode HYBRIDE faketrx-qemu (Approche C) : 2 osmo-bts-trx, 1 cœur
#   BTS#0 = pipeline QEMU INTOUCHÉ (run.sh : osmo-trx-ipc 5700, ARFCN 514, Calypso)
#   BTS#1 = side-car : osmo-bts-trx (unit-id 6002, base-port 5820/5720) + fake_trx
#           (-P 5720 -p 6720) + trxcon + mobile osmocom-bb (ARFCN 516, IMSI ...0002)
#   Les 2 MS s'enregistrent sur le même osmo-bsc/MSC/HLR → appel intra-MSC.
#   1 BTS = 1 horloge (clk_s par process osmo-bts-trx) → pas de conflit d'horloge :
#   une seule osmo-bts-trx 2-PHY est IMPOSSIBLE (clk_s partagé, reset ping-pong),
#   d'où 2 process distincts. On NE TOUCHE NI qemu-src/run.sh NI osmo-bts-trx.cfg.
# ══════════════════════════════════════════════════════════════════════════
