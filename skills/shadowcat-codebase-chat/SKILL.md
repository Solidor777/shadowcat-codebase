---
name: shadowcat-codebase-chat
description: "Use when touching Shadowcat's chat system: the message Document model (incl. source/edited/deleted markers), SendMessage/EditMessage/DeleteMessage ingest, the ops_target_message ingress guard, the WriteOrigin-gated Update exemption, the content sanitizer + shortcode pre-pass, the chat/dice settings policies, the command parser, the roll wire boundary (chat::rolls's caps/entropy/span-scanner, RollEmbed/RollButton segments, System error notices, roll immutability, attribution authz), the SSRF-guarded link-preview fetcher (chat::link_preview's GuardedResolver/IP-blocklist/redirects, chat::preview_cache, the LinkPreview segment + ingest enrich + previews_enabled toggle), inline chat images (Segment::Image, chat::body::compose_message, the InlineImage post-publish job, Provenance::ChatImage), the synchronous chat::body::compose_static composer + chat::NOTE_CONTENT_POLICY a note's server-derived body uses (see shadowcat-codebase-tables-notes for the note engine doc type itself), the client body mirror (the chat-docs module), or the chat UI modules (chat, chat-composer, chat-card, plus ui-kit's SegmentList — the {@html} boundary + roll/preview/image rendering). Covers src/server/src/chat/ + src/client/core/src/chat-docs.ts + src/modules/chat* + src/client/ui-kit/src/SegmentList.svelte. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Chat Core

Orientation for the server-authoritative chat system. Messages are ordinary sequenced
`Document`s (`doc_type: "message"`) riding the existing Event/redaction/search path — **no
chat-specific transport or index code**. Readership is driven by an `Audience` enum mapped onto
the generic `PermissionSet`/`gm_role` mechanism, with zero message-specific
redaction/search/broadcast code. Content passes a sanitization boundary (`chat::sanitize`,
`ammonia` + `pulldown-cmark`); a leading-command parser (`chat::parse_command`) derives
`MessageKind` and a content-level `/w` whisper target; `EditMessage`/`DeleteMessage` are the
authorized, sanitizing edit path and soft-tombstone delete path, gated by a `WriteOrigin` marker.
The display layer rests on three server enablers — `MessageEngine.source` (edit-prefill raw
input), an always-on `:shortcode:` → emoji pre-pass in `sanitize`, and a member-visible world
roster — plus the client Zod mirror (the `chat-docs` module) and the chat UI as three replaceable
modules (`module-chat` host / `module-chat-composer` / `module-chat-card`). Rolls execute
server-side at chat ingest (`chat::rolls` — the ONLY untrusted-notation execution path, behind
caps + per-roll OS entropy), outcomes ride the body as `Segment::RollEmbed`/`RollButton`, roll
errors surface as whispered `MessageKind::System` notices (`build_roll_error_notice`), rolls are
edit-immutable, attribution is ownership-validated at ingest, and the card/composer render/author
it all. SSRF-guarded link previews are the server's ONLY outbound HTTP, behind a validating DNS
resolver + IP blocklist, fetched synchronously at ingest, stored as a `Segment::LinkPreview`, and
rendered client-side (never fetched by the client). A `chat::post_publish` background pipeline
runs AFTER the synchronous send/edit already returned: it resolves a preview's `og:image` and
allowlisted-provider oEmbed embeds (`chat::oembed`) into asset-ified thumbnails, republishing the
message via the same `WriteOrigin::ServerMessageRevision` chokepoint edit/delete/recalc use.

## Link previews — `chat::link_preview` + `chat::preview_cache`

The server's only outbound HTTP. `reqwest` is a PRODUCTION dep (rustls-tls; ~1.1 MiB binary
delta, far under budget). Load-bearing security surface — treat any change to `chat::link_preview`
as review-worthy by default (a literal-IP URL
`http://169.254.169.254/` can bypass the resolver via hyper's IP-literal DNS short-circuit unless
guarded, per `validate_url` below).

- **`fetch_preview(client, url)`** — the ONLY untrusted-URL fetch path. Guards in order:
  `validate_url` (scheme `http`/`https` ONLY, reject `userinfo`, reject empty host, AND — the
  load-bearing arm — for an IP-LITERAL host run `is_blocked_ip` directly, since hyper
  short-circuits DNS for a literal and `GuardedResolver` would never see it; url-crate normalizes
  `2130706433`/`0x7f000001` to `Host::Ipv4`, caught here);
  `GuardedResolver` (custom `reqwest::dns::Resolve`, validates EVERY resolved IP against the
  clean-room RFC-cited `is_blocked_ip` v4+v6 blocklist — private/loopback/link-local/CGNAT/ULA/
  multicast/documentation/6to4-`2002::/16`/NAT64/IPv4-mapped/IPv4-compat, ALL-OR-NOTHING so a
  public+private mix rejects wholesale → the DNS-rebind close, since reqwest connects to exactly
  the validated IPs); `redirect(Policy::none())` + a manual ≤`MAX_REDIRECTS=5` loop re-validating
  scheme+host per hop; ONE wall-clock `tokio::time::timeout(TOTAL_TIMEOUT=5s)` over the whole
  redirect chain (not per-hop); streamed `MAX_PREVIEW_BYTES=512KiB` cap; `text/html` content-type
  gate; a bounded `<title>`/OpenGraph extractor (title≤200, desc≤400). Production
  `build_client()` takes NO flag (`allow_loopback` false); `build_client_allow_loopback`/
  `build_client_with_resolve_fn` are `#[cfg(test)]`-only — production literally cannot build a
  loopback-permitting client. **No preview image in v1** (an `<img src>` would make the client
  fetch → leak the viewer's IP; title+desc only).
- **Ingest (`chat::link_preview::enrich`, called from `handle_send_message`/`handle_edit_message`):**
  extracts hrefs from GENUINE `<a>` tags in the sanitized `Segment::Html` runs (NOT a raw
  `href=` substring scan — inert body text `see href="http://x"` would otherwise trigger a real
  outbound fetch), dedups, caps `MAX_PREVIEWS_PER_MESSAGE=3`, resolves each candidate via
  `cached_or_fetch` (checks the in-memory `LinkPreviewCache` tier first, then the persisted
  `link_preview_cache` row on a miss, before ever attempting a network fetch), fetches remaining
  cache-misses concurrently (`JoinSet`), appends one `Segment::LinkPreview` per success at the
  END. SYNCHRONOUS before publish (no spawned task/post-hoc revision). Gated on
  `ChatContentPolicy::previews_enabled()` (= `hyperlinks && link_previews.unwrap_or(true)` —
  default-ON only when hyperlinks on) AND an EXPLICIT `kind != MessageKind::Roll` guard. Holds NO
  lock across the fetch await (only the sending connection's own loop blocks, bounded by the 5s
  deadline). Every failure degrades silently (no card, cached negative). `enrich`'s own signature
  takes an `EnrichDeps<'a> { repo, fetch: LinkPreviewDeps<'a> }` bundle rather than a flat
  parameter list — the repository handle a persisted-cache lookup needs, grouped in with the
  existing `client`/`cache`/`rate` fetch bundle to stay under clippy's too-many-arguments limit,
  same restructuring pattern as `PostPublishDeps`/`data::asset::NewAssetBytes`. `enrich` ALSO
  takes `image_urls: &[sanitize::ImageSource]` (`chat::body::compose_message`'s second return
  value): each valid, non-blocked-URL source (`validate_url` — the SAME SSRF guard the link-scrape
  path uses, not a separate check), rate-limited the same way, is queued as a
  `PendingEnrichment::InlineImage{image_url, alt}` job, capped at `MAX_INLINE_IMAGES=4`
  independently of `MAX_PREVIEWS_PER_MESSAGE` (an image-heavy message can carry both link previews
  and inline images up to their own separate caps). The call site's gate is
  `previews_enabled() || !image_urls.is_empty()`, not `previews_enabled()` alone — see
  `chat::body::compose_message` above for why.
- **`LinkPreviewCache`** (in-memory, on `WsState`): URL→`(Instant, Option<LinkPreview>)`,
  positive/negative TTLs, evict-oldest past a cap; `PreviewRateLimiter` (per-user distinct-URL
  fetch budget, only on cache MISS). Both mirror `message_rate`'s `WsState` Arc-field pattern. This
  is the FIRST (request-lifetime) tier of a two-tier cache — see `link_preview_cache` below for
  the persisted second tier the post-publish image pipeline reads/writes.
- **`ChatContentPolicy.link_previews: Option<bool>`** — tri-state (absent/`None` = default-on;
  `Some(false)`/`Some(true)` = GM override), authored in `module-game-settings`' new chat-settings
  section. Singleton `chat-settings`/`dice-settings` resolution is deterministic-by-lowest-UUID
  (`query_documents ORDER BY id`); construction-time uniqueness is a logged TODO.
- **Client:** the `chat-docs` module mirrors `link_preview` (fail-closed refine); the card renders a
  bordered escaped-text card (title/description/host), the whole card an `<a rel="noopener
  noreferrer nofollow">` whose href is gated by a `safeHref` scheme re-check (http/https only —
  a stored non-http url renders non-clickable, defense-in-depth). An `<img>` renders ONLY when
  `image_asset_id` is present, its source always resolved via `ctx.assets.url(uuid)` — this
  server's own asset endpoint, never the raw external image URL (which is never stored on the
  segment at all).

### Post-publish enrichment — `chat::post_publish` + `chat::oembed`

The image/embed half of link previews, deliberately split from the synchronous scrape above:
fetching and asset-ifying an image is unbounded-enough latency that it must never sit on the
`SendMessage`/`EditMessage` request path. `link_preview::enrich` queues zero-to-many
`PendingEnrichment` jobs (`PreviewImage{preview_url, image_url}` when its synchronous scrape found
an `og:image` candidate; `OEmbed{post_url, provider}` when `chat::oembed::match_provider` matches
an allowlisted host) for the caller to run via `post_publish::run_pending_enrichments` AFTER
`Room::publish`'s synchronous send/edit already returned.

- **`run_pending_enrichments(deps: PostPublishDeps, message_id, world_id, jobs)`** — resolves every
  job concurrently (`JoinSet`), then issues AT MOST ONE `Operation::Update` on `/engine`
  re-publishing whichever fields resolved, via `publish_resolved`. Re-reads the CURRENT stored
  document (OCC pre-image) immediately before publishing — a message edited, deleted, or
  concurrently modified by the time the fetches complete is not clobbered; a tombstoned message is
  a silent no-op. `PostPublishDeps` groups `room`/`repo`/`client`/`assets_root`/`write_barrier`/
  `preview_fetch_locks` — the same `AppState.write_barrier` `http::assets::upload`/`replace`/
  `delete` hold, since this is the first asset-commit path reachable from outside a direct HTTP
  request.
- **`PreviewFetchLocks`** (`AppState.preview_fetch_locks`, `Arc<DashMap<String,
  Arc<tokio::sync::Mutex<()>>>>`) — a process-wide per-URL fetch lock, same keyed-registry shape as
  `ws::room::RoomRegistry.rooms`, closing the race where two concurrent post-publish jobs resolving
  the identical URL both observe a `link_preview_cache` miss and each create their own orphaned
  `Asset`. `with_preview_url_lock` runs a resolver's WHOLE check-cache-then-fetch-then-set sequence
  under the per-URL lock (a second caller for the same URL observes a cache HIT and skips the
  fetch entirely), then reclaims the map entry once no concurrent caller still holds a clone —
  the strong-count check and the removal happen inside one continuous keyed-entry lookup so no
  waiter can observe or clone the `Arc` in between, ruling out two different `Mutex` instances ever
  existing for the same URL at once.
- **`resolve_preview_image`** — checks the persisted `link_preview_cache` row for the preview's
  URL FIRST and reuses an existing `image_asset_id` verbatim on a hit (never re-fetching/
  re-creating an asset for a link any message already imaged); on a miss, fetches the image via
  `fetch_image_bytes` (the same SSRF-guarded client `fetch_preview` uses) and asset-ifies it via
  `data::asset::create_asset_from_bytes` with `created_by: None` — see `shadowcat-codebase-assets`
  for that shared commit path and the `created_by: None` convention.
- **`resolve_inline_image`** — the `PendingEnrichment::InlineImage` resolver, structurally a
  mirror of `resolve_preview_image` with ONE difference: a preview target's `link_preview_cache`
  row already exists (the synchronous scrape wrote it), so `resolve_preview_image` only ever
  `set`s the image column; an inline image's URL has no such prior row, so `resolve_inline_image`
  `upsert_link_preview_cache`s a fresh one before `set_link_preview_cache_image`. Cache hit ⇒
  reuses the stored `image_asset_id` verbatim (`ResolvedEnrichment::NewImageSegment(Segment::
  Image{asset_id, alt})`, no re-fetch); cache miss ⇒ `fetch_image_bytes(client, url,
  Duration::from_secs(5), MAX_INLINE_IMAGE_BYTES)` (the inline-image byte cap, independent of
  `MAX_IMAGE_BYTES`'s preview-thumbnail cap — `fetch_image_bytes` takes the cap as a parameter
  precisely so the two callers can differ) → `create_asset_from_bytes` with
  `Provenance::ChatImage`, `created_by: None` (see `shadowcat-codebase-assets`) → cache-write →
  `NewImageSegment`. `publish_resolved`'s `ResolvedEnrichment::NewImageSegment(segment)` arm
  simply pushes the resolved `Segment::Image` onto `content` — unlike a `LinkPreview`/`OEmbed`
  patch, there is no existing segment to update; the image segment did not exist in the message
  at all until this background job resolved it.
- **`resolve_oembed`/`resolve_thumbnail_asset`** — queries `provider.endpoint(post_url)` (the
  allowlisted host, `post_url` only ever contributes the `url` query VALUE — never the endpoint
  host) via `fetch_json_bytes`, deserializes into `OEmbedResponse` (structurally incapable of
  carrying a provider's `html` field — no such field exists on the type, so ordinary serde
  unknown-field handling drops it before it can ever reach `OEmbedSegment`), then resolves an
  optional thumbnail through the same cache-then-fetch-then-`create_asset_from_bytes` path
  `resolve_preview_image` uses (keyed by the thumbnail's own URL). Builds a brand-new
  `Segment::OEmbed` appended to `content` — never patches an existing segment, and never appended
  alongside a `Segment::LinkPreview` for the same URL (`link_preview::enrich`'s oEmbed-vs-generic
  routing is mutually exclusive per URL).
- **`chat::oembed`** — allowlisted provider HOSTS only (`OEmbedProvider::YouTube`/`Vimeo`), NEVER
  autodiscovery (`<link rel="alternate" type="application/json+oembed">` against an arbitrary
  posted URL would reintroduce the arbitrary-host-fetch risk this feature exists to avoid).
  `match_provider(raw_url)` is a synchronous, zero-network host check — the entire SSRF mitigation
  for oEmbed; a URL failing it falls through to the generic `LinkPreview` scrape unchanged.
  `OEmbedSegment{url, provider_name, title, author_name, thumbnail_asset_id}` has NO `html` field
  by construction, mirroring `OEmbedResponse`'s own structural guarantee one layer earlier —
  `provider_name` is always THIS SERVER'S fixed display name (`OEmbedProvider::name`), never a
  provider's self-reported `provider_name` JSON field.
- **`link_preview_cache` (persisted, SQLite)** — the second, durable tier beneath the in-memory
  `LinkPreviewCache`: `Repository::get_link_preview_cache`/`upsert_link_preview_cache`/
  `set_link_preview_cache_image`, keyed by URL, storing `image_asset_id` once a background job
  resolves one. `resolve_preview_image`/`resolve_thumbnail_asset` both check this table before any
  network fetch, so a link imaged once by any message is never re-fetched or re-asset-ified for a
  later message reusing the same URL.
- **`Segment::LinkPreview.image_asset_id: Option<Uuid>`** — `#[serde(default)]` (every
  `LinkPreview` segment persisted before this field existed has no such key on disk), `None` when
  `enrich`'s synchronous scrape first appends the segment, set later ONLY via a
  `WriteOrigin::ServerMessageRevision` republish (`run_pending_enrichments`).

## Dice wire — `chat::rolls` + the ingest roll stage

- `chat::rolls`: caps (`MAX_ROLL_DICE=100` summed over the parsed `Expr` — `walk_groups` recurses
  into `Expr::Call`'s arguments too, so a dice group nested inside a math-function call still
  counts; `MAX_ROLL_RECORDS=1000`
  post-roll; `MAX_EXPERTISE=100`; `MAX_DIE_SIDES=10_000`; `MAX_INLINE_ROLLS=8`),
  `DieKind::validate()` per group, `entropy_seed()` (fresh `Uuid::new_v4` fold per roll —
  nothing persists the seed; a stored outcome's naturals reproduce it), `scan_body_capped` (BALANCED
  `[[…]]` span grammar — single-bracket nesting depth so notation `[label]`s survive;
  `roll:`-prefixed spans are buttons, `|` splits a label), `execute_roll` /
  `validate_formula` (parse+caps without rolling, for buttons), `RollError` + Display.
- **References in roll notation resolve server-side at this boundary.** A roll's formula may be a
  raw TEMPLATE (`1d20 + stats.str`): `execute_roll`/`execute_roll_with_seed` first run it through
  `crate::formula::resolve_notation_template` (the Rust twin of the TS template rewrite), resolving
  each reference against the roll's HOST — for chat, the send's already-ownership-validated
  `actor_owner` via `chat::host::host_for_actor_owner` (a token's embedded actor copy, else its
  linked actor, the combat precedence rule shared through `data::document::embedded_actor_copy`),
  with no binding ⇒ `NoHostResolver` ⇒ an `unknown-ref` refusal via `RollError::Reference`
  (player-presentable `detail`). The substituted labeled constants surface as `labeled_consts`
  chips; the stored `RollEmbed.formula` keeps the author's template text, and recalc re-derives
  from the stored `spec`/`raw`, never re-resolves. Buttons (`[[roll:...]]`) validate structurally
  with a placeholder zero (a reference can never sit in dice-count/sides position) and store the
  raw template, resolving per CLICKER at click time. The template scan also reserves the notation
  `fn_call` vocabulary (`floor(101d6/2)` is notation, never a reference).
- `handle_send_message` roll stage (post-parse, pre-sanitize): kind `Roll` ⇒ the body is the
  formula, content becomes ONE `RollEmbed{formula, outcome, roll_id, spec, raw,
  recalc_history: None}` (sanitize skipped — no text). `chat::rolls::execute_roll`/
  `execute_roll_with_seed` return the parsed `RollSpec` and rolled `RawRoll` alongside
  `formula`/`outcome`, and both are PERSISTED (not discarded) onto the embed — `spec`/`raw` are
  what let a GM later recalculate the roll via `handle_recalc_roll`; `roll_id` (a fresh `Uuid`) is
  the stable identity a recalc targets, never the segment's array index.
  Normal/Emote bodies are `scan_body_capped`-chunked — Text chunks sanitize EACH INDEPENDENTLY
  (markdown spanning an inline roll doesn't survive, documented), Inline chunks execute,
  Button chunks validate-only. Ambient `ParseContext` = `resolve_dice_context(repo, world,
  channel)` (the `dice-settings` config doc: a `channel_overrides` entry for the SENDING channel
  wins outright over the doc's own `mode`/`direction`, full replacement never partial merge; fail-
  closed to Total/HighWins on any query error, absent doc, or malformed body, REGARDLESS of
  channel; GM-authored in module-game-settings' Dice section, including a per-channel editor
  enumerating `channel-registry`'s channels). ANY roll failure ⇒ the message is NOT created; instead
  ONE server-authored `MessageKind::System` notice (audience `Whisper{[sender]}`, same
  channel, sender-owned/deletable, content = the error's Display text) — exactly one message
  per attempted send, so the flood budget stays 1:1. `System` still has NO parse_command
  producer (exhaustive test unchanged).
- **Roll immutability (anti-cheat):** `handle_edit_message` rejects (`RollImmutable`) when the
  stored `kind == Roll`, when the stored content carries ANY `RollEmbed`/`RollButton` segment
  (an executed inline roll's audit record cannot be erased by editing around it), or when the
  new content parses to kind `Roll` (no editing INTO a roll). The stored-kind check is
  deliberately UNCONDITIONAL because `kind: Roll` + `audience: Whisper` IS reachable via the
  frame `audience` field (no `/w` token ⇒ `parse_command` still runs). Edits DO now route through
  `chat::body::compose_message` under `ScanMode::NoExecute` — a `[[doc:]]`/`[[token:]]`/
  `[[asset:]]` span in edited content composes into its typed segment the same as on send, and a
  `[[roll:]]` button span VALIDATES structurally (a malformed formula still fails the edit), but
  `ScanMode::NoExecute` guarantees no inline `[[Ndm]]` roll is ever EXECUTED by an edit — the
  distinction this bullet's title protects is "an edit can never mint a new rolled outcome," not
  "an edit treats `[[…]]` as inert text" (that was the pre-`compose_message` behavior; it changed).
  **Recalculation is the one deliberate
  exception to immutability**, gated entirely differently (see the next bullet) — it does not
  weaken this check, since `handle_edit_message` still refuses to touch `content` at all.
- **Recalculation (`handle_recalc_roll`):** the ONLY path that ever mutates an existing
  `RollEmbed`. GM-only (`ctx.world_role == WorldRole::Gm`) — deliberately NEVER owner-or-GM,
  unlike `handle_edit_message`/`handle_delete_message`: the roll's own author has no
  self-service correction path (`RecalcRollError::Forbidden`). Locates the targeted roll inside
  the message's `content` by `roll_id` (never array index — survives link-preview enrichment
  appending later segments), and refuses (`RecalcRollError::NoStoredState`) when the targeted
  `RollEmbed` carries no `spec`/`raw` (a roll embedded before this feature shipped) rather than
  guessing a spec back from `outcome`. Draws a fresh `entropy_seed()`, applies
  `dice::recalculate(&spec, &raw, &ops, &mut rng)`, overwrites `raw`/`outcome` in place, and
  appends a `RecalcEntry{ops, previous_raw, previous_outcome, recalculated_by,
  recalculated_at}` to `recalc_history` capturing the PRE-recalc state — the roll's original
  result is never silently discarded (`recalc_history` is append-only; `previous_raw`/
  `previous_outcome` on the Nth entry are exactly what the (N-1)th recalc, or the original roll,
  produced). Reuses `WriteOrigin::ServerMessageRevision` as this origin's THIRD producer (after
  `handle_edit_message`/`handle_delete_message`), publishing a single `Operation::Update` that
  writes BOTH `/engine` (the mutated content) AND `/permissions/property_overrides`
  (recomputed via `roll_property_overrides`, since a freshly-appended
  `RecalcEntry.previous_raw` needs its own GM-only override entry) — the exact two-path
  admission `apply_intent`'s `ServerMessageRevision` branch grants (see chokepoint 4 below).
  Rate-limited via the same `PingRateLimiter`/`budget_per_min` shape as
  `handle_send_message`/`handle_edit_message`. `WireRecalcOp` (`RerollDice`/`ReplaceDie`/
  `RemoveDice`, ts-rs exported — the wire frame's op vocabulary) converts via
  `WireRecalcOp::into_recalc_op` to `dice::recalc::RecalcOp` before reaching
  `dice::recalculate`; see `shadowcat-codebase-dice` for the engine-side op semantics.
  `ws::protocol`'s `ClientMsg::RecalcRoll{request_id, message_id, roll_id, ops}` and
  `ws::conn`'s dispatch arm are documented below alongside `SendMessage`/`EditMessage`/
  `DeleteMessage`.
- **Attribution authz (world-pinned):** `handle_send_message`
  fail-closed-validates `actor_owner` BEFORE `build_message_doc` — an `Actor` ref must resolve to
  an existing `doc_type=="actor"` doc, IN THE SENDING ROOM'S WORLD
  (`crate::data::document::world_of(d) == Some(room.world_id)`), owned by the sender (GM: any
  actor in that world). An actor doc from another world is refused (`ActorNotSpeakable`) even for
  its owner — ownership alone does not cross world scope. A `TokenInstance` ref is validated the
  same world-pinned way, except ownership resolves through `Repository::effective_owner_of`
  (the token's own `owner` override, else the linked actor's owner) rather than a stored `owner`
  field read directly — the same chokepoint every other ownership decision in this codebase
  goes through, never reimplemented inline. Edits copy `actor_owner` verbatim
  from the stored doc, so this ingest gate is the only one needed. `world_of` (`data::document`,
  `pub(crate)`) is the SAME helper `ws::conn::scene_ping_permitted` uses for its own
  cross-world scene pin — one idiom for "does this doc belong to world X," not two independent
  `Scope` matches.
- Client: the `chat-docs` module mirrors `roll_embed`/`roll_button` (`RollOutcomeSchema`/
  `DieRecordSchema`, records `.passthrough()` for server-only audit fields; the
  unknown-segment fallback REFUSES both new kinds — fail-closed; i64 `total`/`margin` can
  saturate past 2^53, a documented display-precision tradeoff). The card renders the block
  form ONLY for kind `Roll` + raw single-`RollEmbed` content, inline chips otherwise, buttons
  via `ctx.chat.send({channel: sys.channel, content: "/roll "+formula})` (fresh PUBLIC roll —
  no audience inheritance), System notices muted+badged; everything escaped, the `{@html}`
  single-sink invariant untouched. The composer's "Speak as" picker (own actors; GM: all)
  sends `actorOwner` and self-prunes when the selected actor disappears.

## Purpose

A chat message is a plain `Document` scoped to a world, authored ONLY by the server. The client
never constructs a stored message doc — it sends a `SendMessage` request frame; the server
validates, builds the `Document`, and publishes it through the normal authoritative
`Room::publish` path used by every other document write. Because a message is just a `Document`,
it automatically inherits per-recipient redaction, sequencing/resync, and the FTS5 search index
with zero message-specific plumbing in any of those subsystems.

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
    fetched server-side, asset-ified, then republished — see "Post-publish enrichment" below). The
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
  `InlineImage` job below for how they become a `Segment::Image`); `hyperlinks: false` removes
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
  roll-immutability invariant below) call, extracted so a `[[doc:]]`/`[[roll:]]`/`[[asset:]]` span
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
  enrich-stage gate below is `policy.previews_enabled() || !image_urls.is_empty()`, not
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
  `RecalcRoll` uses its own `RecalcRollError` + `Display` (see `handle_recalc_roll` above) but
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
  post-publish section above — this producer runs unattended, well after the original sender's
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
     `declared_caps_for_path` world/module-requirement check (`apply_intent::is_scoped_smr_write`
     in the `Operation::Update` arm, a three-way conjunction: origin + doc_type + exact
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

## Gotchas

- **Docs-ratchet is live on the whole `chat/` tree:** all ten files carry
  `#![deny(missing_docs)]` + `#![deny(clippy::missing_docs_in_private_items)]` — a new
  undocumented item fails the 3-OS CI clippy step, and doc comments on the ts-rs types
  (`ActorOwnerRef`, `Audience`) flow into the generated bindings (regenerate + commit with any
  change). SSRF docs state BOTH guard arms (literal-IP in `validate_url`, domain resolution in
  `GuardedResolver`) — keep the arm citations true when touching the preview pipeline.
- **The four chat frames carry `request_id`, NOT `intent_id`, and correlate to `ChatError`, not
  `Reject`.** A rejected send/edit/delete/recalc is surfaced to the sender via a `request_id`-
  correlated `ServerMsg::ChatError` (sender-only, never broadcast). Client
  side: `WsClient.sendChatMessage`/`editChatMessage`/`deleteChatMessage`/`recalcRoll` return
  `Promise<void>` tracked in a `chatPending` map. Chat correlation is ASYMMETRIC: only a rejection
  replies, so the promise RESOLVES on a `CHAT_ERROR_WINDOW_MS` (15s) timeout (success-assumed) and
  REJECTS on a `chat_error` frame; `failPending` rejects in-flight ops on disconnect.
  `AppContext.chat.send`/`edit`/`delete`/`recalc` (ui-kit) return `Promise<void>`; the composer
  surfaces the reason inline (`errorMsg`).
- **`SendMessageError`'s `Display` is a `[sec]` security boundary — do not widen it.** It is what
  `ChatError.message` carries. Validation-class variants (`Empty`/`TooLong`/`RateLimited`/
  `UnknownRecipient`/`AudienceLocked`/`RollImmutable`) surface a specific reason; authorization/
  existence/internal-class (`ActorNotSpeakable`/`Forbidden`/`NotFound`/`Data`) return a FIXED
  generic string that ignores the inner value. `NotFound`==`Forbidden` (existence-oracle close);
  `Data(_)` never echoes the inner `DataError`. Adding a variant means classifying it here.
- **`Segment` has two variants, `Text` and `Html`; content is not always literal, inert text.**
  `sanitize()` produces `Segment::Html{sanitized_html}`
  whenever the world's `chat-settings` policy has `markdown` or `html` enabled, and the client is
  expected to render that variant via `innerHTML` (it is safe by construction ONLY because it
  passed through `ammonia`; never innerHTML-render a `Text` segment or a `Html` segment your code
  produced by any path other than `chat::sanitize`).
- **The Update blanket-rejection is conditional on `WriteOrigin`, not absolute.** Any
  code that reasons about `apply_intent`'s message-Update behavior must account for the
  `WriteOrigin::ServerMessageRevision` exemption (see Hard Invariants); treating the rejection as
  unconditional will misdiagnose why an edit/delete succeeds.
- **`chat-settings` fail-closed means a missing or malformed policy doc silently degrades to plain
  text**, not an error surfaced anywhere — a GM who intends to enable Markdown but leaves the
  `chat-settings` doc absent, or types a field with the wrong JSON type, gets ordinary
  plain text with no diagnostic. This is deliberate (see `chat::settings`'s module doc) but easy to
  mistake for a bug when testing enrichment toggles.
- **`MAX_MESSAGE_CHARS = 4096` and the per-minute flood budget are enforced only inside
  `handle_send_message`/`handle_edit_message`/`handle_delete_message`** — they do not apply to any
  other document-write path (there isn't one for messages, per the invariants above, but this is a
  chat-specific limit, not a general `Document` size cap).
- **`Audience::Whisper.recipients` is capped at `MAX_WHISPER_RECIPIENTS = 128`**, checked in
  `handle_send_message` BEFORE the per-recipient `member_role` validation loop — an oversized list
  is rejected (`SendMessageError::TooLong`) without running any of those DB round-trips. Without
  this, one cheap `SendMessage` frame could force one sequential DB query per (attacker-supplied)
  recipient.
- **`previews_enabled() || !image_urls.is_empty()` gates enrichment, not `previews_enabled()`
  alone.** A world with `images: true, hyperlinks: false` still reaches `link_preview::enrich`
  (to queue `InlineImage` jobs) even though its `previews_enabled()` is false — treating the two
  conditions as equivalent will silently drop that world's inline images.
- **A message's sender always retains `DocRole::Owner` in `permissions.users`**, regardless of the
  message's `Audience` or any later `gm_role`/world-role change — e.g. a Player who posts to a
  `GmOnly` channel permanently keeps read/search access to their own message even if never
  promoted to GM. Anyone building an edit/delete path on top of this must not assume `Owner`
  implies "currently privileged" — it marks who authored the message, independent of current
  privilege.

## Client display layer

Three independently replaceable modules (UI-is-modules; swap any one without the others):

- **`@shadowcat/module-chat`** (the host) — contributes the sidebar tab
  (order 0 = the default tab; `settings` uses order 6, keeping 0 unique) and DECLARES
  the singleton surfaces `shadowcat.surface:chat.composer` / `chat.message`. **Unread badge:**
  the chat tab is dockview-rendered imperatively via `PanelTabRenderer`, not a
  Svelte component, so the badge is a new `PanelBadge` subscribe/get LIVE-BINDING seam on
  `PanelMeta` (a plain static count field would go stale, since `DockviewEngine.apply()` reassigns
  the whole `#meta` map to a fresh `Map` on every rebuild while `PanelMeta` object references
  themselves stay stable — see `shadowcat-codebase-panels`). Unread tracking is a pure `unread`
  module: a per-channel `ReadMarker{createdAt,id}` frontier matching `channels`'s `byCreation`
  tie-break (no per-message seq field exists on `WireDocument` for the client to key off), spanning
  ALL channels combined into one tab-level pip (not per-channel sub-badges), excluding the reader's
  own posts. Persisted via `ctx.uiState.getChatRead`/`setChatRead`, an opaque sibling key to the
  existing `panelLayout` `ui_state` path (same debounced-persist mechanism). Cleared via the same
  `offsetParent===null` keep-mounted-hidden idiom used for scroll-safety, plus a real
  `IntersectionObserver`-driven `markRead()` on tab reveal. Reads both
  contributions DIRECTLY from the registry (not `<Surface>`) because it must pass reactive
  instance props: per-message `{message, showChannel}` to the card, and to the composer the
  current `postTarget(view, channels)`'s `{channel, audience}` plus a registry-derived
  `placeholderName`. Views:
  All / per-registry-channel / **GM pseudo-channel** (display-only filters over
  `query("message")` — the server enforces `audience`, never `channel`; posting on the GM view
  sets `audience: gm_only`). The GM/All post target's channel is the registry's lowest-sorted id
  (`postTarget(view, channels)` — never a hardcoded `"general"`), falling back to `"general"` only while the
  registry doc hasn't arrived. Channels live in a `channel-registry`
  singleton config doc (id→`{name}` map, server-seeded `{general}` at world create/join;
  add/rename are single-key updates but **remove is a WHOLE-FIELD replace of
  `/engine/channels`** with the key deleted — `set_pointer` cannot delete keys, and a null
  tombstone is deliberately not used). Render cap: last 200 per view, derived incrementally via
  `channels`'s `ChatDerivationCache` (`deriveVisibleDocs`) — `channel`/`audience` are frozen at
  creation (see `handle_edit_message` above), so an id's view membership and sorted position are
  parsed/computed once and never revisited; a subsequent edit (a new WireDocument reference for a
  known id) only refreshes the cached reference, an O(log n) binary-search insertion handles a
  genuinely new id, and the full history is never re-sorted. The cache is reset (a fresh
  `ChatDerivationCache`) on `view` object-identity change, since membership is view-scoped.
  Mounting is windowed a second time within that 200-cap: `computeVisibleWindow` maps the
  `.messages` container's scroll-fraction onto an index range (+`VIRTUALIZE_OVERSCAN` each side)
  rather than dividing by an assumed fixed row height, since message rows vary in height; it
  falls back to the full range when `clientHeight` is unmeasured or content doesn't overflow.
  Scroll: stick-to-bottom + "new messages" pill; the pill effect tracks the previous count in a
  non-reactive closure + `untrack`ed `atBottom` (scrolling alone must not re-trigger), and all
  scroll measurement bails while the tab is `display:none`-hidden (an IntersectionObserver
  re-syncs on visibility — panels stay mounted in the tabbed sidebar). Both `scrollToBottom` and
  the visibility-reveal path must call the same scroll-state sync used by the `onscroll` handler,
  or the virtualized window silently goes stale after a programmatic (non-event-firing) scroll.
- **`@shadowcat/module-chat-composer`** — Enter sends / Shift+Enter newline / `isComposing` IME
  guard; validation on the TRIMMED length (what's actually sent); NO client command parsing
  (`/`-commands ride verbatim — the server parses); the "Speak as" picker sends
  `actor_owner` `Actor` refs, server-ownership-validated at ingest (see Dice wire above). A
  `@doc` trigger button opens a live document-search popover (`AppContext.searchDocuments`,
  same cancellation-guard `$effect` pattern as `ActorsPanel`'s live search) and inserts a
  `[[doc:<id>|<label>]]`/`[[token:<id>|<label>]]` span at the cursor; the inserted label strips
  all of `[`/`]`/`|` in one pass (an unstripped `[` would desync `scan_body_capped`'s bracket-depth
  scan) and falls back to the id's first 8 characters if stripping leaves it empty (an empty
  label is `RollError::MalformedDocLink`, rejecting the whole message). Separately,
  `AppContext.speakAsToken` (`SpeakAsToken`, a `ui-kit`-local stable-instance/mutate-in-place
  class sibling of `SceneSelection`) holds a ONE-SHOT pending "speak as this token" selection:
  `module-scene-tools`'s `ToolRail` sets it via a button visible only when exactly one token is
  selected and the current user is GM or the effective owner (`ownerFloorApplies`, advisory-only
  — the server re-authorizes via `effective_owner_of` regardless), and the composer reads
  `.tokenId` for a "Speaking as: {name}" indicator and calls `.consume()` on send, giving the
  pending token precedence over the sticky actor `<select>` when building `actor_owner`. An
  `image-insert` button (`data-testid="image-insert"`), gated on the world's `chat-settings`
  `images` toggle, opens `AppContext.pickAsset` and inserts a `[[asset:<uuid>|alt]]` span at the
  cursor — the label falls back to `id.slice(0, 8)` unconditionally (no asset-name-lookup surface
  exists on `AppContext` to populate a real name).
- **`@shadowcat/module-chat-card`** — fail-closed render (`parseMessageEngine` null ⇒ nothing).
  **The segment renderer + the `{@html}` sink live in `@shadowcat/ui-kit`, not this module:**
  `SegmentList.svelte` (`src/client/ui-kit/src/SegmentList.svelte`) is the extracted
  `{segments, channel}`-driven renderer for EVERY `ChatSegment` kind (text/html/doc_link/
  roll_embed/roll_button/link_preview/oembed/**image**) — `MessageCard.svelte` delegates to it
  (`<SegmentList segments={sys.content} channel={sys.channel} />`) rather than looping segments
  itself; `RollTooltip.svelte` lives in ui-kit alongside it (a `SegmentList`-only dependency). An
  `image` segment renders as `<a href={ctx.assets.url(s.asset_id)}><img
  src={ctx.assets.url(s.asset_id, "preview")} alt={s.alt} loading="lazy"></a>` — always through
  `AssetResolver.url`, this server's own asset endpoint, never a raw external URL (none is ever
  stored on the segment to begin with). Moving the renderer does not relocate the invariant below,
  only its file.
  **GM recalc menu + recalculated badge:** `MessageCard.svelte` renders a `recalc-menu` (one row
  per base die — reroll/remove buttons plus a bounded numeric replace input, each calling
  `sendRecalc` → `ctx.chat.recalc(message.id, rollId, [op])`) ONLY for the BLOCK form (a
  standalone `kind: "roll"` message), gated on `isGm && rollBlock.raw` — `raw` is present in the
  parsed wire doc only when the viewer is GM (server-side `property_overrides` gating, see Hard
  Invariants above), so the menu's visibility is a structural consequence of that redaction, not
  a separate client-side GM check duplicating it. A passive "recalculated" chip
  (`t("chat.roll.recalculated")`) renders whenever `recalc_history?.length` is truthy, in BOTH
  the block form (`MessageCard.svelte`) and the inline-chip form (`RollTooltip.svelte`, via its
  `recalcHistory` prop) — never interactive in `RollTooltip`, only in the block form's menu.
  **`RollTooltip`:** an accessible focus/hover-triggered popover on a roll segment, showing the full
  `outcome.records[]` table with dropped dice distinguished. Popover `id` is derived per-instance
  (`$props.id()`, the `LauncherMenu` convention) — never hardcoded, since a message can
  contain multiple inline rolls and many `MessageCard`s render simultaneously in the chat log.
  Touch affordance: `onclick` toggle gated on `matchMedia("(hover: hover)")` so a tap opens it on
  touch devices without a hover-just-opened tooltip re-closing on a desktop click (a hover-capable
  BUT touch-driven hybrid device, e.g. a touchscreen laptop, is a disclosed narrow residual gap).
  Touch target is an invisible absolutely-positioned 44×44 `::after` hit-slop, NOT visible sizing
  (visible sizing would balloon an inline text-flow chip). Escape dismisses via a document-level
  listener while open (not just the focused-trigger keydown, so it also dismisses from a
  hover-only-open state).
  **THE `{@html}` INVARIANT: `SegmentList`'s single `{@html}` sink (in ui-kit, see above) renders
  only an
  `isKnownSegment`-narrowed `kind:"html"` segment's `sanitized_html` (ammonia-produced);
  Text segments are text nodes (`white-space: pre-wrap`); an `image` segment renders through an
  `<img src>` bound to `AssetResolver.url`, never `{@html}`; every other string interpolates
  escaped.** Header: author via `ctx.members` (`list_members` is member-visible, not GM-only —
  chat name resolution needs it), actor name via
  the real `resolveTokenActor`/`actorDisplayName` fail-closed chokepoint (an
  `ActorOwnerRef::Actor` is wrapped in a synthetic `{engine:{actor_id, overrides:{}}}` token
  — safe: that resolver branch reads only
  `engine.actor_id` + `engine.overrides`, and the
  empty overrides map is a no-op). Roll-pending shell derives the
  formula from `sys.source` (command prefix stripped per `parse_command`'s exact tokens) —
  `textOf(content)` alone is EMPTY on markdown/html worlds where the body becomes one Html
  segment. Edit prefill = `source ?? textOf`; deleted tombstone suppresses body+actions;
  actions are owner-or-GM, hover/focus-revealed only on hover-capable devices.

## Pointers

- **Generated API** — `/api/rust/shadowcat/chat/` (rustdoc, private items included — the
  `rolls`/`link_preview`/`preview_cache`/`post_publish`/`oembed`/`sanitize`/`shortcodes`/
  `settings`/`commands` submodule tree), `/api/ts/modules/_shadowcat_module-chat.html`,
  `_shadowcat_module-chat-composer.html`, `_shadowcat_module-chat-card.html` (TypeDoc). Produce
  with `pnpm build:all`.
- The sanitizer's only new production dependencies are `ammonia` (HTML cleaning) and
  `pulldown-cmark` (Markdown rendering).
- `shadowcat-codebase-documents-permissions` — the `Document`/`PermissionSet`/redaction/search
  machinery a message rides, including the `gm_role` field (owned there, load-bearing here — see
  that skill's Hard Invariants for what `Some(role)` does to `resolve_access`'s GM branch).
- `shadowcat-codebase-assets` — `Provenance::ChatImage`, `create_asset_from_bytes`/
  `NewAssetBytes`, and the stable-asset-id serving path `Segment::Image`/`AssetResolver.url`
  read; the `created_by: None` convention `resolve_inline_image`/`resolve_preview_image`/
  `resolve_thumbnail_asset` all share.
- `shadowcat-codebase-client-shell` — `AppContext.pickAsset`/`assets: AssetResolver` (the
  composer's image-insert button and `SegmentList`'s `<img>` rendering both go through it), and
  `@shadowcat/ui-kit`'s module boundary where `SegmentList.svelte`/`RollTooltip.svelte` now live.
- `shadowcat-codebase-realtime-sync` — `Room::publish`, WS `Intent`/`SendMessage` dispatch,
  broadcast/resync, and the HTTP `write_ops` mirror guard.
- graphify: `graphify explain "chat"` / `graphify query "how does SendMessage reach a stored
  document"` for the cross-file call graph.
- Dice + chat resume context: memory `m11-dice-chat-resume` in the project's auto-memory.
