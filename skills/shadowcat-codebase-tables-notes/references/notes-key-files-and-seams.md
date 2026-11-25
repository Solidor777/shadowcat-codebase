# Notes: Key files & seams

Part of the shadowcat-codebase-tables-notes skill. Read it before changing or reviewing note code (engine doc type, server-derived body, client note UI).

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
  Create AND `Operation::Move` arms of both `apply_intent`/`apply_command` already call (and
  `import_world`'s post-loop pass, where the maps are empty because every bundle row is already
  inserted) — the
  in-flight-batch map `apply_intent` threads through that helper (named for folders, but
  not folder-only) is populated with BOTH `asset_folder` AND `note` Creates in one batch, since
  ids are unique regardless of doc_type; `check_move_acyclic`'s cycle walk therefore covers a note's
  same-batch ancestors for free, with no separate note-specific map. See
  `shadowcat-codebase-documents-permissions` for the shared placement/cascade mechanics this plugs
  into.
- Client (`@shadowcat/core`) — `note-docs.ts`:
  - `NOTE_DOC_TYPE`, re-exports the ts-rs-generated `NoteEngine` verbatim (like `TableEngine`, a
    note crosses the wire as a stored, editable document).
  - `buildNoteDoc(worldId, name, source, opts?: BuildNoteDocOptions{parentId?, sort?, id?, owner?, kind?}) -> WireDocument` —
    `engine: {source, body: [], sort, kind}` (`kind` defaults to `{kind:"text"}`; the placeholder `body` is discarded server-side; `sort`
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
    `RowRange` never did). Private-by-default permissions: `default: "none"`; when `opts.owner` is
    given, `grantAuthor(doc, opts.owner)` (`scene-docs.ts`) stamps `users[owner] = "owner"` PLUS
    `core:delete`/`core:edit_permissions` onto `by_role.owner` — the `Owner` floor alone
    (read+`WRITE_FIELDS`) cannot delete or reshare the note. The builder is pure and has no
    session, so the caller MUST pass the authoring user's id explicitly, or the note is readable
    (and manageable) by nobody but a GM.
  - `parseNoteBody(doc) -> (ChatSegment | UnknownSegment)[] | null` — fail-closed: wrong doc_type or
    a malformed `engine.body` both yield `null`. Validates through chat-docs.ts's exported
    `SegmentListSchema` (the SAME schema `ChatMessageEngine.content` validates against — a note body
    and a chat message body share one segment grammar and one validator, never a re-spelled copy).
  - `appendNoteSortKey(notes, parentId) -> number` — the `sort` a newly created note appended
    under `parentId` (or `null` for root) should take: filters `notes` to `doc_type === "note"`
    with a matching `parent_id`, reads each survivor's `engine.sort` (defaulting a missing/absent
    value to `0`), and hands the resulting values to `@shadowcat/core`'s shared
    `appendSortKey`/`SORT_KEY_DENSITY` primitive (`sort-key.ts` — see
    `shadowcat-codebase-client-shell` for that module's general contract, shared with
    `appendFolderSortKey` in `shadowcat-codebase-assets`) rather than re-deriving the
    "highest sibling → append" computation locally. Two call sites feed it the caller's own
    optimistic view: `NotesPanel`'s panel-level create (siblings = every root note) and
    `NoteSheet`'s child-note create (siblings = the open note's existing children) — the two
    modules never import one another, so this lives in `@shadowcat/core` beside `buildNoteDoc`
    rather than in either.
- **Page kind** — `NoteEngine.kind: NotePageKind` (`#[serde(tag = "kind")]`: `Text` | `Image{asset_id}`
  | `Pdf{asset_id}` | `Video{asset_id}`, `#[default]` `Text`, so an older stored note reads as text).
  `asset_id` is not existence-checked at ingest (same posture as a chat `[[asset:]]` span and a
  table `Image` entry); the client renders through the asset resolver and shows a placeholder when
  it does not resolve or the asset is deleted. Client: `parseNotePageKind(doc)` is fail-closed to
  `{kind:"text"}` for a wrong doc_type, a missing field, an unknown tag or a media kind without an
  `asset_id`. `NoteSheet` renders the media block (image, embed and video elements via `ctx.assets.url`) and
  offers Change media through the asset picker.
- **Secret blocks** — `NoteEngine::secret_property_overrides` plus
  `data::validation::stamp_note_secret_overrides` (see the skill's invariants). A note accepts only
  `[[secret:gm|...]]` (`RollError::SecretRequiresGm` otherwise).
- **Present to table** — `ClientMsg::PresentNote` is handled by `notes::handle_present_note`
  (`PresentNoteError`: `Forbidden`, `RateLimited`, `NotFound`, `NotShared`, `Data`); rejections
  return as a correlated `ServerMsg::ChatError`. Success is the out-of-band `ServerMsg::PresentNote`
  (never sequenced or logged), delivered to clients as `PresentNoteNotice`
  (`WsClientHandlers.onPresentNote`, `WorldSession.onPresentNote`, `AppContext.notes`' present
  call); the shell's `createPresentedNoteHandler` (wired in `Table.svelte`) opens the note's sheet
  panel. A new `ServerMsg` variant needs its wire type and Zod arm in the same change.
- **Note sheet and tree UI** — `NoteSheet` (`@shadowcat/module-sheet-note`) mounts the ui-kit
  `PermissionsEditor` (default role, per-user overrides, opt-in GM role; gated on the `/permissions`
  edit capability) and `UserMultiSelect`; sharing is `PermissionSet.users`. It builds its table of
  contents from the rendered DOM (`collectHeadings`, `findAnchor` in `note-toc`) and scrolls
  in-note `#fragment` links itself. The sheet has no visibility control of its own: `PermissionsEditor`
  is the one editor of a note's visibility (`setVisibility` only shares an unshared note when it is
  presented). A PDF page renders as a link that opens in a new tab (`note-media-pdf-link`), not an
  embed, because the server serves a PDF with an attachment disposition. `NoteTree` (`@shadowcat/module-notes`; `canReorder` requires `/engine/sort` edit access on the row AND every sibling at its level) reorders siblings through
  core's `createDragController` (a drag handle, plus Alt+Arrow keys; drag is off while a search
  filters the tree) with `noteSiblings` and the shared sort-key helpers (`computeReorderUpdate`,
  `buildReorderOps`), and opens its right-click / long-press menu through ui-kit's
  `createContextMenuTrigger` calling the same handlers as the buttons.

