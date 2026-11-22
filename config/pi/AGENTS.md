# Portable pi — global instructions

You are running from a portable USB drive, on a machine that is almost certainly **not**
the usual computer of your user.

## Context

- Sessions, config, skills and caches live **on the drive** (`config/pi/`, `temp/`). They do
  not write anything into the host's `~/.pi/agent`: that is guaranteed by the launcher, not
  an assumption.
- The available skills are **only** the ones mounted from the drive (`config/pi/skills`) plus
  the ones exposed by packages you installed on the drive yourself.
- The host may be a friend's laptop, a corporate PC or a throwaway VM.

## Rules about the host

- **Do not touch the host**: no package installs, no system file edits, no `sudo`
  or privilege escalation, no changes to `~/.bashrc`, `~/.gitconfig`, the registry,
  persistent environment variables or services.
- **Ask before** anything destructive or irreversible outside the current working directory.
- **Work inside the project directory**, not in `$HOME`. If you need a temporary file, use
  `$TMPDIR`/`%TEMP%`, which already point at the drive.
- **Git**: local commits are fine, **never push** to a remote without explicit approval from
  the user ("shall I push?" and wait for a clear yes). The only exception is a push the user
  already approved for that specific work.
- **Secrets**: credentials live in `config/pi/auth.json` on the drive. Do not print them, do
  not copy them off the drive, never put them in a commit.
- If the host looks compromised or permissions look wrong, stop and tell the user instead of
  working around it.

## Isolated environment: everything you install goes here

One rule: **what you need lives on the drive, inside your agent dir**. Your
`PI_CODING_AGENT_DIR` is `<drive>/config/pi`: settings, extensions, packages, skills, MCP
servers and sessions all belong there. There is no system-wide installation you need.

### Skills

- New or edited skill → `<drive>/config/pi/skills/<name>/SKILL.md` (frontmatter `name` +
  `description`). That directory is mounted by the launcher, so `/reload` picks it up.
- Do not write into the host's `~/.agents/skills` or `~/.pi/agent/skills`: they are not read
  (the launcher uses `-ns` + `--skill`) and they are outside your environment anyway.
- Skills that come inside a package load on their own; do not copy them by hand.

### Extensions and packages

```bash
pi install npm:<package>      # personal scope = <drive>/config/pi   (CORRECT)
pi list                       # what is configured
pi remove npm:<package>       # uninstall
pi -e npm:<package>           # try for a single invocation (cache on the drive)
```

- **Never `-l` / `--local`**: it writes `.pi/settings.json` **into the host project**, i.e.
  outside your environment. If a command requires `-l`, stop and ask.
- **Never `npm install -g`, `pip install --user`, `apt`, `brew`, `cargo install`, `winget`**:
  they install on the host. If an extension needs an external binary, tell the user instead
  of installing it.
- npm caches and temporary extensions already land in `<drive>/temp` and `<drive>/config/pi`;
  no redirection needed.
- After installing: `/reload` (or restart pi). If an install fails because of the network,
  do **not** fall back to a global install: report the error.

### Cross-platform constraint

The same drive must work on Windows and Linux, and the agent dir is **shared** between them:

- prefer **pure JS/TS** extensions with no native binaries (`*.node`, bundled `.exe`);
- before installing, check the `package.json`: dependencies carrying `os`/`cpu` fields or
  native `optionalDependencies` will probably break on the other system;
- if an extension is unavoidably native, tell the user: it will only work on the system where
  you installed it. Do not install two copies into the same directory.

### Disk space

The drive is small: before installing something large, check `du -sh
"$PI_CODING_AGENT_DIR"` and `df -h`. If space runs out, clear
`<drive>/temp/npm-cache` first.

### Drive maintenance

- `bash <drive>/scripts/update.sh` — updates pi (and optionally Node) without touching auth,
  sessions, settings or local skills.
- `bash <drive>/scripts/verify.sh <drive>` — checks that isolation is intact.
- On Windows the same commands are `scripts\update.ps1` and `scripts\verify.ps1`.

## Language

Reply in the user's language (Italian by default for this user). Be concise; show file paths
when you touch code.
