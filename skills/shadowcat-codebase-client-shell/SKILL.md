---
name: shadowcat-codebase-client-shell
description: "Use when touching the Shadowcat UI shell: the contribution/Surface module architecture, Contribution.panel metadata, AppContext (incl. the chat, uiState.panelLayout, panels/PanelsBridge, and multi-scene viewedSceneId/setGmViewedScene/searchDocuments/sceneSelection seams), the hash router + entry views, i18n/locale, or the shell/UI modules (entry, core-ui, topbar, statusbar, settings, scene-browser). Covers src/client/{shell,ui-kit} + those src/modules. For the panel-manager internals (module-panels, engines, layout tree) invoke shadowcat-codebase-panels; for the render-engine consumption of viewedSceneId invoke shadowcat-codebase-scene-rendering. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Client Shell & UI Modules

Orientation for the SPA shell, the UI-as-modules contribution architecture, and i18n.

## Purpose

The browser UI is layered: a thin app **shell** bootstraps routing/session/AppContext and wires
the default module set; in-game UI is contributed by `src/modules/*` packages into named
**surfaces** via a `provides`/`requires` contract system; entry views (login/world management) are
plain-routed, not contributions. i18n is a framework-neutral core with a thin Svelte adapter.

## Key files & seams

- `Contribution`, `ContributionRegistry` (modules
  contribute UI into named surfaces). `Contribution.panel?` is optional
  plain-data panel metadata (`icon`, `labelKey`, `gmOnly?`, `defaultPlacement`) the panel host
  renders; `labelKey` is an i18n key the HOST resolves (locale-reactive). There is no `tab`
  field — a `Contribution` describes only a panel.
- **Panels are the sidebar**: the sidebar module and ui-kit
  `TabbedSurface` do not exist. `@shadowcat/module-panels` provides the multi
  `shadowcat.panel` contract every panel module contributes into, hosts `PanelHost` in
  core-ui's singleton `shadowcat.surface:panel-host` region and the minimized-chips strip in
  statusbar's `shadowcat.surface:panel-dock`. Keep-mounted rule carries over: panels hide via
  CSS/slot adoption, never `{#if}`; hidden content reads `scrollHeight = 0` (module-chat's
  IntersectionObserver pattern still applies). Internals → [[shadowcat-codebase-panels]].
- `ModuleRegistry`; `ServiceRegistry`; a `singleton`-cardinality `provides` collision is resolved
  by graceful demotion + explicit `ContractProvide.priority` (see `shadowcat-codebase-module-toolchain`),
  not an abort. `reconcileTopology(...)` is a separate, warn-only comparison of the client's own
  resolved `provides`/`requires` against the server-broadcast topology. Contract schemas:
  `ContractProvideSchema`.
- **`SYSTEM_CONTRACT` and the server-seeded world-setting defaults.**
  `SYSTEM_CONTRACT = "shadowcat.system"` is the singleton contract a game-system module claims to
  become "the" active system for a world (`ModuleRegistry::systemModule()` resolves the winner
  through the SAME active/demoted `activeProvidersOf` bookkeeping every other singleton contract
  uses — a losing claimant is excluded exactly as elsewhere, no separate resolution mechanism).
  A system's world-setting defaults are declared in its `module.json` `systemDefaults` (the
  manifest, validated server-side — see `shadowcat-codebase-module-toolchain`; the client's
  `ManifestSchema` shape-checks it for authoring feedback only), and the SERVER writes the
  world's `system-defaults` singleton from that declaration — at world creation, at every world
  join, and on any enabled-set change. Client writes to the singleton are rejected outright,
  and `WorldSession.#onWelcome` dispatches no config-doc writes at all (its only remaining seed
  is the GM first-scene create — a scene is not config). This feeds the four-tier settings
  chain (engine → system-defaults → world → scene) `resolve_combat_rules`/
  `resolveSettingProvenance` resolve server- and client-side — see `shadowcat-codebase-combat`
  for the resolver and the combat-specific `CombatDefaults` shape this chain carries.
- `<Surface>` is the host that renders contributions for a
  surface id; `AppContext`, `setAppContext`/`getAppContext`, `__APP_CONTEXT_KEY__`.
- `t(key, params)`, `locale()`, the `i18n` adapter over
  core's `I18n`; catalogs in `ui-kit/src/locales/`.
- **Module-facing i18n registration**: `I18n.addMessages(locale, messages, opts)` merges a
  fragment into a locale's catalog (last write wins — a later call for the same `(locale, key)`
  overwrites an earlier one, including a BUILT-IN key; no collision arbitration beyond that).
  `ModuleContext.i18n.addMessages(locale, messages)` is the module-scoped wrapper `ModuleRegistry`
  builds (stamps the calling module's id via `opts.module`), and `I18n.removeModule(moduleId)` —
  wired into `ModuleRegistry.unload` alongside `hooks`/`services`/`middleware`/
  `contributions.removeModule` — undoes exactly that module's own inserted `(locale, key)` pairs on
  unload. It does NOT restore a value the module's insertion shadowed (e.g. a module overwriting a
  built-in key): the key is simply absent afterward, falling back to the raw key string in `t()`
  like any other missing key — an accepted limitation, not a bug. The shell wires the ui-kit `i18n`
  singleton into `WorldSession`'s `ModuleRegistry` construction (`i18n` import alongside
  `SceneInteractionBridge`/`ActorSelection`/`TokenSelection`), the same precedented pattern for
  pulling a ui-kit-owned singleton into shell-built `Deps`.
- `src/client/ui-kit/src/{sceneInteraction,actorSelection,tokenSelection}.*` — AppContext seams.
- **The three selection classes share a shape but NOT their repeat-set reactivity.** All of
  `ActorSelection`, `TokenSelection`, `SceneSelection` are stable instances mutated in place (never
  reassigned) so the AppContext-captured reference stays valid, and none of them PRUNE an id whose
  document is later deleted — a stale id stays selected until something clears it, so every consumer
  MUST resolve against the current store and handle the miss itself. That is an obligation, not an
  observation: today's consumers all check, but not uniformly — scene-tools' place tool aborts on a
  miss while its measure tool substitutes defaults (`eng?.x ?? 0`, a 0.4 footprint), which is a
  silently-wrong measurement rather than a no-op. They diverge on what re-selecting the
  CURRENT value does: `ActorSelection`/`SceneSelection` are `$state`-backed scalars, so `select(same)`
  is a no-op for reactivity (`$state`'s default `===`), while `TokenSelection` is `SvelteSet`-backed
  and `set()` clears-then-re-adds, so passing back an identical id list still re-triggers every
  reader of `.ids`/`.has`/`.size`. The one exception is empty→empty: `SvelteSet.clear()` early-returns
  without bumping its version when already empty, so that case alone is a genuine no-op. Do not
  reason from "they're siblings" to "they behave alike" — an effect keyed off `TokenSelection` runs
  on repeat-sets that an `ActorSelection`-keyed one skips.
- **`AppContext.serverRole`** — the caller's SERVER tier (`"admin" | "user"`),
  distinct from the per-world `role`. Gates admin-only UI (the settings module's user manager).
  Derived in `App` from `/api/me` as `me?.server_role === "admin" ? "admin" : "user"`, so an
  absent or unrecognized value yields `"user"` — fail-closed. **It is COSMETIC**: the server
  re-checks every admin route through the `AdminUser` extractor, so a forged client gains nothing.
  Never gate an admin surface on the per-world `role` instead: `permission_context` maps
  `ServerRole::Admin → WorldRole::Gm`, so a world-role check is satisfied by any GM. All three
  `setAppContext` fixture sites default it to `"user"` so no existing test silently gains admin UI.
- `AppContext.pathfind` — correlated-request seam: issues a
  `Pathfind` frame via `WsClient.pathfind` and resolves with `PathResult` or rejects with
  `PathError`; wired through `WorldSession` and consumed by `scene-tools` measure-tool route mode.
- **`AppContext.combat` / `COMBAT_SERVICE`** — `WorldSession` constructs its `CombatController`
  (`@shadowcat/core`, owned by `shadowcat-codebase-combat`) IN ITS OWN CONSTRUCTOR, before any
  world is entered, so `CombatControllerDeps.world`/`role` are LIVE GETTERS
  (`() => this.world ?? ""`, `() => (this.role === "gm" ? "gm" : ...)`), never construction-time
  snapshots — the same shape a plain field could not express, since `this.world` is still `null`
  at construction time. `WorldSession.enter`/`leave` open/close a `"combat"` scene subscription
  (`subscribeScene("combat", ...)`) that feeds `CombatController.setResolved`; `leave` also resets
  it to empty. The first nine `CoreHooks` entries (`combat:start`/`end`/`round-start`/
  `round-end`/`turn-start`/`turn-end`/`rewind`/`effect-tick`/`effect-expired`, declared via
  `declare module "./hooks" { interface CoreHooks {...} }` in `@shadowcat/core`'s
  `combat-hooks.ts`) are the FIRST concrete entries the generic `HookBus`/`CoreHooks` merge-point
  (`src/client/core/src/hooks.ts`) ever gained — no skill currently owns that merge-point's
  general mechanics beyond this one concrete use. `WorldSession.onCommand` runs a cheap
  `commandTouchesCombat` pre-scan
  before paying for a pre-image `Map` lookup, so an ordinary token drag never enters the combat
  derivation path. `deriveCombatHookEvents` reads the authoritative `DocumentStore` pre/post
  image, never the optimistic view, and `CombatHookEmitter` emits in strict seq order.
  `AppContext.combat` is exposed to every module/Svelte surface exactly like `AppContext.pathfind`;
  all `setAppContext` fixture sites default it to a real `CombatController` over the fixture's
  `documents`, never a stub.
- `WsClient.moveRequest(scene, tokenId, path) → Promise<MoveStream>` — correlated-request mirror of
  `pathfind`: sends `MoveRequest`, resolves with the broadcast `MoveStream` when the matching
  `move_stream` frame arrives (mover's `request_id` correlates; the resolved value signals success
  only — it does NOT drive animation), rejects on `move_error` or timeout (default 10 s). Pure
  transport — no client-side movement logic. Keyed in the shared `pending` map alongside search and
  pathfind.
- `WsClient.onMoveStream(cb) -> unsubscribe` — the actual playback seam: fires for EVERY scene
  viewer (mover + observers) on every broadcast `MoveStream`, independent of the `moveRequest`
  promise. Listeners survive reconnects (not cleared by `failPending`).
- `AppContext.moveRequest` — AppContext seam wired through
  `WorldSession`; consumed by scene-tools measure-tool route-commit (sends `MoveRequest`, awaits the
  signal-only resolution, does NOT locally animate — the `TokenAnimator` plays back from the
  broadcast, not the promise). Route-commit is request-only: no optimistic local dispatch, and no
  client-side chaining of collinear path runs.
- `onMoveStream` wiring (`WorldSession.enter`): subscribes once at session start,
  **filters `stream.scene` against the active scene** (`this.#optimistic.query("scene")[0]?.id`)
  before forwarding — a room-wide `MoveStream` broadcast for a DIFFERENT scene must not animate a
  token or feed a fog sweep in the one currently rendered (cross-scene leak/flicker guard, mirrors
  the existing `toVisibility`/`toLighting` active-scene filter). On a match, calls
  `sceneInteraction.animateSamples(tokenId, samples, durationMs, startServerMs, () => ws.serverNow(), moverVision)`, which
  forwards through `RenderEngine` to `TokenView`/`TokenAnimator` (position tween) and, when
  `moverVision` is present (mover only), the engine's `visionSweeps` fog-sweep playback (see
  `shadowcat-codebase-scene-rendering`).
- **Cold-start bootstrap: snapshot before WS, never full replay** — `WorldSession.enter(worldId)`,
  BEFORE constructing `WsClient`, fetches `GET /api/worlds/{id}/snapshot` (`getWorldSnapshot`,
  `shadowcat-codebase-realtime-sync`'s `http::routes::world_snapshot`) and seeds both `store` and
  `documents` from it (`DocumentStore.seedDocuments`/`OptimisticClient.seedDocuments` — a wholesale
  replace, not an operation-log merge, since these are LOADED documents, not events that occurred).
  It then pre-seeds `WsClient`'s sequence watermark via `WsClient.seedWatermark(snapshot.seq)`
  BEFORE `start()`/`open()` — so the existing Welcome-triggered gap-check
  (`current_seq >= nextExpected`) only resyncs whatever committed after the snapshot was read,
  never a full replay from seq 1. A snapshot-fetch failure degrades gracefully (logged, falls
  through to full replay), mirroring `#loadExternalModules`'s own "a broken pipeline must never
  brick a world" pattern below. `WsClient.open()` sends a real `ClientMsg::Hello` as the FIRST
  frame on every socket open (including internal reconnects) — `last_seq` is `null` if-and-only-if
  this is the FIRST open this `WsClient` INSTANCE has ever made (`#hasEverOpened`, an identity fact
  about the instance's own open history), NEVER derived from `nextExpected`'s live value: since
  `seedWatermark` runs before the first `open()`, `nextExpected` is already > 1 by the time the
  first `Hello` sends, so a `nextExpected`-derived `last_seq` would never report `null` and the
  server would never learn this was a genuine cold start (see `shadowcat-codebase-realtime-sync`'s
  `Room::resync_floor_enforced` for the server-side consequence this seam feeds).
- **External-module loading, and live hot-reload** — `WorldSession`'s `#loadExternalModules(world,
  serverVersion)` runs once, after the FIRST successful `#onWelcome` activation
  (`WorldSession.loadExternalModules.serverVersion` = `w.server_version`, also captured onto
  `#serverVersion` for later reuse): fetches the world's enabled set (keyed on the install FOLDER
  id, `InstalledModuleInfo.id`, never manifest id), calls core `loadModules`
  (per-module-contained, non-throwing `ModuleLoadResult`), then activates. `WorldSession.
  reconcileInstalledModules()` is the separate, explicitly-triggered live path: re-fetches the
  enabled set and diffs it against `#externalModuleIds` (a folder-id → manifest-id map — BOTH id
  spaces are load-bearing, since the diff must key on the folder id `getEnabledModules` uses while
  `ModuleRegistry.unload` must be called with the manifest id `ModuleRegistry.add` actually
  registered the module under), unloading (`cascade: true`) anything no longer enabled and
  loading+activating anything newly enabled — first-party modules (`opts.modules`) are never
  touched. Exposed through `AppContext.reconcileInstalledModules`, wired in `Table.svelte`, and
  called by `ModuleManager.svelte`'s `save()` after a successful `setEnabledModules` so a GM's
  toggle takes effect in the running session immediately, not just on next world entry. This is
  also what makes `LauncherMenu`'s focus-recovery `$effect` reachable outside a unit test: a live
  unload can drop the launcher's currently-focused item out of `panels.metaMap` while the menu is
  open, and the effect closes the menu + returns focus to the trigger when that happens (reads
  `open` via `untrack` so the effect's only TRACKED dependency is the `panels` derived — tracking
  `open` directly makes the effect misfire on the OPEN transition itself, before `openMenu`'s
  `queueMicrotask` moves focus onto the first item). The shell serves ONE runtime instance of
  `svelte`/`@shadowcat/*` via `RUNTIME_ENTRIES` + `preserveEntrySignatures:"strict"` + the
  `index.html` import map. GM management UI = `ModuleManager`. Full subsystem (server
  discovery/serving/enablement, engine-compat gate) → [[shadowcat-codebase-module-toolchain]].
- **`boot()` resolves the world route-first, not `lastWorld`-first** —
  `App`'s `boot()` reads `currentRoute()` once, AFTER the `getMe`/`getUiState` awaits and
  BEFORE both the `withRetry(() => listWorlds())` await and consulting `ui.global.lastWorld` (a
  hash change during the `listWorlds` await is ignored).
  The rule lives in one pure, directly-testable helper, `resolveBootWorld(route, lastWorld,
  worlds)`: a world route (`#/world/<id>`) always wins — `lastWorld` is
  NOT consulted at all while a world route is present, even if it would resolve to a different,
  still-valid world; `lastWorld` seeds ONLY a bare/non-world load. A route's world id absent from
  `listWorlds()` (deleted/revoked) clears `lastWorld` ONLY if `lastWorld` is ALSO stale — a dead
  deep link must never wipe an otherwise-valid `lastWorld` reference — then lets `boot()` fall
  back to the entry/worlds-list route. Entering the
  resolved id still goes through `enterWorld(worldId)`, which itself calls `setLastWorld` +
  `navigate` — `lastWorld` write semantics are unchanged. A `boot()` that consulted `lastWorld`
  ahead of the URL restores whichever world that account last entered from any other session, so a
  deep-linked reload teleports away from its own URL — a product defect, not merely a
  parallel-test artifact.
- **`navigate()` (`route.svelte.ts`) updates `currentRoute()`'s reactive state synchronously, in
  the same call, not only via its hashchange listener** — a caller that reads `currentRoute()` in
  the same tick as its own `navigate()` call (e.g. `boot()`'s catch/deadline paths setting
  `booted = true` immediately after navigating away on a failure) would otherwise observe the
  PRE-navigation route for one render, since a real browser dispatches the hashchange event as a
  separate async task and jsdom does not dispatch it at all on a bare hash assignment. The
  listener still fires afterward for a self-triggered navigation (a harmless redundant
  re-assignment of the same route) and remains the only update path for a navigation this module
  did not initiate (back/forward, the user editing the URL bar).
- **Bounded + retried boot fetches, against a silent hang at startup** — `FETCH_TIMEOUT_MS`
  (15s) covers every fetch in its module, not only the session/boot trio: `getMe`, `getUiState`,
  `listWorlds`, `postJson` (login/logout), and `putUiState` (including the unload keepalive PUT)
  all carry `AbortSignal.timeout(FETCH_TIMEOUT_MS)`, so a hung backend rejects instead of leaving
  any of them unsettled forever. `App.boot()` wraps each of the three awaits in `withRetry`
  (3 attempts, full-jitter delays — `withRetry`'s base delays are jittered the same way
  `WsClient.scheduleReconnect` jitters its backoff, not applied as a literal flat wait) before
  degrading to the login/worlds route, so a transient non-2xx or connection reset during startup
  does not permanently strand the SPA on that fallback route with no retry.
- **`App.boot()`'s overall deadline is a closure-local abandon flag, not a cancelled fetch** —
  `BOOT_DEADLINE_MS` (60s) bounds `boot()`'s total wall-clock time independent of the three
  `withRetry` chains above (whose own combined worst case is ~141s); `STILL_TRYING_AFTER_MS` (8s)
  switches the rendered "Loading…" message to "Still trying…" before that deadline. Neither timer
  cancels the underlying fetch — `boot()` instead threads a closure-local abandonment flag through
  an `if (abandoned) return;` check after every await (a generation counter is unwarranted:
  `boot()` has exactly one call site, so a per-invocation closure flag is sufficient). That flag
  gates every navigation/session-entry action AND the `me` assignment itself (`me` is read into a
  local before the check, so a late `getMe()` resolution after abandonment cannot clobber a `me`
  set afterward by `onAuthenticated()`) — but it cannot gate a side effect embedded INSIDE an
  awaited call before that call resolves (e.g. `loadSessionState`'s own `i18n.setLocale` write
  still applies once that call settles, even after abandonment), since true cancellation would
  need an abort signal threaded through `withRetry`/`getMe`/`getUiState`/`fetch`, out of scope for
  this mechanism.
- **`WorldSession`'s activation latch is split, and the split order is load-bearing** —
  latching a single `#bootstrapped` boolean BEFORE `await #modules.activate()` would let a
  failed/hung first activation (e.g. a manifest dependency cycle) cache "done" for the
  session's life: reconnect Welcomes would short-circuit, `role` would be set, but every
  Surface would stay empty. It is instead two fields: `#modulesAdded` (latches once per
  session — re-adding modules would duplicate registrations) and `#activated` (latches only on a
  successful `activate()`, reverted to `false` in the catch clause on a thrown activation, so the NEXT
  Welcome retries instead of caching the failure). **`#activated` is still set to `true`
  SYNCHRONOUSLY, before the `activate()` await** — deliberately, and it is the one place a latch
  is set ahead of the work it guards: same-tick concurrent Welcomes re-enter `#onWelcome`, and
  setting `#activated` only after the await (e.g. in a `.then()`) would let a second Welcome
  arriving mid-activation see `#activated === false` and call `activate()` again, double-
  activating. Any future change to this seam must keep the synchronous pre-await set — do not
  "simplify" it to an after-await assignment.
  **`leave()` is a PARTIAL teardown, and the latches are what makes that dangerous.** It stops and
  drops the `WsClient` and resets `state`/`role`/`world`/`#gmViewedScene`, but does NOT clear
  `store`/`documents`, module registrations, or EITHER latch. That is correct only because
  `App.leaveWorld` discards the instance and constructs a fresh `WorldSession`. Reuse one
  across `leave()` → `enter()` and it carries the PREVIOUS world's state into the new one: `store`/
  `documents`, module registrations, and the `contributions` registry all survive (nothing clears
  them — `ContributionRegistry` drops entries only via a contribution's own dispose or
  `removeModule`), while both latches stay set so the next Welcome skips activation. Surfaces then
  render the previous world's contributions — stale cross-world content, NOT an empty screen, which
  is the harder failure to notice. Treat `WorldSession` as single-use per world entry. (Distinct
  from what the latch split itself guards, which is a FAILED first activation being cached.)
  **Two more boundaries worth knowing before relying on `enter()`:** it resolves when the connect
  ATTEMPT SETTLES — `WsClient.open` catches a failed `connect` and schedules a reconnect instead of
  rejecting — so resolution implies neither an open transport nor a usable world; Welcome, module
  activation, the member fetch, and external module loading all happen afterward and are not
  awaited. `#onWelcome` contains BOTH failure sources at the point of failure and neither
  propagates: the member fetch has its own inner catch (logged, non-blocking), and a thrown
  `activate()` (a genuine contract cycle) reverts `#activated` and logs
  `"module activation failed; Surfaces degrade until a later Welcome retries"` without rethrowing —
  external-module loading is skipped for that Welcome (it stays gated behind a successful
  `activate()`), but the member fetch, topology reconcile, scene re-establishment, and the GM
  first-scene seed all still run. An outer catch remains around the whole method for any other,
  genuinely unexpected failure, so the method itself never rejects.
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
  Concurrent same-user sessions (two tabs) now contend only on the individual fields/keys both
  sessions actually write, instead of last-writer-wins on a whole slice or the whole blob.
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
- **Multi-scene / viewed-scene seams** — `AppContext.viewedSceneId: string | null`
  (a live getter, `Table`: `get viewedSceneId() { return session.viewedSceneId; }` —
  NEVER destructure a snapshot of it), `AppContext.setGmViewedScene(id): void` (GM-only local
  roam; no-ops+warns for a non-GM), `AppContext.searchDocuments(query, opts, onUpdate) ->
  Promise<SubscriptionHandle>` (the live-FTS subscription seam, exposed through
  `AppContext`/`WorldSession` — wraps `WsClient.subscribeSearch`, ephemeral/NOT
  reconnect-resilient), `AppContext.sceneSelection: SceneSelection`
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
  `chat: ChatApi {send, edit, delete, recalc}`
  (over `WsClient.sendChatMessage`/`editChatMessage`/`deleteChatMessage`/`recalcRoll`. These frames DO carry a
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
- `src/modules/{entry,core-ui,panels,stage,topbar,statusbar,settings,game-settings,scene-browser,
  chat,chat-composer,chat-card}/` — entry = `@shadowcat/module-entry` (login + world mgmt, behind
  `<Entry onEnterWorld>`); core-ui owns the layout grid + region surfaces into the singleton
  `root` (its main region hosts `shadowcat.surface:panel-host`; BOTH cells of the `1fr` row —
  `.main` AND `.toolrail` — carry the growth cap (`min-height: 0` + a non-visible `overflow-y`),
  because a grid row is at least as tall as its tallest item's minimum contribution: one
  uncapped cell grows the row, the grid and every sibling past 100vh, the document becomes
  scrollable, and a canvas rect measured before a scroll lands raw-coordinate gestures off the
  canvas — which is how a `ToolRail` taller than the row once broke token placement. `.main`
  hides overflow (the panel host owns inner scrolling); `.toolrail` scrolls its stacked
  contributions itself (`overflow-y: auto`, `overflow-x: hidden`). `Layout.test` enumerates
  the row's cells against the cap, reading component styles through jsdom's cascade — core-ui's
  vitest config compiles them with `emitCss: false`, since vitest never attaches an emitted CSS
  asset to the document); the grid's compact/expanded
  switch is keyed SOLELY off `sizeClass()` (48rem, `ui-kit`'s single breakpoint axis) — no
  media query; `grid-template-rows` reserves a fixed `2rem` statusbar row in both states.
  panels = the panel manager ([[shadowcat-codebase-panels]]); stage = the canvas stage well
  (inviolable — never docked/floated/minimized); the panel modules each contribute one
  `shadowcat.panel`; defaults are launcher-closed for every panel except chat (docked right
  by default); game-settings gmOnly. `topbar` = `@shadowcat/module-topbar`: hosts
  `LauncherMenu` (open/close any registered panel by id via `AppContext.panels.toggle`,
  `launcher-item-{panelId}` testids, a11y menu + focus management) + `Presence` (member
  roster) + a standing settings-entry button that toggles `settings:panel` through the same
  `AppContext.panels` seam — imports NOTHING from `@shadowcat/module-panels` (seam boundary by
  design: topbar's package.json declares no module-panels dependency and the launcher talks to
  panels only through `AppContext.panels`; NOT lint-enforced — the repo's sole
  `no-restricted-imports` rule covers `dockview-core` only, and .svelte files are unlinted).
  Below 48rem the
  topbar drops the world-name label and the scene-tools `ToolRail` collapses from a vertical
  side rail into a horizontal bottom strip (`sizeClass()`-driven, same axis).
  `game-settings` = `@shadowcat/module-game-settings` (GM-only): EDITS the world's singleton
  config-docs (every one server-seeded at world creation/join) — the vision/lighting trio
  (`world-settings`/`light-gradation`/`vision-modes`, resolved by
  `resolveSceneSettings`/`resolveGradation`/`resolveVisionModes`),
  plus `dice-settings` and `chat-settings` (the `hyperlinks` +
  `link_previews` tri-state toggles). World-defaults inputs display the provenance-resolved
  EFFECTIVE value while writes carry the RAW stored overlay leaf as the OCC pre-image, and the
  reset control CLEARS the leaf (writes null) so resolution falls through — never a
  client-resolved literal. The chat/dice server resolvers + segments are covered by
  `shadowcat-codebase-chat`/`-dice`.

## Hard invariants

- **A value put into `setContext`/AppContext must be a stable, in-place-mutated ref** (e.g. a
  `SvelteMap`), not a reassigned `$state`, or consumers hold a stale snapshot
  [[svelte-context-stable-ref]].
- **Contribute/activate before any await that gates the host mount** — an async-populated
  contribution Surface paints blank until activation runs; the minimal fix touches only the
  diverging path [[refactor-async-contribution-paint-timing]].
- **In-game elements communicate ONLY through seams** (module contracts, `ContributionRegistry`,
  `<Surface>`, AppContext, render-layer API) — never import one another or the shell directly.
- **Entry views are plain-routed, not contributions; surfaces are in-world only.**
- **Config docs are server-seeded; a panel never creates one.** Every config singleton
  (world-settings, the faction/condition/channel/resource registries, chat/dice settings,
  system-defaults) exists from world creation/join via the server's `ConfigSeed` path, so a
  panel `$effect` that creates a missing config doc is a defect, not a convention. Panels read
  reactively (`createSubscriber` + `subscribe()` — a plain store read inside `$derived`/`$effect`
  registers no dependency, and panels mount during `#onWelcome` BEFORE the resync stream
  populates the store) and EDIT with real-OCC stored pre-images only
  [[contribution-seed-reactive-before-resync]].

## Gotchas

- **i18n MUST stay framework-neutral** — the core `I18n` is Svelte-free; the Svelte `t`/`locale`
  adapter wraps it via `createSubscriber`. Don't pull a Svelte i18n lib into core.
  **There is NO cross-locale fallback:** a key missing from the ACTIVE locale's catalog renders as
  the raw key string, even when another loaded locale defines it. A partial translation therefore
  ships visible key text rather than English, so a new key must land in every shipped catalog.
- **`setAppContextForTest` does not emulate optimistic behavior** —
  `documents` defaults to `over.documents ?? over.store ?? new
  DocumentStore()`, so a test overriding only `store` gets that SAME plain store as `documents`.
  Predicted-op overlay and rollback-on-reject are absent; reads through `documents` are plain
  authoritative reads. In production the two are INDEPENDENT siblings fed the same `applyCommand`.
  A test asserting optimistic semantics must supply its own `documents`, or it is asserting
  nothing. (Same fixture-fidelity class as that
  fixture's identity-echo `t: (k) => k`, which resolves every key to itself rather than through a
  catalog.)
- **`WorldSession.canEdit` is an affordance mirror, and it diverges from server authz in BOTH
  directions** — treat it as "which controls to show", never as the
  authority. It can over-permit: the `role === "gm"` short-circuit returns `true` unconditionally and
  never consults `doc.permissions.gm_role`, while the server's GM bypass is CONDITIONAL — a doc
  carrying `gm_role: Some(role)` floors even a GM to ordinary `DocRole` resolution
  (`data::permission::effective_role`/`data::permission::resolve_access`). It can also over-restrict: the Welcome
  union mixes GM-authored `world_cap_requirements` with module-declared manifest requirements, and
  the server does NOT reject a write merely because a module declared a requirement on that path.
  **The two halves are unobservable today for UNRELATED reasons, and arm on unrelated triggers —
  do not give them a shared bound.** The over-permit is neutralized by the server: `SqliteRepository::apply_intent`
  re-checks independently, and `gm_role` is currently written only by chat-message construction
  (`chat::build_message_doc`), whose `message` doc_type the server rejects ordinary client Updates to outright
  regardless of role (`SqliteRepository::apply_intent`; only the server-set `WriteOrigin::ServerMessageRevision`
  bypasses it, which no wire message can name). It arms if `gm_role` is ever set on another
  doc_type. The over-restrict is NOT neutralized by that re-check at all — hiding a control means
  the user never reaches `apply_intent` — it is merely unobservable while no enabled installed
  module declares `requirements`, since the Welcome union then contributes nothing beyond the
  GM-authored record. It arms when an ENABLED, ENGINE-COMPATIBLE module declares a non-empty
  `requirements` — compatibility is re-checked on every Welcome, not just at enable time, so a
  module that has gone stale stops publishing — with no `gm_role` involvement whatsoever
  (`ws::conn::welcome_capability_requirements`, whose own doc marks the union ADVISORY ONLY,
  vs. `SqliteRepository::apply_intent`'s enforcement reading only `world_cap_requirements`).
- **`listWorldMembers` is FORKED — two implementations of one endpoint, already diverged.** The
  shell's `api` module's `listWorldMembers` goes through `getJson`: it has a request timeout, does NOT
  `encodeURIComponent` the world id, and raises status-only errors. Core's public
  `user-rest` module's `listWorldMembers` (re-exported from `@shadowcat/core`'s public entry) encodes the id and surfaces the server's error
  text, but has no timeout. The shell's `members` seam calls its own copy
  (`WorldSession`'s), so the two can drift further with nothing failing. This is the
  never-fork-a-decision class from `shadowcat-codebase-core`; do not add a third caller to either
  copy without collapsing them.
- **Refactors across a callback boundary must preserve decision branches, not just await ordering**
  [[refactor-preserve-decision-branches]].
- UI packaging target: swappable entry package + per-element packages + thin shell
  [[ui-packaging-target]].

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_shell.html`, `_shadowcat_ui-kit.html` (TypeDoc),
  plus the shell/UI module pages `_shadowcat_module-core-ui.html`, `_shadowcat_module-entry.html`,
  `_shadowcat_module-topbar.html`, `_shadowcat_module-statusbar.html`,
  `_shadowcat_module-scene-browser.html`, `_shadowcat_module-settings.html`,
  `_shadowcat_module-game-settings.html`. Produce with `pnpm build:all`. `@shadowcat/module-settings`
  and `@shadowcat/module-game-settings` are distinct packages with distinct pages.
- Rationale: `docs/design/ARCHITECTURE.md` §1 (client UI packaging) + §2 invariant 7 (framework-neutral API).
- Relationships:
  `graphify query "contribution registry surface appContext shell router i18n locale panel"`.
- History: [[m7-brainstorm]], [[m6b-modules-capabilities]].
