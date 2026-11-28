#!/usr/bin/env bash
# Run the end-to-end tests: download KOReader's desktop Linux build (once),
# start it headless with this plugin installed, and call the plugin over MCP.
#
#   test/e2e/run.sh [--only epub|pdf] [--keep-running]
#
# Needs: bash, curl, tar with xz, python3, Xvfb (or an X display), and
# ImageMagick's `import` for screenshots (optional). Linux x86_64 only.
# Environment:
#   KOREADER_VERSION  KOReader release tag (default below)
#   E2E_WORK_DIR      scratch directory (default: .e2e in the repository)
#   RELAY_DIR         a koreader-mcp-cloud-relay checkout: also start it with
#                     `wrangler dev` (needs bun) and test through it
#   RELAY_URL         an already running relay to test through instead
set -euo pipefail

KOREADER_VERSION="${KOREADER_VERSION:-v2026.07.1}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${E2E_WORK_DIR:-$REPO/.e2e}"
KO_DIR="$WORK/koreader-$KOREADER_VERSION"
ASSET="koreader-linux-x86_64-$KOREADER_VERSION.tar.xz"

mkdir -p "$WORK"

if [ ! -x "$KO_DIR/lib/koreader/reader.lua" ]; then
    echo "Downloading KOReader $KOREADER_VERSION ($ASSET)"
    rm -rf "$KO_DIR" "$WORK/$ASSET"
    if command -v gh >/dev/null && [ -n "${GH_TOKEN:-}" ]; then
        gh release download "$KOREADER_VERSION" --repo koreader/koreader --pattern "$ASSET" --dir "$WORK" || {
            echo "Recent KOReader releases:"; gh release list --repo koreader/koreader -L 8
            gh release view --repo koreader/koreader --json tagName,assets --jq '.tagName, .assets[].name'
            exit 1
        }
    else
        curl -fL --retry 3 -o "$WORK/$ASSET" \
            "https://github.com/koreader/koreader/releases/download/$KOREADER_VERSION/$ASSET"
    fi
    mkdir -p "$KO_DIR"
    tar -xJf "$WORK/$ASSET" -C "$KO_DIR"
    rm -f "$WORK/$ASSET"
fi

XVFB_PID=""
RELAY_PID=""
cleanup() {
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
    true
}
trap cleanup EXIT
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"

# A local relay
if [ -n "${RELAY_DIR:-}" ] && [ -z "${RELAY_URL:-}" ]; then
    echo "Starting the relay from $RELAY_DIR"
    (cd "$RELAY_DIR" && bun install --frozen-lockfile >/dev/null)
    (cd "$RELAY_DIR" && WRANGLER_SEND_METRICS=false exec bunx wrangler dev --port 8787 --ip 127.0.0.1 \
        >"$WORK/relay.log" 2>&1) &
    RELAY_PID=$!
    for _ in $(seq 120); do
        curl -fs -o /dev/null http://127.0.0.1:8787/ && break
        sleep 0.5
    done
    curl -fs -o /dev/null http://127.0.0.1:8787/ || { echo "The relay did not start; see $WORK/relay.log"; exit 1; }
    RELAY_URL="http://127.0.0.1:8787"
fi

# A virtual display, unless there is a real one
if [ -z "${DISPLAY:-}" ]; then
    display=":$((90 + RANDOM % 100))"
    Xvfb "$display" -screen 0 758x1024x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB_PID=$!
    export DISPLAY="$display"
    sleep 1
fi

python3 "$REPO/test/e2e/e2e.py" --koreader "$KO_DIR/lib/koreader" --plugin "$REPO" --work "$WORK" \
    ${RELAY_URL:+--relay "$RELAY_URL"} "$@"
