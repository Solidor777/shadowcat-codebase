# Stage module, scene-tools, explored-fog client seams, multi-scene viewing and client footprints

Part of the shadowcat-codebase-scene-rendering skill; read it before changing src/modules/stage, src/modules/scene-tools, scene-docs, viewed-scene resolution or client footprint readers.

- `Stage` (`src/modules/stage`) — mounts the render engine over a `ReadableDocuments` view.
- `src/modules/scene-tools/` — the `controller` + `hit-test` modules, tools (place/select/move/
  draw/template/measure/ping/wall/region/light) dispatching intents. Wall tool writes a **three-flag**
  segment: `blocksSight` + `blocksMove` + `blocksLight`. **Light + wall authoring:** `makeLightTool`
  places a `light` doc with `DEFAULT_LIGHT_EMISSION`, click-selects and drag-repositions with
  raw-stored OCC pre-images; the select tool picks a light marker (`LightView`, drawn on the walls
  layer for any doc recipient) or a wall segment into `ToolController.editingEntity`, and
  `ToolRail` renders the light editor (enabled/color/intensity/radii/falloff/elevation/delete,
  via the shared `LightEmissionEditor`) and the wall editor (`blocksSight`/`blocksMove`/
  `blocksLight`, the occlusion-band interval, delete). Editing is GM-gated at the tool layer and
  re-checked by the server. Region tool (`makeRegionTool`) drags out
  a rect/circle/polygon `region` doc (`ToolController.regionShapeMode`/`regionBehavior`/
  `regionCost`/`regionCostByTag`/`regionSecret`/`regionTriggers` reactive fields) via `buildRegionDoc` +, when `regionSecret`,
  `setRegionVisibility(doc, true)` (declares `/engine` `gm_only` at construction — not
  `/system`; the create op never carries the geometry in the clear). Create-only, mirroring
  `makeWallTool`: no edit UI for an already-placed region's behavior/cost/visibility/`enabled` — a
  GM re-authors via delete+recreate, or the server's live `enabled` toggle (region_field already
  honors it) without a UI surface. **Per-movement-tag terrain cost authoring:**
  `ToolController.regionCostByTag` holds staged `RegionCostByTagRow` rows (`{tag, cost}`);
  `ToolRail` renders the row editor (`data-testid` `region-cost-by-tag-row`/`-tag`/`-cost`/
  `-remove`/`-add`) only while `regionBehavior === "terrain"`, with the flat `regionCost` staying
  the fallback for a mover matching no row. The module-private `regionCostByTagRecord(controller)`
  is the ONE function folding the rows into `RegionEngine.cost_by_tag` (blank tag dropped, each
  cost through `clampRegionCost`, the same `>= 1` floor with `NaN` floored to 1 that the flat cost
  and the server's `SceneEcs::region_field_if` apply), and BOTH region-persist paths call it —
  `makeRegionTool.onPointerUp` and `ToolController.commitRegionParts` — so a row list never
  becomes a record two different ways. The generated `RegionEngine` type declares `cost_by_tag`
  as a REQUIRED member (the Rust field is `serde(default)`, but ts-rs emits it non-optional), so
  every hand-built client `RegionEngine` literal, including test fixtures and the `buildRegionDoc`
  argument, must carry it (`{}` for none). `buildRegionDoc`/`setRegionVisibility`/`RegionEngine`/
  `RegionShape`/`RegionShapeKind`/`RegionBehavior` are exported from `@shadowcat/core`'s public
  entrypoint module (the client type is `RegionEngine`, not `RegionSystem` — no
  back-compat alias; the entrypoint's export list is written by hand, so any future `scene-docs`
  addition needs its own export line — it is not automatic). **A newly ts-rs-generated Rust type
  needs an UPSTREAM hand-written re-export before that entrypoint line can even exist**:
  `src/types/index.ts` (the `@shadowcat/types` barrel) exports each generated binding by name
  (`export type { AmbientLightMode } from "./generated/engine/AmbientLightMode"`) — nothing
  imports `src/types/generated/**` directly, so a type absent from this barrel is unreachable
  from every client package regardless of any other export line. `scene-docs`'s own import
  block and `@shadowcat/core`'s entrypoint module (above) are two FURTHER, separate hand-written
  steps on top of it — three re-export lines across three files for one new generated type
  (`AmbientLightMode`/`AmbientLightOverride` needed all three), none of them automatic.
  **Region behavior gains a THIRD authoring mode, `"ambient_light"`** —
  `RegionBehaviorMode = "terrain" | "impassable" | "arrest" | "ambient_light"`
  (`ToolController`) — with conditional mode/level inputs (`ToolRail`'s
  `data-testid="region-ambient-mode"`/`"region-ambient-level"`, shown only when
  `controller.regionBehavior === "ambient_light"`) bound to `ToolController.regionAmbientMode`/
  `regionAmbientLevel`. The module-private `regionAmbientOverride(controller)` is the ONE
  function building `RegionEngine.ambient_override` (`null` unless `regionBehavior ===
  "ambient_light"`, else `{mode, level}` from those two fields) — it is what keeps the client
  from ever authoring the combination `RegionEngine::validate` rejects server-side — a present
  `ambient_override` paired with a `behavior` other than `"ambient_light"`. **Both region-persist paths route
  through it**: the single-shape flow (`makeRegionTool.onPointerUp`) and the compound-parts
  commit (`ToolController.commitRegionParts`) each call `regionAmbientOverride(this/controller)`
  when building their `RegionEngine` body — never re-derive the mode/level pairing inline at
  either site, or the forked-decision defect this shared helper exists to close reopens between
  the two authoring flows.
- `scene-docs` (`src/client/core/src`) — **vision/lighting/movement data model: the server mask
  consumes these shapes; the client lighting render (see `lighting` in references/client-fog-sweeps-lighting-perf.md) is display-only**:
  world-scoped config-docs `world-settings`/`light-gradation`/`vision-modes`
  (builders + deep-frozen MIRRORS `DEFAULT_WORLD_SETTINGS`/`DEFAULT_GRADATION`/`SEED_VISION_MODES`
  of the server's engine-literal/seed definitions — the server seeds every config singleton; the
  gradation/vision builders `structuredClone` the frozen default, while `buildWorldSettingsDoc`
  defaults to the EMPTY overlay), per-scene `SceneSystem.vision?`/`lighting?`
  overrides + `grid.distance?` + `bounds?`, the scene-parented `is_engine_doc_type::light` doc_type
  (`LightEngine` + `buildLightDoc`), and the fail-closed resolvers `resolveSceneSettings`/
  `resolveGradation`/`resolveVisionModes`. **`bounds`:** `SceneDimensions {width,
  height}` (grid units) — the navmesh's triangulation boundary; per-scene ONLY, no
  world-settings layer; `resolveBounds` (private helper called from `resolveSceneSettings`) falls
  back to the deep-frozen `DEFAULT_SCENE_BOUNDS = {width:100,height:100}` on absent OR malformed
  (non-finite/≤0-on-either-axis) input — never a degenerate rectangle, never throws. Authored by
  `src/modules/game-settings/` (see `shadowcat-codebase-client-shell`).
- **Explored-fog client seams (pooling mode + GM reset).** `FogPooling` is mirrored client-side:
  `DEFAULT_WORLD_SETTINGS.scene.fogPooling` is `"individual"`, `resolveSceneSettings` resolves
  `ResolvedSceneSettings.fogPooling` through the same scene-override > world > system-defaults > default
  order as the server's `SceneEcs::resolve_scene`, and the settings-provenance resolver carries a
  matching scene.fogPooling case. `GameSettingsPanel` authors it twice: a world-level select
  dispatching `/engine/scene/fogPooling`, and a per-scene override select dispatching
  `/engine/vision/fogPooling` whose blank "inherit" option writes `null`; both follow the
  raw-stored-value `old` rule in references/grid-pathfinding.md. The same panel's `data-testid="reset-explored-fog"` button
  calls `AppContext.resetExploredFog(scene.id)` with NO scope, so it only ever sends the
  scene-wide reset (the `user`/`level` narrowing in `ResetExploredFogOptions` has no panel
  surface, and a `user`-scoped request on a `Shared` scene is refused server-side — see the
  `scene::explored` bullet). `AppContext.resetExploredFog` is a fire-and-forget GM-only intent:
  the shell's AppContext construction binds it to `WorldSession.resetExploredFog`, which forwards to
  `WsClient.resetExploredFog`; a refusal surfaces through the generic error handler and there is
  no local state to update, because every connection re-derives its `"vision"` payload on the
  server's `ExploredFogReset` broadcast (`shadowcat-codebase-realtime-sync` owns that frame's
  wire mirror). `setAppContextForTest`'s fixture defaults `resetExploredFog` to a no-op, so a
  spec asserting the call passes its own spy.
- **Multi-scene viewing / GM local roam.** `resolveViewedScene(store, {gmViewedScene?})`
  (`scene-docs` module) is the single client-side answer to "which scene does THIS client render/
  subscribe to". Resolution order: a resolvable `gmViewedScene` (GM-only local override) → a
  resolvable `world-settings` `activeScene` (`WorldSettingsEngine.active_scene`, an overlay
  leaf like every other world-settings member — absent means unset, no structural requirement)
  → the first scene (legacy single-scene fallback) → `null` only when no scene exists
  at all. Fail-closed by construction: an id naming a scene that no longer exists is treated as
  unresolvable and skipped to the next tier, never rendering nothing while scenes exist and never
  leaking a stale scene's channel. `WorldSession.viewedSceneId` (the `worldSession` module) is the
  live getter (`resolveViewedScene(this.#optimistic, {gmViewedScene: role==="gm" ?
  this.#gmViewedScene : null})`); `setGmViewedScene(id)` sets the GM-only `#gmViewedScene` $state
  (warns + no-ops for a non-GM), and also scene-scopes `tokenSelection`: it stashes the live
  `TokenSelection`'s ids into `WorldSession`'s private `#tokenSelectionByScene` map (keyed by the
  scene being left, read via `viewedSceneId` before the switch) and restores whatever was stashed
  for the scene being entered (empty if never visited) — a GM roaming away and back keeps their
  selection instead of leaking it across scenes or losing it. `sendPing`/`sendEmote`,
  `onMoveStream`, and the `scene_ping`/`emote` handlers all
  resolve through `viewedSceneId` (not a fixed `query("scene")[0]`) and drop a frame whose `scene`
  doesn't match — closing a cross-scene leak (see Gotchas). The `scene-scope` module (client/render)
  — `sceneScopedDocs(store, docType, viewedSceneId)` filters a doc-type query to `d.parent_id ===
  viewedSceneId()`, or returns the unfiltered list when `viewedSceneId()` is `null` (the
  degenerate pre-scene case). `RenderEngine` takes `RenderEngineOpts.viewedSceneId?:
  () => string | null` and exposes a private `viewedScene` resolver (falls back to
  `store.query("scene")[0]?.id` when unset — legacy/test callers unaffected); every render-layer
  view (`token-view`, `wall-view`, `drawing-view`, `template-view`, `region-view`)
  and `reconciler` take a trailing `viewedSceneId: () => string | null = () => null`
  constructor param and filter through `sceneScopedDocs`. `RenderEngine.reapplyViewedScene()` is
  the client-local-switch seam: a scene switch (`activeScene` flip or GM roam) carries no new
  server frame, so it re-runs every view's `reconcile()` (their `parent_id` filter target changed)
  and re-filters the last cached vision payload against the newly-current scene. `Stage`
  passes `viewedSceneId: () => ctx.viewedSceneId` into the engine and a `$effect` watches
  `ctx.viewedSceneId`, calling `engine.reapplyViewedScene()` exactly once per change.
  The scene-tools `controller` module's private `activeScene(ctx)` helper resolves through
  `ToolContext.viewedSceneId?.()` before falling back to the first scene — every doc-creating tool
  (place/wall/region/drawing/template) stamps `parent_id` onto the viewed scene, not always the
  first one.
- **Client-side footprint consumption — every seam is a READ of the `\"footprints\"` channel.**
  `@shadowcat/core`'s `footprints` module owns `FootprintExtent`, `FootprintLookup`
  (`token(id)`/`unit(sceneId)`, each `null` when the server has stated nothing),
  `parseFootprints(payload)` and `EMPTY_FOOTPRINTS`. A payload that fails the Zod schema yields
  `EMPTY_FOOTPRINTS` rather than a partial read — mixing authoritative extents with silently
  dropped ones is indistinguishable to a caller.
  - **`WorldSession` owns the subscription, not the render engine** — the extents feed the canvas,
    the hit-test and the place tool, so they belong beside the document view
    all three read. `AppContext.footprints` is the getter; `RenderEngineOpts.footprints?: () =>
    FootprintLookup` (→ `TokenView`) and `ToolContext.footprints?` (→ `footprintsOf(ctx)`, used by
    `topTokenAt`, the select/move drag and the place tool) both read it through Stage/ToolRail.
    `enter()`'s `subscribeScene("footprints", …)` runs before the socket is up and that first
    attempt is dropped; `#onWelcome` re-establishes it, and `leave()` unsubscribes and resets to
    `EMPTY_FOOTPRINTS` so a second world cannot inherit the first's extents.
  - `resolveTokenBox(token, store, footprints, eff?)` is a pure reader: `w: resolved?.w ?? eng?.w
    ?? 0`. `buildTokenFromActor(..., unit: FootprintExtent | null, id?)` stamps the scene's
    server-resolved unit extent onto a token it creates, rather than deriving one — the standing
    extent until that token's own arrives, and permanently for a token no actor sizes.
  - **`RenderEngine.reapplyFootprints()` joins `reapplyViewedScene()` as a client-local
    re-projection entry point**: a footprints frame carries no store commit (the server recomputes
    derived channels on a debounce AFTER the event that changed them), so without it the canvas
    keeps drawing the previous extents until an unrelated commit. Tokens only — no other view reads
    a footprint. `Stage`'s `$effect` watches `ctx.footprints` alongside `ctx.viewedSceneId` and
    calls it exactly once per genuine change.
  - **`RenderEngine.reapplyTokenSelection()` is the same shape for token SELECTION.** Selection is
    client-local UI state (`RenderEngineOpts.selectedTokens?: () => ReadonlySet<string>`, fed
    `ctx.tokenSelection.ids` by `Stage` and read by `TokenView` at `toSpec` time), so a selection
    change carries no store commit and the selection highlight fx would lag behind the click until
    the next unrelated one — the re-projection call just re-runs the token view's `reconcile()`
    (tokens only, exactly as `reapplyFootprints`). `Stage`'s `$effect` diffs a sorted key of the
    ids and calls it exactly once per genuine membership change.
  - **Deliberately NOT behind the `appliedSeq` watermark that guards `vision`.** That watermark
    exists because fog is the client's secrecy gate; an extent is a rendering quantity with no
    confidentiality stake, and holding it back would delay a purely cosmetic correction. If a
    future field on this channel ever carries a secrecy stake, that decision has to be revisited —
    it is a property of the payload, not of the channel.
  - Cost of the seam, by design: a freshly placed actor-backed token draws at the scene's unit
    footprint for one round trip, until its own resolved extent arrives.

