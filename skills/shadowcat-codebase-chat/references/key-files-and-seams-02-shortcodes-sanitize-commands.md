Part of the shadowcat-codebase-chat skill; read it when editing shortcodes, the sanitizer, body composition, chat settings, commands or the fx command. Part 02 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-chat-module.md.

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
  audience_intent: Option<AudienceIntent>, body}`, pure (no repo/async — it only records the
  intent; the async `resolve_audience_intent` turns it into a concrete `Audience` and the caller
  re-validates). `AudienceIntent` is `Whisper(names)`, `GmOnly`, `Public`, `Blind`, `SelfOnly`
  (a whisper with no recipients), `Players` (every current non-GM member except the sender,
  frozen at send time) or `ReplyToLastWhisper` (`Repository::last_whisper_to`; no prior whisper
  is `SendMessageError::NoReplyTarget`). Tokens: `/w`, `/gm`, `/gmroll`, `/publicroll`,
  `/players`, `/reply`, `/blindroll`|`/br`, `/selfroll`|`/sr`, plus the `/ooc` and `/ic` display
  kinds. Only a LEADING token counts; the same text mid-message
  is literal. `/me `/`/em `/`/emote ` → `MessageKind::Emote`. `/roll `/`/r `, or bare `/NdM`
  shorthand (optionally `+K`/`-K`) → `MessageKind::Roll`, body stored VERBATIM/unexecuted (nothing
  in the parser executes it). `/w @user @user... rest` → `MessageKind::Normal` +
  `AudienceIntent::Whisper(raw_usernames)` — this is chat's SECOND `/w` front-door, independent of the
  `SendMessage` wire frame's `audience` field; `handle_send_message` reconciles the two,
  content taking precedence (see key-files-and-seams-03-ws-http-and-invariants.md). **`kind` can never be `MessageKind::System` from any
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
