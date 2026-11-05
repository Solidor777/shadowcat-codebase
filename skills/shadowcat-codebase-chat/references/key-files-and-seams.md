# Key files and seams

Part of the shadowcat-codebase-chat skill; read it when editing server chat code, ingest, the sanitizer, settings or commands.
## Key files & seams

- The `chat` module — the domain home:
  - `MESSAGE_DOC_TYPE = "message"`.
  - `ActorOwnerRef` (`Actor{actor_id}` | `TokenInstance{token_id}`) — the ONLY chat type with
    `#[derive(TS)]` (ts-rs export); carried on the `SendMessage` wire frame.
  - `MessageKind` (`Normal` default, `Emote`/`Roll` producible by `parse_command`; `System`
    reserved for future server-authored notices — NO parse path can ever produce it, proven by an
    exhaustive test) and `Segment` (tagged enum: `Text{text}` — verbatim, client renders as a DOM
    text node; `Html{sanitized_html}` — a run of already-`ammonia`-cleaned HTML, produced ONLY by
    `sanitize::sanitize`, client renders via `innerHTML`; `Image{asset_id, alt}` — see below) —
    both serde-only, NO ts-rs; they live
    inside the `engine` JSON body, not the wire frame, so the client
    declares its own Zod mirror later. **Design note (revised for `Image`):** inline
    formatting/hyperlink markup does NOT get its own typed `Segment` variant — it stays INSIDE a
    `Segment::Html` run as ordinary sanitized markup (`<strong>`/`<a>`). Images are the deliberate
    EXCEPTION: an `<img>` is stripped from every `Html` run regardless of the `images` policy
    toggle (`chat::sanitize::sanitize` never lets a raw image URL reach the client — see
    `sanitize`'s `ImageSource` extraction below) and instead becomes a typed `Segment::Image{
    asset_id, alt}` referencing an asset THIS SERVER already holds, produced either directly from a
    `[[asset:<uuid>|alt]]` span (`chat::rolls::scan_body_capped`, ingest-time, no network) or
    asynchronously via the `chat::post_publish` `InlineImage` job (a Markdown/HTML image URL is
    fetched server-side, asset-ified, then republished — see "Post-publish enrichment" in references/link-previews.md). The
    server never stores or forwards an external image URL verbatim; the client never fetches one.
    `Segment::DocLink{target, label}` remains a structured REFERENCE (a doc/token id + a display
    label), not inline formatting or markup, so it stays a distinct typed variant rather than
    folding into `Html`. `Segment::TableDraw(TableDrawSegment)` — the one variant chat's OWN
    parser can never produce (only `tables::handle_draw_table` builds one) — carries a rollable
    table's executed draw (formula/outcome/GM-only spec+raw/matched row, recursive through
    `TableDrawSegment.row.nested`); see `shadowcat-codebase-tables-notes` for the draw-resolution
    side and `roll_property_overrides`'s `push_draw_overrides` note above for its redaction.
  - `Segment::DocLink{target: DocLinkTarget, label}` — a free-form in-body link to a document or
    token, recognized by `chat::rolls::scan_body_capped` from a `[[doc:<uuid>|<label>]]` or
    `[[token:<uuid>|<label>]]` span (same `[[...]]` bracket-depth grammar as `[[roll:...]]`; the
    `|<label>` half is REQUIRED, unlike roll's optional label). `DocLinkTarget` is `Doc{doc_id,
    embedded_path: Option<String>}` | `Token{token_id}` (`#[serde(tag="kind",
    rename_all="snake_case")]`). NO server-side existence or authz check runs on ingest — the
    referenced doc/token may not exist, may be in another world, or may be invisible to some
    recipients; the client fails closed at RENDER time (`module-chat-card` only makes it a
    clickable sheet-open link when the target resolves against the viewer's own `ctx.documents`,
    else an inert span), mirroring the actor-name-header link's own presence-gate pattern.
  - `plain_text_content(raw) -> Vec<Segment>` — the fail-closed plain-text producer, wraps raw input verbatim as one
    `Segment::Text` (no sanitization yet; the client renders it as a text node, never
    `innerHTML`, so embedded markup is inert).
  - `chat::search_text::segments_search_text(segments: &[Segment]) -> String` — the ONE
    reader-facing text extraction over a `Segment` list, shared by every caller that needs plain
    searchable text rather than a renderable body: `Text`/`Html` (tags stripped, entities
    decoded) contribute their text, `RollEmbed` contributes its `formula` only (it carries no
    label; never `outcome`/`spec`/`raw`/`recalc_history`), `RollButton` its `formula` + `label`,
    `LinkPreview` its title, description AND url (never the image asset id), `OEmbed` its title,
    author and provider names (never an id or the url), `DocLink`/`Image` only their label/alt,
    and `TableDraw` recurses through its `table_name` and matched row's label/content, nested
    draws included (never the draw's own `formula`/`outcome`/`spec`/`raw`/ids). `data::engine::search_text`
    (`shadowcat-codebase-documents-permissions`) calls it for BOTH `note` (a rendered `body`) and
    `message` (`content`) doc-type projections — the single function keeping those two engines'
    indexed text in sync rather than two ad-hoc leaf sweeps.
  - `Audience` (`Public`/`Whisper{recipients: Vec<Uuid>}`/`GmOnly`, `#[default] Public`, tagged
    enum, ts-rs exported same as `ActorOwnerRef`) — the intended readership of a message, carried
    on the `SendMessage` frame and stored verbatim in `MessageEngine`. This is the ONLY
    server-enforced VISIBILITY concept for chat; `channel` never gates document visibility, message audience, or any capability check — that
    boundary is `Audience` alone. `channel` IS validated at ingest: `chat::settings::channel_registered` checks it
    against the world's `channel-registry` singleton (`SendMessageError::UnknownChannel`, validation-class, and
    `CombatError`'s own arm for `CombatRoll` — an unregistered channel is refused, not filed, and the registry
    itself can never be written empty (`ChannelRegistryEngine::validate` wired into `normalize_engine`: non-empty
    map, non-empty names, keys within `MAX_CHANNEL_CHARS`). `channel` has exactly ONE other narrow
    server-enforced reason to be
    read: `chat::settings::resolve_dice_context` looks it up against the world's `dice-settings`
    `channel_overrides` map to select which `mode`/`direction` pair an ambient roll resolves under
    (see the "Dice wire" section) — misresolving it at worst changes which dice settings a
    roll uses, never who can see a message. A client module choosing to post to a "GM" channel is
    what sets `audience: GmOnly`; the server has no concept of a reserved channel name.
  - `MessageEngine{channel, user_owner, actor_owner, kind, audience, content, source,
    edited_at, deleted_at}` lives at
    `Document.engine`, not `Document.system` — a message doc's `system` body is empty `{}` — the
    `engine` body shape; `#[serde(deny_unknown_fields)]` rejects any unknown key on ingress,
    closing that gap the same way every other engine-defined doc_type's ingress
    does. `audience` rides the body verbatim, same treatment as `kind`/`actor_owner`.
    `edited_at`/`deleted_at` (both
    `Option<i64>`, `#[serde(skip_serializing_if = "Option::is_none")]`) are the edit/delete
    markers — absent (not `null`) on an unedited/live message, so an existing stored message
    lacking those fields round-trips unchanged. `source: Option<String>` (same serde shape) is the author's
    RAW input kept for client edit-prefill (sanitized `Segment::Html` can't be reversed):
    stored at ingest as `parsed.body` when the send parsed a `/w` (so an unmodified prefill
    resubmit can't trip the edit path's `AudienceLocked`) else the FULL content
    (command prefix KEPT — `/me x` prefills as `/me x` and re-parses to the same kind);
    set to the full post-edit content on edit (a WHISPER edit skips command parsing entirely,
    mirroring send's literal-body semantics for a whisper — a non-whisper edit still rejects `/w`);
    **CLEARED (`None`) by
    the delete tombstone alongside `content`** — a retained source would leak deleted content.
    EXPOSURE NOTE: like everything `index_content` sweeps — the `doc_type`, the envelope `name`,
    and every string and number leaf of `engine` (the band `source` and `channel` both live in)
    and `system` — `source` is swept into the content-agnostic FTS index and can surface in
    `SearchHit.snippet`/`.document` — any search-UI consumer must treat message snippet/`source`
    strings as inert text, never innerHTML (documented at the field — a high-volume instance of
    that pattern, not a new leak class).
  - `build_message_doc(...) -> Document` — constructs the whole `Document`: `owner = Some(user)`;
    `audience` maps onto `PermissionSet{default, gm_role, users}` (see
    `shadowcat-codebase-documents-permissions` for what `gm_role` does at `resolve_access` time):

    | `Audience` | `default` | `gm_role` | `users` |
    |---|---|---|---|
    | `Public` | `Observer` | `None` | `{owner: Owner}` — the original, unrestricted default shape |
    | `Whisper{recipients}` | `None` | `Some(DocRole::None)` | `{owner: Owner, ...recipients: Observer}` |
    | `GmOnly` | `None` | `Some(DocRole::Observer)` | `{owner: Owner}` only |

    `owner` is inserted into `users` LAST in every branch, so a `Whisper` that redundantly names
    the sender as their own recipient can never downgrade them from `Owner` to `Observer` via
    map-insertion order. A `GmOnly` message names no GM in `users` at all — `gm_role =
    Some(Observer)` grants it to ANY current `WorldRole::Gm`, re-resolved on every `resolve_access`
    call (every broadcast recipient, every search hit, every page load), so GM-channel visibility
    tracks promotion/demotion dynamically rather than a frozen roster at send time. The SOLE
    construction site for a stored message doc.
  - `handle_send_message(room, repo, ctx, rate, channel, content, actor_owner, audience, now,
    budget_per_min) -> Result<Command, SendMessageError>` — validates (empty/`MAX_MESSAGE_CHARS =
    4096`/`MAX_CHANNEL_CHARS = 128`/per-user-per-minute flood budget via `PingRateLimiter`), then
    runs `parse_command(&content)`. If the parsed command carries `whisper_to` (a content-
    level `/w @user...`), its RAW name list is cap-checked against `MAX_WHISPER_RECIPIENTS = 128`
    BEFORE any username is resolved (resolving first would run one sequential
    `member_id_by_username` DB round-trip per `@name` ahead of the cap — the exact resource-
    amplification `MAX_WHISPER_RECIPIENTS` exists to prevent); resolved names build the
    EFFECTIVE `Audience::Whisper` — **content `/w` wins over the `SendMessage` wire frame's
    `audience` field.** The effective audience is then re-validated (cap + `Repository::
    member_role(world_id, r).await?.is_some()` per recipient, fail-closed,
    `SendMessageError::UnknownRecipient`, nothing persisted) through the SAME chokepoint
    regardless of which front-door (frame field or content `/w`) produced it. A post-parse empty
    body (e.g. `/w @alice` with no trailing text) is rejected the same as raw-empty content. Only
    then does it resolve the world's `chat-settings` policy (`resolve_content_policy`), call
    `sanitize(&parsed.body, &policy)` to produce `handle_send_message::content_segments`, then
    `build_message_doc`, then
    `room.publish(..., vec![Operation::Create { doc }], ..., WriteOrigin::Client)`. **The sole
    message-authoring entry point** — nothing else may produce a stored `message` doc. Posting
    rights are open to any world member (any member may `SendMessage`); `audience` restricts only
    *readers*, never senders.
  - `ops_target_message(ops: &[Operation]) -> bool` — the ingress guard: `true` if any `Create`/
    `Delete` op targets a `message` doc_type. `Operation::Update` is always `false` here (an
    `Update` carries no `doc_type`, only `doc_id` + field changes) — Updates are guarded
    separately, see below.
  - `handle_edit_message(room, repo, ctx, rate, message_id, content, now, budget_per_min) ->
    Result<Command, SendMessageError>` — owner-or-GM authorized (`cur.owner == Some(ctx.user_id)
    || ctx.world_role == WorldRole::Gm`); rejects editing an already-tombstoned message (reuses
    `NotFound` — an edit must not resurrect cleared `content` on a soft-deleted doc); for a
    NON-WHISPER message, re-runs `parse_command` + `sanitize` on the new content (so `kind` MAY
    change, e.g. a plain message edited into `/me`), and a `/w` in the edit content is rejected as
    `SendMessageError::AudienceLocked` rather than silently retargeting readership; for a WHISPER
    message, `parse_command` is SKIPPED entirely — the content is treated as the literal body and
    stored `kind` is kept, mirroring `handle_send_message`'s own literal-body treatment of a
    whisper's content, so an unmodified resubmit of the whisper's `source` prefill (itself
    post-`/w`-strip) can never reparse into a different `kind` or spuriously trip
    `AudienceLocked` on a literal "/w ..." body. `channel`/`user_owner`/`actor_owner`/`audience`/
    `deleted_at` are always copied verbatim from the STORED doc, never re-derived from the
    request. Publishes a single `Operation::Update` on `/engine`
    under `WriteOrigin::ServerMessageRevision`. Rate-limited like `handle_send_message`.
  - `handle_delete_message(room, repo, ctx, rate, message_id, now, budget_per_min) ->
    Result<Command, SendMessageError>` — same owner-or-GM authorization; a pure SOFT tombstone (no
    command parsing/sanitization runs): clears `content` to `[]` and sets `deleted_at`, leaving
    `channel`/`user_owner`/`actor_owner`/`audience`/`kind`/`edited_at` untouched. Publishes an
    `Operation::Update` on `/engine` (NOT a hard
    `Operation::Delete`) under `WriteOrigin::
    ServerMessageRevision` — the doc stays in the sequenced log at its original seq, so resync and
    per-recipient redaction continue to apply unmodified. Rate-limited (without a budget, a single
    owner/GM could repeatedly re-delete the same message, each call consuming a real seq number
    and re-writing the FTS index — an unbounded write/broadcast amplification from one frame).
- `chat::shortcodes` — `replace_shortcodes(raw) -> Cow<str>`: an
  always-on `:name:` → unicode-emoji pre-pass (`[a-z0-9_+-]+` names, sorted static table +
  binary search, O(n), UTF-8-boundary-safe, no policy toggle — typing sugar, zero security
  surface since output is plain unicode). Runs as the FIRST line of `sanitize()`, so it applies
  identically to the plain-text early-return and the enriched path, on send AND edit; `source`
  is captured BEFORE it runs, so shortcodes stay literal in edit-prefill. A `:name:` whose
  opening `:` falls inside a markdown inline code span (backtick-run-delimited, computed by
  `code_span_ranges` before the scan) is skipped — not a full CommonMark parser, only the
  backtick-run/code-span rule. Table sortedness
  is pinned by a test (`binary_search_by_key` silently breaks on a mis-sorted row).
- `chat::sanitize` — `sanitize(raw: &str, policy: &ChatContentPolicy) ->
  Sanitized{segments: Vec<Segment>, image_urls: Vec<ImageSource>}` (was a bare `Vec<Segment>`;
  `Sanitized` and `ImageSource{url, alt}` are re-exported from `chat::mod` alongside `sanitize`),
  the content-security boundary. `!policy.markdown && !policy.html` short-
  circuits to a single `Segment::Text` + empty `image_urls` (identical to `plain_text_content`,
  the fail-closed baseline). Otherwise: `pulldown-cmark` renders Markdown to an HTML string (when
  `markdown` is
  on; when `html` is off, cmark's raw-HTML events are DOWNGRADED to escaped `Text` events rather
  than dropped, so an author's embedded tag becomes inert display text, e.g. `<b>` → `&lt;b&gt;`,
  never silently vanishing and never reaching `ammonia` as live markup) or is passed straight
  through (html-only). An `<img>` is ALWAYS stripped from the HTML string by `ammonia` regardless
  of the `images` toggle — a raw external image URL never reaches the client — but before
  stripping, `sanitize` walks the pre-`ammonia` HTML for genuine `<img src alt>` tags (same
  genuine-tag extraction discipline `link_preview::enrich`'s href scan uses, not a substring scan)
  and collects each into `image_urls: Vec<ImageSource>`, gated on `policy.images` (no images
  policy ⇒ empty list, same as no hyperlinks ⇒ no link-preview candidates). The WHOLE HTML string
  still crosses `ammonia::Builder::clean()` exactly once — the single security boundary —
  producing one `Segment::Html` with NO `<img>` inside it. `ammonia_for(policy)` narrows
  ammonia's already-safe default (which already strips `<script>`/`<style>`/the `style`
  attribute/`javascript:`/`data:` schemes) further per toggle: `<img>` is unconditionally removed
  regardless of `images` (the extracted `image_urls` are the ONLY surviving trace of a source
  message's image markup — see `chat::body::compose_message`/`chat::link_preview::enrich`'s
  `InlineImage` job in references/link-previews.md for how they become a `Segment::Image`); `hyperlinks: false` removes
  `<a>`; `emails`
  gates whether `mailto:` is in the allowed URL scheme set (always `http`/`https`). CSS is
  ALWAYS stripped regardless of any toggle (belt-and-suspenders re-removal of `style` on every
  currently-whitelisted tag, not just reliance on ammonia's default). **`url_relative(Deny)` is
  load-bearing**: ammonia's own default (`PassThrough`) lets a schemeless, protocol-relative URL
  (`//evil.example/pixel.gif`) through unfiltered — invisible to the `url_schemes` allowlist,
  which only inspects URLs that HAVE a scheme — and would otherwise let a smuggled tracking pixel
  fire for every recipient of a whispered/GM-only message.
- `chat::body::compose_message(body: &str, deps: ComposeDeps<'_>, mode: ScanMode) ->
  Result<(Vec<Segment>, Vec<sanitize::ImageSource>), ComposeError>` — the shared chunk→segment
  composer BOTH `handle_send_message` (`ScanMode::Execute` — inline rolls actually roll) and
  `handle_edit_message` (`ScanMode::NoExecute` — inline rolls validate structurally only, per the
  roll-immutability invariant in references/dice-wire.md) call, extracted so a `[[doc:]]`/`[[roll:]]`/`[[asset:]]` span
  and `sanitize`'s markdown-derived `image_urls` compose identically on send and on edit. Chunks
  through `chat::rolls::scan_body_capped`; each `Text` chunk independently calls `sanitize` and
  accumulates its `segments` across the whole body (markdown spanning a
  chunk boundary does not survive — same documented per-chunk-independent sanitize limit as
  before); `image_urls` is deduped ACROSS chunks too (first-seen URL wins), not only within one
  chunk's own `sanitize` call, so the same image referenced before and after an inline roll queues
  one job, not two. An `[[asset:<uuid>|alt]]` span becomes a `Segment::Image{asset_id, alt}` directly, no
  network fetch, no existence check (mirrors `DocLink`'s own no-existence-check-at-ingest
  design — a dangling `asset_id` is a client fail-closed-at-render concern via
  `ctx.assets.url`); an `[[asset:<uuid>]]` (no `|alt`) referencing an asset the repository cannot
  find as a valid asset UUID fails the compose with `ComposeError::Roll(RollError::UnknownAsset)`
  (grammar-adjacent to `[[roll:]]`'s own malformed-span errors, but the two `compose_message`
  callers surface a `ComposeError::Roll`/`SendMessageError::Roll` DIFFERENTLY: `handle_send_message`
  catches it and authors a whispered `MessageKind::System` notice instead — see
  `build_roll_error_notice` below, never a hard `ChatError` on that path — while
  `handle_edit_message` returns it DIRECTLY as the edit's `ChatError`, since an edit's
  rejected-intent path has no notice-authoring step to route through). The composed `image_urls` returned
  alongside `segments` is what `handle_send_message`/`handle_edit_message` pass on to
  `link_preview::enrich` to queue `InlineImage` jobs (see next section) — this is why the
  enrich-stage gate in references/link-previews.md is `policy.previews_enabled() || !image_urls.is_empty()`, not
  `previews_enabled()` alone: a world can enable `images` without `hyperlinks`, and such a world's
  markdown image URLs must still reach the post-publish pipeline even though link previews stay
  off. `enrich` itself takes a separate `scan_previews: bool` (= `previews_enabled()`) parameter
  gating ONLY its own href/oEmbed scan over the message's `Html` segments — the two concerns are
  independent, so a world with `hyperlinks: true, link_previews: Some(false), images: true` still
  gets its images queued without also scanning for link previews.
- `chat::body::compose_static(body: &str, policy: &ChatContentPolicy, max_spans: usize) ->
  Result<Vec<Segment>, RollError>` — `compose_message`'s SYNCHRONOUS sibling, for a document body
  composed at write time with no repository/network access (first consumer:
  `data::engine::note::NoteEngine::derive_body`, see `shadowcat-codebase-tables-notes`). Shares
  `scan_body_capped`'s chunk grammar, but an `Inline` OR `Button` span always becomes an unexecuted
  `Segment::RollButton` (never a `Segment::RollEmbed` — there is no per-caller host to resolve a
  reference against, and a document save must never roll dice as a side effect), and an `Image`
  chunk gets no existence/policy check beyond the alt-length cap (the caller's own policy already
  gates whether images are structurally possible; there is no async repository lookup to run one
  here). `Sanitized.image_urls` is discarded outright — no outbound fetch exists on the caller's
  write path, so a markdown image renders only as its alt text.
- `chat::NOTE_CONTENT_POLICY` (`chat::settings`) — the fixed `ChatContentPolicy`
  `compose_static`'s first consumer (`NoteEngine::derive_body`) always passes, independent of the
  world's own `chat-settings` document: markdown/hyperlinks/images on, html/emails/link-previews
  off.
- `chat::settings` — `ChatContentPolicy{markdown, html, images, hyperlinks,
  emails: bool}`, all `#[serde(default)]` = `false`, stored as the `system` body of the single
  per-world `chat-settings` config `Document` (`CHAT_SETTINGS_DOC_TYPE`). `resolve_content_policy
  (repo, world_id) -> ChatContentPolicy` is FAIL-CLOSED on every failure mode: a query error, an
  absent doc, or a `system` body that fails `serde_json::from_value` all yield
  `ChatContentPolicy::default()` (every toggle off, plain text) — never a partial/best-effort
  parse that could widen enrichment on malformed input. Every toggle can only WIDEN from that
  safe baseline, so degrading to `default()` is always the safe direction.
- `chat::commands` — `parse_command(raw: &str) -> ParsedCommand{kind,
  whisper_to: Option<Vec<String>>, body}`, pure (no repo/async — the async caller resolves
  `whisper_to` usernames and re-validates). Only a LEADING token counts; the same text mid-message
  is literal. `/me `/`/em `/`/emote ` → `MessageKind::Emote`. `/roll `/`/r `, or bare `/NdM`
  shorthand (optionally `+K`/`-K`) → `MessageKind::Roll`, body stored VERBATIM/unexecuted (nothing
  in the parser executes it). `/w @user @user... rest` → `MessageKind::Normal` +
  `whisper_to: Some(raw_usernames)` — this is chat's SECOND `/w` front-door, independent of the
  `SendMessage` wire frame's `audience` field; `handle_send_message` reconciles the two,
  content taking precedence (see below). **`kind` can never be `MessageKind::System` from any
  parse path** — proven by an exhaustive test over every command token, not just the default
  fallthrough — `System` is reserved for a future server-authored-notice producer that does not
  go through this parser at all.
- `chat::fx` — the `/fx <asset-id-or-name> @<token name>` command, intercepted in
  `handle_send_message` BEFORE `parse_command` runs (a `/fx` prefix with no word boundary —
  `/fxwhatever` — falls through as ordinary text). The server resolves the asset (a raw UUID
  used as-is; otherwise `Repository::asset_id_by_name`, case-insensitive on `original_name`)
  and the target token's CENTER server-side (`Document.name` case-insensitive, READ-gated
  through the same `resolve_access_world`/`effective_owner_via` projection `list_documents`
  runs — an unreadable name collapses into the SAME "No such token." text as a nonexistent
  one, no existence oracle) on the world's ACTIVE scene (`world-settings` `activeScene`),
  charges the shared `vfx_rate` bucket BEFORE broadcast (the same per-user budget the raw
  frame spends — one rate decision per VFX play regardless of entry path), then
  reuses `ws::vfx`'s `validate_bounds`/`vfx_permitted` verbatim (a spectator is refused) and
  `broadcast_aux`es `ServerMsg::Vfx`. A successful `/fx` authors NO message document —
  `handle_send_message` returns `Ok(None)` (its return type is
  `Result<Option<(Command, Vec<PendingEnrichment>)>, SendMessageError>` — every other success
  is `Ok(Some(...))`, and the `ws::conn` call site's `Ok(None) => {}` arm sends no reply
  frame); a failure authors ONE whispered `MessageKind::System` notice to the sender via the
  generalized `build_system_error_notice` (whose `build_roll_error_notice` is a thin
  wrapper). `/fx` without an `@`-target is refused with the usage notice (no coordinate-literal
  form). See `shadowcat-codebase-vfx` for the whole subsystem.
- `ws::protocol` — `ClientMsg::SendMessage { request_id, channel, content,
  actor_owner: Option<ActorOwnerRef>, audience: Audience }` (ts-rs exported; `audience` is
  `#[serde(default)]`, so an omitted field parses as `Audience::Public`).
  `ClientMsg::EditMessage { request_id, message_id, content }`,
  `ClientMsg::DeleteMessage { request_id, message_id }`, and
  `ClientMsg::RecalcRoll { request_id, message_id, roll_id, ops: Vec<WireRecalcOp> }` (all three
  ts-rs exported) are the ONLY client-facing ways to mutate an existing stored message. **All
  four carry a REQUIRED `request_id: Uuid`** (mirroring the `Search`/`Pathfind`/`MoveRequest`
  correlation pattern): success is confirmed only by the broadcast `Event` echo, while a
  rejection is surfaced to the sender as a `ServerMsg::ChatError { request_id, message }`.
  `SendMessage`/`EditMessage`/`DeleteMessage` share one `SendMessageError` enum + one `Display`;
  `RecalcRoll` uses its own `RecalcRollError` + `Display` (see `handle_recalc_roll` in references/dice-wire.md) but
  the SAME `ServerMsg::ChatError` frame shape and asymmetric confirm-by-broadcast-echo protocol.
  `message` is `SendMessageError`'s (or `RecalcRollError`'s) `Display`, which is
  `[sec]`-classified: validation-class variants surface a specific reason, but
  authorization/existence/internal-class variants (`ActorNotSpeakable`, `Forbidden`, `NotFound`,
  `Data`; `RecalcRollError::Forbidden`/`NotFound`/`RollNotFound`) collapse to a fixed generic
  string — `NotFound`==`Forbidden` (no existence oracle), `Data` never leaks its inner detail.
  See the `Display` impls on `chat::SendMessageError` and `chat::RecalcRollError`.
- `ws::conn` — four chat dispatch points plus the `Intent` guard:
  - `ClientMsg::Intent { ops, .. }` arm: calls `chat::ops_target_message(&ops)` BEFORE
    `room.publish`; if true, sends `ServerMsg::Reject{reason: Forbidden}` and continues without
    ever reaching `apply_intent`.
  - `ClientMsg::SendMessage { .. }` arm: calls `chat::handle_send_message`.
  - `ClientMsg::EditMessage { .. }` arm: calls `chat::handle_edit_message`.
  - `ClientMsg::DeleteMessage { .. }` arm: calls `chat::handle_delete_message`.
  - `ClientMsg::RecalcRoll { .. }` arm: converts each `WireRecalcOp` via
    `WireRecalcOp::into_recalc_op` and calls `chat::handle_recalc_roll`.
  - All four chat arms confirm success only by the broadcast echo of the authored `Event` (same
    pattern as `Intent`), not a direct reply; a failure is `tracing::debug!`-logged AND emits a
    `ServerMsg::ChatError { request_id, message: e.to_string() }` to the SENDER's connection only
    (`handle_socket::etx`, never broadcast) so the rejection is surfaced instead of vanishing.
- `http::routes::write_ops` — mirrors the WS ingress guard:
  `if chat::ops_target_message(&ops) { return Err(AppError::Forbidden); }` before the room/repo
  write path. Both transports must independently apply this guard. (`EditMessage`/`DeleteMessage`/
  `RecalcRoll` have no HTTP equivalent — they are WS-only frames, same as `SendMessage`.)
- `data::sqlite::apply_intent` — takes a `WriteOrigin` (`Client` |
  `ServerMessageRevision`, from `data::command`) parameter, threaded from
  `Room::publish` through ~60+ call sites (every existing caller passes `WriteOrigin::Client`;
  ONLY `handle_edit_message`/`handle_delete_message`/`handle_recalc_roll`/
  `post_publish::run_pending_enrichments` ever construct `WriteOrigin::ServerMessageRevision`, and
  only after either their own owner-or-GM check has already passed (edit/delete/recalc) or, for
  `run_pending_enrichments`, after an OCC re-read against the current stored document (see the
  post-publish section in references/link-previews.md — this producer runs unattended, well after the original sender's
  own authorization already gated the message's existence). FOUR coupled chokepoints:
  1. **Create-gate exemption** (`apply_intent::is_baseline_message = doc.doc_type == MESSAGE_DOC_TYPE &&
     ctx.world_role == WorldRole::Player && doc.owner == Some(ctx.user_id)`) — lets a Player
     create a `message` doc even though `core:create` is otherwise GM-only by world default.
  2. **Ingress guard** (`ops_target_message`, WS `Intent` + HTTP `write_ops`) — rejects any
     client-authored `message` Create/Delete before it ever reaches chokepoint 1.
  3. **Update blanket rejection**, CONDITIONAL: `if cur.doc_type == MESSAGE_DOC_TYPE &&
     origin != WriteOrigin::ServerMessageRevision { return Err(DataError::Forbidden); }` — still
     rejects every ordinary client `Update` against a stored `message` doc (an owning Player's
     `DocRole::Owner` would otherwise satisfy WRITE_FIELDS and let them forge fields post-hoc), but
     now EXEMPTS the one write shape `handle_edit_message`/`handle_delete_message` produce.
  4. **`WriteOrigin::ServerMessageRevision` access grant**: when `cur.doc_type ==
     MESSAGE_DOC_TYPE && origin == WriteOrigin::ServerMessageRevision`, `apply_intent` does NOT
     call `resolve_access_world` (which would independently re-derive GM write authority from the
     MESSAGE'S OWN `gm_role`/`users` fields — and would incorrectly DENY a non-addressed/
     non-listed GM editing/deleting a `Whisper`/`GmOnly` message, since their capped role there
     has no `WRITE_FIELDS`). Instead it grants a narrowly SCOPED `Access { caps: {READ,
     WRITE_FIELDS}, all: false, ... }`, trusting that the calling handler has ALREADY completed
     its owner-or-GM check. This is proven correct for edit, delete, AND recalc, across all three
     `Audience` variants, for both the owner and a non-addressed GM —
     `handle_recalc_roll_succeeds_for_public_whisper_and_gmonly_audiences` independently
     test-proves the recalc case. `all: false` (not `all:
     true`) is deliberate — it authorizes writing `/engine` only,
     not `/permissions`/`/embedded`, even for this trusted origin. A write scoped to EXACTLY
     `/engine` or `/permissions/property_overrides` is ALSO exempted from the additive
     `declared_caps_for_path` world/module-requirement check (`authorize_update_change::is_scoped_smr_write`,
     a three-way conjunction: origin + doc_type + exact
     path) — `CapabilityRequirement` carries no `doc_type`, so its ancestor-overlap rule would
     otherwise make ANY world-declared requirement under `/engine` (e.g. an actor's
     `/engine/vision`) block every `ServerMessageRevision` `/engine` write in that world,
     regardless of doc_type, denying a GM's already-vetted moderation edit/delete/recalc. A
     `ServerMessageRevision` write to any OTHER path still goes through the additive check —
     the exemption is scoped by path, not by origin alone, so it cannot silently widen if a
     future caller of this origin ever targets a path outside those two.

- **`SendMessage` is the SOLE message-authoring path.** A stored `message` doc can only be
  produced by `chat::handle_send_message` → `chat::build_message_doc` → `Room::publish`. No other
  code path may construct or persist one.
- **The seam is a FOUR-part coupled surface — weakening any one part alone reopens forgery.**
  (1) create-gate exemption, (2) `ops_target_message` ingress guard (WS `Intent` + HTTP
  `write_ops`), (3) the Update blanket rejection (conditional on `WriteOrigin`), and (4) the
  `WriteOrigin::ServerMessageRevision` scoped-access grant. (1) is sound only because (2) rejects
  a client-authored `message` Create/Delete before it ever reaches (1). (3) still blocks EVERY
  ordinary client Update, so a Player's own `DocRole::Owner` can never satisfy WRITE_FIELDS on
  their own message directly — the ONLY way through (3) is (4), and (4) is reachable ONLY via
  `handle_edit_message`/`handle_delete_message`, which run their own owner-or-GM check BEFORE
  setting `WriteOrigin::ServerMessageRevision`. `WriteOrigin` is not derivable from any wire frame
  — a client cannot request it, forge it, or otherwise reach (4) directly. Do not touch any one of
  the four without re-verifying the others.
- **GM edit/delete authority is audience-independent by design.** A GM may edit or delete ANY
  message (`Public`/`Whisper`/`GmOnly`) via `handle_edit_message`/`handle_delete_message`'s
  `ctx.world_role == WorldRole::Gm` check, REGARDLESS of whether that GM is individually listed in
  a `Whisper`'s `recipients` or would otherwise have read access to a `GmOnly`/`Whisper` message at
  all (moderation authority, not read authority — the two are deliberately decoupled). This is
  exactly why chokepoint (4) above cannot call `resolve_access_world` on the message's own
  `PermissionSet`: a non-addressed GM's capped role there has no `WRITE_FIELDS`, which would
  incorrectly deny a legitimate moderation edit/delete.
- **`/w` has two independent front-doors, and content wins.** A whisper audience can be set either
  via the `SendMessage` wire frame's `audience: Audience::Whisper{...}` field, or via a
  content-level `/w @user...` command. `handle_send_message` reconciles both through the exact
  same cap+membership validation chokepoint; when BOTH are present, the parsed content `/w`
  overrides the frame's `audience` argument. An edit can never open either front-door — a `/w` in
  edited content is rejected outright (`AudienceLocked`), not silently applied.
- **A NON-WHISPER edit re-runs the FULL send pipeline (`parse_command` + `sanitize`) except
  audience, which is frozen.** `kind` MAY change on edit (a plain message can become `/me`), but
  `channel`/`user_owner`/`actor_owner`/`audience`/`deleted_at` are always copied verbatim from the
  STORED document, never re-derived from the edit request. **A WHISPER edit skips
  `parse_command` entirely** — the edit content is the literal body and `kind` is left as stored,
  mirroring `handle_send_message`'s own literal-body treatment of a whisper's content; without
  this, an unmodified resubmit of a whisper's edit-prefill (itself post-`/w`-strip `source`) could
  silently reparse into a different `kind` or spuriously trip `AudienceLocked` one token deeper.
  `AudienceLocked` therefore fires only for a non-whisper edit. A delete is a pure SOFT tombstone — `content`
  is cleared and `deleted_at` is set via `Operation::Update` on `/engine` (was
  `/system`), NOT a hard `Operation::Delete`; the doc stays in the sequenced log at its original
  seq, so resync and per-recipient redaction keep applying to it unmodified. An edit on an
  already-tombstoned message is rejected (`NotFound`) — content can never be resurrected on a
  soft-deleted doc.
- **Content model is opaque and NOT ts-rs-exported** (`MessageKind`, `Segment`, `MessageEngine`)
  — only `ActorOwnerRef` and `Audience` (both on the wire `SendMessage` frame) are. The client
  mirror NOW EXISTS: the `chat-docs` module — Zod schemas +
  `parseMessageEngine(doc) -> ChatMessageEngine | null` (parses `doc.engine` not `doc.system`;
  fail-closed: wrong doc_type or ANY
  malformed body → null, never partial) + `isKnownSegment` (the source of truth for which
  segment kinds are known — unknown kinds parse as
  opaque forward-compat and render as nothing, but the fallback REFUSES every kind it lists so
  a malformed known-kind segment fails the whole message instead of being misclassified —
  load-bearing, pinned by tests). A Rust-side body-shape change MUST update that file by hand
  (drift notes at both ends), not a regenerated binding. `MAX_MESSAGE_CHARS` is mirrored there
  for composer pre-validation (JS `.length` counts UTF-16 units vs the server's
  `chars().count()` — divergence is fail-safe: client can only over-block). `PermissionSet`
  itself IS a generic, already-mirrored envelope type — its new `gm_role` field is picked up by
  the existing drift guard, not a message-specific mirror.
- **A whisper hides from the GM by default; only `recipients` membership grants a GM access.**
  There is no automatic GM see-all for `Whisper`/`GmOnly` messages — a GM must be individually
  listed in `recipients` (for `Whisper`) or simply hold `WorldRole::Gm` at read time (for
  `GmOnly`, via `gm_role`); a GM not covered by either sees nothing, not even that the doc exists.
  This is a deliberate product decision, not an oversight.
- **Recipient validation happens BEFORE document construction, fail-closed on the whole send.**
  `handle_send_message` checks every `Whisper` recipient against current world membership; a
  single bad uuid rejects the entire message (no partial send, nothing persisted) — do not move
  this check after `build_message_doc` or make it per-recipient-tolerant.
- **Messages ride the existing Event/redaction/search machinery with zero message-specific
  code in those subsystems** — a message's visibility, per-recipient redaction, sequencing, and
  FTS5 search hit are governed entirely by the generic `Document`/`PermissionSet` rules
  (`shadowcat-codebase-documents-permissions`) and the generic room broadcast/resync path
  (`shadowcat-codebase-realtime-sync`). Any change to those subsystems' redaction or indexing
  logic implicitly changes chat behavior too — there is no separate chat-specific override to
  audit, but also no chat-specific safety net.
- **`spec`/`raw` on a `RollEmbed` (and every `RecalcEntry.previous_raw`) are GM-only via
  `permissions.property_overrides`, populated by `roll_property_overrides` at
  message-Create time and re-populated on every recalc — never a chat-specific redaction
  filter; `outcome`/`recalc_history`/`roll_id` stay visible to every recipient.**
  `roll_property_overrides` (its name covers both `RollEmbed` and `TableDraw` segments — see the
  `push_draw_overrides` note below) is recomputed from scratch against the CURRENT `content` on
  every call (never incrementally patched), so a message's override set always matches what it
  actually carries; `build_message_doc` calls it at Create, `handle_recalc_roll` calls it again
  after every recalculation and writes the result to `/permissions/property_overrides` in the
  SAME `Operation::Update` as the mutated `/engine` — the one write shape `apply_intent`'s
  `ServerMessageRevision` branch admits at that exact path (chokepoint 4 above). A
  `Segment::TableDraw(TableDrawSegment)` — produced only by `tables::handle_draw_table`, never by
  chat's own parser — recurses the SAME GM-only treatment through `push_draw_overrides`: its own
  `spec`/`raw` at `/engine/content/{i}/spec|raw`, and recursively through every
  `TableDrawSegment.row.nested` entry at `/engine/content/{i}/row/nested/{j}/...` — a nested draw
  arbitrarily deep still redacts at every level, see `shadowcat-codebase-tables-notes`.

