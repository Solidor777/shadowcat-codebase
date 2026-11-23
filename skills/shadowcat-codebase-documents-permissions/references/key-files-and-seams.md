Part of the shadowcat-codebase-documents-permissions skill; read it when touching any file or seam under src/server/src/data or its client wire mirror.

# Key files and seams

The full Key files & seams section: `data::document`, `data::engine`, `data::permission`, `data::search`, `Repository` and validation, `apply_intent` and its `WriteOrigin`s, the client `wire` mirror, snapshots and role caps.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-document-engine-token-ownership.md](key-files-and-seams-01-document-engine-token-ownership.md) | Key files & seams: `data::document`; geometry and asset-ref validators; `data::engine`; effective token ownership; the level dimension of the vision and footprints channels | Touching the `Document` envelope, engine-band structs, ingress validation, token ownership or the derived vision and footprints channels |
| [key-files-and-seams-02-field-changes-permission-search.md](key-files-and-seams-02-field-changes-permission-search.md) | Key files & seams: `apply_field_change`; `validate_field_change`; `Operation::Move`; `FieldChange.remove`; `data::permission`; `data::search`; `Repository` and `data::validation` | Touching field-change application or validation, Move, redaction in `data::permission`, search indexing or the `Repository` trait |
| [key-files-and-seams-03-apply-intent-wire-snapshots-caps.md](key-files-and-seams-03-apply-intent-wire-snapshots-caps.md) | Key files & seams: `validate_system_schema_tree`; `data::sqlite::apply_intent` and its `WriteOrigin` capability-skips; the sandboxed-validator chokepoint; the client `wire` and `scene-docs` modules; `data::snapshot`; role caps; `grantAuthor` | Touching `apply_intent`, a `WriteOrigin`, OCC pre-image comparison, the client wire mirror, snapshots or role caps |
