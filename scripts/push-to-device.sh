#!/bin/sh
# Copy this checkout of the plugin to an e-reader over KOReader's SSH server.
#
# On the reader: Settings > Network > SSH server (port 2222). Add your public
# key to koreader/settings/SSH/authorized_keys, or allow login without a
# password while testing. Afterwards restart KOReader (Menu > Exit > Restart
# KOReader) so the new code loads.
#
# Usage: scripts/push-to-device.sh <reader-ip> [koreader-dir]
#   koreader-dir defaults to the first that exists of
#   /mnt/onboard/.adds/koreader (Kobo), /mnt/us/koreader (Kindle),
#   /sdcard/koreader (Android), /mnt/ext1/applications/koreader (PocketBook)
# Environment: SSH_PORT (default 2222), SSH_USER (default root)
set -eu

if [ $# -lt 1 ]; then
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

host=$1
port=${SSH_PORT:-2222}
user=${SSH_USER:-root}
repo=$(cd "$(dirname "$0")/.." && pwd)

ssh_cmd() {
    ssh -p "$port" -o ConnectTimeout=10 "$user@$host" "$@"
}

if [ $# -ge 2 ]; then
    koreader=$2
else
    koreader=$(ssh_cmd 'for d in /mnt/onboard/.adds/koreader /mnt/us/koreader /sdcard/koreader /mnt/ext1/applications/koreader; do
        [ -d "$d/plugins" ] && { echo "$d"; exit 0; }; done; exit 1') || {
        echo "Could not find KOReader on the device; pass its directory as the second argument." >&2
        exit 1
    }
fi
target="$koreader/plugins/mcp.koplugin"

# Only the plugin's own files: tracked .lua files at the top level
files=$(cd "$repo" && git ls-files -- '*.lua' | grep -v /)
[ -n "$files" ] || { echo "No plugin files found in $repo" >&2; exit 1; }

echo "Copying to $user@$host:$target"
# shellcheck disable=SC2086
(cd "$repo" && tar -cf - $files) | ssh_cmd "mkdir -p '$target' && tar -C '$target' -xf -"

branch=$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
commit=$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "Installed $branch @ $commit. Restart KOReader on the device: Menu > Exit > Restart KOReader."
