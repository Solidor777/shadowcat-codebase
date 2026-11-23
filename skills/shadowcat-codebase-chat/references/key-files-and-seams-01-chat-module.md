Part of the shadowcat-codebase-chat skill; read it when editing the chat module itself (message types, ingest, authoring). Part 01 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

## Key files & seams

- The `chat` module — the domain home:
  - `MESSAGE_DOC_TYPE = "message"`.
  - `ActorOwnerRef` (`Actor{actor_id}` | `TokenInstance{token_id}`) — the ONLY chat type with
    `#[derive(TS)]` (ts-rs export); carried on the `SendMessage` wire frame.
  - `MessageKind` (`Normal` default, `Emote`/`Roll`/`Ooc` producible by `parse_command`; `System`
    reserved for future server-authored notices — NO parse path can ever produce it, proven by an
    exhaustive test) and `Segment` (tagged enum: `Text{text}` — verbatim, client renders as a DOM
    text node; `Html{sanitized_html}` — a run of already-`ammonia`-cleaned HTML, produced ONLY by
    `sanitize::sanitize`, client renders via `innerHTML`; `Image{asset_id, alt}` — see below; the full variant list, including `Secret`, is in
    SKILL.md) — both serde-only, NO ts-rs; they live
    inside the `engine` JSON body, not the wire frame, so the client
    declares its own Zod mirror later. **Design note (revised for `Image`):** inline
    formatting/hyperlink markup does NOT get its own typed `Segment` variant — it stays INSIDE a
    `Segment::Html` run as ordinary sanitized markup (`<strong>`/`<a>`). Images are the deliberate
    EXCEPTION: an `<img>` is stripped from every `Html` run regardless of the `images` policy
    toggle (`chat::sanitize::sanitize` never lets a raw image URL reach the client — see
    `sanitize`'s `ImageSource` extraction in key-files-and-seams-02-shortcodes-sanitize-commands.md) and instead becomes a typed `Segment::Image{
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
    side and `roll_property_overrides`'s `push_draw_overrides` note in key-files-and-seams-03-ws-http-and-invariants.md for its redaction.
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
    decoded) contribute their text, `RollEmbed` contributes its `formula` and its `flavor` when set
    (never `outcome`/`spec`/`raw`/`recalc_history`), `RollButton` its `formula`, `label` and `flavor`,
    `Secret` recurses into its `content` (the document's `property_overrides` then decide whether that text reaches the
    public index partition, via `index_content_public`'s `filter_properties` pass),
    `LinkPreview` its title, description AND url (never the image asset id), `OEmbed` its title,
    author and provider names (never an id or the url), `DocLink`/`Image` only their label/alt,
    and `TableDraw` recurses through its `table_name` and matched row's label/content, nested
    draws included (never the draw's own `formula`/`outcome`/`spec`/`raw`/ids). `data::engine::search_text`
    (`shadowcat-codebase-documents-permissions`) calls it for BOTH `note` (a rendered `body`) and
    `message` (`content`) doc-type projections — the single function keeping those two engines'
    indexed text in sync rather than two ad-hoc leaf sweeps.
  - `Audience` (`Public`/`Whisper{recipients: Vec<Uuid>}`/`GmOnly`/`Blind`, `#[default] Public`,
    tagged enum, ts-rs exported same as `ActorOwnerRef`) — the intended readership of a message,
    carried on the `SendMessage` frame and stored verbatim in `MessageEngine`. This is the ONLY
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
    `audience` maps onto `PermissionSet{default, gm_role, users}` through the one decider
    `permissions_for_audience` (also called by `handle_revise_audience`;
    `build_message_doc_with_readers` takes the `BlindReaders` a blind message's world settings
    grant, and `build_message_doc` passes the empty default) (see
    `shadowcat-codebase-documents-permissions` for what `gm_role` does at `resolve_access` time):

    | `Audience` | `default` | `gm_role` | `users` |
    |---|---|---|---|
    | `Public` | `Observer` | `None` | `{owner: Owner}` — the original, unrestricted default shape |
    | `Whisper{recipients}` | `None` | `Some(DocRole::None)` | `{owner: Owner, ...recipients: Observer}` |
    | `GmOnly` | `None` | `Some(DocRole::Observer)` | `{owner: Owner}` only |
    | `Blind` | `Observer` when `BlindReaders.everyone`, else `None` | `None` | `{owner: Owner, ...BlindReaders.also: Observer}` |

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
    runs `parse_command(&content)`. If the parsed command carries an `audience_intent` (a content-
    level `/w @user...`, `/gm`, `/blindroll` ...), a `Whisper` intent's RAW name list is cap-checked against `MAX_WHISPER_RECIPIENTS = 128`
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
    separately, see key-files-and-seams-03-ws-http-and-invariants.md.
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
