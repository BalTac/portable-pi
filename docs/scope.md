# Scope: cosa entra nella chiavetta e cosa no

Derivato da `manifest.json` (fonte di verità per la build). Regola: **una skill entra solo
se funziona su una macchina vergine senza altri dispositivi della rete**.

## Incluse (9)

| Skill | Peso | Perché è portabile |
|---|---|---|
| `frontend-design` | 12 KB | solo istruzioni |
| `frontend-ui-engineering` | 20 KB | solo istruzioni; `npx` citato come opzione |
| `impeccable` | 22 MB | porta l'engine self-contained (win-x64); su Linux lo scarica al primo uso |
| `ponytail`, `-audit`, `-debt`, `-gain`, `-help`, `-review` | ~28 KB | solo istruzioni |

## Escluse (14)

| Skill | Dipendenza che la blocca |
|---|---|
| `contextvault` | DB + semantic embedding server sul **Pi 5** (`pi5=True`, nitro) |
| `voice-nitro` | server XTTS sul **Nitro** (`127.0.0.1:8123`) — esclusa su richiesta |
| `voice-starlitram` | server TTS su **StarlitRAM** (`192.168.50.185:8008`) — esclusa su richiesta |
| `voice-clone` | clone voci su StarlitRAM + profili su `/mnt/d/audio-server` del Nitro |
| `vision-toolkit` | modelli CV (SCUNet/YOLO/SAM2) sul Nitro |
| `graphify` | CLI `graphify` + redis `:6379` + neo4j `:7687` + python/uv |
| `session-rotation` | `pi-rotate` (python) in `D:\openclaw\bin` + shim WSL |
| `subagent` | tool `subagent` fornito dall'estensione pi-toolkit |
| `council-mode` | estensione pi-subagents |
| `pi-subagents` | estensione pi-subagents + spawn di processi pi figli |
| `pi-intercom` | estensione pi-intercom + una seconda sessione viva sullo stesso host |
| `playwright-browser` | `@playwright/cli` + browser binaries (centinaia di MB) |
| `llm-wiki` | estensione pi-llm-wiki + un vault esistente |
| `loop` | il suo flusso invoca il tool `subagent` (7 riferimenti) |

## Fase 2 (opzionale, non implementata)

Montare l'estensione `pi-subagents` (13 MB, puro JS) sulla chiavetta sbloccherebbe
`subagent`, `pi-subagents`, `council-mode` e `loop`. Serve:

1. installare il pacchetto in `<usb>/config/pi/npm/` e dichiararlo in `settings.json`;
2. uno shim `pi`/`pi.cmd` su `PATH` per i processi figli;
3. un test di spawn isolato (i figli devono ereditare `PI_CODING_AGENT_DIR`).

## Config sanificata

| File | Trattamento |
|---|---|
| `auth.json` | copiato (5 provider: openai-codex, openrouter, nvidia, github-copilot, deepseek) |
| `settings.json` | solo `theme`, `defaultProvider`, `defaultModel`, `defaultThinkingLevel`, `compaction`. **Scartati** `packages` (12 estensioni con path host) e `llm-wiki.embeddingBaseUrl` (`192.168.50.222:8093`, il Pi 5) |
| `models.json` | copiato: provider `openmodel`, endpoint pubblico, chiave via `$OPENMODEL_API_KEY` |
| `AGENTS.md` | riscritto: niente bridge Telegram, niente path `D:\openclaw`; resta la politica "mai push senza approvazione" |
