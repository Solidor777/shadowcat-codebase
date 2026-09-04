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
chat message. A table's `TableEngine` is either `DrawRule::Weighted` (rolls `1d<sum-of-row-weights>`,
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

- `data::engine::table` — the `table` engine doc type, `#[ts(export)]` +
  `#[serde(deny_unknown_fields)]` on every struct:
  - `TableEngine{draw: DrawRule, rows: Vec<TableRow>, description: String}` — envelope `name` is
    the table's display name; `description` is plain text, never rendered as markup.
  - `DrawRule` — `Weighted` | `Formula{notation: String}` (`#[serde(tag = "kind")]`). A
    `Formula` row's `notation` is ingress-validated via `chat::rolls::validate_table_formula`
    (see `shadowcat-codebase-dice`), never left to fail lazily at draw time.
  - `TableRow{weight: u32, range: Option<RowRange>, label: String, results: Vec<TableEntry>}` —
    `weight` is used (and must still be `>= 1`) under BOTH draw rules, even though only
    `Weighted` reads it for selection; `range` must be `Some` under `Formula`, `None` under
    `Weighted`.
  - `RowRange{lo: i32, hi: i32}` — an inclusive total range, deliberately the narrower 32-bit
    integer width rather than the wider one: a row range bounds a dice roll's total, already well
    within the narrower width via `MAX_DIE_SIDES`/`MAX_ROLL_DICE`, and the wider width would force
    ts-rs to emit a client-unconstructible bigint; `TableEngine::validate` requires
    `lo <= hi` and requires every `Formula` row's range to be non-overlapping with every other
    row's (NOT that ranges are exhaustive — a total matching no row's range is a legitimate "no
    matching row" draw, `DrawnRow` absent).
  - `TableEntry` — `Text{text}` (sanitized through `chat::sanitize` at DRAW time, same content
    policy every chat message uses) | `Doc{target: DocLinkTarget, label}` (becomes a
    `Segment::DocLink`, no existence check at draw time — same fail-closed-at-render precedent as
    chat's own `[[doc:]]` spans) | `Image{asset_id, alt}` (becomes a `Segment::Image` iff the
    asset resolves AND is IN THE DRAWING WORLD — `DrawTableError::MissingAsset` otherwise, a
    GM-fixable table-authoring error, never silently dropped) | `Draw{table_id, count}` (fans out
    `count` nested `draw_table` calls at `depth + 1`).
  - `TableEngine::validate(&self) -> Result<(), String>` — row count `<= MAX_TABLE_ROWS=1000`;
    every `weight >= 1`; label/text/description/alt length caps
    (`MAX_ROW_LABEL_CHARS`/`MAX_ROW_TEXT_CHARS`/`MAX_TABLE_DESCRIPTION_CHARS`/chat's own
    `MAX_IMAGE_ALT_CHARS`); `TableEntry::Draw.count` within `1..=MAX_NESTED_DRAW_COUNT=10`;
    `DrawRule::Weighted`'s summed row weights must not exceed
    `chat::rolls::MAX_DIE_SIDES` (the roll it drives is a literal `1d<sum>`, so this IS that
    cap, pinned by a mutation-style positive+negative control at the exact boundary — see
    `data::engine::table::tests::weighted_sum_bound_is_the_chat_die_cap`); `DrawRule::Formula`
    requires EVERY row to carry a `range`, `lo <= hi`, and pairwise non-overlap, plus notation
    validity via `validate_table_formula`.
  - `TABLE_DOC_TYPE = "table"`. Registered in `is_engine_doc_type`/`normalize_engine`
    (`data::engine::mod`) and `validate_containment` (`data::validation`) — a table is ALWAYS
    top-level: no parent, never embedded (see `shadowcat-codebase-documents-permissions` for the
    registry/containment mechanics this plugs into).
- `tables` module (`src/server/src/tables/`) — the one place a draw happens:
  - `DrawTableRequestCtx<'a>{room, repo, ctx, rate, now, budget_per_min}` — mirrors
    `MessageRequestCtx`'s shape; deliberately carries NO `world_defaults` field.
    `handle_draw_table` loads `repo.world_cap_defaults(room.world_id)` INTERNALLY, mirroring
    `combat::handle_combat_intent`'s own acquisition (a fresh read per request, not a
    connection-lifetime cache) rather than trusting a caller-supplied snapshot.
  - `handle_draw_table(req, table_id, channel, count, actor_owner, audience) ->
    Result<Command, DrawTableError>` — reuses chat's OWN validation chokepoints, not
    reimplementations: `rate.check` (flood budget), `chat::channel_registered`,
    `chat::validate_audience`, `chat::validate_actor_owner` (if `actor_owner` is `Some`), then a
    `count` bound (`1..=MAX_TOP_LEVEL_DRAWS=10`) BEFORE resolving `world_cap_defaults`/
    `resolve_content_policy` and looping `draw::draw_table` `count` times, each iteration
    appending one `Segment::TableDraw` to the outgoing message's `content`. Publishes exactly ONE
    `MessageKind::Roll` message via `chat::build_message_doc` + `Room::publish` — the SAME
    authoring chokepoint every other message goes through, never a bespoke document-write path.
  - `DrawTableError` — `[sec]`-classified `Display` mirrors `SendMessageError`'s rule:
    `Forbidden`/`NotFound`/`Data` all collapse to ONE generic "that table could not be found"
    string (no existence oracle — a hidden table and a nonexistent table id are indistinguishable
    to the caller); every other variant (`RateLimited`, `UnknownChannel`, `UnknownRecipient`,
    `ActorNotSpeakable`, `TooMany`, `TooDeep`, `Cycle`, `EmptyTable`, `MissingAsset`, `Roll`,
    `TooLong`) is specific and player-presentable. `From<SendMessageError>` maps the two
    `SendMessageError`-returning reused functions onto this type; every OTHER
    `SendMessageError` variant maps conservatively to `Forbidden` (never leaks anything, and a
    future `SendMessageError` variant compiles here rather than panicking in production).
- `tables::draw` — the recursive resolver:
  - `DrawCtx<'a>{repo, ctx, world_defaults, policy, world_id, chain: Vec<Uuid>, budget: usize,
    image_urls: Vec<chat::ImageSource>, #[cfg(test)] seed: Option<u64>}` —
    `chain` is the DFS-visited-stack cycle guard (table ids on the CURRENT recursion path only,
    not the whole request tree — two sibling branches reusing the same table id are both fine);
    `budget` counts every draw resolved ACROSS THE WHOLE REQUEST (top-level plus every nested
    fan-out), capped at `MAX_DRAWS_PER_REQUEST=64` regardless of depth. `image_urls` accumulates
    inline markdown image sources from every `TableEntry::Text` entry resolved anywhere in the
    tree (top-level plus every nested fan-out) — `handle_draw_table` runs ONE
    `chat::enrich_link_previews` call over the assembled message content after every draw
    resolves, mirroring `chat::body::compose_message`'s own per-message collection, so a row's
    inline image is asset-ified exactly like a chat message's (see `shadowcat-codebase-chat`'s
    `link_preview`/`post_publish` machinery — the SAME `LinkPreviewDeps` bundle
    `MessageRequestCtx` carries is threaded through `DrawTableRequestCtx`). `seed` is a
    `#[cfg(test)]`-only deterministic roll seed (never compiles into the release binary) —
    `draw_table` reads it to choose `chat::rolls::execute_roll_with_seed` over
    `chat::rolls::execute_roll`; set via the `#[cfg(test)]` `draw_table_with_seed` wrapper
    (never by hand), which lets a row-selection test assert a deterministic matched row across
    a genuine multi-row table instead of relying on a degenerate single-row (always-hit) or
    wholly-out-of-range (always-miss) fixture.
  - `draw_table(cx, table_id, depth)` — checks budget/depth/cycle FIRST (in that order), then
    loads+authorizes the table (`resolve_access_world` against `cx.world_defaults`, `cap::READ`
    required — `DrawTableError::Forbidden` on a denial), deserializes+validates the stored
    `TableEngine`, rolls under `chat::rolls::TABLE_PARSE_CONTEXT` via `chat::rolls::execute_roll`
    (or, in a test build with `cx.seed` set, `chat::rolls::execute_roll_with_seed`), matches a
    row (`weighted_row`/`ranged_row`, pure functions), then resolves that row's
    `results` via `resolve_row_results`. **`table_id` is pushed onto `cx.chain` for the duration
    of resolving the matched row, popped UNCONDITIONALLY on every path — including the error
    path — by capturing the `Result` via `.map()` BEFORE popping, then propagating via `?` only
    AFTER the pop.** An early `?` inside the pushed scope would otherwise leak `table_id` on
    `cx.chain` past this call's return, corrupting cycle detection for a LATER SIBLING draw in
    the same request that happens to reuse the same table id — this was a real bug caught before
    merge, not a hypothetical; any refactor of this function must preserve the push→map→pop→`?`
    ordering exactly.
  - `MAX_DRAW_DEPTH=8` bounds `TableEntry::Draw` recursion; exceeding it is `TooDeep`, checked
    BEFORE the cycle check on every call.
  - `weighted_row(rows, total) -> Option<usize>` — first row whose cumulative weight (in row
    order) is `>= total`; always `Some` for a well-formed table (every weight `>= 1`,
    `validate`d at ingest) and any `total` in `1..=sum`.
  - `ranged_row(rows, total) -> Option<usize>` — the row whose `range` contains `total`; `None`
    is a legitimate "no matching row" outcome, not an error (`TableEngine::validate` guarantees
    non-overlap, never exhaustive coverage).
  - `resolve_row_results`'s `TableEntry::Text` arm collects `chat::sanitize`'s `image_urls` onto
    `cx.image_urls` alongside its `segments` — dropping this half of `Sanitized`'s output (as an
    earlier version did) silently means a row's inline markdown image is never asset-ified, with
    no error anywhere; see `chat::body::compose_message`'s identical collection for the reused
    pattern.
- `chat::Segment::TableDraw(TableDrawSegment)` — the one `Segment` variant chat's own parser can
  NEVER produce (only `tables::draw::draw_table` builds one); `TableDrawSegment{table_id,
  table_name, roll_id, formula, outcome, spec, raw, row}` (`spec`/`raw` are boxed `Option`s
  holding the row-selecting roll's `RollSpec`/`RawRoll`; `row` is an `Option<DrawnRow>`),
  `DrawnRow{index, label, content: Vec<Segment>, nested:
  Vec<TableDrawSegment>}`. GM-only redaction (`spec`/`raw`, at EVERY depth) is computed by
  `chat::roll_property_overrides` → `push_draw_overrides` (recurses through `row.nested`) — same
  `permissions.property_overrides` mechanism `RollEmbed` uses, never a chat-specific or
  tables-specific redaction filter; full detail (including the `Within`-redaction-removes-the-key
  gotcha for `Option` fields) lives in `shadowcat-codebase-chat`/`shadowcat-codebase-documents-permissions`.
- `ws::protocol::ClientMsg::DrawTable{request_id, table_id, channel,
  count: u32 (#[serde(default = "default_draw_count")] = 1), actor_owner: Option<ActorOwnerRef>
  (#[serde(default)]), audience: Audience (#[serde(default)])}` — ts-rs exported. `ws::conn`'s
  dispatch arm calls `tables::handle_draw_table` and, on `Err`, sends a correlated
  `ServerMsg::ChatError{request_id, message: e.to_string()}` — the SAME asymmetric
  confirm-by-broadcast-echo protocol `SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll`
  share (see `shadowcat-codebase-chat`'s Gotchas section for the client-side settle-path detail).
- Client (`@shadowcat/core`):
  - `table-docs.ts` — re-exports the ts-rs-generated `TableEngine`/`DrawRule`/`TableRow`/
    `RowRange`/`TableEntry` verbatim (unlike `MessageEngine`/`Segment`, `TableEngine` DOES cross
    the wire as a stored, editable document, so it gets the real ts-rs binding, not a hand-mirror)
    plus `buildTableDoc(worldId, name, engine, id?)` — standalone envelope,
    `permissions.default: "observer"`, `system: {}`.
  - `chat-docs.ts` — `TableDrawSegment`/`DrawnRow` declared as their OWN named types (never
    `Extract<ChatSegment, {kind:"table_draw"}>` — that narrowing is undocumentable by TypeDoc, an
    invariant `shadowcat-codebase-core` states generally). `chatSegmentSchemaImpl` is
    `z.union([nonRecursiveChatSegmentSchemaImpl, tableDrawSegmentSchemaImpl])` rather than one
    Zod's discriminated-union validator — it cannot host a recursive lazy member, so the
    non-recursive segment kinds (`nonRecursiveChatSegmentSchemaImpl`'s members) stay one
    discriminated union and the recursive `table_draw`
    member (`tableDrawSegmentSchemaImpl`) is unioned in separately as a lazy schema.
  - `ws-client.ts` — `DrawTableOptions{tableId, channel, count?, actorOwner?, audience?}`,
    `WsClient.drawTable(opts) -> Promise<void>` — same `trackChatOp`/`chatPending` correlation as
    `sendChatMessage`/`recalcRoll`.
  - `@shadowcat/ui-kit`'s `ChatApi.drawTable(opts): Promise<void>` — wired through
    `worldSession.svelte.ts`/`Table.svelte`; see `shadowcat-codebase-client-shell`.
  - `SegmentList.svelte` — the `table_draw` render branch: a `RollTooltip` over the
    row-selecting roll, then the matched row's `content` and each `row.nested` entry rendered
    through a RECURSIVE self-import of `SegmentList` itself (the Svelte-5-idiomatic way to
    self-reference a component, in place of `<svelte:self>`), or a "no matching row" message
    when `row` is absent/null. A
    `doc_link` segment additionally renders a Draw button when its target resolves to a `table`
    document in the local store.

### Notes — key files & seams

- `data::engine::note` — `NoteEngine{source: String, body: Vec<Segment>, sort: i64}`,
  `NOTE_DOC_TYPE = "note"`, `MAX_NOTE_SOURCE_CHARS = 65_536`, `MAX_NOTE_SPANS = 64` (the non-text
  `[[...]]`-span cap `compose_static` enforces for a note body — deliberately larger than chat's
  own `MAX_INLINE_ROLLS = 8`, since a journal page is far longer than one chat message).
  `NoteEngine::validate` checks only `source`'s length — `body` is never validated here because it
  is unconditionally overwritten before a note is ever stored, so a client-supplied `body` (however
  shaped) can never survive ingress. `NoteEngine::derive_body` sets `self.body =
  chat::compose_static(&self.source, &chat::NOTE_CONTENT_POLICY, MAX_NOTE_SPANS)`, mapping a scan/
  parse failure to `RollError`'s player-presentable `Display` text. Registered in
  `is_engine_doc_type`/`normalize_engine`'s `"note"` arm (deserialize → `validate` → `derive_body` →
  re-serialize — the SAME order every other validating engine arm follows, so `body` lands in the
  stored row, the `world_events` entry, and the returned `Command` identically); `data::validation`'s
  `validate_containment` forbids a `note` as an embedded child (same shape as the `table`/
  `asset_folder`/combat-family rules), but — unlike `table` — a `note` MAY carry a `parent_id`.
  **`MAX_NOTE_SOURCE_CHARS` bounds `source`, not the DERIVED `body` that is actually stored.**
  `apply_intent`'s Create AND Update arms re-run `validation::validate_system_size` a SECOND
  time, immediately after `validate_engine_tree` (the call that runs `derive_body` and replaces
  `doc.engine` with the derived value in place) — the first, earlier `validate_system_size` call
  only ever sees the client's pre-derivation payload (an empty `body: []`), never the value that
  is actually persisted, written to `world_events`, and broadcast. A `source` near the char cap
  made mostly of HTML-escapable characters (`&`/`<`/`>`) expands several-fold through
  `chat::sanitize`'s escaping, so without the second check a well-formed-looking Create/Update
  could store, log, and broadcast a body well past `MAX_SYSTEM_BYTES` with no refusal at all.
  Reusing the same function (rather than a second size rule) is deliberate — this is the general
  shape any future engine-doc-type whose `normalize_engine` arm DERIVES a stored value (not just
  validates the submitted one) must repeat.
- `chat::body::compose_static(body, policy, max_spans) -> Result<Vec<Segment>, RollError>` — the
  SYNCHRONOUS sibling of `chat::body::compose_message` a note's ingress arm calls (also usable by
  any other document body that composes at write time with no repository/network access): a `Text`
  chunk sanitizes under `policy`; an `Inline` OR `Button` `[[...]]` span validates (never executes —
  a document save must never roll dice as a side effect) and becomes an unexecuted
  `Segment::RollButton` (an inline `[[formula]]` is NOT a `Segment::RollEmbed` here, unlike
  `compose_message`'s Execute mode); a `DocLink` chunk passes its parsed target/label straight
  through; an `Image` chunk becomes a `Segment::Image` with NO existence check (no outbound fetch or
  repository lookup exists on this write path) — `Sanitized.image_urls` is deliberately DISCARDED,
  so a markdown image in a note renders only as its alt text and only an explicit `[[asset:...]]`
  span produces an image.
- `chat::NOTE_CONTENT_POLICY` (`chat::settings`) — the FIXED `ChatContentPolicy` a note's body
  derives under: markdown/hyperlinks/images on, html/emails/link-previews off. Deliberately NOT the
  world's own `chat-settings` policy — a note is a journal page, not a chat message, so a world that
  keeps chat plain-text still wants rich notes.
- `data::sqlite::notes::check_note_parent` — mirrors `data::sqlite::assets::check_asset_folder_parent`
  exactly: a note's `parent_id`, when set, must name a `note` in the SAME scope, resolved against
  this batch's own in-flight Creates before the database (same-batch parent+child Creates resolve
  without a database round trip). Dispatched from the ONE shared `check_parent_placement` helper the
  Create AND `Operation::Move` arms of both `apply_intent`/`apply_command` already call — the
  in-flight-batch map `apply_intent` threads through that helper (despite its historical
  folder-only name) is now populated with BOTH `asset_folder` AND `note` Creates in one batch, since
  ids are unique regardless of doc_type; `check_move_acyclic`'s cycle walk therefore covers a note's
  same-batch ancestors for free, with no separate note-specific map. See
  `shadowcat-codebase-documents-permissions` for the shared placement/cascade mechanics this plugs
  into.
- Client (`@shadowcat/core`) — `note-docs.ts`:
  - `NOTE_DOC_TYPE`, re-exports the ts-rs-generated `NoteEngine` verbatim (like `TableEngine`, a
    note crosses the wire as a stored, editable document).
  - `buildNoteDoc(worldId, name, source, opts?: {parentId?, sort?, id?, owner?}) -> WireDocument` —
    `engine: {source, body: [], sort}` (the placeholder `body` is discarded server-side; `sort`
    is built as a plain `number`, NOT a bigint, despite `NoteEngine.sort`'s ts-rs bigint typing —
    a bigint value is not JSON-serializable and `WsClient.send` does a bare JSON stringify call,
    so a real bigint value breaks every `Create` containing a note; `wire.ts`'s own hand-mirrored
    types resolve the identical i64/bigint gap by using `number`, and this was the first
    non-hand-mirrored ts-rs type to construct a real i64 VALUE rather than merely re-export the
    TYPE — the identical trap DID land on `table-docs.ts`'s `RowRange.lo`/`hi` once a real
    `Formula`-table caller constructed one; fixed by narrowing the Rust field width instead
    (a row range bounds a dice total, already well inside that narrower width), rather than
    adding a per-caller `number`-construction workaround the way `buildNoteDoc` does for `sort`
    — the two fields differ in kind, not just history: `sort` genuinely needs the wider width on
    the Rust side (a client-chosen sibling-ordering value with no natural bound), while
    `RowRange` never did). Private-by-default permissions: `default: "none"`, `users: {[owner]: "owner"}`
    when `opts.owner` is given — the builder is pure and has no session, so the caller MUST pass the
    authoring user's id explicitly, or the note is readable by nobody but a GM.
  - `parseNoteBody(doc) -> (ChatSegment | UnknownSegment)[] | null` — fail-closed: wrong doc_type or
    a malformed `engine.body` both yield `null`. Validates through chat-docs.ts's exported
    `SegmentListSchema` (the SAME schema `ChatMessageEngine.content` validates against — a note body
    and a chat message body share one segment grammar and one validator, never a re-spelled copy).

## Hard invariants

- **A draw is resolved server-side, end to end — there is no client-side row-selection fallback
  and no client-constructed `table_draw` segment.** The client only ever renders a
  `TableDrawSegment` the server already produced.
- **`spec`/`raw` are GM-only at EVERY depth of a draw tree, never just the top level.** A nested
  draw fanned out from `TableEntry::Draw` gets the identical redaction treatment as the top-level
  draw — see `push_draw_overrides`'s recursion through `row.nested`.
- **`cx.chain`'s push/pop must bracket exactly the scope that can recurse, and the pop must run
  even on an error return.** See `draw_table`'s ordering note above — this is the whole cycle
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
  content as "derive from `source`", never "validate the client's `body`".
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
- `shadowcat-codebase-sheets` — the not-yet-built table/notes sheets are the first UI consumers of
  `buildTableDoc`/`buildNoteDoc` and `parseNoteBody`; nothing in this skill's own subsystem builds
  a sheet.
