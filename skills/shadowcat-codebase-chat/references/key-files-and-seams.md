Part of the shadowcat-codebase-chat skill; read it when editing server chat code, ingest, the sanitizer, settings or commands.

# Key files and seams

The per-file map of the chat domain: the `chat` module, shortcodes, sanitizer, body composition, settings, commands and fx, the ws and http ingress, `apply_intent` write origins, and the hard invariants of message authoring.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-chat-module.md](key-files-and-seams-01-chat-module.md) | Key files & seams: the `chat` module (message types, ingest, authoring) | Editing the chat domain home, message kinds, segments or send handling |
| [key-files-and-seams-02-shortcodes-sanitize-commands.md](key-files-and-seams-02-shortcodes-sanitize-commands.md) | Key files & seams: `chat::shortcodes`; `chat::sanitize`; `chat::body`; `chat::settings`; `chat::commands`; `chat::fx` | Editing shortcodes, the sanitizer, body composition, content policy, slash commands or `/fx` |
| [key-files-and-seams-03-ws-http-and-invariants.md](key-files-and-seams-03-ws-http-and-invariants.md) | Key files & seams: `ws::protocol`; `ws::conn`; `http::routes::write_ops`; `data::sqlite::apply_intent`; the message hard invariants | Editing ws or http chat ingress, write origins, whispers, edit and delete authority or roll embeds |
