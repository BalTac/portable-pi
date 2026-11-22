#!/usr/bin/env bash
# Verify isolation and integrity of a portable-pi drive. Linux/macOS side.
#
#   bash scripts/verify.sh /media/$USER/PORTABLE-PI
#   bash scripts/verify.sh /tmp/usb-sim --no-model
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# prefer the manifest shipped on the drive: it records the effective skill list
MANIFEST="$DRIVE/manifest.json"
[ -f "$MANIFEST" ] || MANIFEST="$REPO/manifest.json"
DRIVE=""
NO_MODEL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-model) NO_MODEL=1 ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) DRIVE="$1" ;;
    esac
    shift
done

[ -n "$DRIVE" ] || { echo "usage: bash scripts/verify.sh /path/to/drive [--no-model]" >&2; exit 2; }
[ -d "$DRIVE" ] || { echo "drive not found: $DRIVE" >&2; exit 1; }
DRIVE="$(cd "$DRIVE" && pwd)"
command -v node >/dev/null || { echo "node required to read manifest.json" >&2; exit 1; }

jget() { node -e 'const m=require(process.argv[1]);console.log(eval(process.argv[2]))' "$MANIFEST" "$1"; }

AGENT_DIR="$DRIVE/$(jget 'm.paths.agentDir')"
SKILLS_DIR="$DRIVE/$(jget 'm.paths.skillsDir')"
FAIL=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n== %s\n' "$*"; }

# A Windows shell can read the drive but cannot execute the Linux node payload.
WIN_SHELL=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN_SHELL=1 ;; esac

# ── 1. layout ───────────────────────────────────────────────────────────
head_ "Layout"
NODE_DIR=$(find "$DRIVE/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1)
CLI="$DRIVE/$(jget 'm.paths.runtimeDir')/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
if [ -n "$NODE_DIR" ] && [ -f "$NODE_DIR/bin/node" ]; then
    if [ "$WIN_SHELL" = 1 ]; then pass "node linux-x64 present ($(basename "$NODE_DIR")) - exec bit not testable from Windows"
    elif [ -x "$NODE_DIR/bin/node" ]; then pass "node linux-x64: $(basename "$NODE_DIR")"
    else fail "node linux-x64 not executable (exFAT mount without exec bit?)"; fi
else fail "node linux-x64 missing"; fi
[ -x "$DRIVE/bin/win/$(cd "$DRIVE/bin/win" 2>/dev/null && ls -d node-v*-win-x64 | head -1)/node.exe" ] && pass "node win-x64" || fail "node win-x64 missing"
[ -f "$CLI" ] && pass "pi entrypoint" || fail "pi entrypoint missing"
for f in auth.json settings.json AGENTS.md; do
    [ -f "$AGENT_DIR/$f" ] && pass "config/$f" || fail "config/$f missing"
done
[ -f "$DRIVE/start.sh" ] && pass "start.sh" || fail "start.sh missing"
[ -f "$DRIVE/start.bat" ] && pass "start.bat" || fail "start.bat missing"

# ── 1b. drive root record ───────────────────────────────────────────────
head_ "Drive root"
ROOT_FILE="$DRIVE/config/drive-root.txt"
ROOT_RECORD=""
[ -f "$ROOT_FILE" ] && ROOT_RECORD="$(tr -d '\r\n' < "$ROOT_FILE")"
CURRENT_ROOT="$DRIVE/"
if [ -z "$ROOT_RECORD" ]; then fail "config/drive-root.txt missing (rebuild the drive)"
elif [ "$ROOT_RECORD" != "$CURRENT_ROOT" ] && [ "$ROOT_RECORD" != "${CURRENT_ROOT%/}" ]; then
    fail "recorded root '$ROOT_RECORD' != current '$CURRENT_ROOT' - run start.sh once to self-heal"
else pass "recorded root matches the current one: $CURRENT_ROOT"; fi

# ── 2. skills whitelist ─────────────────────────────────────────────────
head_ "Skills whitelist"
EXPECTED="$(jget 'm.skills.include.map(s=>s.name).concat(m.packageSkills||[]).join(" ")')"
PRESENT="$(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md -printf '%h\n' 2>/dev/null | xargs -r -n1 basename | sort)"
for n in $EXPECTED; do
    printf '%s\n' "$PRESENT" | grep -qx "$n" && pass "$n" || fail "$n missing on the drive"
done
EXTRA="$(comm -13 <(printf '%s\n' $EXPECTED | sort) <(printf '%s\n' "$PRESENT"))"
[ -z "$EXTRA" ] && pass "no unexpected skills" || fail "unexpected skills: $EXTRA"

# ── 3. no host references in shipped config/skills ──────────────────────
head_ "No host-specific references"
LEAKS="$(grep -rlE '[A-Za-z]:\\Users\\|/mnt/[a-z]/|/home/[a-z]|192\.168\.' "$AGENT_DIR" "$SKILLS_DIR" \
    --include='*.json' --include='*.md' --exclude=auth.json --exclude=models-store.json \
    --exclude-dir=packages 2>/dev/null || true)"
[ -z "$LEAKS" ] && pass "no host paths or LAN endpoints" || fail "host references in: $LEAKS"

# ── 3b. vendored packages, no SearXNG, vault on the drive ───────────────
head_ "Third-party packages"
PKG_ROOT="$AGENT_DIR/packages/node_modules"
PKG_COUNT="$(jget '(m.packages||[]).length')"
if [ "$PKG_COUNT" != "0" ]; then
    i=0
    while [ "$i" -lt "$PKG_COUNT" ]; do
        NAME="$(jget "m.packages[$i].name")"
        WANT="$(jget "m.packages[$i].version")"
        if [ -f "$PKG_ROOT/$NAME/package.json" ]; then
            HAVE="$(node -e 'console.log(require(process.argv[1]).version)' "$PKG_ROOT/$NAME/package.json")"
            [ "$HAVE" = "$WANT" ] && pass "$NAME@$HAVE" || fail "$NAME version mismatch: drive $HAVE, manifest $WANT"
        else fail "$NAME missing under config/pi/packages"; fi
        grep -qF "./packages/node_modules/$NAME" "$AGENT_DIR/settings.json" 2>/dev/null \
            || fail "settings.json does not declare ./packages/node_modules/$NAME"
        i=$((i + 1))
    done
    if grep -qiE 'searxng|192\.168\.' "$AGENT_DIR/settings.json" "$AGENT_DIR/web-search.json" 2>/dev/null; then
        fail "web-search/settings reference SearXNG or a LAN address"
    else pass "web-search.json without SearXNG/LAN"; fi
fi
NEEDS_HOST="$(jget '(m.packages||[]).some(p=>p.requiresHostSdk)?"1":"0"')"
if [ "$NEEDS_HOST" = "1" ]; then
    RTNM="$DRIVE/$(jget 'm.paths.runtimeDir')/node_modules"
    for rel in @earendil-works/pi-coding-agent/dist/index.js @earendil-works/pi-agent-core/package.json @earendil-works/pi-ai/package.json typebox/package.json; do
        if [ -f "$RTNM/$rel" ] || [ -f "$RTNM/@earendil-works/pi-coding-agent/node_modules/$rel" ]; then
            pass "host SDK: $rel"
        else fail "host SDK missing for child processes: tools/pi/node_modules/$rel"; fi
    done
fi
[ -d "$DRIVE/workspace" ] && pass "workspace present (WIKI_HOME)" || fail "workspace missing (llm-wiki vault home)"

# ── 4. host baseline ────────────────────────────────────────────────────
head_ "Host isolation"
WATCH="$HOME/.pi/agent/skills $HOME/.pi/agent/npm $HOME/.pi/agent/extensions $HOME/.pi/agent/settings.json $HOME/.pi/agent/auth.json $HOME/.pi/agent/AGENTS.md $HOME/.agents/skills"
snapshot() {
    for p in $WATCH; do
        [ -e "$p" ] || continue
        find "$p" -type f -printf '%p|%s|%T@\n' 2>/dev/null
    done | sort
}
BEFORE="$(snapshot)"

# ── 5. launcher smoke ───────────────────────────────────────────────────
head_ "Launcher"
if [ "$WIN_SHELL" = 1 ]; then
    pass "SKIP start.sh (Windows shell: use scripts/verify.ps1)"
else
    LAUNCH="$(cd "$DRIVE" && bash start.sh --version 2>&1 | tail -3)"
    case "$LAUNCH" in
        *[0-9].[0-9].[0-9]*) pass "start.sh --version -> $(printf '%s' "$LAUNCH" | tr '\n' ' ')" ;;
        *) fail "start.sh --version failed: $LAUNCH" ;;
    esac
fi

# ── 6. live turn ────────────────────────────────────────────────────────
if [ "$NO_MODEL" = 0 ]; then
    head_ "Live turn (model call)"
    VISIBLE=""
    for n in $EXPECTED; do
        grep -qs 'disable-model-invocation: true' "$SKILLS_DIR/$n/SKILL.md" || VISIBLE="$VISIBLE $n"
    done

    if [ "$WIN_SHELL" = 1 ]; then
        RUN_NODE="$(command -v node)"
        pass "runtime: host node (the drive payload is Linux-only)"
    else
        RUN_NODE="$NODE_DIR/bin/node"
    fi

    TESTDIR="$(mktemp -d)"
    MARKER="$(mktemp)"
    REPLY="$(cd "$TESTDIR" && PI_CODING_AGENT_DIR="$AGENT_DIR" \
        PI_CODING_AGENT_SESSION_DIR="$AGENT_DIR/sessions" \
        PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 \
        "$RUN_NODE" "$CLI" -ns --skill "$SKILLS_DIR" \
        -p "Answer with exactly two lines and nothing else.
MARK: PORTABLE-VERIFY-OK
SKILLS: <comma separated names of the skills available to you>" 2>&1 || true)"
    rm -rf "$TESTDIR"

    case "$REPLY" in *PORTABLE-VERIFY-OK*) pass "model replied (marker present)" ;;
        *) fail "model reply unexpected: $REPLY" ;; esac

    MISSING=""
    for n in $VISIBLE; do
        printf '%s' "$REPLY" | grep -q -- "$n" || MISSING="$MISSING $n"
    done
    [ -z "$MISSING" ] && pass "all $(printf '%s\n' $VISIBLE | wc -l | tr -d ' ') model-visible drive skills reported" \
        || fail "skills not reported: $MISSING"

    LEAKED=""
    # package-provided skills are excluded as *standalone* copies but are legitimately visible
    for n in $(jget 'm.skills.exclude.map(s=>s.name).filter(n=>!(m.packageSkills||[]).includes(n)).join(" ")'); do
        printf '%s' "$REPLY" | grep -qE "(^|[[:space:],])$n($|[[:space:],.])" && LEAKED="$LEAKED $n"
    done
    [ -z "$LEAKED" ] && pass "no host/discovered skill leaked in" || fail "leaked skills: $LEAKED"

    head_ "Session isolation"
    SESS="$(find "$AGENT_DIR/sessions" -name '*.jsonl' -newer "$MARKER" 2>/dev/null | head -1)"
    rm -f "$MARKER"
    [ -n "$SESS" ] && pass "session written on the drive: $(basename "$SESS")" || fail "no session file under $AGENT_DIR/sessions"
else
    head_ "Live turn"
    printf '  SKIP  --no-model\n'
fi

# ── 7. host untouched ───────────────────────────────────────────────────
head_ "Host config unchanged after the run"
AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then pass "host skills/npm/extensions/settings/auth untouched"
else fail "host config changed: $(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -5)"; fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "VERIFY: PASS"
    exit 0
fi
echo "VERIFY: $FAIL FAILURE(S)"
exit 1
