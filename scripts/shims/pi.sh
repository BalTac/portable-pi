#!/bin/sh
# portable-pi shim: runs the bundled pi with the portable Node runtime.
# Self-contained on purpose: works even when invoked outside start.sh.
set -eu

self=$0
case $self in
  */*) ;;
  *) self=$(command -v -- "$self" 2>/dev/null || echo "$self") ;;
esac
bin_dir=$(cd -- "$(dirname -- "$self")" && pwd)
usb=$(cd -- "$bin_dir/../.." && pwd)

node_dir=$(find "$usb/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1)
if [ -z "${node_dir:-}" ]; then
  echo "portable-pi: Node.js not found in $usb/bin/linux (run the build first)" >&2
  exit 1
fi

export PI_CODING_AGENT_DIR=${PI_CODING_AGENT_DIR:-$usb/config/pi}
export PI_CODING_AGENT_SESSION_DIR=${PI_CODING_AGENT_SESSION_DIR:-$usb/config/pi/sessions}
export PI_SKIP_VERSION_CHECK=${PI_SKIP_VERSION_CHECK:-1}
export PI_TELEMETRY=${PI_TELEMETRY:-0}
export TMPDIR=${TMPDIR:-$usb/temp}
export TMP=${TMP:-$usb/temp}
export TEMP=${TEMP:-$usb/temp}
export NPM_CONFIG_CACHE=${NPM_CONFIG_CACHE:-$usb/temp/npm-cache}
export NODE_COMPILE_CACHE=${NODE_COMPILE_CACHE:-$usb/temp/node-cache}
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-$usb/temp/cache}

if [ -f "$usb/tools/bin/fix-paths.js" ]; then
  "$node_dir/bin/node" "$usb/tools/bin/fix-paths.js" "$usb" --quiet 2>/dev/null || true
fi

skills_dir="$usb/config/pi/skills"
cli="$usb/tools/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"

if [ -d "$skills_dir" ]; then
  exec "$node_dir/bin/node" "$cli" -ns --skill "$skills_dir" "$@"
fi
exec "$node_dir/bin/node" "$cli" -ns "$@"
