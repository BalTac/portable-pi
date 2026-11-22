#!/usr/bin/env node
/*
 * portable-pi: rewrite stale drive-root paths when the drive shows up under a
 * different letter or mount point (F:\ -> H:\, or F:\ -> /media/user/PORTABLE-PI).
 *
 * pi stores absolute paths in its own config (the agent dir, and sometimes a
 * theme path). Those were absolute when the drive was built, so on another
 * machine they can point at a drive letter that no longer exists. The launcher
 * runs this before pi starts.
 *
 * Usage: node fix-paths.js <usb-root> [--quiet]
 * Exit code is always 0: a broken config must never block startup.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
const quiet = argv.includes('--quiet');
const rawArg = argv.filter((a) => a !== '--quiet')[0] || path.resolve(__dirname, '..', '..');
// Defensive: a batch caller can hand us `"F:\"` where the closing quote is escaped
// by the trailing backslash, so the value arrives as `F:" --quiet`.
const cleanedArg = rawArg.replace(/["']/g, '').replace(/\s+--\S*$/, '').trim();
const usb = path.resolve(cleanedArg || '.');

const isWin = process.platform === 'win32';

/** Canonical drive root: "H:\" on Windows, "/media/u/DRIVE" elsewhere. */
function normalizeRoot(p) {
    if (!p) return '';
    let s = String(p).trim();
    if (!s) return '';
    s = s.replace(/[\\/]+$/, '');
    if (isWin) {
        const m = /^([A-Za-z]):$/.exec(s);
        if (m) return m[1].toUpperCase() + ':\\';
        return s.split('/').join('\\') + '\\';
    }
    return s || '/';
}

/**
 * Raw spellings a recorded root can have inside a config file.
 * JSON-escaped occurrences need no special case: replacing the raw form leaves
 * the extra backslash intact, so "F:\\config" becomes "H:\\config" (still valid JSON).
 */
function variantsOf(root) {
    if (!root) return [];
    const out = new Set();
    out.add(root);
    if (isWin) {
        const bare = root.replace(/\\$/, ''); // "H:"
        for (const r of [bare, bare.toLowerCase(), bare.toUpperCase()]) {
            out.add(r + '\\');
            out.add(r + '/');
        }
    } else {
        out.add(root + '/');
    }
    return Array.from(out).filter(Boolean);
}

const stateFile = path.join(usb, 'config', 'drive-root.txt');
const current = normalizeRoot(usb);

let previousRaw = '';
try {
    previousRaw = fs.readFileSync(stateFile, 'utf8').trim();
} catch {
    /* first run, or no record yet */
}
const previous = normalizeRoot(previousRaw);

const log = (...a) => { if (!quiet) console.log('[fix-paths]', ...a); };

/** Files that may carry a drive-absolute path. Sessions and skills are user data. */
function targetFiles() {
    const out = [];
    const agentDir = path.join(usb, 'config', 'pi');
    for (const name of ['settings.json', 'models.json', 'mcp.json', 'trust.json', 'hooks.json']) {
        const f = path.join(agentDir, name);
        if (fs.existsSync(f)) out.push(f);
    }
    for (const name of ['env.sh', 'env.bat']) {
        const f = path.join(usb, 'config', name);
        if (fs.existsSync(f)) out.push(f);
    }
    return out;
}

function rewriteFile(file, pairs) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { return 0; }
    const before = text;
    for (const [from, to] of pairs) {
        if (!from) continue;
        text = text.split(from).join(to);
    }
    if (text === before) return 0;
    if (file.endsWith('.json')) {
        try {
            JSON.parse(text);
        } catch {
            return 0; // never leave broken JSON behind
        }
    }
    try {
        fs.writeFileSync(file, text);
        return 1;
    } catch {
        return 0;
    }
}

function sanitizeTheme() {
    // A theme entry pointing at a path that does not exist (the usual symptom after
    // a drive-letter change) is reset to the built-in "dark", which pi always has.
    const f = path.join(usb, 'config', 'pi', 'settings.json');
    let settings;
    try { settings = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return; }
    const theme = settings && settings.theme;
    if (typeof theme !== 'string' || !theme) return;
    const looksLikePath = theme.indexOf('\\') !== -1 || theme.indexOf('/') !== -1 || /\.json$/i.test(theme);
    if (!looksLikePath) return;
    const resolved = path.isAbsolute(theme) ? theme : path.join(usb, 'config', 'pi', 'themes', theme);
    if (fs.existsSync(resolved)) return;
    settings.theme = 'dark';
    try {
        fs.writeFileSync(f, JSON.stringify(settings, null, 2) + '\n');
        log('theme pointed at a missing file, reset to "dark"');
    } catch {
        /* ignore */
    }
}

let changed = 0;
if (previous && previous !== current) {
    const pairs = variantsOf(previous).map((from) => [from, current]);
    for (const file of targetFiles()) changed += rewriteFile(file, pairs);
}

sanitizeTheme();

try {
    if (previousRaw !== current) {
        fs.mkdirSync(path.dirname(stateFile), { recursive: true });
        fs.writeFileSync(stateFile, current + '\n');
    }
} catch {
    /* ignore */
}

if (previousRaw !== current) {
    log(`drive root ${previousRaw || '(none)'} -> ${current}; ${changed} file(s) rewritten`);
} else {
    log(`drive root ${current} (unchanged)`);
}
process.exit(0);
