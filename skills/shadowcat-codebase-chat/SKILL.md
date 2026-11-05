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

Covers the SSRF-guarded `fetch_preview` path, the validating resolver and IP blocklist, `chat::preview_cache`, the LinkPreview segment, ingest enrichment, the `previews_enabled` toggle, and the `chat::post_publish` / `chat::oembed` post-publish enrichment. Read references/link-previews.md before touching any of these or anything that makes outbound HTTP.

## Dice wire — `chat::rolls` + the ingest roll stage

Covers `chat::rolls` (caps, per-roll entropy, span scanner), RollEmbed/RollButton segments, System error notices, roll immutability, attribution authz, and the card/composer roll rendering. Read references/dice-wire.md before changing roll execution, roll segments or roll display.

## Purpose

A chat message is a plain `Document` scoped to a world, authored ONLY by the server. The client
never constructs a stored message doc — it sends a `SendMessage` request frame; the server
validates, builds the `Document`, and publishes it through the normal authoritative
`Room::publish` path used by every other document write. Because a message is just a `Document`,
it automatically inherits per-recipient redaction, sequencing/resync, and the FTS5 search index
with zero message-specific plumbing in any of those subsystems.

## Key files & seams

Covers the per-file map of the chat domain: `MESSAGE_DOC_TYPE`, `ActorOwnerRef`, `MessageKind`, `Segment`, ingest, sanitizer, settings, commands, and the seams between them. Read references/key-files-and-seams.md before editing anything under src/server/src/chat/ or the message ingest path.

## Hard invariants

These hold on every change to chat; the full text of each, with its rationale, is in references/key-files-and-seams.md. Read it before touching message authoring, audiences, whispers, roll embeds or edit and delete authority.

- **`SendMessage` is the SOLE message-authoring path.**
- **The seam is a FOUR-part coupled surface — weakening any one part alone reopens forgery.**
- **GM edit/delete authority is audience-independent by design.**
- **`/w` has two independent front-doors, and content wins.**
- **A NON-WHISPER edit re-runs the FULL send pipeline (`parse_command` + `sanitize`) except audience, which is frozen.**
- **A whisper hides from the GM by default; only `recipients` membership grants a GM access.**
- **Recipient validation happens BEFORE document construction, fail-closed on the whole send.**
- **Messages ride the existing Event/redaction/search machinery with zero message-specific code in those subsystems**
- **`spec`/`raw` on a `RollEmbed` (and every `RecalcEntry.previous_raw`) are GM-only via `permissions.property_overrides`, populated by `roll_property_overrides` at message-Create time and re-populated on every recalc**

## Gotchas

- **Docs-ratchet is live on the whole `chat/` tree:** every module file carries
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

Covers the client Zod mirror (`chat-docs`), the chat/chat-composer/chat-card modules, SegmentList and the `{@html}` single-sink boundary. Read references/client-display-layer.md before changing chat UI modules or segment rendering.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/link-previews.md | Link previews, `chat::link_preview`, `chat::preview_cache`, post-publish enrichment, oEmbed | touching link previews, outbound HTTP, post-publish jobs, inline image jobs |
| references/dice-wire.md | Dice wire: `chat::rolls`, roll segments, error notices, attribution | touching roll execution, roll segments or roll rendering |
| references/key-files-and-seams.md | Key files and seams of the chat domain | editing server chat code, ingest, sanitizer, settings, commands |
| references/client-display-layer.md | Client display layer | editing chat-docs, chat UI modules, SegmentList |

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
