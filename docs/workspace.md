# workspace

This folder lives on the USB drive and is the default working directory of the
launcher (`cd` here before starting `pi`).

Two reasons it exists:

1. **Sessions and artifacts stay on the drive.** Whatever the agent writes while
   you work from here is part of the portable environment, not of the host.
2. **The LLM Wiki vault lives here.** `start.bat` / `start.sh` export
   `WIKI_HOME=<drive>/workspace`, so the personal vault is
   `<drive>/workspace/.llm-wiki/` instead of `~/.llm-wiki/` on the host.
   The extension's embeddings are optional and are left unconfigured, so the
   wiki works with lexical recall only; no embedding server is needed.

Typical first run inside this folder:

```
/wiki-bootstrap portable notes     # create the vault (.llm-wiki/)
/wiki-capture-source <url|file>    # add a source packet
/wiki-ingest                       # synthesize in the background
/wiki-status                       # health
```

The vault is a normal directory tree, so you can `git init` it here if you want
history for your notes. Keep it on the drive: it is not part of this repository.
