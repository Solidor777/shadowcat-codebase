# Tables: Key files & seams

Part of the shadowcat-codebase-tables-notes skill. Read it before changing or reviewing rollable-table code (engine doc type, draw pipeline, client table UI).

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
    the same request that happens to reuse the same table id; any refactor of this function must
    preserve the push→map→pop→`?` ordering exactly.
  - `MAX_DRAW_DEPTH=8` bounds `TableEntry::Draw` recursion; exceeding it is `TooDeep`, checked
    BEFORE the cycle check on every call. A stored draw nests 3 JSON levels per draw level, so a
    row-selecting roll's serialized depth must stay under serde_json's 128-level read limit; that is
    what `dice::notation::MAX_EXPR_JSON_DEPTH` guarantees (`tables::nested_depth_tests` pins it with a roll at the
    cap in the deepest draw), so raising `MAX_DRAW_DEPTH` needs that cap re-checked.
  - `weighted_row(rows, total) -> Option<usize>` — first row whose cumulative weight (in row
    order) is `>= total`; always `Some` for a well-formed table (every weight `>= 1`,
    `validate`d at ingest) and any `total` in `1..=sum`.
  - `ranged_row(rows, total) -> Option<usize>` — the row whose `range` contains `total`; `None`
    is a legitimate "no matching row" outcome, not an error (`TableEngine::validate` guarantees
    non-overlap, never exhaustive coverage).
  - `resolve_row_results`'s `TableEntry::Text` arm collects `chat::sanitize`'s `image_urls` onto
    `cx.image_urls` alongside its `segments` — dropping this half of `Sanitized`'s output
    silently means a row's inline markdown image is never asset-ified, with
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
    plus `buildTableDoc(worldId, name, engine, opts?: BuildTableDocOptions)` — standalone envelope,
    `permissions.default: "observer"`, `system: {}`; `opts.id` (the builder's former positional
    third arg) and `opts.owner`, which calls `grantAuthor` (`scene-docs.ts`,
    `shadowcat-codebase-documents-permissions`) so the creator holds `core:delete`/
    `core:edit_permissions` in addition to the `Owner` floor's read+`WRITE_FIELDS` — without it, a
    granted player could create a table but never edit or delete the one they made.
  - `chat-docs.ts` — `TableDrawSegment`/`DrawnRow` declared as their OWN named types (never
    `Extract<ChatSegment, {kind:"table_draw"}>` — that narrowing is undocumentable by TypeDoc, an
    invariant `shadowcat-codebase-core` states generally, in its references/invariants-detail.md). `chatSegmentSchemaImpl` is
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
- **Table folders** — `data::engine::table_folder::TableFolderEngine{sort: i64}` (`TABLE_FOLDER_DOC_TYPE`
  = `"table_folder"`, `deny_unknown_fields`, ts-rs exported), registered in `normalize_engine` and
  `validate_containment` (never embedded). The folder's `name` is its display name; a table or
  another folder points at it through `Document.parent_id`.
  - Placement: `SqliteRepository::check_table_folder_parent` (`data::sqlite::tables`) requires a
    `table` or `table_folder` parent to be a `table_folder` in the same scope, resolved against the
    batch's in-flight Creates before the database, dispatched from the shared
    `check_parent_placement` on Create and `Operation::Move`; cycles are `check_move_acyclic`'s.
  - Delete: `table_folder_reparent_moves` (its inputs: the transaction, the folder id and the set of ids being deleted) returns explicit `Move` ops for
    every `table` in the folder's subtree (breadth-first closure of nested folders), targeting the
    nearest ancestor not in that set (`deleted_ids` of the whole command). Both write loops call it
    at the start of a `Delete` expansion; `moved_ids` feeds `descendants_first`'s `kept` argument.
    The nested folders themselves are deleted by the normal descendant expansion.
  - Client: `TABLE_FOLDER_DOC_TYPE` and `buildTableFolderDoc(worldId, name, opts)` in
    `table-docs.ts` (`opts`: `id`, `owner`, `parentId`, `sort`; `sort` is sent as a plain number
    since the ts-rs type is a bigint); `buildTableDoc`'s `opts.parentId` files a table under a
    folder. `TablesPanel` (`@shadowcat/module-tables`) renders ui-kit's generic `DocFolderTree`
    (props `folderDocType`, labels, `rootDropId`, `deleteChoices`, `onDelete`, `buildFolder`,
    `dropHover`; exposes `dropTargets()`), with a filter, create-under-folder, a drag handle, a Move
    picker and a menu Move. The asset browser's `FolderTree` is a thin wrapper over the same
    component, so a change to `DocFolderTree` reaches both panels.

