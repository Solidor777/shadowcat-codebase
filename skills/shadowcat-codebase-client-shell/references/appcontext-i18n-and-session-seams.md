# Client shell - AppContext, i18n and session seams

Part of shadowcat-codebase-client-shell: the system contract, i18n, selection classes, AppContext seams (serverRole, pathfind, combat, hooks, plural/compare, notifications) and sort keys; read it before changing any of them.

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
- `t(key, params)`, `locale()`, `plural(key, count, params)`, `compare(a, b)` — the `i18n` Svelte
  adapter over core's `I18n`; catalogs in `ui-kit/src/locales/`. `I18n` resolves a key/entry
  missing from the active locale's catalog against `fallbackLocale` (constructor arg, default
  `"en"`) before falling through to the raw key string — `t`/`plural` share that one chain.
  `plural(key, count, params)` selects a CLDR plural category, via the standard ECMAScript
  plural-rules API, from a catalog entry shaped as a `PluralEntry` (`{ other, zero?, one?, two?,
  few?, many? }`; `other` is mandatory, every other category optional and falls back to `other`
  when absent) rather than a plain string; `{count}` is merged into the interpolation params
  automatically. Category selection uses that plural-rules API bound to whichever locale SUPPLIED
  the matched entry (active locale first, then `fallbackLocale`) — NEVER the active locale's own
  rules — because a fallback-sourced entry selected under the active locale's grammar can pick the
  wrong category (a French-active session with only an English catalog entry: the English rules
  select `"other"` for a count of zero while the French rules would select `"one"`, so using the
  active locale's own rule would render "0 item" instead of "0 items"). A `t()` lookup
  that lands on a `PluralEntry` reads as a miss (no count to select with) and falls through the
  chain rather than stringifying the object. `compare(a, b)` wraps one string-collation object per
  `I18n` instance, rebuilt on every `setLocale` — the ONE collator every locale-aware sort in the
  client reads (`AppContext.compare`, `folderChildren`'s injected comparator, `TablesPanel`'s name
  sort); no call site constructs its own collator.
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
  image, never the optimistic view; its turn boundaries are the `combat-history` records the
  command appended (`collectHistoryTouch` → `crossedRecords` → `turnWalk`), and because that
  document is GM-only egress a player's derivation falls back to the combat document's own
  `turn`/`round` endpoints (a different `turn`, or the same `turn` in a later `round` — a lap), so
  a player's list is a subsequence of the GM's; nothing infers a turn from a `lifespan`
  decrement or a combatant delete (`shadowcat-codebase-combat`'s `combat::history` bullet, in its references/key-files-and-seams.md).
  `CombatHookEmitter` emits in strict seq order. `WorldSession.dispatchIntent` returns
  `boolean`: `false` is the guarded drop before `enter()`/after `leave()` (warn + discard, no
  prediction), and `CombatController.dispatch` turns it into a thrown `CombatClientError`
  `"not-connected"`, so no `CombatApi` document helper returns an id for a dropped op
  (`AppContext.dispatchIntent` keeps its void return shape for every other caller). The `"combat"`
  subscription parses through `parseCombats(payload, logger)`, which reports a malformed frame
  through the session's logger — unlike `parseFootprints`, which stays silent — never a bare
  `console.warn`.
  `AppContext.combat` is exposed to every module/Svelte surface exactly like `AppContext.pathfind`;
  all `setAppContext` fixture sites default it to a real `CombatController` over the fixture's
  `documents`, never a stub.
- **`HookBus` pre-declares `core:hook-fault`** (an `"info"`-kind hook, registered in the
  constructor before any `defineHook` call) and dispatches it from every `emitInfo`/`emitMutate`/
  `emitCancel`'s per-listener catch with `{ hook, error }` — fire-and-forget observability; nothing
  about dispatch to the ORIGINAL hook's other listeners changes because of it. `emitFault`'s only
  re-entrancy guard is GENUINE self-recursion: a fault raised by a listener registered ON
  `core:hook-fault` itself is dropped (that throw is still isolated by the ordinary per-listener
  catch, just with no further fault dispatch) — a second synchronous fault from a DIFFERENT
  listener on the SAME hook, a concurrent fault on a DIFFERENT hook, and a fault raised while an
  earlier `core:hook-fault` dispatch is still in flight (including one that never resolves) all
  still produce their own dispatch; a persistent "one fault at a time" flag would instead drop
  those and let one hung `core:hook-fault` listener silently disable fault reporting for the rest
  of the session. `WorldSession`'s constructor is the real consumer: it registers a `core:hook-fault`
  listener that logs `hook ${fault.hook} handler faulted` through the session's own logger, the
  same sink `#onWelcome`'s catch-all uses.
- **`AppContext.plural`/`AppContext.compare`** sit beside `t` (`PluralFunc`/`CompareFunc` types in
  `appContext.ts`) — every module goes through these seams for plural text/locale-aware sorting,
  never the ui-kit `i18n` singleton directly, so a test can fixture-override them exactly like `t`
  (`setAppContextForTest`'s `plural`/`compare` overrides). `AppContext.hooks: HooksEmitApi` is the
  component-facing counterpart to `ModuleContext.hooks`: a Svelte component has no `ModuleContext`
  of its own, so this is the one seam through which built-in UI (the chat composer's pre-send
  interception, `chat:composer-send`) EMITS a hook a module registered against via its own
  `register()`. `HooksEmitApi` exposes only `emitMutate<K extends keyof CoreHooks>(name, payload)`
  — deliberately narrower than `ModuleContext.hooks`, since `defineHook`/`on` stay module-only
  (declared once by the seam that owns the hook, e.g. `defineChatComposerHooks`, and subscribed to
  via a module's `register`); a component emits, it never declares or listens. `WorldSession.hooks`
  is a thin forwarder onto the session's own `HookBus`.
- **`NotificationCenter` caps the VISIBLE set at `MAX_VISIBLE_NOTIFICATIONS` (5)** — a push beyond
  the cap queues FIFO in a separate internal list and is promoted into `items` as a visible
  notification dismisses (auto or manual); `items` never exposes a queued entry. `NotificationHost`'s
  auto-dismiss `$effect` schedules its dismiss timer off `activeNotifications()` (i.e. `items`), so a
  queued notification gets no timer at all until promotion makes it visible, at which point the
  effect re-runs on the new `items` array and schedules it fresh from that moment — a notification's
  auto-dismiss clock does not start ticking while it sits in the queue.
- **`allocateSortKey`/`appendSortKey`/`SORT_KEY_DENSITY` (`@shadowcat/core`'s `sort-key` module) are
  THE shared gap-based sibling-ordering primitive** for any document tree with an integer `sort`
  field: a fresh sibling gets a key spaced `SORT_KEY_DENSITY` (1000) away from its neighbours
  rather than a dense 0/1/2/... counter, so a later insert between two existing siblings can take
  the integer midpoint without renumbering every later sibling; `allocateSortKey(prev, next)`
  signals `renumber: true` (gap exhausted, no integer strictly between `prev`/`next`) rather than
  silently colliding with a neighbour. `appendFolderSortKey` (asset-browser) and `appendNoteSortKey`
  (`@shadowcat/core`, called from both `NotesPanel` and `NoteSheet`'s child-create) are its two
  current callers — **both only ever APPEND today** (`appendSortKey`, the `prev = max, next = null`
  case); nothing yet exercises `allocateSortKey`'s insert-between or prepend cases, or its
  `renumber` signal, from a real UI drag-to-reorder. Route a new sibling-ordering need through this
  module rather than re-deriving the "highest sibling → append" computation locally — a forked copy
  is exactly the defect class `shadowcat-codebase-core`'s never-fork-a-decision rule targets.
