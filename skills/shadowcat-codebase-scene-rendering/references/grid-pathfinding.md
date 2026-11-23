# Grid A* pathfinder, movementModel and snapToGrid

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::pathfinding, SceneEcs::pathfind, the movementModel axis or the snapToGrid axis.

- `scene::pathfinding` — pure, headless grid A* (no I/O; clean-room):
  `DiagonalRule` (`chebyshev`|`manhattan`|`euclidean`|`alternating`) + `resolved_diagonal_rule`
  (world-only — no per-scene override; mirrors `resolveSceneSettings` precedence);
  `PathInputs` (the caller-supplied routing environment: `footprint_radius_cells`, `cell`, `walls`
  built from `move_walls`, `mask`, `regions`, `shape`) and `PathGrid { inputs: PathInputs, window }`,
  which HOLDS a `PathInputs` rather than restating its fields — `window` is the `find`-derived
  unbounded-wander bound, not a caller input, which is why it sits outside `PathInputs`;
  `cell_enterable(grid, from, to)` — four checks, ALL must
  pass: (1) footprint-disc-vs-wall clearance (the token's bounding disc must clear ALL `blocksMove`
  segments, via `point_segment_distance`); (2) **mask** — every cell in `footprint_cells(to,...) ∪
  grid.inputs.shape.line_traversal(cell_center(from), cell_center(to), cell)` must be in the non-GM mask
  (the union is required — the footprint disc at the destination alone misses a diagonal
  step's corner-flanker cells for sub-0.5-cell footprints, so the router would approve a step the
  executor rejects; `None` from `line_traversal` fails closed); (3) center-to-center
  step crosses no wall (`segments_cross`); (4) `RegionField::is_arrest`/impassable check via
  `PathGrid.inputs.regions: Option<&RegionField>` (see below; a `None` grid field means "no region enforcement",
  distinct from an empty `RegionField`). `astar_leg` — king-move A*, 4 diagonal
  rules, 5-10-5 parity tracked in the `(cell, parity)` node and carried across waypoint legs (cost
  1,2,1,2…, never reset per leg), admissible+consistent heuristics per rule, stale-pop skip,
  `MAX_PATH_NODES`/`MAX_WAYPOINTS`/`MAX_FOOTPRINT_CELLS` fail-closed bounds; **Terrain
  weighting:** each iteration of `astar_leg`'s neighbor loop multiplies the diagonal-rule base cost
  (`astar_leg::sc`, the per-neighbour cost VALUE the `for (next, sc, next_parity) in
  grid.inputs.shape.neighbors_with_cost(...)` binding yields — not a function) by
  `terrain_cost(grid.inputs.regions, next, &grid.inputs.traits)` — the ONE terrain-cost read
  (`regions.map_or(1.0, |r| r.resolved_terrain_multiplier(next, &traits.tags))`, the mover's
  tag-resolved multiplier, or a constant 1.0 for an `MoveTraits::ignore_terrain` mover) — so a
  terrain region raises (never lowers — flat and per-tag costs are clamped to at least 1.0 in
  `SceneEcs::region_field_if`) the A* edge weight
  into that cell, honored by the admissible/consistent heuristic (which already lower-bounds the
  UNWEIGHTED cost, so remains admissible under any `>=1.0` weighting, and equals an exempt mover's
  cost exactly). `find` — validates
  request, computes search window (AABB{start∪waypoints∪wall-endpoints}+8-cell margin), threads
  end-parity of each leg into the next, sums cost, returns ordered cell-center scene coords, THEN
  applies **arrest truncation**: cuts the assembled route at the first cell (after the
  start — a token already standing in a cell is not "entering" it) flagged `is_arrest` in the
  region field, sets `arrested: true`, and recomputes the truncated `cost` by REPLAYING the
  per-step cost over the surviving prefix from parity 0 through the ONE shared helper
  `replay_step_costs` — the budget truncation consumes the same helper, so a pricing fix cannot
  land in one replay and not the other (a cost-replay technique, not trusting `astar_leg`'s
  per-leg running total, because parity threading is purely sequential/order-dependent —
  replaying reproduces the exact cost the original per-leg accumulation would give for that same
  prefix) — like the rest of `find`, the replay never calls the private `step_cost` fn directly;
  `replay_step_costs::sc` is the per-neighbour cost VALUE `neighbors_with_cost` yields for each
  iterated pair, not a function of its own. Returns
  `PathOutcome { path, cost, arrested, truncated }`. This truncation exists so a
  player-facing route preview is honest about a hazard it already knows about — it never shows a
  route running past an arrest cell the requester can see.
  `SceneEcs::pathfind(requester: RouteRequester, scene, start, waypoints, mover: RouteMover)` —
  `RouteRequester` describes the REQUESTER ONLY (`user`, `is_gm`, `explored`); the route itself
  stays in `pathfind`'s own parameters, and `RouteMover { footprint_radius, budget_cells, traits }`
  carries the MOVER's request-scoped quantities (resolved once by `handle_pathfind`, mirroring
  `move_exec::MoveGateInputs`'s `budget`/`traits`). `RouteMover::budget_cells` is the
  movement-budget preview clamp: the grid engine cuts inside `pathfinding::find` by per-step
  replay, the walls-only continuous engine via `navmesh::truncate_at_budget`'s span cut, and
  EVERY budget-boundary comparison — both cuts and `execute_move`'s own stop — runs through the
  ONE predicate `pathfinding::budget_admits_step`, so the preview and the executor cannot
  disagree at the boundary by an epsilon only one of them applies. `handle_pathfind` resolves
  the clamp through `budget_gate_for_token` + `resolve_budget` (the executor's own gate) for a
  named, authorized token; refusals reuse the generic wording, and `PathResult.truncated`
  reaches only the requester of their own preview. It builds a `PathInputs` and passes it to
  `pathfinding::find`. **`pathfind`'s route parameters and the wire-side `PathfindRequest` are
  deliberately NOT unified into one type** even though `scene`/`start`/`waypoints`/
  `footprint_radius` coincide: `footprint_radius` is a client hypothetical on the wire and the
  token-derived authoritative value here, because `handle_pathfind` REPLACES it via
  `SceneEcs::resolve_token_footprint` whenever the frame names a token. A shared type would let a
  caller forward the frame straight through and skip that override — a token-size oracle. Do not
  "simplify" these into one type.
  It reuses the SAME `visible_cells` mask as the movement gate (**the
  invariant: never fork the per-cell visibility decision** — the route cannot thread the unknown nor
  leak hidden geometry); unions `explored` (`ExploredSet::iter`) for `revealed`; GM unconstrained
  (no mask); empty non-GM mask ⇒ `PathError::Unreachable` (fail-closed); passes
  `ecs.region_field(scene, if is_gm { None } else { Some(user) })` — the PER-REQUESTER field (a
  non-GM's route/budget silently omits a region they cannot see; the secret region only "springs"
  later, at `move_exec`, which always reads the authoritative field — see `region_field` above).
  `SceneEcs::move_walls(scene, viewer: Option<Uuid>) -> Vec<vision::Seg>` is a **two-value
  contract, never a third mode, mirroring `region_field` exactly**: `None` is AUTHORITATIVE (every
  `blocksMove` segment, used by `execute_move` and by GM requesters); `Some(user)` is the
  PER-REQUESTER view used by the router — a wall is included only when `user` can see the
  visibility tier declared on its `/engine`, through the SAME `engine_tier_visible` wrapper
  `region_field` calls (no new secrecy machinery). Callers MUST pass `None` for a GM requester, exactly as `region_field`
  requires. `pathfind` computes it once (`move_walls(scene, if is_gm { None } else { Some(user) })`)
  and passes the same slice into both engines; `navmesh_for`'s memo key incorporates the
  requester's exact wall-set bit-pattern (not merely "filtered vs unfiltered"), since two
  requesters can see two different wall subsets. **Vision and lighting keep the FULL wall
  set and must never be unified with routing:** `SceneEcs::sight_walls`/`SceneEcs::light_walls` (the
  full-wall-set invariant) deliberately include `gm_only` walls — a wall you cannot see still
  blocks your sight, which under-reveals and is correct — while `move_walls(scene, Some(user))`
  omits exactly those same walls from a non-GM's ROUTE so its geometry isn't leaked through route
  shape. These are two independent wall-visibility axes serving opposite purposes on the same
  underlying wall set; a `gm_only` wall always springs at `execute_move` regardless of what the
  router's per-requester set showed. Wire frames `Pathfind`/`PathResult` (`{path, cost, arrested, truncated, budget_cells}` —
  `cost` is in CELLS on every movement model, which the client scales by `grid.distance.perCell` for
  display; `arrested` is always disclosed to the requester, no secrecy concern: it only tells them a
  route THEY could already see is truncating, and `truncated` likewise reaches only the requester's
  own budget-clamped preview; `budget_cells` is the mover's REMAINING movement budget in cells
  under an enforced combat — `None` for a hidden combatant, a non-combatant token, or an
  unresolvable resource binding — computed by the SAME `combat::budget::resolve_movement_budget`
  resolution (`MovementBudget::cells`, through `combat::budget::resource_cells`) the
  movement-budget gate's truncation ceiling and the `"combat"` channel's `movement_cells` use, so
  a route preview's disclosed number, the executor's own clamp and the tracker's number cannot
  drift apart; scene-tools' `requestRoute` labels a `Warn`-enforcement overage or a `Hard`
  truncation on the drawn route through `ToolContext.t` — REQUIRED, no English fallback copy of
  the catalog — and `ToolRail` builds its `ToolController` argument `satisfies HostToolContext`,
  every `ToolContext` member that also exists on `AppContext` made mandatory, so a host seam
  (`t`, `moveRequest`, `combat`, …) cannot be left out of that literal without a type
  error)/`PathError` — one-shot to the requesting connection only
  (never broadcast); `get_explored` fetched off the scene read lock (no lock across await).
  `Pathfind` also carries an optional `token: Option<Uuid>` (`ws::protocol`): when present
  the server AUTHORIZES it (effectively owned by the requester AND parented to `scene` — the same
  ownership rule used elsewhere, never a forked check) and DERIVES the footprint from that token's
  document via `resolve_token_footprint`, IGNORING any wire `footprint_radius` — so a route preview
  and the authoritative gate cannot disagree about the mover's size. The named token is NOT a
  presence proof: non-GM scene presence remains the separate effective-ownership scan
  `handle_pathfind` already performs, which naming a token neither replaces nor satisfies (it
  strengthens that check by requiring the SAME token to be owned-and-parented, rather than adding a
  second one). When `token` is absent, the wire `footprint_radius` is honored and the result is an
  explicitly hypothetical preview with no preview-equals-execution guarantee.
  Client: `ToolContext.pathfind?` seam + `SceneTool.onDeactivate?()` hook in scene-tools (clears
  the tool's overlays and retires in-flight previews on a tool swap, but DETACHES rather than
  cancels an in-flight route commit — see the measure-tool commit bullet in Gotchas); ruler `Grid.distance()` gains the `alternating` (5-10-5) rule wired
  from `resolveSceneSettings(...).diagonalRule` into the Stage `GridSpec`.
- **`movementModel` axis**: a per-scene/world-default routing-engine choice
  (`MovementModel::{GridStepped,Continuous}` server-side, `MovementModel = "grid-stepped" |
  "continuous"` client-side), resolved by `resolve_scene`/`resolveSceneSettings` with the EXACT
  same shape as `movement_restriction`/`MovementRestriction` (world default in
  `WorldSettingsEngine.scene` at `/engine/scene`, a per-scene override in `SceneEngine.vision` at
  `/engine/vision`, fail-closed to `GridStepped` on unknown/absent — never silently promotes a
  scene to the newer engine). Both `MovementModel` and `MovementRestriction`
  are typed `engine`-band fields, ts-rs exported (`data::engine::scene`) — neither is opaque
  `system`-body JSON; do not assume
  either enum is untyped. `SceneEcs::pathfind`
  dispatches on `resolve_scene(scene).movement_model`: `GridStepped` calls the unchanged
  `pathfinding::find`; `Continuous` calls `navmesh_for` → `navmesh::navmesh_find` →
  `navmesh::clip_to_visible_mask` (in references/navmesh-router.md). Both branches build the per-`(user,scene)` visibility
  mask ONCE, above the dispatch, and pass the SAME reference into whichever engine runs — never
  forked (mirrors the pathfinder's own mask invariant, generalized to a second engine). Client:
  `movementModel` world-default + scene-override editor in `GameSettingsPanel` (mirrors the
  `movementRestriction` editor exactly). The measure-tool's
  `commitRoute` (the scene-tools `controller` module) does not branch on `movementModel` at
  all — committing a route proceeds identically for grid-stepped and continuous scenes, because
  the server move-execution path (`execute_move`/`gate_walk`/`sample_path`/the egress clip) is
  fully engine-agnostic: no `movementModel` branch anywhere in that path means nothing
  engine-specific needs gating at the client. `requestRoute` (the preview path) is unaffected —
  no grid-snap fallback, silent no-op on double-click.
- **`snapToGrid` axis (the `scene-docs` module)**: `SceneEngine.snapToGrid?:
  boolean` (typed `engine`-band field, ts-rs exported — not opaque `system`-body
  JSON; mirrors `movementModel`/`bounds`'s field shape).
  `resolveSceneSettings` resolves a DERIVED DEFAULT keyed off the already-resolved
  `movementModel`: `sys?.snapToGrid ?? (movementModel === "continuous" ? false : true)` — an
  explicit stored boolean (including `false`) always overrides the derived default in either
  direction via nullish-coalescing, never a truthy check (`false` is meaningful and must
  persist). Independent of `movementModel` (a deliberate design choice — an independent toggle
  rather than tying no-snap directly to the movement model — though the derived default preserves
  the original intent that a fresh continuous scene is free-form by default). **`RenderEngine.snap`
  chokepoint (the `engine`/`types` modules)**: `SceneToolHost.setSnapEnabled(enabled:
  boolean): void` interface member; `RenderEngine` carries a private `snapEnabled = true` field and
  gates `snap(p)`: `return this.snapEnabled ? this.grid.snap(p) : p`. This is the SINGLE
  enforcement point — every scene tool that calls `ctx.scene.snap` (place, select-move drag,
  measure-route waypoints, wall/region/template/draw tools) inherits the toggle automatically,
  since they all go through the same `AppContext.scene` bridge. Snap gating is independent of grid
  RENDERING — a snap-off scene may still display its reference grid; `setSnapEnabled` never
  touches `redrawGrid`/grid-line drawing. **Wiring:** `SceneInteractionBridge.setSnapEnabled`
  (the `sceneInteraction` module) forwards to the host, and no-ops when detached.
  **Detached behavior is NOT uniform across the bridge, despite every method being "safe" when
  unbound:** the void commands genuinely no-op, but the two QUERIES return plausible wrong VALUES
  — `snap` returns the point unchanged (identity) and `gridDistance` returns `0`. A caller that
  runs before bind gets an unsnapped position or a zero distance and cannot distinguish either
  from a real answer. The test double carries the same shape (the `fakeSceneHost` fixture module:
  identity `snap`, `gridDistance: () => 0`), so a test that takes the fixture defaults never sees
  the difference either — the fixture's own doc tells a test asserting snap/measure output to
  override those two. `Stage` pushes the resolved `snapToGrid` into the
  engine unconditionally on every document-subscription pass
  (`e.setSnapEnabled(settings.snapToGrid)`), placed OUTSIDE the grid-key change-detection gate that
  exists for `setGrid`'s more expensive Grid-object rebuild — a cheap flag write doesn't need that
  gate, and gating it behind that key would be a real bug since the key doesn't include
  `snapToGrid` and would silently freeze the pushed value. **Authoring:** a GM-only persistent toggle button in `ToolRail`
  (`data-testid="snap-toggle"`), reflecting the resolved `snapToGrid` via a reactive
  `createSubscriber`+`$derived.by` subscription to the document store (mirrors
  `FactionsPanel`/`GameSettingsPanel`'s pattern), dispatching a `/engine/snapToGrid` (not
  `/system/snapToGrid`) scene-doc update on click. **Load-bearing convention for any
  config-doc field-toggle editor:** the dispatched update's `old` field must read the RAW stored
  value (`scene.engine?.snapToGrid ?? null`), NOT the resolved/defaulted value — a hardcoded `old:
  null` breaks after the first
  successful write, since the server's field-level optimistic-concurrency check
  (`Repository::apply_intent`) rejects any subsequent `Update` whose `old` doesn't match the
  actual current stored value. `GameSettingsPanel`, `FactionsPanel` and `ConditionsPanel` carry the
  same rule for the same reason — always read the raw stored value for `old`,
  never the resolved/defaulted one, in any future editor of this shape. **Speak-as-token
  affordance:** `ToolRail` also carries a "speak as this token" button (`data-testid=
  "speak-as-token"`), visible only when exactly one token is selected AND the current user is GM
  or the token's effective owner (`ownerFloorApplies`, `@shadowcat/core`) — advisory-only client
  gating, since the server independently re-authorizes via `effective_owner_of` at send time. On
  click it sets `AppContext.speakAsToken`, a one-shot pending selection the composer consumes;
  see [[shadowcat-codebase-chat]] for the full seam. **Emote palette:** `ToolRail` also mounts an
  emote picker (stock glyphs plus a free-input draft, byte-length-checked client-side against the
  server's 16-byte bound so an over-long draft can't vanish into the server's silent drop) under
  the SAME one-selected-token ownership predicate as speak-as, sending via
  `AppContext.sendEmote`; the relayed echo (own sends included) renders through `onEmote` →
  `Stage` → `SceneToolHost.addEmote` → `RenderEngine`'s `EmoteView` (the `emote-view` module —
  a pure age-tracker: the glyph anchors above the token's position AT FIRE TIME and tracks
  nothing, rising and fading over its lifetime on the engine ticker, drawn via
  `DisplayBackend.drawEmotes`; a token id the viewer cannot resolve drops the overlay).
