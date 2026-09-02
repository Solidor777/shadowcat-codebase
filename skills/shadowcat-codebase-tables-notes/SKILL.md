---
name: shadowcat-codebase-tables-notes
description: "Use when touching Shadowcat's rollable tables: the `table` engine doc type (`TableEngine`/`DrawRule`/`TableRow`/`RowRange`/`TableEntry`), `tables::handle_draw_table`/`tables::draw::draw_table`'s recursive draw resolution (cycle detection, depth/budget caps, weighted/formula row selection), the `Segment::TableDraw`/`TableDrawSegment`/`DrawnRow` chat segment family and its GM-only spec/raw redaction, the `draw_table` wire frame, the client `table-docs`/`chat-docs` mirrors and `WsClient.drawTable`, or `SegmentList`'s recursive `table_draw` rendering. Covers src/server/src/data/engine/table.rs, src/server/src/tables/, the `TableDraw`/`DrawnRow`/`roll_property_overrides` portions of src/server/src/chat/mod.rs, src/client/core/src/table-docs.ts, the `table_draw` portion of src/client/core/src/chat-docs.ts, and the `table_draw` portion of src/client/ui-kit/src/SegmentList.svelte. A "notes" document type is NOT yet implemented — this skill's name anticipates it; do not assume note-taking coverage exists here. Invoke shadowcat-codebase-core first; for the Segment/redaction/chat-frame machinery a table draw rides, invoke shadowcat-codebase-chat; for the row-selecting roll's parse context and formula validation, invoke shadowcat-codebase-dice; for the engine-doc-type registry/containment rules, invoke shadowcat-codebase-documents-permissions."
---

# Shadowcat — Rollable Tables

Orientation for rollable tables: a `table` document is authored/edited like any other document
(no special write path — plain `Create`/`Update` through the generic engine-ingress gate), but is
only ever *drawn from* through one server-owned resolution pipeline
(`tables::handle_draw_table` → `tables::draw::draw_table`) that rolls, matches a row, and posts
the result to chat as a `Segment::TableDraw`. Nothing about a table's OWN document lifecycle is
special; everything about a DRAW is centralized to close cheating/leak surface a client-side
resolver could not close (row-selecting roll state must stay GM-only, and a malicious or
misconfigured table chain must not recurse forever or fan out unboundedly).

## Purpose

Delivers one engine doc type (`table`) and one action (`draw_table`) that turns it into a chat
message. A table's `TableEngine` is either `DrawRule::Weighted` (rolls `1d<sum-of-row-weights>`,
matches the row whose cumulative weight reaches the total — always has a match by construction)
or `DrawRule::Formula` (rolls the table's own dice notation, matches the row whose inclusive
`RowRange` contains the total — may match nothing). A matched row's `results` resolve into plain
content (`text`/`doc`/`image` entries, the SAME segment shapes chat's own `[[…]]` spans produce)
and `nested` — one `TableDrawSegment` per `TableEntry::Draw` entry, recursing through another
full `draw_table` call. A draw is NEVER stored back onto the table document; it exists only as the
chat message it produces.

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
  - `RowRange{lo: i64, hi: i64}` — an inclusive total range; `TableEngine::validate` requires
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
  - `DrawCtx<'a>{repo, ctx, world_defaults, policy, world_id, chain: Vec<Uuid>, budget: usize}` —
    `chain` is the DFS-visited-stack cycle guard (table ids on the CURRENT recursion path only,
    not the whole request tree — two sibling branches reusing the same table id are both fine);
    `budget` counts every draw resolved ACROSS THE WHOLE REQUEST (top-level plus every nested
    fan-out), capped at `MAX_DRAWS_PER_REQUEST=64` regardless of depth.
  - `draw_table(cx, table_id, depth)` — checks budget/depth/cycle FIRST (in that order), then
    loads+authorizes the table (`resolve_access_world` against `cx.world_defaults`, `cap::READ`
    required — `DrawTableError::Forbidden` on a denial), deserializes+validates the stored
    `TableEngine`, rolls under `chat::rolls::TABLE_PARSE_CONTEXT` via `chat::rolls::execute_roll`,
    matches a row (`weighted_row`/`ranged_row`, pure functions), then resolves that row's
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
    Zod's discriminated-union validator — it cannot host a recursive lazy member, so the 8
    non-recursive segment kinds stay one discriminated union and the recursive `table_draw`
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

## Gotchas

- **A "notes" document type does not exist yet.** This skill's name anticipates a future
  note-taking feature; nothing in this skill or in the current codebase implements one — do not
  infer note-document coverage from the skill's name.
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

## Pointers

- `docs/site/protocol.md`'s "Rollable tables" section — the wire-level summary of `draw_table`.
- `docs/design/ARCHITECTURE.md` invariant 6 — `table`'s place in the engine-doc-type count.
