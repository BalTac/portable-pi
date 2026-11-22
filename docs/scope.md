# Selection policy: what ships and what cannot

Two layers:

- **The base repo is pi-only.** It ships no skill names and no extensions:
  `config/pi/settings.json` has no `packages`, `config/pi/skills/` stays empty (gitignored),
  and CI fails if either changes. `skills.example.json` shows the shape, with fake names.
- **Your drive profile decides what actually travels.** `skills.local.json` (gitignored) has
  `include` (skills), `packages` (extensions), `settings` (extra keys for the drive's
  `settings.json`) and `exclude` (what you deliberately left out, with the reason).

What follows is the **rule** used to decide what a profile may contain, so the reasoning is
reusable.

## Rule

A skill or package ships only if it works on a **virgin machine** with nothing but the drive:

1. it needs no service on your LAN (no fixed IPs, no localhost ports, no GPU box);
2. it needs no private repository, database or vault that only you have — unless that vault
   can live on the drive (llm-wiki: yes, via `WIKI_HOME`);
3. it needs no host path (`D:\...`, `/mnt/...`, `~/.local/bin/<your-shim>`);
4. it needs no installed tool that the drive does not carry (this rules out Python
   toolchains, browser binaries, GPU models, and similar);
5. an extension must be pure JS/TS, because the agent dir is shared between Windows and
   Linux; native or model-heavy optional dependencies go in `skipOptional`;
6. an extension that spawns child pi processes must be marked `requiresHostSdk: true`, because
   the build then also vendors the host SDK closure into `tools/pi` (~65 MB); without it the
   extension loads but every child fails with `ENOENT .../dist/index.js`;
7. an extension must be installable **from the build machine** so the build can vendor it
   (the profile `spec` is an npm spec; `scripts/vendor-packages.mjs` copies the package and
   its dependency closure, no registry access at run time).

Categories that fail this rule, and why:

| Category | Blocking dependency |
|---|---|
| Anything talking to a local service | a second machine on your network, a fixed IP, a port |
| Anything running local models | GPU host, model weights, a Python or CUDA stack |
| Anything needing a private repo or vault that cannot move | data that is not on the drive |
| Anything needing a host shim or absolute path | the drive must be self-contained |
| Skill packages with browser binaries | hundreds of MB downloaded per platform |
| Extensions with native builds or 2 GB models | not portable across Windows/Linux; skip the optional dep |

## How the profile is applied

- `include[]` → `{ name, root, path }`, where `root` is `agent` (`<home>/.pi/agent`),
  `agents` (`<home>/.agents`) or `npm` (`<home>/.pi/agent/npm/node_modules`). The build copies
  each entry to `<drive>/config/pi/skills/<name>/`.
- `packages[]` → `{ name, spec, skipOptional?, configFiles?, reason }`. The build vendors the
  package into `<drive>/config/pi/packages/node_modules/<name>` with its dependency closure,
  writes `settings.json` entries as `./packages/node_modules/<name>` (drive-relative), mirrors
  the package's own `skills/*` into `config/pi/skills/` (because `-ns` disables package skill
  discovery), and prunes packages no longer listed.
- `settings{}` → merged into `<drive>/config/pi/settings.json` (e.g. `subagents` model
  defaults). It never carries LAN endpoints.
- `exclude[]` → `{ name, reason }`: documentation only, so the next session knows why a skill
  was left out instead of re-adding it.
- The drive copy of `manifest.json` records the effective lists (`skills`, `packages`,
  `packageSkills`); `update` and `verify` read the drive manifest, so the drive documents
  itself.
- Skills with `disable-model-invocation: true` still ship: they are reachable through
  `/skill:<name>` but are deliberately absent from the model's skill index.

## Config that gets sanitized

Whatever machine you build on, some files are host-specific and must not travel:

| File | Treatment |
|---|---|
| `auth.json` | copied (credentials are meant to travel with the drive) |
| `settings.json` | from the repo template (theme, default provider/model/thinking level, compaction); `packages` is generated from the profile, `subagents` (or other portable keys) come from `settings`; host paths and LAN endpoints never |
| `models.json` | copied only if every provider uses a public endpoint and takes its key from an environment variable |
| `web-search.json` | repo template `{"provider": "auto"}` (no SearXNG: it is a self-hosted Python service); keys are added on the drive, never a LAN address |
| `AGENTS.md` | replaced with the portable rule set in `config/pi/AGENTS.md` |
| `workspace/` | created empty for the launcher cwd and the llm-wiki vault (`WIKI_HOME`); the vault itself is not part of the repo |
