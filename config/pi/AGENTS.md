# Portable pi — istruzioni globali

Stai girando da una chiavetta USB portatile, su una macchina che quasi
certamente non è quella del tuo utente abituale.

## Contesto

- Sessioni, config, skill e cache sono **sulla chiavetta** (`config/pi/`, `temp/`).
  Non scrivono nulla in `~/.pi/agent` dell'host: è una garanzia del launcher, non un'ipotesi.
- Le skill disponibili sono **solo** quelle montate dalla chiavetta (`config/pi/skills`)
  più quelle eventualmente esposte dai pacchetti che hai installato tu sul drive.
- La macchina host può essere di un amico, un PC aziendale o una VM usa-e-getta.

## Regole sull'host

- **Non toccare il sistema host**: niente pacchetti, niente modifiche a file di sistema,
  niente `sudo`/elevazione, niente modifiche a `~/.bashrc`, `~/.gitconfig`, registro,
  variabili d'ambiente permanenti o servizi.
- **Chiedi prima** di qualunque azione distruttiva o irreversibile fuori dalla directory
  di lavoro corrente.
- **Lavora nella directory del progetto**, non in `$HOME`. Se serve un file temporaneo,
  usa `$TMPDIR`/`%TEMP%`, che puntano già alla chiavetta.
- **Git**: commit locali pure, **mai push** su un remoto senza approvazione esplicita
  dell'utente ("Vuoi che pushi?" e attendi un "sì" chiaro). Eccezione solo se l'utente
  ha già approvato quel push specifico.
- **Segreti**: le credenziali vivono in `config/pi/auth.json` sulla chiavetta. Non
  stamparle, non copiarle fuori dal drive, non metterle in un commit.
- Se l'host sembra compromesso o i permessi sono strani, fermati e dillo all'utente
  invece di aggirare il problema.

## Ambiente isolato: dove va installato tutto

Regola unica: **tutto ciò che ti serve vive sul drive, dentro il tuo agent dir**.
Il tuo `PI_CODING_AGENT_DIR` è `<drive>/config/pi`: settings, estensioni, pacchetti,
skill, MCP e sessioni stanno lì. Non esiste un'installazione "di sistema" che ti serva.

### Skill

- Skill nuova o modificata → `<drive>/config/pi/skills/<nome>/SKILL.md`
  (frontmatter `name` + `description`; è la directory già montata dal launcher, quindi
  viene caricata subito dopo `/reload`).
- Non scrivere in `~/.agents/skills` o `~/.pi/agent/skills` dell'host: non vengono lette
  (il launcher usa `-ns` + `--skill`) e sarebbero comunque fuori dal tuo ambiente.
- Skill che arrivano dentro un pacchetto: si caricano da sole, non copiarle a mano.

### Estensioni e pacchetti

```bash
pi install npm:<pacchetto>      # scope personale = <drive>/config/pi  (CORRETTO)
pi list                         # verifica cosa è configurato
pi remove npm:<pacchetto>       # disinstalla
pi -e npm:<pacchetto>           # prova per una sola invocazione (cache sul drive)
```

- **Mai `-l` / `--local`**: scrive `.pi/settings.json` **nel progetto dell'host**, cioè
  fuori dal tuo ambiente. Se un comando richiede `-l`, fermati e chiedi.
- **Mai `npm install -g`, `pip install --user`, `apt`, `brew`, `cargo install`,
  `winget`**: installerebbero sull'host. Se un'estensione ha bisogno di un binario
  esterno, dillo all'utente invece di installarlo.
- Le cache di npm e le estensioni temporanee finiscono già in `<drive>/temp` e
  `<drive>/config/pi`: non serve reindirizzarle a mano.
- Dopo un'installazione: `/reload` (o riavvia pi). Se l'installazione fallisce per rete,
  **non** ripiegare su un'installazione globale: segnala l'errore.

### Vincolo cross-platform

La stessa chiavetta deve funzionare su Windows e Linux, e l'agent dir è **condiviso**
tra i due sistemi. Quindi:

- preferisci estensioni **pure JS/TS**, senza binari nativi (`*.node`, `*.exe` inclusi);
- prima di installare, controlla il `package.json`: dipendenze con `os`/`cpu` o
  `optionalDependencies` native = probabilmente si rompono sull'altro sistema;
- se un'estensione è inevitabilmente nativa, dillo all'utente: funzionerà solo sul
  sistema su cui l'hai installata. Non installare due copie nella stessa cartella.

### Spazio

Il drive è piccolo (~1,2 GB liberi): prima di installare qualcosa di grosso controlla
`du -sh "$PI_CODING_AGENT_DIR"` e `df -h`. Se lo spazio si esaurisce, libera
`<drive>/temp/npm-cache` prima di tutto il resto.

### Manutenzione del drive

- `bash <drive>/scripts/update.sh` — aggiorna pi (e opzionalmente Node) senza toccare
  auth, sessioni, settings e skill locali.
- `bash <drive>/scripts/verify.sh <drive>` — collauda che l'isolamento sia intatto.
- Su Windows gli stessi comandi sono `scripts\update.ps1` e `scripts\verify.ps1`.

## Lingua

Rispondi nella lingua dell'utente (di norma italiano). Sii conciso; mostra i path dei
file quando tocchi il codice.
