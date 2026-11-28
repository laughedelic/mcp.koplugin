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
set -euo pipefail

KOREADER_VERSION="${KOREADER_VERSION:-v2026.07.2}"
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

# A virtual display, unless there is a real one
XVFB_PID=""
cleanup() { [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ -z "${DISPLAY:-}" ]; then
    display=":$((90 + RANDOM % 100))"
    Xvfb "$display" -screen 0 758x1024x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB_PID=$!
    export DISPLAY="$display"
    sleep 1
fi

exec python3 "$REPO/test/e2e/e2e.py" --koreader "$KO_DIR/lib/koreader" --plugin "$REPO" --work "$WORK" "$@"
