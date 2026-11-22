#!/usr/bin/env bash
# Aggiorna una chiavetta portable-pi esistente (lato Linux).
#
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh --pi latest
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh --node latest --skip-skills
#
# Rinfresca il runtime di pi (e opzionalmente Node) e le skill whitelist.
# Non tocca MAI auth.json, sessions/, settings.json, models.json
# e le skill che hai aggiunto tu al drive.
set -euo pipefail

DRIVE=""
PI_VERSION=""
NODE_VERSION=""
SKIP_SKILLS=0
NO_VERIFY=0
FORCE_PI=0

while [ $# -gt 0 ]; do
    case "$1" in
        --drive) DRIVE="${2:-}"; shift ;;
        --pi) PI_VERSION="${2:-}"; shift ;;
        --node) NODE_VERSION="${2:-}"; shift ;;
        --skip-skills) SKIP_SKILLS=1 ;;
        --no-verify) NO_VERIFY=1 ;;
        --force-pi) FORCE_PI=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        -*) echo "opzione sconosciuta: $1" >&2; exit 2 ;;
        *) DRIVE="$1" ;;
    esac
    shift
done

[ -n "$DRIVE" ] || DRIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$(cd "$DRIVE" && pwd)"
MANIFEST="$DRIVE/manifest.json"
[ -f "$MANIFEST" ] || { echo "manifest.json non trovato sul drive: $MANIFEST" >&2; exit 1; }

# use the drive's own node: no host dependency
NODE_BIN="$(find "$DRIVE/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1)"
NODE_EXE="$NODE_BIN/bin/node"
if [ ! -x "$NODE_EXE" ]; then
    NODE_EXE="$(command -v node || true)"
fi
[ -n "$NODE_EXE" ] || { echo "nessun node utilizzabile (drive non eseguibile? monta con umask=000)" >&2; exit 1; }

jget() { "$NODE_EXE" -e 'const m=require(process.argv[1]);console.log(eval(process.argv[2]))' "$MANIFEST" "$1"; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

step() { printf '==> %s\n' "$*"; }
ok()   { printf '    %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }

download() { curl -fsSL --retry 3 --connect-timeout 20 --progress-bar -o "$2" "$1"; }
extract() { mkdir -p "$2"; case "$1" in *.zip) unzip -q "$1" -d "$2" ;; *) tar -xf "$1" -C "$2" ;; esac; }
npm_url() {
    "$NODE_EXE" -e '
      const [name, v] = process.argv.slice(1);
      const base = name.startsWith("@") ? name.split("/")[1] : name;
      const scope = name.startsWith("@") ? encodeURIComponent(name) : name;
      console.log(`https://registry.npmjs.org/${scope}/-/${base}-${v}.tgz`);
    ' "$1" "$2"
}
# FAT/exFAT cannot hold symlinks: replace them with real files
deref_links() {
    find "$1" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
        target="$(readlink -f "$link" 2>/dev/null || true)"
        rm -f "$link"
        [ -n "$target" ] && [ -e "$target" ] && cp -RL "$target" "$link"
    done
}

step "Update portable-pi at $DRIVE"

# ── pi ──────────────────────────────────────────────────────────────────
[ -n "$PI_VERSION" ] || PI_VERSION="$(jget 'm.pi.version')"
if [ "$PI_VERSION" = "latest" ]; then
    PI_VERSION="$("$NODE_EXE" -e 'fetch("https://registry.npmjs.org/@earendil-works%2fpi-coding-agent/latest").then(r=>r.json()).then(j=>console.log(j.version))')"
    ok "registry: pi $PI_VERSION"
fi

RUNTIME_NM="$DRIVE/$(jget 'm.paths.runtimeDir')/node_modules"
INSTALLED="$(jget 'm.pi.version')"

if [ "$FORCE_PI" = 0 ] && [ "$PI_VERSION" = "$INSTALLED" ]; then
    step "pi $INSTALLED già aggiornato (usa --force-pi per reinstallare)"
else
    step "pi: $INSTALLED -> $PI_VERSION"
    COUNT="$(jget 'm.pi.runtimePackages.length')"
    i=0
    while [ "$i" -lt "$COUNT" ]; do
        NAME="$(jget "m.pi.runtimePackages[$i].name")"
        VERSION="$(jget "m.pi.runtimePackages[$i].version")"
        [ "$NAME" = "@earendil-works/pi-coding-agent" ] && VERSION="$PI_VERSION"
        DEST="$RUNTIME_NM/$NAME"
        ok "scarico $NAME@$VERSION"
        download "$(npm_url "$NAME" "$VERSION")" "$STAGING/pkg.tgz"
        rm -rf "$STAGING/pkg"; extract "$STAGING/pkg.tgz" "$STAGING/pkg"
        deref_links "$STAGING/pkg"
        NEW="$DEST.new"
        rm -rf "$NEW"; mkdir -p "$NEW"
        KEEP_COUNT="$(jget "m.pi.runtimePackages[$i].keep.length")"
        k=0
        while [ "$k" -lt "$KEEP_COUNT" ]; do
            ENTRY="$(jget "m.pi.runtimePackages[$i].keep[$k]")"
            if [ "$ENTRY" = "*" ]; then cp -R "$STAGING/pkg/package/." "$NEW/"
            else mkdir -p "$NEW/$(dirname "$ENTRY")"; cp -R "$STAGING/pkg/package/$ENTRY" "$NEW/$ENTRY"; fi
            k=$((k + 1))
        done
        rm -rf "$DEST"; mv "$NEW" "$DEST"
        ok "$NAME $VERSION ($(find "$DEST" -type f | wc -l | tr -d ' ') file)"
        i=$((i + 1))
    done

    CLI="$RUNTIME_NM/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
    OUT="$(PI_CODING_AGENT_DIR="$DRIVE/$(jget 'm.paths.agentDir')" PI_SKIP_VERSION_CHECK=1 "$NODE_EXE" "$CLI" --version)"
    case "$OUT" in *[0-9].[0-9].[0-9]*) ok "pi ora risponde: $OUT" ;; *) echo "pi --version non risponde: $OUT" >&2; exit 1 ;; esac
    "$NODE_EXE" -e '
      const fs=require("fs");const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,"utf8"));
      m.pi.version=process.argv[2];m.pi.runtimePackages[0].version=process.argv[2];
      fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
    ' "$MANIFEST" "$PI_VERSION"
fi

# ── node (opzionale) ────────────────────────────────────────────────────
if [ -n "$NODE_VERSION" ]; then
    if [ "$NODE_VERSION" = "latest" ]; then
        NODE_VERSION="$("$NODE_EXE" -e 'fetch("https://nodejs.org/dist/index.json").then(r=>r.json()).then(a=>{const l=a.find(x=>x.lts&&x.version.startsWith("v24."));console.log(l.version.slice(1))})')"
        ok "LTS: node $NODE_VERSION"
    fi
    CURRENT="$(jget 'm.node.version')"
    if [ "$NODE_VERSION" != "$CURRENT" ]; then
        step "node: $CURRENT -> $NODE_VERSION"
        download "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" "$STAGING/sums.txt"
        i=0; COUNT="$(jget 'm.node.targets.length')"
        while [ "$i" -lt "$COUNT" ]; do
            ARCHIVE="$("$NODE_EXE" -e 'const m=require(process.argv[1]);console.log(m.node.targets[+process.argv[2]].archive.split("{version}").join(process.argv[3]))' "$MANIFEST" "$i" "$NODE_VERSION")"
            URL="$("$NODE_EXE" -e 'const m=require(process.argv[1]);console.log(m.node.targets[+process.argv[2]].url.split("{version}").join(process.argv[3]))' "$MANIFEST" "$i" "$NODE_VERSION")"
            INSTALL_REL="$("$NODE_EXE" -e 'const m=require(process.argv[1]);console.log(m.node.targets[+process.argv[2]].installDir.split("{version}").join(process.argv[3]))' "$MANIFEST" "$i" "$NODE_VERSION")"
            ok "scarico $ARCHIVE"
            download "$URL" "$STAGING/$ARCHIVE"
            EXPECTED="$(grep -E "[[:space:]]$ARCHIVE\$" "$STAGING/sums.txt" | awk '{print $1}')"
            ACTUAL="$(sha256sum "$STAGING/$ARCHIVE" | awk '{print $1}')"
            [ "$ACTUAL" = "$EXPECTED" ] || { echo "checksum mismatch: $ARCHIVE" >&2; exit 1; }
            rm -rf "$STAGING/x"; extract "$STAGING/$ARCHIVE" "$STAGING/x"; deref_links "$STAGING/x"
            TOP="$(find "$STAGING/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
            DEST="$DRIVE/$INSTALL_REL"
            rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"; mv "$TOP" "$DEST"
            # npm/npx/corepack: sh wrappers instead of symlinks
            for pair in "npm:npm-cli.js:../lib/node_modules/npm/bin" "npx:npx-cli.js:../lib/node_modules/npm/bin" "corepack:corepack.js:../lib/node_modules/corepack/dist"; do
                n="${pair%%:*}"; rest="${pair#*:}"; js="${rest%%:*}"; dir="${rest#*:}"
                rm -f "$DEST/bin/$n"
                printf '#!/bin/sh\nself=$0\ncase $self in */*) ;; *) self=$(command -v -- "$self" 2>/dev/null || echo "$self") ;; esac\nbasedir=$(cd -- "$(dirname -- "$self")" && pwd)\nexec "$basedir/node" "$basedir/%s/%s" "$@"\n' "$dir" "$js" > "$DEST/bin/$n"
                chmod +x "$DEST/bin/$n" 2>/dev/null || true
            done
            ok "installato $(basename "$DEST")"
            i=$((i + 1))
        done
        "$NODE_EXE" -e 'const fs=require("fs");const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,"utf8"));m.node.version=process.argv[2];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");' "$MANIFEST" "$NODE_VERSION"
    else
        step "node $NODE_VERSION già presente"
    fi
fi

# ── skills (solo se le sorgenti di questo PC esistono) ──────────────────
if [ "$SKIP_SKILLS" = 0 ]; then
    MISSING=""
    COUNT="$(jget 'm.skills.include.length')"
    i=0
    while [ "$i" -lt "$COUNT" ]; do
        NAME="$(jget "m.skills.include[$i].name")"
        ROOT="$(jget "m.skills.include[$i].root")"
        REL="$(jget "m.skills.include[$i].path")"
        case "$ROOT" in
            agent)  SRC="$HOME/.pi/agent/$REL" ;;
            agents) SRC="$HOME/.agents/$REL" ;;
            npm)    SRC="$HOME/.pi/agent/npm/node_modules/$REL" ;;
        esac
        [ -f "$SRC/SKILL.md" ] || MISSING="$MISSING $NAME"
        i=$((i + 1))
    done

    if [ -z "$MISSING" ]; then
        step "Aggiorno $COUNT skill dalla whitelist"
        SKILLS_DIR="$DRIVE/$(jget 'm.paths.skillsDir')"
        i=0
        while [ "$i" -lt "$COUNT" ]; do
            NAME="$(jget "m.skills.include[$i].name")"
            ROOT="$(jget "m.skills.include[$i].root")"
            REL="$(jget "m.skills.include[$i].path")"
            case "$ROOT" in
                agent)  SRC="$HOME/.pi/agent/$REL" ;;
                agents) SRC="$HOME/.agents/$REL" ;;
                npm)    SRC="$HOME/.pi/agent/npm/node_modules/$REL" ;;
            esac
            rm -rf "$SKILLS_DIR/$NAME"
            cp -R "$SRC" "$SKILLS_DIR/$NAME"
            ok "$NAME"
            i=$((i + 1))
        done
    else
        warn "sorgenti non disponibili su questa macchina:$MISSING — skill lasciate invariate"
        warn "le skill che hai aggiunto tu al drive restano intatte"
    fi
fi

if [ "$NO_VERIFY" = 0 ] && [ -f "$DRIVE/scripts/verify.sh" ]; then
    step "Collaudo (senza chiamata al modello)"
    bash "$DRIVE/scripts/verify.sh" "$DRIVE" --no-model || { echo "verify ha segnalato errori" >&2; exit 1; }
fi

sync 2>/dev/null || true
echo
echo "Aggiornamento completato."
echo "Verifica completa con modello:  bash $DRIVE/scripts/verify.sh $DRIVE"
