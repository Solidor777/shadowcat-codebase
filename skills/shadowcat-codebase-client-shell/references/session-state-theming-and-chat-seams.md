# Client shell - session state, theming, scenes and chat seams

Part of shadowcat-codebase-client-shell: the ui_state persistence pipeline, theming, performance mirror, multi-scene seams, asset pick, chat and speak-as seams, canCreate/canDelete, the rejected-intent toast and the shared op builders; read it before changing any of them.

- The shell package — `App`, the `main` entry module, and its `lib/` directory (hash router, api client, session,
  WorldSession controller, default-module wiring). The `sessionState` module owns the
  `ui_state` blob: `getPanelLayout(world)`/`setPanelLayout(world, blob)` persist the
  per-world panel layout into `UiState.worlds[world].panelLayout` via
  the existing leading-edge-debounced PUT. The blob is OPAQUE to the shell — the panel host
  owns its shape/validation. **Leaf-key dirty tracking, which is what keeps two sessions of the
  same user from clobbering each other**: a `dirty` structure
  (`Set<GlobalField>` + a `Map<worldId, Set<WorldKey>>`) tracks which individual FIELDS/KEYS
  changed since the last successful write — `global.locale`/`global.lastWorld` and
  `worlds.<id>.panelLayout`/`worlds.<id>.chatRead` each track independently, so two owners of the
  same slice (the panels module writing `panelLayout`, the chat module writing `chatRead` inside
  the same `worlds.<id>`) never clobber each other. `persist()`/`flushOnUnload()` build a
  `UiStatePatch` covering only those dirty leaves — never the whole slice, and never
  the whole `{global, worlds}` blob — clearing them before the write and re-marking on failure
  (both functions snapshot the dirty structure, clear it, attempt the write, and on rejection
  re-add every snapshotted field/key) so a retry doesn't lose the write. `persist()` also carries
  an in-flight-PUT ordering guard (`persistInFlight`/`persistQueued`): a call arriving while an
  earlier call's `putUiState` is still unresolved shares a single coalesced retry chained onto
  the in-flight attempt instead of racing a second overlapping PUT — every such caller awaits
  that SAME retry, which runs (picking up everything dirtied meanwhile) once the in-flight
  attempt settles. `resetSessionState()` — wired into `Table.svelte`'s `logout` handler,
  after the server-side session invalidation and before navigating away — cancels the cooldown
  timer, clears dirty tracking, and resets `loaded` to `false`, so a mutation landing inside a
  re-login `loadSessionState()`'s `await getUiState()` window cannot pass the write guard under
  the new session's cookie. Server-side, `SqliteRepository::merge_ui_state` merges the patch one
  level inside `worlds.<id>` and inside any other top-level object key — a leaf blob
  (`panelLayout`, etc.) still replaces wholesale, never deep-merged — in one transaction, and a
  `null` patch value REMOVES rather than replaces (a whole `worlds.<id>` entry, or a single leaf
  key inside `worlds.<id>`/`global`) via `merge_one_level`; the HTTP surface, size cap, and a
  route-level pre-check on the patch's own serialized size (before the pool is touched) live in
  `http::routes::put_ui_state`. The client never sends the whole `{global, worlds}` blob.
  Concurrent same-user sessions (two tabs) contend only on the individual fields/keys both
  sessions actually write, never as last-writer-wins on a whole slice or the whole blob.
  **`pruneStaleWorlds(memberWorldIds)`** is the client-side caller that actually exercises the
  server's whole-entry-removal path: it deletes every local `worlds.<id>` entry absent from the
  caller's current membership list, tracks each removed id in a third `dirty` set
  (`removedWorlds`, alongside `global`/`worlds`, mirrored through `DirtySnapshot`/
  `snapshotDirty`/`clearDirty`/`remarkDirty` like the other two), and `buildPatch` emits a `null`
  for each — written after the per-key `worlds` loop so a removal wins if an id somehow lands in
  both sets, though `pruneStaleWorlds` itself already deletes any stale `dirty.worlds` entry for
  an id it removes so that collision shouldn't arise by construction. `App.svelte`'s `boot()`
  calls it right after its existing conditional `listWorlds()` fetch (not an added unconditional
  call) — this is deliberately not comprehensive: a boot with no `lastWorld` and no world-route
  URL skips the `listWorlds()` branch entirely and prunes nothing that boot. `buildGlobalPatch`/
  `buildWorldPatch` copy their dirty leaves through `copyGlobalField`/`copyWorldKey`, a switch
  statement ending in `field satisfies never`/`key satisfies never` — a `GlobalField`/`WorldKey`
  union widened by a new `UiState.global`/`worlds[id]` member fails to compile in that `default`
  branch rather than silently dropping the new field from every patch.
- **Theming** — the `theme` singleton (a `ThemeController`, `@shadowcat/ui-kit`) owns the
  active theme: `BUILTIN_THEMES` (slate-dark/slate-light/contrast-dark; `DEFAULT_THEME_ID`)
  plus user-authored custom themes resolved by `resolveTheme` (validated overrides layered
  onto a built-in base). `applyTo` writes every token and the color scheme as INLINE styles
  on a document's root element (beating the shell stylesheet and any cloned stylesheets),
  and every change re-applies to the main document plus each `registerDocument`'d secondary,
  so pop-out windows follow a swap live; Svelte consumers read through `activeTheme`.
  Persistence rides the `sessionState` machinery: `UiState.global.theme` (a
  `PersistedTheme` — the active selector plus the custom-theme map) is dirty-tracked as a
  `GlobalField` through the same leaf-key patch pipeline as `global.locale`, and a
  localStorage mirror (`THEME_MIRROR_STORAGE_KEY`, `readThemeMirror`/`writeThemeMirror`)
  lets the `main` entry module apply the last-used theme synchronously before login, so
  neither the login screen nor the first post-login paint flashes the default. The settings
  module's picker switches themes; its `ThemeEditor.svelte` authors custom themes with live
  whole-app preview through the controller's `previewCustom(draft, owner)` seam —
  presentational only, `serialize` never observes it — cleared on teardown by the
  owner-scoped `clearPreview(owner)`, DEFERRED to a microtask: a component destroyed in the
  same flush that mutated controller state reads its `$state` fields stale, so a synchronous
  `onDestroy` clear lets persistence subscribers serialize state the flush already
  superseded, and an unscoped clear can wipe a successor editor's preview mounted by that
  same flush. Module styling modes: `Contribution.styling` (default host-themed, or
  isolated) — isolated content is wrapped by `Surface.svelte` and slot-classed by
  `PanelHost.svelte` with `THEME_ISOLATION_CLASS`, whose rule (`themeIsolationCss`,
  generated from the default theme's data and installed per themed document by `applyTo`
  under `THEME_ISOLATION_SHEET_ID`) re-declares every token at its engine-default value for
  that subtree only. External modules ship a stylesheet via the manifest `style` field,
  installed as one link per enabled module by the world session (see
  `shadowcat-codebase-module-toolchain`).
- **Performance settings** — `AppContext.performance` (a ui-kit `PerformanceController`, the
  `performanceController` singleton — see `shadowcat-codebase-performance` for the controller
  and the render-side budget seams) holds the per-device render budget. The shell side is
  exactly the theme-mirror pattern and nothing more: `main`'s entry module calls
  `performanceController.load(readPerformanceMirror(localStorage), readDeviceSignals())`
  pre-mount (so pre-login screens never flash the wrong budget) and registers
  `performanceController.onChange = (p) => writePerformanceMirror(localStorage, p)`.
  `readPerformanceMirror`/`writePerformanceMirror` (in `sessionState`) read/write the
  `PERFORMANCE_STORAGE_KEY` blob through `parsePersisted`/`serializePersisted`
  (`@shadowcat/core`) — fail-closed to the auto default on a garbled value, a throwing
  storage swallowed with a log. `readDeviceSignals` guards every global probe on existence
  (matchMedia, navigator.hardwareConcurrency, the Chromium-only navigator.deviceMemory), so
  each output field is present only when its probe exists in this environment — jsdom has no
  matchMedia at all, while Node ≥ 21.5 reports a value for
  `DeviceSignals.hardwareConcurrency`. Per-device only: never the server `ui_state`,
  deliberately — a phone and a desktop on one account keep separate budgets.
- **Multi-scene / viewed-scene seams** — `AppContext.viewedSceneId: string | null`
  (a live getter, `Table`: `get viewedSceneId() { return session.viewedSceneId; }` —
  NEVER destructure a snapshot of it), `AppContext.setGmViewedScene(id): void` (GM-only local
  roam; no-ops+warns for a non-GM), `AppContext.searchDocuments(query, opts, onUpdate) ->
  Promise<SubscriptionHandle>` (the live-FTS subscription seam, exposed through
  `AppContext`/`WorldSession` — wraps `WsClient.subscribeSearch`, ephemeral/NOT
  reconnect-resilient; `opts.docTypes?: string[]` narrows server-side to the listed `doc_type`s
  — an empty/omitted array searches every type — threaded straight to the wire `Search` frame's
  `doc_types`, capped server-side at `MAX_SEARCH_DOC_TYPES`; a caller narrowing to one type (e.g.
  `ActorsPanel`'s `docTypes: ["actor"]`) does NOT re-filter results client-side, since the server
  already returns only matching-type hits), `AppContext.sceneSelection: SceneSelection`
  (a small stable-ref class, `configureSceneId`
  + `select(id)`, shell-constructed in `Table` like `panels`/`sheets`; distinct from BOTH
  `viewedSceneId`/`activeScene` — configuring a scene's per-scene settings never moves any
  camera/render target). `WorldSession.viewedSceneId` (getter) resolves via `resolveViewedScene`
  (`@shadowcat/core`): a resolvable `gmViewedScene` (GM local roam, `WorldSession`-private
  `#gmViewedScene` `$state`) → a resolvable `world-settings.activeScene` (players follow) → the
  first scene (legacy fallback) → `null` only when no scene exists at all. See
  `shadowcat-codebase-scene-rendering` for how the render engine consumes this seam.
  `@shadowcat/module-scene-browser` (GM-only panel, `order: 6`) is the authoring surface: list +
  background thumbnails, create, "Configure" (deep-links the EXISTING `game-settings` panel's
  per-scene section via `ctx.sceneSelection.select(id)` +
  `ctx.panels.open("game-settings:panel")` — the exact `"<module>:panel"` contribution-id
  convention every `PANEL_CONTRACT` registration uses; a bare module id silently no-ops the open
  call), "View" (`ctx.setGmViewedScene`), "Activate" (writes
  `activeScene` via `ctx.dispatchIntent` with the REAL current value as OCC `old`). Scenes have
  no `name` field — the browser labels rows by index + thumbnail, deliberately.
- **Asset pick seam** — `AppContext.assetPick: AssetPickController` (ui-kit stable-ref class:
  one reactive `pending` request; a new `request` cancels the previous with `null`; `settle`
  clears `pending` BEFORE resolving) plus the overloaded convenience
  `AppContext.pickAsset(opts)` (`PickAssetMultiple` → ordered `string[] | null`, otherwise
  `string | null`), both wired in `Table` over one shell-constructed controller. The
  asset-browser module renders `pending` as `AssetPickOverlay`, contributed into
  `shadowcat.surface:overlay` — a `core-ui` singleton `Layout` renders OUTSIDE and AFTER the
  region grid so fixed-position modal chrome is never clipped (the merge-conflict modal
  precedent is a Table-mounted host instead; new app-level modals should prefer the surface).
  The overlay contribution is deliberately un-gated (any member picks); the browser PANEL
  contribution is `gmOnly`. Consumers: scene-tools `AssetPicker`'s browse affordance,
  `VisualKindEditor`'s face/frames/sheet picks, and `module-chat-composer`'s `image-insert` button
  (inserts a `[[asset:<uuid>|alt]]` chat span — see `shadowcat-codebase-chat`).
- **`SegmentList.svelte`/`RollTooltip.svelte` live in `@shadowcat/ui-kit`**, not
  `module-chat-card` — the chat message segment renderer (and its single `{@html}` sink) was
  extracted here so it can be a plain `{segments, channel}`-driven component reused without
  pulling in the whole chat-card module; `module-chat-card`'s `MessageCard.svelte` delegates to
  it. Full segment-kind/invariant detail lives in `shadowcat-codebase-chat`, not here — this is
  the module-boundary/ownership fact, not the rendering contract.
- AppContext seams (wired in `Table`): `uiState {getPanelLayout, setPanelLayout}`
  (narrow; the shell owns storage), `panels: PanelsApi & PanelsChipsView` — the shell
  constructs ONE `PanelsBridge` (`$state`-backed so
  pre-bind readers unfreeze at bind; details → [[shadowcat-codebase-panels]]) — and
  `chat: ChatApi {send, edit, delete, recalc, drawTable}`
  (over `WsClient.sendChatMessage`/`editChatMessage`/`deleteChatMessage`/`recalcRoll`/`drawTable`.
  `drawTable(opts)` posts one `draw_table` frame (`tableId`, `channel`, optional `count`/
  `actorOwner`/`audience`), correlates and settles EXACTLY like the other four — see
  `shadowcat-codebase-tables-notes` for the server-side draw resolution `drawTable` triggers.
  These frames DO carry a
  `request_id` and `chatPending` is keyed by it: a `chat_error` correlates back and REJECTS the
  caller's promise with the server's player-presentable reason, which the composer surfaces.
  SUCCESS is the asymmetric case — the broadcast Event echo carries no `request_id`, so nothing
  acknowledges an accepted op and the 15s timer RESOLVES on silence. Exactly three settle paths:
  that timer, a `chat_error` reject, and a `failPending` reject — reached from BOTH a disconnect
  and an explicit `stop()` (`WorldSession.leave()`, and the `evicted` frame handler). Details →
  [[shadowcat-codebase-chat]]). `members` is populated for EVERY role, not only GM — chat name
  resolution needs it, and the roster endpoint is member-visible. `AppContext.speakAsToken:
  SpeakAsToken` (a `ui-kit`-local stable-instance/mutate-in-place class, shell-constructed in
  `Table` alongside `sceneSelection`) holds a ONE-SHOT pending "speak as this token" selection —
  `select(id)`/`consume()`, read-once by design: the scene-tools `ToolRail` sets it, the
  composer reads `.tokenId` for its indicator and calls `.consume()` on send. Its sibling
  `AppContext.speakAs: SpeakAs` holds the STICKY speak-as actor selection (`actorId`, `""` =
  myself): the composer's `<select>` binds it, and every roll-producing surface — the composer
  and the chat card's roll buttons — sends it as the roll's actor binding (the pending one-shot
  takes precedence) so the server resolves a statted template's references as the SENDER, never
  the button's author. Details →
  [[shadowcat-codebase-chat]].
- **`canCreate`/`canDelete` advisory mirrors + `role_capabilities`.** `ServerMsg::Welcome`
  carries `role_capabilities: RoleCapabilities { all, by_type }` — the CONNECTING user's own
  world-level capabilities, projected from `WorldCapDefaults.role_caps` for their role by
  `data::permission::project_role_caps_for` (`shadowcat-codebase-documents-permissions`; nothing
  about another role crosses). `@shadowcat/core`'s `canCreateDoc(docType, role, roleCaps)` mirrors
  `apply_intent`'s Create arm (`role === "gm"` ⇒ true; else `roleCaps.all` or
  `roleCaps.by_type[docType]` contains `"core:create"`); `WorldSession.canCreate(docType)` reads it
  off the stored Welcome projection, exposed as `AppContext.canCreate(docType): boolean`.
  `WorldSession.canDelete(doc)` mirrors the `Operation::Delete` gate (`role === "gm"` ⇒ true; else
  the SAME private `#capsFor(doc)` resolver `canEdit` already uses contains `core:delete` — never
  a second resolver call, never raw `doc.owner`; `resolveCaps` adds `core:delete` for a token's effective owner, so an owner sees Delete on their own token), exposed as `AppContext.canDelete(doc)`. Both are
  ADVISORY (the server re-checks at `apply_intent`) and both are used to HIDE, not gate, an
  affordance the server would refuse — `ActorsPanel`'s whole create form sits under
  `canCreate(ACTOR_DOC_TYPE)` (carried-light/hide-name/ownership stay `role === "gm"`-gated
  Update-path controls). Every `setAppContext` fixture defaults `canCreate`/`canDelete`
  by the SAME rule `role` already uses (`() => (over.role ?? "gm") === "gm"`), so an unmodified
  GM-role fixture keeps its create/delete affordances.
- **Rejected-intent toast.** `WorldSession`'s `WsClient.onReject` handler, beside
  `#optimistic.reject(id)`, invokes an optional `opts.onReject?(reason: RejectReason)` —
  `RejectReason` is the EXISTING ts-rs type `ws-client.ts` already threads through, no second name
  introduced. `App.svelte` wires it to `notifications.push("warning",
  t(\`intent.rejected.${reason}\`))` (three keys: `forbidden`/`conflict`/`invalid`), the same sink
  `Table.svelte` wires `AppContext.notify` to. This is the ONE place a refused write becomes
  user-visible feedback — every sheet built on `setField` inherits it for free; a per-sheet reject
  handler would fork this decision.
- **`firstChannel`/`buildMoveOp` live in `@shadowcat/core`, not a module.** `firstChannel
  (documents): string | null` (`chat-docs.ts`) returns the world's `channel-registry` singleton's
  first key, `null` only in the pre-resync window (the registry is server-seeded) — EVERY
  roll/draw-posting surface (`ItemSheet`, `NoteSheet`, `TableSheet`, `TablesPanel`) reads this ONE
  symbol and disables its send/draw control while it is `null`; no module hardcodes a `"general"`
  channel literal. `buildMoveOp(docId, targetParentId, currentParentId): WireOperation`
  (`move-op.ts`) is the one `{ op: "move", ... }` builder — the asset-browser folder tree and the
  notes panel's Move-to both call it, so the wire shape never forks between the two `parent_id`
  trees that use it.
- **`buildUpdate` is the one Update-op builder.** `buildUpdate(docId, edits: FieldEdit[]):
  WireOperation` (`update-op.ts`, `@shadowcat/core`) builds every `{ op: "update", doc_id,
  changes }` envelope in the client — the `old ?? null` OCC collapse and the `remove: true` change
  shape (which still carries `new: null`, a required wire field) are stated there once. ui-kit's
  `setField`/`unsetField`/`setFields` (`sheetEdit.ts`, taking `Pick<AppContext, "dispatchIntent">`)
  wrap it; `CombatController`, scene-tools' `controller.svelte.ts`, `ToolRail`, and every panel that
  edits a field call it directly or through those wrappers. A multi-document batch composes several
  `buildUpdate` results into one `dispatchIntent`. No module hand-builds an `op: "update"` literal.
