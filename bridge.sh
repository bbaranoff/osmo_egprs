#!/usr/bin/env bash

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

# ── Attente BB VTY ───────────────────────────────────────────────────────────
wait_bb_vty() {
    local container="$1"
    local timeout=120
    local elapsed=0

    echo -ne "  Attente BB VTY 4247 "

    while ! docker exec "$container" bash -c \
        "echo >/dev/tcp/127.0.0.1/4247" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."

        if [ "$elapsed" -ge "$timeout" ]; then
            echo -e " ${RED}TIMEOUT${NC}"
            echo "Verifier : docker logs $container"
            return 1
        fi
    done

    echo -e " ${GREEN}OK${NC}"
}

# ── Bridge principal ──────────────────────────────────────────────────────────
bridge_attach() {
    local container="$1"

    echo ""
    echo "=== $container ==="

    wait_bb_vty "$container" || exit 1

    echo ""
    echo "Attachement tmux..."
    exec sudo docker exec -ti "$container" tmux attach
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    echo "Usage: $0 <container>"
    exit 1
fi

CONTAINER="$1"

bridge_attach "$CONTAINER"
