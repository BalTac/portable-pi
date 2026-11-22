# Selection policy: what ships and what cannot

The skill list itself is private: the repo ships `skills.example.json` only, and the real
selection lives in `skills.local.json` (gitignored). What follows is the **rule** used to
decide, so the reasoning is reusable.

## Rule

A skill ships only if it works on a **virgin machine** with nothing but the drive:

1. it needs no service on your LAN (no fixed IPs, no localhost ports, no GPU box);
2. it needs no private repository, database or vault that only you have;
3. it needs no host path (`D:\...`, `/mnt/...`, `~/.local/bin/<your-shim>`);
4. it needs no installed tool that the drive does not carry (this rules out Python
   toolchains, browser binaries, GPU models, and similar);
5. if it depends on a pi extension, that extension must be installable on the drive
   (`pi install npm:...`) and be pure JS/TS, because the agent dir is shared between
   Windows and Linux.

Categories that fail this rule, and why:

| Category | Blocking dependency |
|---|---|
| Anything talking to a local service | a second machine on your network, a fixed IP, a port |
| Anything running local models | GPU host, model weights, a Python or CUDA stack |
| Anything needing a private repo or vault | data that is not on the drive |
| Anything needing a host shim or absolute path | the drive must be self-contained |
| Extension-backed skills | the extension must be pure JS and installed on the drive |
| Skill packages with browser binaries | hundreds of MB downloaded per platform |

## How the whitelist is applied

- `skills.local.json` → `include[]` entries `{ name, root, path }`, where `root` is
  `agent` (`<home>/.pi/agent`), `agents` (`<home>/.agents`) or `npm`
  (`<home>/.pi/agent/npm/node_modules`).
- The build copies each entry to `<drive>/config/pi/skills/<name>/` and merges the list into
  `<drive>/manifest.json`; `update` and `verify` read that drive manifest, so the drive
  documents itself.
- Skills with `disable-model-invocation: true` still ship: they are reachable through
  `/skill:<name>` but are deliberately absent from the model's skill index.

## Config that gets sanitized

Whatever machine you build on, some files are host-specific and must not travel:

| File | Treatment |
|---|---|
| `auth.json` | copied (credentials are meant to travel with the drive) |
| `settings.json` | only `theme`, default provider/model/thinking level and `compaction`; `packages` (extensions bound to host paths) and any embedding endpoint pointing at a LAN address are dropped |
| `models.json` | copied only if every provider uses a public endpoint and takes its key from an environment variable |
| `AGENTS.md` | replaced with the portable rule set in `config/pi/AGENTS.md` |
