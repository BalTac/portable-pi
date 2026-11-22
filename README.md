# portable-pi

**Una chiavetta USB con `pi` (pi-coding-agent) dentro. Nessuna installazione sull'host.**

Colleghi, lanci, lavori, scolleghi. Sessioni, credenziali, skill e cache restano sulla
chiavetta: l'host non viene toccato e non c'è alcuna dipendenza da altri dispositivi
della tua rete.

```
Windows  → doppio clic su start.bat
Linux    → bash /media/$USER/PORTABLE-PI/start.sh
```

Volume: **~430 MB**, ~7.600 file. Chiavetta consigliata: **2 GB exFAT, USB 3.0**.

---

## Quick start

**Windows** — apri la chiavetta in Esplora file, doppio clic su `start.bat`.
Si apre pi con le skill del drive già montate.

**Linux** — `bash /media/$USER/PORTABLE-PI/start.sh`.
Se il drive è montato senza bit di esecuzione, lo script te lo dice e ti stampa il
comando di remount.

```bash
bash start.sh --shell        # invece di pi, una shell con node/git/pi nel PATH
bash start.sh --version      # qualunque argomento viene passato a pi
```

## Cosa contiene

| Componente | Ruolo | Peso | File |
|---|---|---|---|
| Node.js 24.22.3 LTS (win-x64 + linux-x64) | runtime portatile | 102 + 192 MB | 6.794 |
| `pi` 1.6.0 (`dist/bundle` + `pi-tui` + `photon-node`) | l'agente | 17 MB | 343 |
| 9 skill whitelist | istruzioni pure, nessun dispositivo esterno | 22 MB | 77 |
| MinGit (solo Windows) | garantisce `bash` e `git` anche su host senza Git | 94 MB | 376 |
| `config/pi/` | auth, settings, models, AGENTS.md, skills, sessions | — | — |

Non contiene: estensioni, MCP server, provider self-hosted, TTS, vision, contextvault,
wiki. Il motivo esatto di ogni esclusione è in [docs/scope.md](docs/scope.md) e nel
`manifest.json`.

### Skill incluse

`frontend-design`, `frontend-ui-engineering`, `impeccable`, `ponytail`,
`ponytail-audit`, `ponytail-debt`, `ponytail-review` (queste visibili al modello) più
`ponytail-gain` e `ponytail-help`, richiamabili solo con `/skill:ponytail-gain` e
`/skill:ponytail-help` perché dichiarano `disable-model-invocation: true`.

## Isolamento (verificato, non dichiarato)

Il launcher imposta:

```
PI_CODING_AGENT_DIR=<usb>/config/pi
PI_CODING_AGENT_SESSION_DIR=<usb>/config/pi/sessions
PI_SKIP_VERSION_CHECK=1   PI_TELEMETRY=0
TMP / TEMP / TMPDIR / NPM_CONFIG_CACHE / NODE_COMPILE_CACHE / XDG_CACHE_HOME → <usb>/temp
```

e lancia:

```
pi -ns --skill <usb>/config/pi/skills
```

`-ns` disattiva **tutte** le skill scoperte — comprese quelle dell'host in
`~/.agents/skills` — mentre i path passati con `--skill` continuano a caricare. Quindi:

- le sessioni nascono e restano sulla chiavetta; `~/.pi/agent` non viene né letto né scritto;
- le skill caricate sono esattamente quelle del drive;
- estensioni, pacchetti, MCP, prompt template e temi vengono solo da `config/pi/`;
- `HOME`/`USERPROFILE` restano quelli dell'host, così git/npm usano la config di chi ti ospita.

Verifica automatica:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify.ps1 -Drive E:\
```
```bash
bash scripts/verify.sh /media/$USER/PORTABLE-PI
```

Controlla layout, whitelist skill, assenza di riferimenti host, il launcher, un turno
reale con marker, il set di skill effettivamente visibile al modello (deve essere quello
del drive, senza leakage), la sessione scritta sul drive e l'hash della config host
prima/dopo. Esce con codice ≠ 0 se qualcosa scrive fuori dal drive. `--no-model` per i
soli controlli statici.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Target E:\
```
```bash
bash scripts/build.sh /media/$USER/PORTABLE-PI
```

Opzioni: `-SkipGit` / `--skip-git` (niente MinGit, −94 MB), `-PiVersion x.y.z`,
`-NodeVersion x.y.z`, `-SmokeTest` / `--smoke`, `-Force` / `--force`.

La build è idempotente: rilanciarla aggiorna pi e le skill senza toccare
`auth.json` e `sessions/` (che restano, a meno di `-Force`).

Requisiti del *build host*: Windows 10 1803+ (per `tar.exe`) oppure Linux con
`curl`, `tar`, `unzip`, `node`.

## Aggiornare pi o le skill

`pi update` è disabilitato di proposito (`PI_SKIP_VERSION_CHECK=1`): su un'installazione
portatile l'aggiornamento si fa **ricostruendo la chiavetta**. Cambia `pi.version` (o
`node.version`, o la lista skill) nel `manifest.json`, rilancia la build. Auth e sessioni
restano dov'erano.

## Limiti noti

- **exFAT e permessi POSIX.** Alcune distro montano il drive con `fmask=0113`, quindi
  `node` esce non eseguibile. Il launcher lo rileva e stampa il rimedio:
  `sudo umount … && sudo mount -o remount,umask=000 …`, oppure una riga in `/etc/fstab`
  con `LABEL=PORTABLE-PI … exfat defaults,uid=$(id -u),umask=000 0 0`.
- **Console Windows legacy.** La TUI richiede VT (Windows 10 1511+). Su host molto vecchi
  usare Windows Terminal.
- **`impeccable`** porta l'engine win-x64; su Linux/macOS lo scarica al primo uso (serve
  internet una volta).
- **Solo x64.** ARM64 non è coperto dal manifest.
- **USB 2.0**: avvio nell'ordine dei secondi; il grosso sono i 6.800 file di Node.
- **`pi wsl`/sandbox**: non testati con questo layout; il sandbox di pi non è configurato.

## Segreti

`config/pi/auth.json` contiene token OAuth / API key **in chiaro** sul drive.
Se perdi la chiavetta:

1. revoca le credenziali dei provider elencati nel file (openai-codex, openrouter,
   nvidia, github-copilot, deepseek);
2. oppure avvia pi da un'altra installazione e usa `/logout` per i provider interessati.

`config/env.sh` e `config/env.bat` (chiavi via ambiente, es. `OPENMODEL_API_KEY`) sono
creati dalla build come copia dei template e non vanno mai committati.

## Struttura

```
PORTABLE-PI/
├── start.bat / start.sh        launcher
├── autorun.inf                 solo label/icona (Windows ignora AutoRun sui USB)
├── bin/{win,linux}/node-v24.22.3-*/
├── tools/
│   ├── pi/node_modules/@earendil-works/{pi-coding-agent,pi-tui}, @silvia-odwyer/photon-node
│   ├── git/mingit/             solo Windows
│   └── bin/pi, pi.cmd          shim usabili anche fuori dal launcher
├── config/pi/                  agent dir: auth.json, settings.json, models.json,
│                               AGENTS.md, skills/, sessions/
├── temp/                       TMP / cache npm+node / XDG_CACHE_HOME
├── scripts/                    verify.ps1 + verify.sh (per collaudare il drive da sé)
├── docs/scope.md
└── manifest.json               cosa è stato costruito (versione, skill, esclusioni)
```

La build (`scripts/build.ps1` / `scripts/build.sh`) e i template di `config/` vivono nel
repo, non sul drive: sul drive c'è solo il verificatore.

## Licenza

MIT — vedi [LICENSE](LICENSE).
