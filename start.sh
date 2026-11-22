#!/usr/bin/env bash
# portable-pi launcher (Linux)
# Usage: bash start.sh [--shell] [pi args...]
set -euo pipefail

USB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_DIR="$(find "$USB/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1 || true)"
if [ -z "${NODE_DIR:-}" ]; then
    echo "ERROR: Node.js not found in $USB/bin/linux"
    echo "Run scripts/build.sh on this drive first."
    exit 1
fi

NODE="$NODE_DIR/bin/node"
if [ ! -x "$NODE" ]; then
    echo "ERROR: $NODE is not executable."
    echo
    echo "exFAT carries no POSIX permission bits, so some distros mount the drive"
    echo "as 0644. Remount it with exec permission and retry:"
    echo
    echo "  sudo umount '$USB' && sudo mount -o remount,umask=000 '$USB'"
    echo "  # or, permanently, in /etc/fstab:"
    echo "  LABEL=PORTABLE-PI /media/\$USER/PORTABLE-PI exfat defaults,uid=\$(id -u),umask=000 0 0"
    exit 1
fi

# ── portable toolchain ───────────────────────────────────────────────
export PATH="$NODE_DIR/bin:$USB/tools/bin:$PATH"
if [ -d "$USB/tools/git/mingit/usr/bin" ] || [ -d "$USB/tools/git/portablegit/usr/bin" ]; then
    GITDIR="$USB/tools/git/mingit"
    [ -d "$GITDIR" ] || GITDIR="$USB/tools/git/portablegit"
    export PATH="$GITDIR/usr/bin:$GITDIR/ucrt64/bin:$GITDIR/cmd:$GITDIR/bin:$PATH"
fi

# ── agent dir: everything stays on the drive ─────────────────────────
export PI_CODING_AGENT_DIR="$USB/config/pi"
export PI_CODING_AGENT_SESSION_DIR="$USB/config/pi/sessions"
# llm-wiki: the personal vault lives on the drive, never in the host's ~/.llm-wiki
export WIKI_HOME="$USB/workspace"
# exFAT has no ownership: git refuses a repo it does not own. Keep the exception
# in the environment instead of writing to the host's ~/.gitconfig.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0

# ── no traces: temp/cache on the drive ───────────────────────────────
export TMPDIR="$USB/temp"
export TMP="$USB/temp"
export TEMP="$USB/temp"
export NPM_CONFIG_CACHE="$USB/temp/npm-cache"
export NODE_COMPILE_CACHE="$USB/temp/node-cache"
export XDG_CACHE_HOME="$USB/temp/cache"
mkdir -p "$USB/temp/npm-cache" "$USB/temp/node-cache" "$USB/temp/cache" "$USB/config/pi/sessions"

# ── optional API keys ────────────────────────────────────────────────
if [ -f "$USB/config/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$USB/config/env.sh"
fi

# ── self-heal: the drive may be mounted at a different path than at build time ──
if [ -f "$USB/tools/bin/fix-paths.js" ]; then
    "$NODE_DIR/bin/node" "$USB/tools/bin/fix-paths.js" "$USB" --quiet || true
fi

# ── shell-only mode ──────────────────────────────────────────────────
if [ "${1:-}" = "--shell" ]; then
    shift
    echo ""
    echo " ======================================================"
    echo "  portable-pi shell"
    echo " ======================================================"
    echo "  pi       the agent (skills mounted from the drive)"
    echo "  node     $(node --version)"
    if command -v git >/dev/null 2>&1; then echo "  git      $(git --version)"; fi
    echo "  exit     to close"
    echo " ======================================================"
    echo ""
    cd "$USB/workspace" 2>/dev/null || cd "$HOME"
    exec bash --norc --noprofile -i
fi

cd "$USB/workspace" 2>/dev/null || cd "$HOME"
exec sh "$USB/tools/bin/pi" "$@"
