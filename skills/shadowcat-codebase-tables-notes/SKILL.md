---
name: shadowcat-codebase-tables-notes
description: "Use when touching Shadowcat's rollable tables OR rich-text notes. Tables: the `table` engine doc type (`TableEngine`/`DrawRule`/`TableRow`/`RowRange`/`TableEntry`), `tables::handle_draw_table`/`tables::draw::draw_table`'s recursive draw resolution (cycle detection, depth/budget caps, weighted/formula row selection), the `Segment::TableDraw`/`TableDrawSegment`/`DrawnRow` chat segment family and its GM-only spec/raw redaction, the `draw_table` wire frame, the client `table-docs`/`chat-docs` mirrors and `WsClient.drawTable`, or `SegmentList`'s recursive `table_draw` rendering. Notes: the `note` engine doc type (`NoteEngine{source, body, sort}`), `data::engine::note`'s server-derived-body ingress arm, `chat::body::compose_static`/`chat::NOTE_CONTENT_POLICY`, `data::sqlite::notes::check_note_parent`'s parent-tree placement, and the client `note-docs` module (`buildNoteDoc`/`parseNoteBody`). Covers src/server/src/data/engine/table.rs, src/server/src/data/engine/note.rs, src/server/src/tables/, src/server/src/data/sqlite/notes.rs, the `TableDraw`/`DrawnRow`/`roll_property_overrides`/`compose_static`/`NOTE_CONTENT_POLICY` portions of src/server/src/chat/, src/client/core/src/table-docs.ts, src/client/core/src/note-docs.ts, the `table_draw` portion of src/client/core/src/chat-docs.ts, and the `table_draw` portion of src/client/ui-kit/src/SegmentList.svelte. Invoke shadowcat-codebase-core first; for the Segment/redaction/chat-frame machinery a table draw rides and for `compose_static`/`NOTE_CONTENT_POLICY` themselves, invoke shadowcat-codebase-chat; for the row-selecting roll's parse context and formula validation, invoke shadowcat-codebase-dice; for the engine-doc-type registry/containment rules and the note-tree placement mechanics `check_note_parent` plugs into, invoke shadowcat-codebase-documents-permissions."
---

# Shadowcat — Rollable Tables & Notes

Orientation for two independent engine doc types that share this skill because they were delivered
together: a `table` document is authored/edited like any other document (no special write path —
plain `Create`/`Update` through the generic engine-ingress gate), but is only ever *drawn from*
through one server-owned resolution pipeline (`tables::handle_draw_table` →
`tables::draw::draw_table`) that rolls, matches a row, and posts the result to chat as a
`Segment::TableDraw`. A `note` document is ALSO authored/edited like any other document, but its
`body` is unconditionally SERVER-DERIVED from `source` on every Create/Update post-image, through
the same chat sanitizer/span-grammar boundary a chat message's content crosses — nothing about a
table's OWN document lifecycle or a note's OWN document lifecycle is special; everything about a
table DRAW is centralized (row-selecting roll state must stay GM-only, and a malicious or
misconfigured table chain must not recurse forever or fan out unboundedly), and everything about a
note's body derivation happens synchronously at ingest (no client-side rendering, no dedicated
write frame).

## Purpose

**Tables** deliver one engine doc type (`table`) and one action (`draw_table`) that turns it into a
chat message. A table's `TableEngine` is either `DrawRule::Weighted` (rolls `1d<sum-of-row-weights>`, the sum taken in u64,
matches the row whose cumulative weight reaches the total — always has a match by construction)
or `DrawRule::Formula` (rolls the table's own dice notation, matches the row whose inclusive
`RowRange` contains the total — may match nothing). A matched row's `results` resolve into plain
content (`text`/`doc`/`image` entries, the SAME segment shapes chat's own `[[…]]` spans produce)
and `nested` — one `TableDrawSegment` per `TableEntry::Draw` entry, recursing through another
full `draw_table` call. A draw is NEVER stored back onto the table document; it exists only as the
chat message it produces.

**Notes** deliver one engine doc type (`note`) with no action of its own: `NoteEngine{source, body,
sort}` — the author writes `source` (markdown), and `data::engine::mod`'s `"note"` arm of
`normalize_engine` derives `body: Vec<Segment>` from it via `chat::compose_static` under the fixed
`chat::NOTE_CONTENT_POLICY`, on every Create AND every Update post-image. A client's own `body` is
never trusted or partially honored — it is unconditionally overwritten. Notes form a `parent_id`
tree of notes (`data::sqlite::notes::check_note_parent`) and are private to their author by default
(client-side convention: `buildNoteDoc` stamps `permissions.default: "none"` with the author granted
`Owner`).

## Key files & seams

Covers the key files and seams of rollable tables: the table engine doc type, the draw pipeline and the client draw UI. Read references/tables-key-files-and-seams.md before changing any table code.

### Notes — key files & seams

Covers the key files and seams of notes: the note engine doc type, the server-derived body and the client note code. Read references/notes-key-files-and-seams.md before changing any note code.

## Hard invariants

- **A draw is resolved server-side, end to end — there is no client-side row-selection fallback
  and no client-constructed `table_draw` segment.** The client only ever renders a
  `TableDrawSegment` the server already produced.
- **`spec`/`raw` are GM-only at EVERY depth of a draw tree, never just the top level.** A nested
  draw fanned out from `TableEntry::Draw` gets the identical redaction treatment as the top-level
  draw — see `push_draw_overrides`'s recursion through `row.nested`.
- **`cx.chain`'s push/pop must bracket exactly the scope that can recurse, and the pop must run
  even on an error return.** See `draw_table`'s ordering note in references/tables-key-files-and-seams.md — this is the whole cycle
  guard; getting it wrong either falsely rejects a legitimate sibling draw or, worse, permits
  infinite recursion.
- **A table document has no parent and is never embedded** (`validate_containment`'s `table`
  arm) — unlike an item or effect, it is always addressed by its own top-level id.
- **`DrawRule::Weighted`'s row-weight sum is bounded by `chat::rolls::MAX_DIE_SIDES`, because the
  draw literally rolls `1d<sum>`.** Any future change to `MAX_DIE_SIDES` or to how a `Weighted`
  draw derives its notation must keep this bound aligned — the positive+negative control at the
  exact boundary (`weighted_sum_bound_is_the_chat_die_cap`) is what pins it.
- **A note's `body` is unconditionally server-derived; a client's own `body` is NEVER partially
  honored.** `normalize_engine`'s `"note"` arm always overwrites `body` via `derive_body`, on both
  Create and Update — there is no path where a client-supplied `body` (garbage, stale, or even a
  plausible-looking segment list) survives ingress. Treat any future reasoning about note body
  content as "derive from `source`", never "validate the client's `body`". The derived `body`
  reaches live views ONLY because `note` is registered in `data::engine::derived_engine_paths`
  (`/engine/body`) — `derive_engine_side_effects` appends the `/engine/body` change to every
  Update whose own `changes` did not already cover it (see `shadowcat-codebase-documents-permissions`),
  and for any `apply_intent` origin that does not `skips_capability_gates`, a world
  `CapabilityRequirement` protecting `/engine/body` gates a `/engine/source` write through that
  same derived-path check.
- **An inline `[[formula]]` span in a note NEVER executes.** `compose_static` always produces a
  `Segment::RollButton`, never a `Segment::RollEmbed` — a note save must not roll dice as a side
  effect of a document write, unlike chat's own `compose_message` (Execute mode).
- **A note MAY carry a `parent_id`; a table NEVER may.** Do not generalize `table`'s
  no-parent rule to `note`, or vice versa — they are independent containment decisions
  (`validate_containment`'s `table` and `note` arms are separate match cases).

## Gotchas

- **`TableEntry`'s content resolves at DRAW time, never at table-authoring/ingest time.** A
  `Doc`/`Image` entry's target/asset is not existence- or authz-checked when the table itself is
  saved — only when a draw actually resolves it (mirrors chat's own `[[doc:]]`/`[[asset:]]`
  no-check-at-ingest precedent). A GM can author a table referencing a not-yet-created document
  or asset without error; the error (if any) surfaces only on the first draw that reaches it.
- **A `Formula` table's draw can legitimately match no row.** `ranged_row` returning `None` is
  not a `DrawTableError` — the draw still posts a message, with `DrawnRow` absent
  (`TableDrawSegment.row: None`). Client rendering must handle this ("no matching row"), not
  treat it as a failure state.
- **`DrawTableError::TooLong` exists only because `chat::validate_audience` can return
  `SendMessageError::TooLong` for an oversized whisper-recipient list** — a draw has no
  author-typed body, so no OTHER `TooLong` case is reachable through this type; do not read it as
  a general content-length cap.
- **`check_note_parent` shares its in-flight-batch map with `check_asset_folder_parent`** — the
  map's own name is a historical artifact of once tracking only folders; do not assume it tracks
  only folders when reading `check_parent_placement`/`check_move_acyclic`.
- **A test named for `check_note_parent` may genuinely be pinning a DIFFERENT mechanism.** Only
  two shapes actually depend on `check_note_parent` itself: a Create/Move whose new parent exists
  but is the WRONG doc_type, and a Create/Move whose new parent is a note in ANOTHER WORLD *when
  no other check reaches the parent first*. On `Create`, that second case is masked: `apply_intent`
  runs its own generic "an existing parent must be in this world" check
  (`check_command_scope` on the loaded parent) BEFORE `check_note_parent` even matters, so a
  foreign-world-parent Create test passes even with `check_note_parent` stubbed to `Ok(())` — verified by mutation. `Move` has no such generic check, so
  the cross-world case is genuinely `check_note_parent`-dependent ONLY there. A cycle test is
  `check_move_acyclic`'s; a cascade-delete test is the parent foreign key's. Before citing a test
  as coverage for this function, stub it and confirm the test actually fails.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/tables-key-files-and-seams.md | Key files and seams of rollable tables | changing table engine, draw or client table code |
| references/notes-key-files-and-seams.md | Key files and seams of notes | changing note engine, body derivation or client note code |

## Pointers

- `docs/site/protocol.md`'s "Rollable tables" and "Notes" sections — the wire-level summary of
  `draw_table` and of a note's server-derived `body`.
- `docs/design/ARCHITECTURE.md` invariant 6 — `table`'s and `note`'s place in the
  engine-doc-type count.
- `shadowcat-codebase-chat` — `chat::body::compose_static`/`compose_message`'s shared chunk
  grammar, `chat::NOTE_CONTENT_POLICY`, and the `Segment` variants both a table draw and a note
  body compose into.
- `shadowcat-codebase-documents-permissions` — the engine-doc-type registry/containment mechanics
  both `table` and `note` register into, and the generic parent-tree/cascade-delete machinery
  `check_note_parent` plugs into.
- `shadowcat-codebase-sheets` — `@shadowcat/module-sheet-note`/`-sheet-table` are the UI
  consumers of `buildTableDoc`/`buildNoteDoc`/`parseNoteBody`; `@shadowcat/module-notes`/`-tables`
  (see `shadowcat-codebase-client-shell`) are the panel-level consumers, and
  `TableSheet`/`TablesPanel` are the UI consumers of `ChatApi.drawTable`. Nothing in this skill's
  own subsystem builds a sheet or a panel.
