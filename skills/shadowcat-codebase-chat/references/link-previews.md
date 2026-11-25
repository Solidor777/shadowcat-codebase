# Link previews and post-publish enrichment

Part of the shadowcat-codebase-chat skill; read it when changing link previews, the preview cache, oEmbed or post-publish jobs.
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
  `2130706433`/`0x7f000001` to an IPv4 host, caught here);
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
  loopback-permitting client. The segment never carries the external image URL (an `<img src>`
  naming it would make the client fetch → leak the viewer's IP); the image is fetched server-side
  and referenced by asset id (see the post-publish section).
- **Ingest (`chat::link_preview::enrich`, called from `handle_send_message`/`handle_edit_message`):**
  extracts hrefs from GENUINE `<a>` tags in the sanitized `Segment::Html` runs (NOT a raw
  `href=` substring scan — inert body text `see href="http://x"` would otherwise trigger a real
  outbound fetch), dedups, caps `MAX_PREVIEWS_PER_MESSAGE=3`, resolves each candidate via
  `cached_or_fetch` (checks the in-memory `LinkPreviewCache` tier first, then the persisted
  `link_preview_cache` row on a miss, before ever attempting a network fetch), fetches remaining
  cache-misses concurrently (`JoinSet`), appends one `Segment::LinkPreview` per success at the
  END, in the candidates' message order. SYNCHRONOUS before publish (no spawned task/post-hoc revision). Gated on
  `ChatContentPolicy::previews_enabled()` (= `hyperlinks && link_previews.unwrap_or(true)` —
  default-ON only when hyperlinks on) AND an EXPLICIT `kind != MessageKind::Roll` guard. Holds NO
  lock across the fetch await (only the sending connection's own loop blocks, bounded by the 5s
  deadline). Every failure degrades silently (no card, cached negative). `enrich`'s own signature
  takes an `EnrichDeps<'a> { world_id, repo, fetch: LinkPreviewDeps<'a> }` bundle rather than a flat
  parameter list — the message's world (the scope of every cache read and write) and the
  repository handle a persisted-cache lookup needs, grouped in with the
  existing `client`/`cache`/`rate` fetch bundle to stay under clippy's too-many-arguments limit,
  same restructuring pattern as `PostPublishDeps`/`data::asset::NewAssetBytes`. `enrich` ALSO
  takes `image_urls: &[sanitize::ImageSource]` (`chat::body::compose_message`'s second return
  value): each valid, non-blocked-URL source (`validate_url` — the SAME SSRF guard the link-scrape
  path uses, not a separate check), rate-limited the same way, is queued as a
  `PendingEnrichment::InlineImage{image_url, alt}` job, capped at `MAX_INLINE_IMAGES=4`
  independently of `MAX_PREVIEWS_PER_MESSAGE` (an image-heavy message can carry both link previews
  and inline images up to their own separate caps). The call site's gate is
  `previews_enabled() || !image_urls.is_empty()`, not `previews_enabled()` alone — see
  `chat::body::compose_message` in references/key-files-and-seams-02-shortcodes-sanitize-commands.md for why.
- **`LinkPreviewCache`** (in-memory, on `WsState`): (world, candidate URL)→`(Instant,
  Option<LinkPreview>)`, positive/negative TTLs, evict-oldest past a cap; `PreviewRateLimiter` (per-user distinct-URL
  fetch budget, only on cache MISS). Both mirror `message_rate`'s `WsState` Arc-field pattern. `cached_or_fetch`
  gives a memory hit with a preview its asset id from the persisted row; a memory hit that carries a preview and whose row
  is absent counts as a miss, and a miss passes the `PreviewRateLimiter` gate before its fetch
  rewrites the row, so a rate-limited miss yields no card and rewrites nothing; a failed row read
  leaves a memory hit that carries a preview as cached and, with no memory hit (for example after a restart), counts as a miss. This
  is the FIRST tier of a two-tier cache — see `link_preview_cache` below for
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
`PendingEnrichment` jobs (`PreviewImage{cache_urls, preview_url, title, description, image_url}` when its synchronous scrape
found an `og:image` candidate; `OEmbed{post_url, provider}` when `chat::oembed::match_provider` matches
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
- **`PreviewFetchLocks`** (`AppState.preview_fetch_locks`, `Arc<DashMap<PreviewLockKey,
  Arc<tokio::sync::Mutex<()>>>>`) — a process-wide per-key fetch lock, same keyed-registry shape as
  `ws::room::RoomRegistry.rooms`, closing the race where two concurrent post-publish jobs of one
  world resolving a shared URL both observe a `link_preview_cache` miss and each create their own
  orphaned `Asset`. A `PreviewLockKey` is `(world_id, url)`, so jobs of different worlds never
  share a lock. `with_preview_url_locks` runs a resolver's WHOLE check-cache-then-fetch-then-set
  sequence under the locks of a slice of keys, sorted and deduped so two callers with overlapping
  key sets acquire the shared keys in the same order (a second caller for a shared key observes a
  cache HIT and skips the fetch). `HeldPreviewLocks` releases from `Drop` (also when the future is
  dropped mid-await) through `release_preview_lock`, which drops the caller's `Arc` and removes the
  map entry when the strong count is then 1; the count check and the removal happen inside one
  keyed-entry lookup so no waiter can clone the `Arc` in between, ruling out two different `Mutex`
  instances ever existing for the same key at once.
- **`resolve_preview_image`** — reads, under the locks of all its rows, the persisted
  `link_preview_cache` rows of the job's `cache_urls` and of its `preview_url` (the landed
  address) in the job's world. The first existing `image_asset_id` is reused verbatim (no fetch)
  and recorded on the rows that lack one. On a miss it fetches the image via `fetch_image_bytes` (the same SSRF-guarded
  client `fetch_preview` uses) and asset-ifies it via `data::asset::create_asset_from_bytes` with
  `created_by: None` — see `shadowcat-codebase-assets` for that shared commit path and the
  `created_by: None` convention. `record_preview_image` writes the id through
  `set_link_preview_cache_image`, which writes only a row that has no id and an asset that exists
  in the row's world, so the first recorded id on a row stays. A landed-address row that does not exist is created only once the job has an
  asset (`create_landed_row`, from the job's `title`/`description`; its `fetched_at` is the earliest
  scraped time among the candidate rows (`create_landed_row::scraped_at`), and a job with none creates no row), so a later
  post of that address reuses the asset.
- **`PreviewImage` job sharing in `link_preview::enrich`** — `enrich` queues ONE `PreviewImage` job per distinct `preview_url` (candidates whose
  previews end on the same address share it, `cache_urls` in message order; every NEW job, for a cached preview as well as a fresh one, spends one unit of the per-user fetch budget through `PreviewRateLimiter` and a refused job leaves the card without its image), and queues none for a
  candidate whose address already has an asset id among the message's previews: that id is recorded
  on the candidate's row and carried on its segment. That reuse write does not take
  `PreviewFetchLocks`, which would make the send wait on a background fetch, and relies on the
  `IS NULL` guard of `set_link_preview_cache_image`. The job's patch sets `image_asset_id` to the
  job's asset even when that write recorded a different id on a row first; that row keeps its id.
- **`resolve_inline_image`** — the `PendingEnrichment::InlineImage` resolver, structurally a
  mirror of `resolve_preview_image` with ONE difference: it keys on the image's own URL, which has
  no prior row, so `record_image_url_row` inserts a text-less row with
  `insert_link_preview_cache_if_absent` before `set_link_preview_cache_image` (`resolve_thumbnail_asset`
  records its thumbnail the same way). Cache hit ⇒
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
  `insert_link_preview_cache_if_absent`/`set_link_preview_cache_image`, keyed by (world, URL),
  storing `image_asset_id` once a background job resolves one. INVARIANT: the cache is
  world-scoped, so an asset id (preview image, inline image or oEmbed thumbnail) is reused only
  within the world whose row holds it; the in-memory tier and `PreviewFetchLocks` carry the same
  world scope. `resolve_preview_image` keys on page
  addresses (`cache_urls`, `preview_url`): a page address whose row carries an asset id is not
  re-imaged. `resolve_inline_image` and `resolve_thumbnail_asset` key on the image URL: an inline
  or oEmbed-thumbnail image URL whose row carries an id is not re-fetched. Both hold only while the
  row keeps the id (deleting the asset nulls the column). `set_link_preview_cache_image` writes
  only a row that has no id and an asset that exists in the row's world.
  `sweep_expired_link_previews`, run from `spawn_housekeeping_sweep`, deletes rows with no asset id
  whose `fetched_at` is more than `POSITIVE_TTL` old; a row holding an id stays.
- **`Segment::LinkPreview.image_asset_id: Option<Uuid>`** — `#[serde(default)]` (every
  `LinkPreview` segment persisted before this field existed has no such key on disk). `enrich` sets
  it at send time when the candidate's persisted row, or another candidate's row at the same
  landed address, carries an asset id; otherwise it is `None` until a
  `WriteOrigin::ServerMessageRevision` republish (`run_pending_enrichments`) patches it.
  `Segment::LinkPreview.url` is the normalized post-redirect address after a fresh fetch and the
  candidate URL after a persisted-row hit, and an in-memory hit carries whichever of the two built
  the entry for the candidate URL; a job patches the segment whose `url` equals its
  `preview_url`.

