#!/usr/bin/env node
/**
 * Update check for a portable-pi drive.
 *
 * Reads <drive>/manifest.json and asks the npm registry (and nodejs.org) what the
 * current versions are. Prints a human plan and, with --json, writes the same
 * plan as JSON for the launchers. Read-only: it never touches the drive.
 *
 *   node scripts/check-updates.mjs
 *   node scripts/check-updates.mjs --drive F:\ --json F:\temp\update-plan.json
 *   node scripts/check-updates.mjs --node          # also checks the Node LTS line
 *
 * Exit code: 0 = check completed (even with no updates), 2 = bad usage,
 * 3 = the registry could not be reached (the JSON still carries the error).
 */

import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const arg = (name, fallback = undefined) => {
    const i = argv.indexOf(`--${name}`);
    return i === -1 ? fallback : argv[i + 1];
};
const flag = (name) => argv.includes(`--${name}`);

const REGISTRY = 'https://registry.npmjs.org';
const TIMEOUT_MS = 15000;

const drive = resolve(arg('drive') || join(dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..'));
const manifestPath = join(drive, 'manifest.json');
if (!existsSync(manifestPath)) {
    console.error(`manifest.json not found on the drive: ${manifestPath}`);
    process.exit(2);
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

function compareVersions(a, b) {
    const clean = (v) => String(v ?? '').trim().replace(/^v/, '').split('+')[0];
    const [ac, apre] = clean(a).split('-');
    const [bc, bpre] = clean(b).split('-');
    const an = ac.split('.').map((n) => Number.parseInt(n, 10) || 0);
    const bn = bc.split('.').map((n) => Number.parseInt(n, 10) || 0);
    for (let i = 0; i < Math.max(an.length, bn.length); i++) {
        const d = (an[i] ?? 0) - (bn[i] ?? 0);
        if (d !== 0) return d > 0 ? 1 : -1;
    }
    if (apre === bpre) return 0;
    if (!apre) return 1;         // 1.0.0 > 1.0.0-beta
    if (!bpre) return -1;
    return apre > bpre ? 1 : -1; // lexical is enough for ordering pre-releases
}

async function getJson(url) {
    const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { accept: 'application/json' } });
    if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
    return res.json();
}

const latestRegistryVersion = async (name) => {
    const meta = await getJson(`${REGISTRY}/${encodeURIComponent(name)}/latest`);
    return meta.version;
};

const errors = [];
const plan = {
    checkedAt: new Date().toISOString(),
    drive,
    client: null,
    node: null,
    extensions: [],
    skills: null,
    anyUpdate: false,
    errors,
};

// ── client (pi) ────────────────────────────────────────────────────────
const piCurrent = manifest.pi?.version ?? 'unknown';
try {
    const latest = await latestRegistryVersion('@earendil-works/pi-coding-agent');
    plan.client = { name: 'pi', current: piCurrent, latest, update: compareVersions(latest, piCurrent) > 0 };
} catch (err) {
    errors.push(`pi: ${err.message}`);
    plan.client = { name: 'pi', current: piCurrent, latest: null, update: false, error: String(err.message) };
}

// ── optional Node LTS line (informational) ─────────────────────────────
if (flag('node')) {
    const nodeCurrent = manifest.node?.version ?? 'unknown';
    try {
        const index = await getJson('https://nodejs.org/dist/index.json');
        const major = String(nodeCurrent).split('.')[0];
        const lts = index.find((r) => r.lts && String(r.version).replace(/^v/, '').split('.')[0] === major);
        const latest = lts ? String(lts.version).replace(/^v/, '') : null;
        plan.node = { current: nodeCurrent, latest, update: Boolean(latest) && compareVersions(latest, nodeCurrent) > 0, optional: true };
    } catch (err) {
        errors.push(`node: ${err.message}`);
        plan.node = { current: nodeCurrent, latest: null, update: false, optional: true, error: String(err.message) };
    }
}

// ── vendored packages ──────────────────────────────────────────────────
for (const entry of Array.isArray(manifest.packages) ? manifest.packages : []) {
    const name = entry.name;
    const current = entry.version ?? 'unknown';
    const spec = String(entry.spec ?? name).replace(/^npm:/, '');
    const at = spec.lastIndexOf('@');
    const specName = at > 0 ? spec.slice(0, at) : spec;
    try {
        const latest = await latestRegistryVersion(specName || name);
        plan.extensions.push({ name, current, latest, update: compareVersions(latest, current) > 0 });
    } catch (err) {
        errors.push(`${name}: ${err.message}`);
        plan.extensions.push({ name, current, latest: null, update: false, error: String(err.message) });
    }
}

// ── skills: only this machine can tell whether the sources are here ────
const roots = {
    agent: join(homedir(), '.pi', 'agent'),
    agents: join(homedir(), '.agents'),
    npm: join(homedir(), '.pi', 'agent', 'npm', 'node_modules'),
};
const includes = Array.isArray(manifest.skills?.include) ? manifest.skills.include : [];
const missing = includes.filter((s) => !existsSync(join(roots[s.root] ?? '', s.path ?? '', 'SKILL.md')));
plan.skills = {
    count: includes.length,
    sourcesAvailable: includes.length === 0 ? null : missing.length === 0,
    missing: missing.map((s) => s.name),
};

// package skills live in config/pi/skills because -ns disables package discovery:
// a package update without the mirror is an incomplete drive, so count it as work
const skillsDir = join(drive, manifest.paths?.skillsDir ?? 'config/pi/skills');
const pkgNm = join(drive, manifest.paths?.agentDir ?? 'config/pi', 'packages', 'node_modules');
const mirrors = [];
const scanPkg = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        if (entry.name === 'node_modules' || entry.name === 'docs') continue;
        const full = join(dir, entry.name);
        if (entry.name === 'skills') {
            for (const sk of readdirSync(full, { withFileTypes: true })) {
                if (sk.isDirectory() && existsSync(join(full, sk.name, 'SKILL.md'))) mirrors.push(sk.name);
            }
            continue;
        }
        if (dir.includes('node_modules') && dir.split(/[\/]/).length > 0 && entry.name !== 'skills') {
            // walk only package roots: node_modules/<pkg>/skills and @scope/<pkg>/skills
            const depth = dir.slice(pkgNm.length).split(/[\/]/).filter(Boolean).length;
            if (depth <= 1) scanPkg(full);
        }
    }
};
plan.repairs = [];
try {
    if (existsSync(pkgNm)) scanPkg(pkgNm);
    for (const name of new Set(mirrors)) {
        if (!existsSync(join(skillsDir, name, 'SKILL.md'))) plan.repairs.push({ name, reason: 'package skill not mirrored into config/pi/skills' });
    }
    // manifest vs what is actually vendored on the drive
    for (const e of Array.isArray(manifest.packages) ? manifest.packages : []) {
        const pj = join(pkgNm, e.name, 'package.json');
        if (!existsSync(pj)) { plan.repairs.push({ name: e.name, reason: 'vendored package missing on the drive' }); continue; }
        const onDisk = JSON.parse(readFileSync(pj, 'utf8')).version;
        if (onDisk && e.version && onDisk !== e.version) {
            plan.repairs.push({ name: e.name, reason: `drive has ${onDisk}, manifest says ${e.version}` });
        }
    }
} catch (err) {
    errors.push(`skills mirror: ${err.message}`);
}

plan.anyUpdate = Boolean(
    plan.client?.update ||
    plan.node?.update ||
    plan.extensions.some((e) => e.update) ||
    plan.repairs.length > 0
);

// ── output ─────────────────────────────────────────────────────────────
const line = (label, value) => console.log(`  ${label.padEnd(12)} ${value}`);
const mark = (update) => (update ? 'aggiornamento disponibile' : 'aggiornato');

console.log('');
console.log(`portable-pi update check — ${drive}`);
console.log('');
line('client', `pi ${plan.client.current}${plan.client.latest ? ` -> ${plan.client.latest}` : ' (registry non raggiungibile)'}   ${plan.client.latest ? mark(plan.client.update) : ''}`.trimEnd());
if (plan.node) {
    line('node', `${plan.node.current}${plan.node.latest ? ` (LTS ${plan.node.latest}${plan.node.update ? ' disponibile' : ' = aggiornato'})` : ''}   opzionale`);
}
if (plan.extensions.length) {
    console.log('  estensioni');
    for (const e of plan.extensions) {
        console.log(`    ${e.name.padEnd(28)} ${e.current}${e.latest ? ` -> ${e.latest}` : ''}  ${e.latest ? mark(e.update) : ''}`.trimEnd());
    }
}
if (plan.skills && plan.skills.count > 0) {
    line('skill', plan.skills.sourcesAvailable
        ? `${plan.skills.count} in whitelist, sorgenti presenti su questo PC`
        : `${plan.skills.count} in whitelist, sorgenti NON presenti qui (restano com'erano)`);
}
console.log('');
if (errors.length) {
    console.log(`  ! rete: ${errors.join(' | ')}`);
    console.log('');
}
if (!plan.anyUpdate) {
    console.log('  Tutto aggiornato.');
} else {
    const client = plan.client?.update ? 'client' : null;
    const exts = plan.extensions.some((e) => e.update) ? 'estensioni' : null;
    const fixes = plan.repairs.length ? `riparazioni (${plan.repairs.map((r) => r.name).join(', ')})` : null;
    console.log(`  Da fare: ${[client, exts, fixes].filter(Boolean).join(' + ')}`);
}

const jsonPath = arg('json');
if (jsonPath) {
    const abs = resolve(jsonPath);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, `${JSON.stringify(plan, null, 2)}\n`);
}

process.exit(errors.length && plan.client?.latest === null ? 3 : 0);
