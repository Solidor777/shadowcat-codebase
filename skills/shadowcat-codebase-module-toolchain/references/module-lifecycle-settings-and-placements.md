# Module toolchain: lifecycle status, conflicts, settings, keybindings, placements

Part of the shadowcat-codebase-module-toolchain skill; read it before touching the activation
result, the module manager's satisfiability preview, `ModuleContext.settings`/`keybindings`, the
enable-set broadcast, or module-declared placements. Authoring-guide sections that cover the same
surface for module authors: "Persisting module settings", "Placing effects on a player's behalf"
and "Contributing a guided tour" in `docs/site/guides/creating-a-module.md`.

## Activation result and status

- `ModuleRegistry.activate()` returns `ModuleActivationResult { outcomes }`, one
  `ModuleActivationOutcome` per module the pass processed (`"activated"`, `"skipped-deps-unmet"`,
  `"failed"`); the same events are still logged.
- `WorldSession` folds every pass into `moduleStatus` (`SvelteMap<string, ModuleStatusEntry>`)
  through the single private `#reportModuleStatus`, which both `#loadExternalModules` and
  `reconcileInstalledModules` call, and which also runs for the first-party pass. A load failure
  (`ModuleLoadResult.failed`) has no activation outcome, so its entry is keyed on the install
  FOLDER id with status `"load-failed"`; an activation problem is keyed on the registry id. A later
  clean pass deletes the entry. Each problem is also forwarded to `opts.onModuleStatus`, which the
  shell turns into a toast through `notifications.push`.
- `AppContext.moduleStatus` is the live map, not a copy; `ModuleManager` renders its status lines
  from it and re-renders as passes land.

## Compatibility, conflicts and the satisfiability preview

- `InstalledModuleInfo.engine_compat_ok` is the server's `engine_compat_ok` verdict, computed
  per module on every list response and fail-closed. The client never recomputes it.
  `ModuleManager` disables the checkbox of a module that is both incompatible and not currently
  enabled. An enabled-but-incompatible module stays uncheckable-away on purpose: if it were forced
  off by the UI the GM could never save, because the server rejects any batch that names an
  incompatible module.
- `set_world_enabled_modules` collects conflicts in the same `Vec<String>` as the other per-entry
  failures. A module's `conflicts` manifest member names install-FOLDER ids; the check covers either
  listing order and ignores a conflict with a module outside the requested set. `declared_conflicts`
  reads the raw manifest and fails open (absent, non-array or non-string entries contribute nothing),
  the scanner's posture for optional members it does not validate. The client `ModuleManifest`
  carries `conflicts` in its Zod shape.
- `checkSatisfiability(candidateIds, catalog, running)` is the client's advisory preview with the
  same all-issues-at-once shape as the server rejection (`SatisfiabilityIssue.kind`:
  `dependency-unmet`, `contract-unmet`, `conflict`). **Two id spaces:** `dependencies` match on
  MANIFEST ids (as `ModuleRegistry.activate` does), `conflicts` match on FOLDER ids (as the server
  does). The third parameter is the manifests already running outside the catalog (first-party
  modules), read through `ModuleRegistry.activeManifests` / `WorldSession.activeModuleManifests` /
  `AppContext.activeModuleManifests`; they satisfy dependencies and contracts unconditionally, and
  one whose id matches a catalog entry is ignored because the candidate set decides that module.
  `ModuleManager` shows the issues and disables Save while any exist. The server stays the
  authority; the preview is never the gate.

## Enable-set change broadcast

After persisting the set and the config reseed, `set_world_enabled_modules` calls
`broadcast_aux(ServerMsg::ModulesChanged)` on a live room, whether or not the reseed succeeded. It
carries no `seq` (it is not a document event). `WsClientHandlers.onModulesChanged` makes
`WorldSession` run `reconcileInstalledModules`, so a second connected client follows the GM's save
without a reload. With no live room nothing is sent; the next join loads the stored set.

## Module-scoped settings

- World-scoped values live in the world's `module-settings` config singleton
  (`MODULE_SETTINGS_DOC_TYPE`, one of `CONFIG_SINGLETON_DOC_TYPES`): one opaque `system`-band slice
  per module id, GM-writable by default. `ModuleContext.settings.getWorld` reads it
  (`readWorldModuleSettings`); `setWorld` builds one Update (`buildWorldModuleSettingsUpdate`) and
  sends it through `Deps.dispatchIntent`. It resolves when the intent is dispatched, not when the
  server accepts it: a server capability rejection arrives through the ordinary rejected-intent
  rollback path.
- User-scoped values are the account's `ui_state.modules.<moduleId>` namespace, held by
  `UserModuleSettings` (`getUser` is a snapshot of loaded state refreshed by the module's own
  `setUser`). `modules` is one of the server's `PER_ID_NAMESPACES`, so patches merge per module id.
  The UI-state REST helpers (`getUiState`/`putUiState`) live in core's `user-rest`.

## Keybindings

`ModuleContext.keybindings` wraps `KeybindingsController`, a core singleton that owns the window
keydown listener and emits the `core:keydown` hook (`KEYDOWN_HOOK`). Auto-repeat and
editable-target keystrokes never reach the hook. Two bindings on one combo resolve to the lower
registration order. User overrides (`"<moduleId>:<bindingId>"` to combo, `null` = unbound) are kept
even for a binding that is not registered right now, are persisted in the account's UI state, and
are loaded with `loadOverrides`. `ModuleRegistry.unload` calls `KeybindingsController.removeModule`,
so a module's bindings go with it. There is no reserved-combo blocklist.

## Module-declared placements

A manifest `placements` array declares effects a client may ask the server to place
(`PlacementDecl`, server-held, `deny_unknown_fields`; an invalid or duplicate declaration is dropped
at scan with a warning, the module still loads). The effect set (`behavior`, `cost`, `triggers`,
`elevation`) comes only from the declaration; a request supplies the area, scene and caster.

- Wire: `ClientMsg::PlaceEffect` handled by `Room::place_effect` (resolves the declaration from the
  world's enabled, engine-compatible modules) then `Room::place_declared` (authorization,
  validation, commit). Success is the broadcast Create; refusal is `ServerMsg::PlaceEffectError`,
  correlated by `request_id`. Client: `WsClient.placeEffect` (resolved by silence on success, like
  the door toggle), `WorldSession.placeEffect`, `AppContext.placeEffect`.
- Authorization: `PlacementWho` is `gm`, `player` or `caster_owner`; a GM always passes, a
  spectator never. `caster_owner` needs a caster token on the request's scene that the sender
  effectively owns (`SceneEcs::token_scene_and_effective_owner`). The area is clamped by
  `PlacementDecl::admits` (shape kinds, `maxExtent`), then `RegionEngine::validate`.
- Range: `maxRangeCells` makes a non-GM request name an owned caster even for `who = player`;
  distance is `euclidean_span_cells` from the caster to the area's bounding-box centre at the
  scene's `world_units_per_cell`, inclusive; a GM naming no caster is unlimited
  (`Room::check_caster_range`, `PlaceEffectError::OutOfRange`).
- Expiry: `durationSecs` (1 to `MAX_PLACEMENT_DURATION_SECS`) stamps
  `PLACEMENT_EXPIRES_AT_KEY` into `system.placement`. `spawn_placement_expiry_sweep` (started in
  `http::serve_with`, one tick per `PLACEMENT_EXPIRY_PERIOD` over `RoomRegistry::live_rooms`) calls
  `Room::expire_due_placements`, which deletes due regions (`due_placement_regions`) authored as the
  world's seed author. The stamp is persisted, so a region that expired while the server was down is
  removed on the first sweep after its room exists; a world with no GM member removes nothing.
- Disclosure: every `PlaceEffectError` displays "placement rejected" to a non-GM, so a reply never
  reveals whether a module, declaration, scene or token exists; a GM gets the variant text
  (`place_effect_wire_message`).
- Write path: `WriteOrigin::ModulePlacement` is server-authored and skips the capability gates, but
  keeps scope, size, engine validation and OCC. The region has `owner = None`, parent = the scene,
  and `system.placement { module, id, by }`. Per-user rate budget is the shared
  `MESSAGE_RATE_PER_MIN`.
