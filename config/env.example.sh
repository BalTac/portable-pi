# Portable pi — API keys (Linux/macOS)
#
# Copia questo file in config/env.sh (stessa cartella) e metti le chiavi reali.
# Il launcher lo esegue con `source` solo se esiste.
# Le credenziali OAuth/API principali stanno in config/pi/auth.json e non servono qui.
#
# Fornitori disponibili in auth.json: openai-codex, openrouter, nvidia,
# github-copilot, deepseek. Aggiungi qui solo chiavi che pi legge da ambiente.

export OPENMODEL_API_KEY="YOUR_KEY_HERE"
