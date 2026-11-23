#!/usr/bin/env bash
# Update an existing portable-pi drive (Linux/macOS side).
#
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh --check
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh --components extensions --yes
#   bash /media/$USER/PORTABLE-PI/scripts/update.sh --pi latest --node latest
#
# Components: client (pi + optional Node), extensions (vendored packages + skills),
# all. Never touches auth.json, sessions/, settings.json, models.json or skills you
# added to the drive yourself. Packages are installed at the latest registry version
# into the host temp, then vendored onto the drive (nothing is installed globally).
set -euo pipefail

DRIVE=""
PI_VERSION=""
NODE_VERSION=""
COMPONENTS="all"
CHECK=0
YES=0
SKIP_SKILLS=0
NO_VERIFY=0
FORCE_PI=0

while [ $# -gt 0 ]; do
    case "$1" in
        --drive) DRIVE="${2:-}"; shift ;;
        --pi) PI_VERSION="${2:-}"; shift ;;
        --node) NODE_VERSION="${2:-}"; shift ;;
        --components) COMPONENTS="${2:-}"; shift ;;
        --check) CHECK=1 ;;
        --yes|-y) YES=1 ;;
        --skip-skills) SKIP_SKILLS=1 ;;
        --no-verify) NO_VERIFY=1 ;;
        --force-pi) FORCE_PI=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) DRIVE="$1" ;;
    esac
    shift
done

case "$COMPONENTS" in client|extensions|all) ;; *) echo "bad --components: $COMPONENTS" >&2; exit 2 ;; esac

[ -n "$DRIVE" ] || DRIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE="$(cd "$DRIVE" && pwd)"
MANIFEST="$DRIVE/manifest.json"
[ -f "$MANIFEST" ] || { echo "manifest.json not found on the drive: $MANIFEST" >&2; exit 1; }

# use the drive's own node: no host dependency
NODE_BIN="$(find "$DRIVE/bin/linux" -maxdepth 1 -name 'node-v*-linux-x64' -type d 2>/dev/null | head -1)"
NODE_EXE="$NODE_BIN/bin/node"
NPM_CLI="$NODE_BIN/lib/node_modules/npm/bin/npm-cli.js"
if [ ! -x "$NODE_EXE" ]; then
    NODE_EXE="$(command -v node || true)"
    NPM_CLI="$(command -v npm >/dev/null 2>&1 && npm root -g 2>/dev/null | sed 's:/node_modules$::' || true)"
    [ -n "$NPM_CLI" ] && NPM_CLI="$NPM_CLI/npm/bin/npm-cli.js"
fi
[ -n "$NODE_EXE" ] || { echo "no usable node (drive not executable? mount with umask=000)" >&2; exit 1; }

jget() { "$NODE_EXE" -e 'const m=require(process.argv[1]);console.log(eval(process.argv[2]))' "$MANIFEST" "$1"; }
ver_cmp() {
    "$NODE_EXE" -e '
      const [a,b]=process.argv.slice(1);const c=v=>String(v).replace(/^v/,"").split("+")[0].split("-")[0].split(".").map(n=>parseInt(n,10)||0);
      const A=c(a),B=c(b);for(let i=0;i<Math.max(A.length,B.length);i++){const d=(A[i]||0)-(B[i]||0);if(d){console.log(Math.sign(d));process.exit(0)}}console.log(0)
    ' "$1" "$2"
}
registry_latest() {
    "$NODE_EXE" -e 'fetch(`https://registry.npmjs.org/${encodeURIComponent(process.argv[1])}/latest`,{signal:AbortSignal.timeout(15000)}).then(r=>{if(!r.ok)throw new Error("HTTP "+r.status);return r.json()}).then(j=>console.log(j.version))' "$1"
}

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

step() { printf '==> %s\n' "$*"; }
ok()   { printf '    %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }

download() { curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"; }
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
# npm on exFAT is pathological: cache and prefix stay in the host temp, removed
# with $STAGING. Warnings on stderr are normal, so only the exit code matters.
run_npm() {
    NPM_CONFIG_CACHE="$STAGING/npm-cache" npm_config_fund=false npm_config_audit=false \
        "$NODE_EXE" "$NPM_CLI" "$@" >>"$STAGING/npm.log" 2>&1 \
        || { tail -12 "$STAGING/npm.log" >&2; echo "npm failed: $*" >&2; exit 1; }
}
free_mb() { df -Pk "$DRIVE" 2>/dev/null | awk 'NR==2{print int($4/1024)}'; }
file_count() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

AGENT_DIR="$DRIVE/$(jget 'm.paths.agentDir')"
SKILLS_DIR="$DRIVE/$(jget 'm.paths.skillsDir')"
RUNTIME_DIR="$DRIVE/$(jget 'm.paths.runtimeDir')"
RUNTIME_NM="$RUNTIME_DIR/node_modules"
PKG_DIR="$AGENT_DIR/packages"

if [ "$CHECK" = 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$NODE_EXE" "$SCRIPT_DIR/check-updates.mjs" --drive "$DRIVE" --node --json "$DRIVE/temp/update-plan.json"
    exit $?
fi

DO_CLIENT=0; DO_EXT=0
case "$COMPONENTS" in client) DO_CLIENT=1 ;; extensions) DO_EXT=1 ;; all) DO_CLIENT=1; DO_EXT=1 ;; esac

step "Update portable-pi at $DRIVE ($COMPONENTS)"
ok "client: $DO_CLIENT | extensions: $DO_EXT | solo rete + drive"

if [ "$YES" = 0 ]; then
    printf 'Procedo con questi componenti? [S/n] '
    read -r ANSWER || ANSWER="n"
    case "$ANSWER" in [nN]*) echo "Annullato."; exit 0 ;; esac
fi

CLIENT_CHANGED=0
EXT_CHANGED=0

# ── client: pi ──────────────────────────────────────────────────────────
if [ "$DO_CLIENT" = 1 ]; then
    [ -n "$PI_VERSION" ] || PI_VERSION="$(jget 'm.pi.version')"
    if [ "$PI_VERSION" = "latest" ]; then
        PI_VERSION="$(registry_latest '@earendil-works/pi-coding-agent')"
        ok "registry: pi $PI_VERSION"
    fi
    INSTALLED="$(jget 'm.pi.version')"

    if [ "$FORCE_PI" = 0 ] && [ "$PI_VERSION" = "$INSTALLED" ]; then
        step "client: pi $INSTALLED già aggiornato (usa --force-pi per reinstallare)"
    else
        step "client: pi $INSTALLED -> $PI_VERSION"
        COUNT="$(jget 'm.pi.runtimePackages.length')"
        i=0
        while [ "$i" -lt "$COUNT" ]; do
            NAME="$(jget "m.pi.runtimePackages[$i].name")"
            VERSION="$(jget "m.pi.runtimePackages[$i].version")"
            [ "$NAME" = "@earendil-works/pi-coding-agent" ] && VERSION="$PI_VERSION"
            DEST="$RUNTIME_NM/$NAME"
            ok "downloading $NAME@$VERSION"
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
            ok "$NAME $VERSION ($(file_count "$DEST") file)"
            i=$((i + 1))
        done

        CLI="$RUNTIME_NM/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
        OUT="$(PI_CODING_AGENT_DIR="$AGENT_DIR" PI_SKIP_VERSION_CHECK=1 "$NODE_EXE" "$CLI" --version)"
        case "$OUT" in *[0-9].[0-9].[0-9]*) ok "pi ora risponde: $OUT" ;; *) echo "pi --version did not answer: $OUT" >&2; exit 1 ;; esac
        "$NODE_EXE" -e '
          const fs=require("fs");const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,"utf8"));
          m.pi.version=process.argv[2];m.pi.runtimePackages[0].version=process.argv[2];
          fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
        ' "$MANIFEST" "$PI_VERSION"
        CLIENT_CHANGED=1
    fi

    # ── node (opzionale) ────────────────────────────────────────────────
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
                ok "downloading $ARCHIVE"
                download "$URL" "$STAGING/$ARCHIVE"
                EXPECTED="$(grep -E "[[:space:]]$ARCHIVE\$" "$STAGING/sums.txt" | awk '{print $1}')"
                ACTUAL="$(sha256sum "$STAGING/$ARCHIVE" | awk '{print $1}')"
                [ "$ACTUAL" = "$EXPECTED" ] || { echo "checksum mismatch: $ARCHIVE" >&2; exit 1; }
                rm -rf "$STAGING/x"; extract "$STAGING/$ARCHIVE" "$STAGING/x"; deref_links "$STAGING/x"
                TOP="$(find "$STAGING/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
                DEST="$DRIVE/$INSTALL_REL"
                rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"; mv "$TOP" "$DEST"
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
            CLIENT_CHANGED=1
        else
            step "node $NODE_VERSION already present"
        fi
    fi
fi

# ── extensions: staging npm nel temp host, poi vendoring sul drive ──────
if [ "$DO_EXT" = 1 ] && [ "$SKIP_SKILLS" = 0 ]; then
    PKG_COUNT="$(jget '(m.packages||[]).length')"
    if [ "$PKG_COUNT" != "0" ]; then
        TARGETS="$STAGING/targets.tsv"
        : > "$TARGETS"
        TODO=""
        i=0
        while [ "$i" -lt "$PKG_COUNT" ]; do
            NAME="$(jget "m.packages[$i].name")"
            CURRENT="$(jget "m.packages[$i].version")"
            LATEST="$(registry_latest "$NAME" 2>/dev/null || echo "$CURRENT")"
            printf '%s\t%s\t%s\n' "$NAME" "$CURRENT" "$LATEST" >> "$TARGETS"
            if [ "$(ver_cmp "$LATEST" "$CURRENT")" -gt 0 ]; then TODO="$TODO $NAME $CURRENT->$LATEST;"; fi
            i=$((i + 1))
        done

        # manifest vs drive: un update interrotto deve essere riparabile
        MISMATCH=""
        i=0
        while [ "$i" -lt "$PKG_COUNT" ]; do
            NAME="$(jget "m.packages[$i].name")"
            WANT="$(jget "m.packages[$i].version")"
            PJ="$PKG_DIR/node_modules/$NAME/package.json"
            if [ ! -f "$PJ" ]; then MISMATCH="$MISMATCH $NAME(missing)"
            else
                HAVE="$("$NODE_EXE" -e 'console.log(require(process.argv[1]).version||"")' "$PJ")"
                [ "$HAVE" = "$WANT" ] || MISMATCH="$MISMATCH $NAME($HAVE!=$WANT)"
            fi
            i=$((i + 1))
        done
        [ -n "$MISMATCH" ] && warn "drive disallineato dal manifest:$MISMATCH"

        if [ -z "$TODO" ] && [ -z "$MISMATCH" ]; then
            step "extensions: già aggiornate"
        else
            step "extensions:$TODO"
            STAGE="$STAGING/ext-stage"
            rm -rf "$STAGE"; mkdir -p "$STAGE"
            SPECS=()
            while IFS=$'\t' read -r NAME _ LATEST; do SPECS+=("$NAME@$LATEST"); done < "$TARGETS"
            ok "npm install (${#SPECS[@]} pacchetti, staging nel temp host)"
            run_npm install --prefix "$STAGE" --omit=dev --no-audit --no-fund --ignore-scripts --package-lock=false --legacy-peer-deps --omit=optional "${SPECS[@]}"

            # profilo per il vendor: tutti i pacchetti al target, con i flag del drive
            "$NODE_EXE" -e '
              const fs=require("fs");
              const [manifestPath, targetsPath, outPath] = process.argv.slice(1);
              const m=JSON.parse(fs.readFileSync(manifestPath,"utf8"));
              const targets=new Map(fs.readFileSync(targetsPath,"utf8").trim().split("\n").filter(Boolean).map(l=>{const [n,c,t]=l.split("\t");return [n,{current:c,latest:t}]}));
              const packages=(m.packages||[]).map(p=>{
                const t=targets.get(p.name)||{latest:p.version};
                const e={name:p.name,spec:`npm:${p.name}@${t.latest}`};
                const skip=p.skipOptional||p.skippedOptional;
                if (skip && skip.length) e.skipOptional=skip;
                if (p.requiresHostSdk) e.requiresHostSdk=true;
                return e;
              });
              fs.writeFileSync(outPath, JSON.stringify({packages},null,2)+"\n");
            ' "$MANIFEST" "$TARGETS" "$STAGING/profile-packages.json"

            # exFAT scrive a cluster da 32 KB: il budget si conta sui file, e la
            # vecchia copia viene rimossa PRIMA di copiare quella nuova.
            STAGE_FILES="$(file_count "$STAGE/node_modules")"
            NEED_MB=$(( STAGE_FILES * 32 / 1024 + 60 ))
            FREE_MB="$(free_mb)"
            # la vecchia copia viene cancellata prima: conta come spazio disponibile
            [ -d "$PKG_DIR" ] && FREE_MB=$(( FREE_MB + $(file_count "$PKG_DIR") * 32 / 1024 ))
            ok "spazio: $STAGE_FILES file in staging, stimati $NEED_MB MB, disponibili ~$FREE_MB MB"
            if [ "$FREE_MB" -lt "$NEED_MB" ]; then
                echo "spazio insufficiente sul drive: servono ~$NEED_MB MB, liberi $FREE_MB MB." >&2
                echo "libera spazio (o usa una chiavetta più grande) e riprova: nessuna modifica fatta." >&2
                exit 1
            fi
            rm -rf "$PKG_DIR"
            "$NODE_EXE" "$DRIVE/scripts/vendor-packages.mjs" --profile "$STAGING/profile-packages.json" \
                --dest "$PKG_DIR" --host-packages "$STAGE/node_modules" --prune --allow-missing \
                --json "$STAGING/vendor.report" | grep -E 'MB|!' | sed 's/^/    /' || true
            [ -d "$PKG_DIR/node_modules" ] || { echo "vendoring failed" >&2; exit 1; }

            # versioni registrate + skill esposte dai pacchetti
            "$NODE_EXE" -e '
              const fs=require("fs");
              const [manifestPath, targetsPath] = process.argv.slice(1);
              const m=JSON.parse(fs.readFileSync(manifestPath,"utf8"));
              const targets=new Map(fs.readFileSync(targetsPath,"utf8").trim().split("\n").filter(Boolean).map(l=>{const [n,c,t]=l.split("\t");return [n,t]}));
              for (const p of m.packages||[]) {
                const t=targets.get(p.name);
                if (t) { p.version=t; p.spec=`npm:${p.name}@${t}`; }
              }
              fs.writeFileSync(manifestPath, JSON.stringify(m,null,2)+"\n");
            ' "$MANIFEST" "$TARGETS"
            PKG_SKILLS=""
            for sk in "$PKG_DIR/node_modules"/*/skills/* "$PKG_DIR/node_modules"/@*/*/skills/*; do
                [ -f "$sk/SKILL.md" ] || continue
                NAME="$(basename "$sk")"
                rm -rf "$SKILLS_DIR/$NAME"
                cp -R "$sk" "$SKILLS_DIR/$NAME"
                PKG_SKILLS="$PKG_SKILLS $NAME"
                ok "package skill $NAME"
            done
            "$NODE_EXE" -e '
              const fs=require("fs");const [p,names]=process.argv.slice(1);
              const m=JSON.parse(fs.readFileSync(p,"utf8"));
              m.packageSkills=names.split(" ").filter(Boolean);
              fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
            ' "$MANIFEST" "$PKG_SKILLS"
            EXT_CHANGED=1
        fi
    else
        step "extensions: nessun pacchetto nel profilo"
    fi

    # package-provided skills: riconciliate a ogni update (-ns disabilita la
    # discovery dei pacchetti, quindi la copia in config/pi/skills è l'unica visibile)
    PKG_NM="$PKG_DIR/node_modules"
    if [ -d "$PKG_NM" ]; then
        PKG_SKILLS=""
        for sk in "$PKG_NM"/*/skills/* "$PKG_NM"/@*/*/skills/*; do
            [ -f "$sk/SKILL.md" ] || continue
            NAME="$(basename "$sk")"
            rm -rf "$SKILLS_DIR/$NAME"
            cp -R "$sk" "$SKILLS_DIR/$NAME"
            PKG_SKILLS="$PKG_SKILLS $NAME"
            ok "package skill $NAME"
        done
        "$NODE_EXE" -e 'const fs=require("fs");const [p,names]=process.argv.slice(1);const m=JSON.parse(fs.readFileSync(p,"utf8"));m.packageSkills=names.split(" ").filter(Boolean);fs.writeFileSync(p,JSON.stringify(m,null,2)+"
")' "$MANIFEST" "$PKG_SKILLS"
    fi

    # skill della whitelist: solo se questo PC ha i sorgenti
    COUNT="$(jget 'm.skills.include.length')"
    if [ "$COUNT" != "0" ]; then
        MISSING=""
        i=0
        while [ "$i" -lt "$COUNT" ]; do
            ROOT="$(jget "m.skills.include[$i].root")"
            REL="$(jget "m.skills.include[$i].path")"
            case "$ROOT" in
                agent) SRC="$HOME/.pi/agent/$REL" ;;
                agents) SRC="$HOME/.agents/$REL" ;;
                npm) SRC="$HOME/.pi/agent/npm/node_modules/$REL" ;;
            esac
            [ -f "$SRC/SKILL.md" ] || MISSING="$MISSING $(jget "m.skills.include[$i].name")"
            i=$((i + 1))
        done
        if [ -z "$MISSING" ]; then
            step "skills: refresh di $COUNT dalla whitelist"
            i=0
            while [ "$i" -lt "$COUNT" ]; do
                NAME="$(jget "m.skills.include[$i].name")"
                ROOT="$(jget "m.skills.include[$i].root")"
                REL="$(jget "m.skills.include[$i].path")"
                case "$ROOT" in
                    agent) SRC="$HOME/.pi/agent/$REL" ;;
                    agents) SRC="$HOME/.agents/$REL" ;;
                    npm) SRC="$HOME/.pi/agent/npm/node_modules/$REL" ;;
                esac
                rm -rf "$SKILLS_DIR/$NAME"
                cp -R "$SRC" "$SKILLS_DIR/$NAME"
                ok "$NAME"
                i=$((i + 1))
            done
        else
            warn "skill sources not available on this machine:$MISSING - skills left untouched"
        fi
    fi
fi

# ── host SDK: serve ai pacchetti che spawnano child pi ─────────────────
NEED_HOST="$(jget '(m.packages||[]).some(p=>p.requiresHostSdk)?"1":"0"')"
if [ "$NEED_HOST" = "1" ] && { [ "$DO_CLIENT" = 1 ] || [ "$DO_EXT" = 1 ]; }; then
    MARKER="$RUNTIME_NM/@earendil-works/pi-coding-agent/dist/index.js"
    if [ "$CLIENT_CHANGED" = 1 ] || [ "$EXT_CHANGED" = 1 ] || [ ! -f "$MARKER" ]; then
        PI_NOW="$(jget 'm.pi.version')"
        step "host SDK: pi $PI_NOW per i child pi"
        STAGE="$STAGING/hostsdk-stage"
        rm -rf "$STAGE"; mkdir -p "$STAGE"
        run_npm install --prefix "$STAGE" --omit=dev --no-audit --no-fund --ignore-scripts --package-lock=false --legacy-peer-deps --omit=optional "@earendil-works/pi-coding-agent@$PI_NOW"
        STAGE_FILES="$(file_count "$STAGE/node_modules")"
        NEED_MB=$(( STAGE_FILES * 32 / 1024 + 60 ))
        FREE_MB="$(free_mb)"
        ok "spazio: $STAGE_FILES file in staging, stimati $NEED_MB MB, liberi $FREE_MB MB"
        if [ "$FREE_MB" -lt "$NEED_MB" ]; then
            echo "spazio insufficiente per l'host SDK: servono ~$NEED_MB MB, liberi $FREE_MB MB." >&2
            exit 1
        fi
        printf '{"packages":[{"name":"@earendil-works/pi-coding-agent","spec":"npm:@earendil-works/pi-coding-agent@%s"}]}\n' "$PI_NOW" > "$STAGING/host-sdk.json"
        "$NODE_EXE" "$DRIVE/scripts/vendor-packages.mjs" --profile "$STAGING/host-sdk.json" \
            --dest "$RUNTIME_DIR" --host-packages "$STAGE/node_modules" --allow-host-provided --force --allow-missing \
            --json "$STAGING/host-sdk.report" | grep -E 'MB|!' | sed 's/^/    /' || true
        [ -f "$MARKER" ] || { echo "host SDK incomplete: $MARKER missing" >&2; exit 1; }
    else
        step "host SDK: già presente e allineato al client"
    fi
fi

# ── verify ──────────────────────────────────────────────────────────────
if [ "$NO_VERIFY" = 0 ] && [ -f "$DRIVE/scripts/verify.sh" ]; then
    step "Verification (no model call)"
    bash "$DRIVE/scripts/verify.sh" "$DRIVE" --no-model || { echo "verify reported errors" >&2; exit 1; }
fi

sync 2>/dev/null || true
echo
echo "Update completed."
echo "Full verification with a model call:  bash $DRIVE/scripts/verify.sh $DRIVE"
