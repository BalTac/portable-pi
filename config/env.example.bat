@echo off
REM Portable pi - API keys (Windows)
REM
REM Copia questo file in config\env.bat (stessa cartella) e metti le chiavi reali.
REM Il launcher lo esegue con `call` solo se esiste.
REM Le credenziali OAuth/API principali stanno in config\pi\auth.json e non servono qui.
REM
REM Fornitori disponibili in auth.json: openai-codex, openrouter, nvidia,
REM github-copilot, deepseek. Aggiungi qui solo chiavi che pi legge da ambiente.

set "OPENMODEL_API_KEY=YOUR_KEY_HERE"
