# Client display layer

Part of the shadowcat-codebase-chat skill; read it when changing chat-docs, the chat UI modules or SegmentList.
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
  creation (see `handle_edit_message` in references/key-files-and-seams.md), so an id's view membership and sorted position are
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
  `actor_owner` `Actor` refs, server-ownership-validated at ingest (see Dice wire in references/dice-wire.md). A
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
  **Pre-send interception hook and in-flight guard.** `Composer.svelte`'s `send()` runs the trimmed
  draft through `chat:composer-send` (`ChatComposerSendPayload{text, cancel}`, a `"mutate"`-kind
  hook declared by `defineChatComposerHooks`/`CHAT_COMPOSER_HOOK_VERSION`, `@shadowcat/core`'s
  `chat-hooks` module) via `ctx.hooks.emitMutate` BEFORE building the `SendMessage` frame — a
  module registers against it through its own `ModuleContext.hooks.on` in `register()` to rewrite
  the outgoing text (e.g. implement a system-specific client-only slash command) or veto the send
  outright (`cancel: true`); the composer applies whichever `text`/`cancel` the hook chain settled
  on and never inspects the text itself, so server-side `/`-command parsing (`chat::parse_command`)
  stays the sole authority over what ALREADY-sent text means. A cancelled send never reaches
  `ctx.chat.send` and the input is left untouched (no optimistic clear, no error) — a module that
  cancels is responsible for its own UI feedback. A `sending` in-flight `$state` guard (checked
  alongside `canSend`, reflected in the Send button's `disabled`) covers ONLY the
  `chat:composer-send` hook's own await — never the
  dispatched `ctx.chat.send(...)` call, which runs fire-and-forget with its own `.catch` surfacing
  a later rejection via `errorMsg`. An ordinary ACCEPTED chat op carries no ack frame at all:
  `WsClient.trackChatOp`/`sendChatMessage` resolve that promise only on the wire client's
  multi-second silence timeout, so awaiting the full send inside the guard would leave the Send
  control (and the Enter-key path) disabled for that whole window on every ordinary message. The
  hook call and frame build run inside a try/finally block that resets `sending` on every exit from
  that region, including a synchronous throw from the hook.
  **`chat.roll.successes`** (`MessageCard`'s roll-successes chip) is a `PluralEntry` catalog entry
  (`{ one, other }`), rendered via `ctx.plural("chat.roll.successes", outcome.successes, { n:
  outcome.successes })` rather than `ctx.t` — see `shadowcat-codebase-client-shell`'s `I18n.plural`
  entry (shadowcat-codebase-client-shell's references/appcontext-i18n-and-session-seams.md) for the category-selection contract.
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
  invariants in SKILL.md), so the menu's visibility is a structural consequence of that redaction, not
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
  segment. **A `kind: "roll"` message is NOT always a lone `roll_embed`:** `tables::handle_draw_table`
  publishes a table draw as `MessageKind::Roll` whose content is one-or-more `table_draw`
  segments, so `MessageCard.svelte` branches on `isTableDrawContent` (every raw segment a KNOWN
  `table_draw`, via `isKnownSegment`) and renders it through `SegmentList` — the pending shell is
  only the fallback for a genuinely unrenderable roll-kind shape (plain text/html, an unknown
  segment, a `roll_embed` plus an extra segment), never the table-draw case.
  Edit prefill = `source ?? textOf`; deleted tombstone suppresses body+actions;
  actions are owner-or-GM, hover/focus-revealed only on hover-capable devices.

