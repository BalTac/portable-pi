#!/usr/bin/env bash
# portable-pi update launcher (Linux/macOS)
# Usage: ./update.sh            interactive: check, then choose components
#        ./update.sh --client   update pi only
#        ./update.sh --ext      update extensions + skills only
#        ./update.sh --all      update everything in one pass
set -euo pipefail

USB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(find "$USB/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1)"
[ -n "$NODE_DIR" ] || { echo "ERROR: Node.js not found in $USB/bin/linux (rebuild the drive)" >&2; exit 1; }
NODE_EXE="$NODE_DIR/bin/node"
if [ ! -x "$NODE_EXE" ]; then
    echo "ERROR: $NODE_EXE is not executable." >&2
    echo "exFAT mount without exec bit: remount with umask=000 (see docs)." >&2
    exit 1
fi

# ── isolation: the same env start.sh sets, so nothing lands on the host ──
export PATH="$NODE_DIR/bin:$USB/tools/bin:$PATH"
export PI_CODING_AGENT_DIR="$USB/config/pi"
export PI_CODING_AGENT_SESSION_DIR="$USB/config/pi/sessions"
export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0
export TMPDIR="$USB/temp" TMP="$USB/temp" TEMP="$USB/temp"
export NPM_CONFIG_CACHE="$USB/temp/npm-cache"
export NODE_COMPILE_CACHE="$USB/temp/node-cache"
export XDG_CACHE_HOME="$USB/temp/cache"
# exFAT has no ownership: keep git's exception in the environment
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
mkdir -p "$USB/temp/npm-cache"
[ -f "$USB/config/env.sh" ] && . "$USB/config/env.sh"

echo
echo " ======================================================"
echo "  portable-pi update"
echo " ======================================================"
RC=0
"$NODE_EXE" "$USB/scripts/check-updates.mjs" --drive "$USB" --node --json "$USB/temp/update-plan.json" || RC=$?
if [ "$RC" = 3 ]; then
    echo
    echo " Rete non raggiungibile: impossibile controllare gli aggiornamenti." >&2
    exit 1
fi
if ! "$NODE_EXE" -e 'const p=require(process.argv[1]);process.exit(p.anyUpdate?0:1)' "$USB/temp/update-plan.json"; then
    echo " Niente da aggiornare. Esco senza toccare il drive."
    exit 0
fi

COMP=""
case "${1:-}" in
    --client) COMP=client ;;
    --ext|--extensions) COMP=extensions ;;
    --all) COMP=all ;;
esac

if [ -z "$COMP" ]; then
    echo
    echo "  [1] client      aggiorna pi (e Node, se lo chiedi)"
    echo "  [2] estensioni  aggiorna pacchetti vendorizzati + skill"
    echo "  [3] tutto       client + estensioni in una passata"
    echo "  [0] esci"
    echo
    printf "  Scelta: "
    read -r SCELTA || SCELTA=0
    case "$SCELTA" in
        1) COMP=client ;;
        2) COMP=extensions ;;
        3) COMP=all ;;
        *) echo "  Nessuna modifica."; exit 0 ;;
    esac
fi

EXTRA=()
if [ "$COMP" = client ] || [ "$COMP" = all ]; then
    printf "  Aggiornare anche Node LTS? [S/n] "
    read -r ANS || ANS=s
    case "$ANS" in [nN]*) ;; *) EXTRA+=(--node latest) ;; esac
fi

echo
RC=0
bash "$USB/scripts/update.sh" --drive "$USB" --components "$COMP" --yes "${EXTRA[@]+"${EXTRA[@]}"}" || RC=$?
echo
if [ "$RC" != 0 ]; then
    echo "Aggiornamento NON riuscito (codice $RC). Rilancia questo launcher" >&2
    echo "oppure scripts/verify.sh per vedere cosa manca." >&2
    exit "$RC"
fi
echo " Fatto. Avvio normale: ./start.sh"
