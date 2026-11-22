# portable-pi

**Una chiavetta USB con `pi` (pi-coding-agent) dentro. Nessuna installazione sull'host.**

Colleghi, lanci, lavori, scolleghi. Sessioni, credenziali, skill e cache restano sulla
chiavetta: l'host non viene toccato e non c'è alcuna dipendenza da altri dispositivi
della tua rete.

```
Windows  → doppio clic su start.bat
Linux    → bash /media/$USER/PORTABLE-PI/start.sh
```

---

## Cosa contiene

| Componente | Ruolo |
|---|---|
| Node.js 24 LTS (win-x64 + linux-x64) | runtime portatile, nessuna installazione |
| `pi` 1.6.0 (bundle ESM) | l'agente |
| 9 skill whitelist | istruzioni pure, funzionano su una macchina vergine |
| PortableGit (solo Windows) | garantisce il tool `bash` e `git` anche su host senza Git |
| `config/pi/` | agent dir: auth, settings, models, AGENTS.md, skills, sessions |

Non contiene: estensioni, MCP server, provider self-hosted, TTS, vision, wiki, contexte
vault. Motivo per ogni esclusione in [docs/scope.md](docs/scope.md) e nel `manifest.json`.

## Isolamento (verificato, non dichiarato)

Il launcher imposta:

```
PI_CODING_AGENT_DIR=<usb>/config/pi
PI_CODING_AGENT_SESSION_DIR=<usb>/config/pi/sessions
TMPDIR / TMP / TEMP / NPM_CONFIG_CACHE / NODE_COMPILE_CACHE / XDG_CACHE_HOME → <usb>/temp
```

e lancia:

```
pi -ns --skill <usb>/config/pi/skills
```

`-ns` disattiva **tutte** le skill scoperte, comprese quelle dell'host in `~/.agents/skills`,
mentre i path passati con `--skill` continuano a caricare. Risultato:

- le sessioni nascono e restano sulla chiavetta, l'host `~/.pi/agent` non viene né letto né scritto;
- le skill caricate sono esattamente quelle della chiavetta;
- estensioni, pacchetti, MCP, prompt template e temi vengono solo da `config/pi/`.

`scripts/verify.sh` / `scripts/verify.ps1` collaudano questi punti e falliscono se qualcosa
scrive fuori dal drive.

## Requisiti

| Requisito | Dettaglio |
|---|---|
| Chiavetta | 2 GB exFAT, **USB 3.0 raccomandato** |
| Host | Windows 10/11 x64 oppure Linux x64 (glibc ≥ 2.28) |
| Rete | internet per il modello (nessun server locale richiesto) |
| Costruzione | Windows con PowerShell 5.1+ **oppure** Linux con `curl`, `unzip`, `xz` |

## Build

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Target E:\
```

```bash
# Linux
bash scripts/build.sh /media/$USER/PORTABLE-PI
```

Opzioni: `-SkipGit` / `--skip-git` (niente PortableGit, −350 MB),
`-PiVersion x.y.z`, `-NodeVersion x.y.z`, `-SmokeTest`.

La build è idempotente: rilanciarla aggiorna pi e le skill senza toccare auth e sessioni.

## Aggiornare pi o le skill

`pi update` è disabilitato di proposito (`PI_SKIP_VERSION_CHECK=1`): su un'installazione
portatile l'aggiornamento si fa **ricostruendo la chiavetta**. Cambia `pi.version` nel
`manifest.json`, rilancia la build. Auth e sessioni restano.

## Limiti noti

- exFAT non ha permessi POSIX: su alcune distro il drive viene montato con `fmask=0113` e
  `node` non risulta eseguibile. Il launcher lo rileva e stampa il comando di remount
  (`sudo mount -o remount,umask=000 …`).
- Console Windows legacy: la TUI richiede VT (Win10 1511+). Su host molto vecchi usare Windows Terminal.
- `impeccable` porta l'engine win-x64; su Linux lo scarica al primo uso (serve internet).
- USB 2.0: avvio nell'ordine dei secondi.

## Segreti

`config/pi/auth.json` contiene token OAuth / API key **in chiaro**. Se perdi la chiavetta:
revoca le credenziali dei provider elencati nel file, oppure lancia `pi` e usa `/logout`.
Non committare mai `auth.json`, `config/env.sh`, `config/env.bat`, `config/pi/sessions/`.

## Licenza

MIT — vedi [LICENSE](LICENSE).
