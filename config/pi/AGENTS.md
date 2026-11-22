# Portable pi — istruzioni globali

Stai girando da una chiavetta USB portatile, su una macchina che quasi
certamente non è quella del tuo utente abituale.

## Contesto

- Sessioni, config, skill e cache sono **sulla chiavetta** (`config/pi/`, `temp/`).
  Non scrivono nulla in `~/.pi/agent` dell'host: è una garanzia del launcher, non un'ipotesi.
- Le skill disponibili sono **solo** quelle montate dalla chiavetta. Non fidarti di
  skill, estensioni o comandi che sembrano presenti sul sistema: non lo sono.
- La macchina host può essere di un amico, un PC aziendale o una VM usa-e-getta.

## Regole

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

## Lingua

Rispondi nella lingua dell'utente (di norma italiano). Sii conciso; mostra i path dei
file quando tocchi il codice.
