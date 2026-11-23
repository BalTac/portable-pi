#!/usr/bin/env node
/**
 * Vendor third-party pi packages onto the drive.
 *
 * A local package path is loaded by pi without copying and without installing
 * its dependencies, so the drive must carry the package *and* its dependency
 * closure. This script copies both from the host's pi npm dir (no network):
 *
 *   <host>/npm/node_modules/<pkg>  ->  <dest>/node_modules/<pkg>
 *   dependencies (recursive)       ->  <dest>/node_modules/<dep>
 *   version conflict               ->  <dest>/node_modules/<pkg>/node_modules/<dep>
 *
 * Symlinks are dereferenced (exFAT has none), test folders and multi-megabyte
 * gallery media are skipped, host-provided peer packages are never copied.
 *
 * Usage:
 *   node scripts/vendor-packages.mjs --profile skills.local.json --dest <dir> [--prune] [--json out.json]
 */

import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, fallback = undefined) => {
    const i = argv.indexOf(`--${name}`);
    return i === -1 ? fallback : argv[i + 1];
};
const flag = (name) => argv.includes(`--${name}`);

const profilePath = resolve(arg('profile', 'skills.local.json'));
const destRoot = resolve(arg('dest'));
const jsonOut = arg('json');
const doPrune = flag('prune');
const allowHostProvided = flag('allow-host-provided');
const forceCopy = flag('force'); // re-copy even when the destination version matches
const allowMissing = flag('allow-missing'); // optional deps omitted on purpose (npm --omit=optional)

const HOST_ROOT = resolve(arg('host-packages') || join(homedir(), '.pi', 'agent', 'npm', 'node_modules'));

if (!arg('dest')) {
    console.error('usage: node scripts/vendor-packages.mjs --profile <file> --dest <dir> [--prune] [--json <file>]');
    process.exit(2);
}

const profile = JSON.parse(readFileSync(profilePath, 'utf8'));
const packages = Array.isArray(profile.packages) ? profile.packages : [];
const destNodeModules = join(destRoot, 'node_modules');

// Host-provided packages: pi maps these for extensions, copying them would
// create duplicate class instances (see pi docs/packages.md).
const HOST_PROVIDED = new Set(allowHostProvided ? [] : [
    '@earendil-works/pi-ai',
    '@earendil-works/pi-agent-core',
    '@earendil-works/pi-coding-agent',
    '@earendil-works/pi-tui',
    'typebox',
]);

const SKIP_DIRS = new Set(['.git', '.github', 'tests', 'test', '__tests__', 'coverage', '.cache', '.turbo']);
const HEAVY_MEDIA = /\.(mp4|webm|mov|gif|png|jpe?g|zip|7z|tar|gz)$/i;
// Never opened at run time: source maps, type declarations, docs. Stripping
// them roughly halves the file count, which matters on exFAT (32 KB clusters).
const NON_RUNTIME = /\.(map|d\.ts|md)$/i;
const HEAVY_BYTES = 512 * 1024;

const readPkg = (dir) => JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
const log = (msg) => console.log(`    ${msg}`);
// stdout on purpose: PowerShell with $ErrorActionPreference='Stop' treats any
// native stderr line as a terminating NativeCommandError.
const warn = (msg) => console.log(`    ! ${msg}`);

const skippedOptional = new Map();
const placed = new Map(); // absolute dest dir -> version
const flatNames = new Set(); // packages placed directly in <dest>/node_modules (what prune may keep)
const missing = new Set(); // dependencies not found on this host: prune must not run
const seen = new Set(); // <src>|<dest> already expanded: npm dependency graphs have cycles
const copiedTop = [];

function locate(name, fromDir) {
    const nested = join(fromDir, 'node_modules', name);
    if (existsSync(join(nested, 'package.json'))) return nested;
    const flatHost = join(HOST_ROOT, name);
    if (existsSync(join(flatHost, 'package.json'))) return flatHost;
    return null;
}

function shouldCopy(src) {
    const base = src.split(/[\\/]/).pop();
    if (SKIP_DIRS.has(base)) return false;
    let st;
    try { st = statSync(src); } catch { return false; }
    if (st.isFile() && NON_RUNTIME.test(base) && !/^skill\.md$/i.test(base)) return false;
    // Markdown is dropped except inside docs/ (pi's system prompt points at its
    // own docs) and except SKILL.md (package skills are mirrored into
    // config/pi/skills, and -ns makes that mirror the only visible copy).
    if (st.isFile() && /\.md$/i.test(base) && !/[\\/]docs[\\/]/.test(src) && !/^skill\.md$/i.test(base)) return false;
    if (st.isFile() && st.size > HEAVY_BYTES && HEAVY_MEDIA.test(base)) return false;
    // TypeScript sources are not opened by the loader; entry points are .js/.ts
    // at the package root, never under src/.
    if (st.isFile() && /\.ts$/.test(base) && /[\\/]src[\\/]/.test(src)) return false;
    return true;
}

function copyTree(src, dst) {
    cpSync(src, dst, { recursive: true, dereference: true, filter: shouldCopy, force: true });
}

function dirSize(dir) {
    let total = 0;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, entry.name);
        if (entry.isDirectory()) total += dirSize(p);
        else if (entry.isFile()) { try { total += statSync(p).size; } catch { /* ignore */ } }
    }
    return total;
}

function place(name, spec, fromDir, container, stack, skip) {
    if (stack.length > 16) { warn(`dependency depth limit reached at ${name}`); return; }
    const srcDir = locate(name, fromDir);
    if (!srcDir) {
        warn(`dependency not found on this host, skipped: ${name} (required by ${stack.join(' > ') || 'profile'})`);
        return;
    }
    const pkg = readPkg(srcDir);
    const version = pkg.version ?? '0.0.0';
    if (spec && /^\d+\.\d+\.\d+/.test(spec) && spec !== version) {
        warn(`${name}: host has ${version}, profile asks ${spec}; vendoring the host copy (pin the spec to match)`);
    }
    if (HOST_PROVIDED.has(name)) return;

    const destDir = join(container, name);
    const seenKey = `${srcDir}|${destDir}`;
    if (seen.has(seenKey)) return;
    seen.add(seenKey);
    const isFlat = resolve(container) === resolve(destNodeModules);
    if (isFlat) flatNames.add(name);
    // --force re-copies only the top-level package asked for; re-copying every
    // dependency too would rewrite thousands of files for no reason.
    const already = !(forceCopy && stack.length === 0) && existsSync(destDir) && (() => { try { return readPkg(destDir).version; } catch { return undefined; } })() === version;
    if (placed.get(destDir) === version || already) {
        // Present and identical: skip the copy but keep walking the dependency
        // tree. Skipping traversal here would make the next prune drop every
        // dependency that is not a top-level package.
        placed.set(destDir, version);
    } else {
        if (existsSync(destDir)) rmSync(destDir, { recursive: true, force: true });
        mkdirSync(container, { recursive: true });
        copyTree(srcDir, destDir);
        placed.set(destDir, version);
    }

    const deps = { ...(pkg.dependencies ?? {}) };
    for (const depName of Object.keys(pkg.optionalDependencies ?? {})) deps[depName] = pkg.optionalDependencies[depName];

    for (const [depName, depSpec] of Object.entries(deps)) {
        if (HOST_PROVIDED.has(depName)) continue;
        if (skip.has(depName.toLowerCase())) continue;
        const depSrc = locate(depName, srcDir);
        if (!depSrc) { warn(`missing dependency ${depName} for ${name}`); missing.add(depName); continue; }
        const depVersion = readPkg(depSrc).version ?? '0.0.0';
        // Flat root unless that slot already holds a different version.
        const flatDest = join(destRoot, 'node_modules', depName);
        const containerForDep = existsSync(flatDest) && (() => { try { return readPkg(flatDest).version; } catch { return undefined; } })() !== depVersion
            ? join(destDir, 'node_modules')
            : join(destRoot, 'node_modules');
        place(depName, depSpec, srcDir, containerForDep, [...stack, `${name}@${version}`], skip);
    }
}

const expectedTop = [];
const summary = [];

for (const entry of packages) {
    const name = entry.name;
    if (!name) { warn('package entry without a name, skipped'); continue; }
    const specRaw = entry.spec ?? name;
    const spec = String(specRaw).replace(/^npm:/, '');
    const at = spec.lastIndexOf('@');
    const wantedVersion = at > 0 ? spec.slice(at + 1) : undefined;
    const wantedName = at > 0 ? spec.slice(0, at) : spec;
    if (wantedName && wantedName !== name) warn(`${name}: spec points at ${wantedName}`);
    const skipOptional = new Set((entry.skipOptional ?? []).map((s) => String(s).toLowerCase()));

    const srcDir = (() => {
        const nested = join(HOST_ROOT, name);
        return existsSync(join(nested, 'package.json')) ? nested : null;
    })();
    if (!srcDir) throw new Error(`package not installed on this host: ${name} (run: pi install ${specRaw})`);
    const hostVersion = readPkg(srcDir).version;
    if (wantedVersion && wantedVersion !== hostVersion) {
        warn(`${name}: profile pins ${wantedVersion}, host has ${hostVersion} (vendoring host copy)`);
    }

    if (doPrune) { /* handled after the loop */ }
    place(name, wantedVersion, HOST_ROOT, destNodeModules, [], skipOptional);
    expectedTop.push(name);
    const version = readPkg(join(destNodeModules, name)).version;
    const mb = +(dirSize(join(destNodeModules, name)) / 1048576).toFixed(1);
    copiedTop.push({ name, version, sizeMb: mb });
    summary.push({ name, spec: specRaw, version, sizeMb: mb, skipOptional: [...skipOptional], skippedOptional: [...skipOptional], requiresHostSdk: entry.requiresHostSdk === true });
    log(`${name}@${version} (${mb} MB)`);
}

if (doPrune && missing.size > 0 && !allowMissing) {
    warn(`prune skipped: incomplete closure (${[...missing].join(', ')})`);
}
if (doPrune && (missing.size === 0 || allowMissing)) {
    const keep = new Set(flatNames);
    for (const entry of readdirSync(destNodeModules, { withFileTypes: true })) {
        const full = join(destNodeModules, entry.name);
        if (entry.name.startsWith('@') && entry.isDirectory()) {
            for (const sub of readdirSync(full, { withFileTypes: true })) {
                const scoped = `${entry.name}/${sub.name}`;
                if (!keep.has(scoped)) { rmSync(join(full, sub.name), { recursive: true, force: true }); log(`pruned ${scoped}`); }
            }
            if (readdirSync(full).length === 0) rmSync(full, { recursive: true, force: true });
            continue;
        }
        if (!keep.has(entry.name)) { rmSync(full, { recursive: true, force: true }); log(`pruned ${entry.name}`); }
    }
}

const totalMb = +(dirSize(destNodeModules) / 1048576).toFixed(1);
const report = { profile: profilePath, packages: summary, totalMb };
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(report, null, 2));
log(`total vendored: ${totalMb} MB in ${destNodeModules}`);
