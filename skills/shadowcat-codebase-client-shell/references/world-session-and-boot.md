# Client shell - move seams and WorldSession lifecycle

Part of shadowcat-codebase-client-shell: moveRequest/onMoveStream, shared ruler, cold-start bootstrap, external-module loading, boot() and navigate(), boot fetch bounds and deadline, and the WorldSession activation latch; read it before touching WorldSession, App boot or those seams.

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
  client-side chaining of collinear path runs. It takes an optional `gesture` object (the identity
  every request of one user gesture shares); `WorldSession.moveRequest` echoes it on each
  `AppContext.onMoveOutcome` record (`outcome` `"executed"`/`"truncated"`/`"rejected"`, where
  `"rejected"` covers a server refusal, the correlated-request timeout AND a dropped or absent
  socket — the last rejects with `NotConnectedError`). `Stage` is the ONE consumer of those
  outcomes and raises the rejection notice through `noticeOncePerGesture` (`@shadowcat/core`); a
  tool never raises its own notice for a rejected `moveRequest` (`shadowcat-codebase-scene-rendering`,
  "Move failures reach the player ONCE per gesture").
- **Shared-ruler seams:** `AppContext.shareRuler: ShareRulerPreference` (a ui-kit stable-instance
  `$state` class, sibling of `SnapModePreference`: `WorldSession` constructs it with its immutable
  `selfId` and the browser's local storage when one exists, and it persists under a per-USER key
  (`shareRulerStorageKey`) because one browser profile's storage is shared by every account and one
  account's opt-in must not switch sharing on for another; default OFF; an absent, unreadable or
  unrecognized stored value reads as off), `AppContext.sendRulerUpdate(scene, points, active)`
  (explicit scene, so a stop reaches the scene the ruler started on) and `AppContext.onRuler(cb)`
  (viewed-scene-filtered, own-connection frames dropped — `WorldSession.onRuler`). `ToolRail`
  builds its controller argument from `ctx.shareRuler`/`ctx.sendRulerUpdate`; every
  `setAppContext` fixture defaults `shareRuler` to a real `ShareRulerPreference`. Behavior:
  `shadowcat-codebase-scene-rendering` (sender/receiver), `shadowcat-codebase-realtime-sync` (wire).
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
