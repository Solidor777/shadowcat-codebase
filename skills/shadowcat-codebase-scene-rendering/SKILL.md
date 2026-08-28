---
name: shadowcat-codebase-scene-rendering
description: "Use when touching Shadowcat scenes, the scene ECS, rendering, the PixiJS canvas/stage, vision raycasting, fog of war, lighting, the server visibility/lit mask, movement restriction (the Room::publish move gate, supercover, visible_cells), token footprints (the single `scene::footprint` definition, `resolve_token_footprint`, the `\"footprints\"` derived channel and its client readers `FootprintLookup`/`resolveTokenBox`/`reapplyFootprints`), the grid A* pathfinder (`SceneEcs::pathfind`, Pathfind/PathResult frames, diagonal rules), the continuous/navmesh router (movementModel axis, polyanya, the navmesh cache, `clip_to_visible_mask`), streamed continuous vision (MoveStream, `player_vision_polygons_at`, the per-recipient egress clip, client fog-sweep/cross-fade playback), regions (weighted/impassable/arrest zones, region docs, the `region-view` render layer), multi-scene viewing (viewedSceneId, resolveViewedScene, world-settings.activeScene, GM local roam, the `scene-scope` module), or scene-tools (place/select/move/draw/template/measure/ping/wall/region). Covers src/server/src/scene, src/client/render, src/modules/{stage,scene-tools}. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Scene & Rendering

Orientation for the server scene ECS + vision/fog and the client PixiJS render layer + scene-tools.

## Purpose

Scene/runtime state is **derived** from documents into a per-world ECS (ephemeral). The server
runs engine-owned geometry (movement-collision, per-player vision); the client renders the
**optimistic** document view through an engine-owned PixiJS layer, with interactive tools.

## Key files & seams

- `scene` — `SceneEcs` (derived read-model, hydrated from documents + the
  config-doc/actor side-tables `world_settings`/`gradation`/`vision_modes`/`actors`, set via
  `set_world_config`/`set_actors` and maintained by `apply_op`),
  `compute_derived(channel, ecs, ctx, world_defaults)` (builds derived frames; the `vision` masked
  payload is `{mode, polygons, bands, lit}`, and `\"footprints\"` is the second per-recipient channel
  — see the derived-channel egress bullet below. `world_defaults:
  &data::document::WorldCapDefaults` is what lets a channel resolve READ against the same
  world-level grants the document stream does; both `egress_loop` call sites already hold it),
  `player_vision_polygons(user_id)`, `player_lit_mask(user_id)` (the lighting-aware mask →
  `LitScene` cells), and the fail-closed server resolvers `resolve_scene`/`resolved_bands`/
  `resolved_vision_modes`/`token_vision_floors` (mirror the `scene-docs` module's + `resolveTokenActor`'s
  precedence) plus `scene_lights`/`light_walls` accessors. `resolve_scene` also yields `bounds:
  (f64,f64)` (`width,height` in grid units), read from the typed `eng::SceneEngine.bounds` via
  `engine_as::<T>(doc)`, the module-local typed accessor (see below) — no scene reader uses a raw
  JSON-pointer walk; non-
  finite or ≤0-on-either-axis falls back to
  `DEFAULT_SCENE_BOUNDS_UNITS = (100.0, 100.0)`, which MUST numerically match the client's
  `DEFAULT_SCENE_BOUNDS` in the `scene-docs` module (dual-language default-parity invariant — verify both
  when either changes). Per-scene only, no world-settings layer. **Movement gate:**
  `visible_cells(user, scene, lenient)` is the move-gate mask — under strict (center) sampling it
  EQUALS `player_lit_mask`'s cells because both share `cell_visible` / `lighting_inputs` /
  `source_los_poly` / `point_qualifies`; `lenient` adds the 4 corners (a superset, never a
  zero-overlap cell). `resolve_scene` also yields `movement_restriction`
  (`MovementRestriction::{Visible,Revealed,Unrestricted}`, scene-overridable, fail-closed to `Visible`)
  + `partial_cell_leniency` (world-only).
  **A single-gate constraint list: `Room::publish`
  gates no non-GM traversal at all** — a non-GM `Update` touching a token's `/engine/x`/`/engine/y`
  is refused outright (`ws::room`'s bitwise `a0 != a1` check); `Room::publish` runs no
  wall/mask/supercover machinery of its own. `move_exec`/`execute_move` is the SOLE
  implementation of the per-cell traversal decision. The six axes below are present-tense
  CONSTRAINTS on `execute_move` itself, and on any future second write path to a
  token's position — such a path MUST route through `execute_move` rather than re-derive its own
  gate; this list is what a reviewer checks a new gate input against, not a live
  two-gate comparison:
  (1) **per-cell decision** — `blocks_move` (now `move_walls`-sourced) + `GridShape::line_traversal`
  + `visible` mask, footprint-aware (see the Footprint predicate bullet below);
  (2) **cell indexing** — the same resolved `GridShape`, never the free square functions;
  (3) **traversal completeness** — a supercover on both grid kinds, never a thin line;
  (4) **input admissibility** — `MAX_GATE_WALK_COORD`, checked before any traversal, in EVERY
  restriction mode (`Unrestricted` short-circuits later, so a check placed after it must still
  apply in every mode, not just two of three);
  (5) **scene identity** — DERIVED from the token, never the frame (below);
  (6) **fail-open defaults** — an absent `scene_grid_sizes` entry means no scene document and must
  REFUSE, never synthesize a 100-unit grid. **This axis lives in `Room::publish`**,
  not `execute_move`: it guards the retained-and-repointed `Create` placement gate, the sole
  surviving piece of `publish`'s gate block, authorizing a created token's position
  rather than an in-motion token's path.
  GM scope: `execute_move` and `gate_walk`'s resource guards (`MAX_GATE_WALK_COORD`/
  `MAX_GATE_WALK_SAMPLES`, non-finite, scene-existence) bind unconditionally including GMs;
  GMs bypass every gameplay gate (walls, mask, impassable, arrest, footprint) on both `execute_move`
  and the Create placement gate — see the GM exemption bullet below.
  **INVARIANT — a movement/routing gate's SCENE is DERIVED FROM THE TOKEN, never taken from the
  frame.** `Room::execute_move` resolves the scene via
  `SceneEcs::token_move(token, &[])`, the same accessor `Room::publish` has always used — which is
  why the drag path was never vulnerable — and EVERY gate input (restriction, cell size,
  `visible_cells_cached`, `get_explored`, and `move_exec`'s walls/regions/grid shape) keys on that
  derived scene. `MoveExecution.scene` carries it out, and `MoveStream.scene` is stamped from it, so
  the per-recipient egress clip and the client's viewed-scene filter cannot key on a client value
  either. A request whose `scene_id` disagrees is additionally refused, but that is redundant
  defense-in-depth: the derivation is the mechanism. **Why derivation, not the request's own
  `scene_id`:** trusting a request's `scene_id` while reading the token's position
  scene-agnostically would let a player owning a token in scene A get the gate evaluated against
  scene B — B's walls, their own mask in B, B's regions — teleporting through fog in A despite
  valid token ownership; deriving the scene from the token is what closes that bypass.
  **A routing request that names NO token**
  (`Pathfind`) cannot derive, so a non-GM must instead prove PRESENCE: they must effectively own a
  token in the named scene, routed through the same effective-ownership rule (never a forked
  ownership check), failing with the generic `Unreachable` so it discloses nothing.
- **`/engine` re-root.** Every scene/vision/movement/pathfinding document read in this
  subsystem now goes through the typed `engine` band, not a `/system` pointer walk. `scene`'s
  private `engine_as::<T: DeserializeOwned>(doc: &Document) -> Option<T>` (`doc.engine.as_ref()
  .and_then(|v| serde_json::from_value(v.clone()).ok())`) is the module-local typed accessor every
  reader calls — a `None` result (absent `engine`, or a stored value that fails to parse) is what
  every caller's OWN field-level fail-closed backstop keys on (bounds →
  `DEFAULT_SCENE_BOUNDS_UNITS`, grid size default 100, etc.). `data/engine::{TokenEngine, SceneEngine, WallEngine, RegionEngine,
  WorldSettingsEngine, LightEngine, ...}` (re-exported here as `eng::*`) are the typed structs
  `engine_as` deserializes into. No `sys_f64`/raw pointer-walk helper exists anywhere in this
  subsystem — do not reintroduce a pointer-walk reader; add a new typed
  field to the relevant `eng::*Engine` struct instead. The per-requester secrecy-tier lookup
  `region_field` reaches through `engine_tier_visible` reads
  `doc.permissions.property_overrides.get("/engine")` (not `"/system"`)
  since a region's shape/behavior/cost live in `engine`; `setRegionVisibility`
  (`scene-docs` module) sets `property_overrides["/engine"] = "gm_only"` to match.
  `movementModel`/`snapToGrid` (below) are likewise typed `SceneEngine` fields, ts-rs exported
  (`MovementModel`/`MovementRestriction` have ts-rs derives; neither is opaque `system`-body JSON).
  **`engine_as_cached` is a caching wrapper around `engine_as` for hot-path callers:** the free function `engine_as` still
  fully re-`serde_json::from_value`-decodes on every call; `SceneEcs::engine_as_cached::<T>(&self,
  id: Uuid, doc: &Document) -> Option<T>` is the cached wrapper 18 of the ~19 hot-path call sites
  in `scene` now go through (walls, tokens, scenes, regions, lights, the world-settings/gradation/
  vision-modes singletons, and actor-table lookups). Cache correctness is VALUE-COMPARISON based,
  not mutation-site invalidation: a cached entry (keyed on the document's own id) is reused only
  when its stored source `engine` `Value` still equals the document's current one — `apply_op` is
  NOT the only place a `Document` in this ECS gets mutated (`set_world_config`/`set_actors`, the
  room-hydration setters, assign fields directly, bypassing `apply_op` entirely), so an
  invalidate-on-every-mutation-site design is incomplete by construction — the shape is pinned by
  `diagonal_rule_reads_world_settings_and_unknown_falls_back` and
  `token_vision_floors_resolve_through_actor_join`. `apply_op` still removes
  the touched id's entry as a best-effort trim (bounds memory on delete), but this is NOT
  load-bearing for correctness. The ONE deliberately-uncached call site is `token_vision_floors`'s
  embedded-actor branch (`token.embedded.get("actor")...`): an embedded actor sub-document's own
  `id` differs from the owning token's `id`, so caching it under its own id would never be
  invalidated by a token-level mutation that changes `/embedded/actor/0/...` — this is the same
  failure shape as the two test bugs above, generalized to a case with no test coverage to catch
  it, so it stays on the direct, uncached `engine_as` path.
  **`visible_cells_cached`:** `SceneEcs::visible_cells_cached(user,
  scene, lenient) -> BTreeSet<(i32,i32)>` is a per-`(user, scene)` memoized wrapper around the same
  mask `visible_cells` computes for the movement gate — `visible_cells` itself and every
  other existing caller (pathfinder, the grid-parity tests) are unchanged and still call the uncached
  primitive. Keyed on `VisibilityInputsSnapshot` (`{lenient, settings, cell, sources: Vec<(id, vp,
  floors)>, lights, light_walls, sight_walls}`) — a VALUE-COMPARISON cache like `engine_as_cached`,
  not mutation-site invalidation: a cached mask is reused only when a freshly rebuilt snapshot
  compares equal to the one stored alongside it, so correctness is independent of which code path
  mutated the underlying documents (`apply_op`, `set_world_config`/`set_actors`, or any other
  setter). `sources` is sorted by id before hashing so hecs' non-stable iteration order can't cause
  a spurious mismatch. The snapshot already covers everything `env_light_polys` occlusion depends
  on (`settings.bounds`, `cell`, `light_walls`), so the `env_polys` addition to
  `lighting_inputs_from` needed no cache-key change to stay correct.
- `scene::footprint` — **THE single footprint definition, in Rust, with no client counterpart.**
  `resolve_footprint_cells(kind: GridKind, shape: &str, w: f64, h: f64) -> FootprintCells {box_w,
  box_h, radius}`, all in GRID UNITS. Square: the box is the authored `w × h` block, the radius its
  conservative enclosure (`max(w,h)/2` for `"circle"`, `hypot(w,h)/2` otherwise). Hex: an authored
  size counts HEXES so `shape` is inert; `n = max(w,h)`, box `n·√3` wide by `n·2` tall, radius `n`.
  Both outputs are on the INDEXING scale (`grid.size`, the circumradius on hex), so the one
  conversion a footprint takes is a multiply by `grid.size` — never
  `GridShape::world_units_per_cell`, which would give a 1-hex token a disc past its own hex's
  circumradius. `resolve_checked` wraps it with the ONE refusal decision
  (`FootprintRefusal::{DegenerateSize, OverCap}`, the cap being
  `pathfinding::MAX_FOOTPRINT_CELLS`), so the gate radius and the drawn extent refuse for the same
  inputs or not at all; every caller propagates the refusal and none clamps — clamping would route
  and gate an oversized token as a smaller disc, letting it enter gaps its real footprint cannot
  (a geometric fail-open).
  **Two readers, one definition, and the client is a READER — never a second implementer.**
  `SceneEcs::resolve_token_footprint` reads `.radius` (the movement/routing gate quantity, `None`
  ⇒ REFUSE, `Some(DEFAULT_FOOTPRINT_RADIUS_CELLS)` = 0.4 for a token nothing sizes);
  `SceneEcs::resolved_footprints` reads `.box_w`/`.box_h`, scales by the scene's own `grid.size`,
  and puts the result on the wire. There is no footprint arithmetic in TypeScript anywhere —
  re-introducing one is exactly the forked-decision defect this seam exists to remove, and the only
  mechanical guard is a mutation of `resolve_footprint_cells` moving BOTH the gate-radius tests and
  the wire-extent tests.
  The module also owns the channel's payload types (ts-rs exported, Zod-mirrored by
  `@shadowcat/core`'s `footprints` module): `FootprintsPayload {scenes}` / `SceneFootprints {scene,
  unit, tokens}` / `TokenFootprint {token, extent: Option<FootprintExtent>}` / `FootprintExtent
  {w, h}` in SCENE units. **The payload carries NO radius** — the collision radius is a server-side
  gate quantity, deliberately not disclosed as a client-consumable number, and the client's only
  uses of an extent are drawing and picking. `extent: None` is a REFUSAL; an ABSENT token entry
  means either the server does not size that token (no actor, dangling link) or the recipient may
  not receive the band that sizes it — the two are indistinguishable to the client on purpose, and
  both fall back to the token document's own authored `w`/`h`, never to a larger box. `unit` is the
  scene's 1x1 extent, which the optimistic placement path stamps.
- **A DERIVED CHANNEL restating a document band is an egress path, and must apply BOTH document
  gates at EVERY document its entry is computed from.** This is the whole shape of
  `SceneEcs::resolved_footprints(ctx, world_defaults)`, computed PER RECIPIENT (both
  `compute_derived` call sites in `egress_loop` pass `view_ctx` — the connection's own context or a
  GM see-as target):
  - `SceneEcs::ctx_access` resolves the `Access` through the SAME `effective_owner_via` +
    `resolve_access_world` pair `filter_command` uses, with the grants projected from the
    document's OWN `doc_type` inside the helper so no caller can hand it a mismatched set. It
    returns the `Access` rather than a verdict because egress asks it TWO questions, and resolving
    it twice is how the two answers drift apart.
  - `engine_tier_visible_to(doc, access)` is the SINGLE authority for the `/engine` tier decision —
    `property_overrides["/engine"]` (default `All`) through `Access::can_see`, the exact pair
    `filter_properties` runs per override pointer. `move_walls` and `region_field` reach it via the
    per-requester wrapper `engine_tier_visible(doc, viewer)`; the footprints channel reaches it
    directly with an already-resolved `Access`. Do not re-inline the lookup or the predicate at a
    new site.
  - `engine_geometry_visible_to(doc, access)` is the composite `cap::READ && tier`, stated once so
    no call site composes its own ordering.
  - Applied at four levels: the SCENE entry and a LINKED actor via `ctx_can_see_engine`; the TOKEN
    entry via `token_footprint_visible`; an INSTANCED token's EMBEDDED actor child via
    `engine_tier_visible_to(child, token_access)` — the child is tested against the TOKEN's access
    and has no whole-document READ of its own, because that is how a child reaches a recipient at
    all (`filter_properties` recurses into `embedded` under the PARENT's access).
    `token_geometry_source` decides which document authors a token's geometry and is SHARED with
    `token_shape_and_size`, so the document whose band is checked cannot drift from the document
    the size comes from.
  - **The redaction is ABSENCE of the whole entry, never a nulled field or an empty list** — a
    scene entry states that scene's id and its grid-derived `unit`, so an entry with an empty
    `tokens` list is not a redaction of a scene the recipient may not see, and `extent: None`
    already means "refused to size", which reusing for withholding would conflate. A token
    parented to a withheld scene is withheld with it (its scene has no `resolved_footprints::by_scene` entry).
  - The cell size comes from `scene_grid_sizes()` rather than a second `grid.size` read, so the
    channel's scale cannot disagree with the gates'; the payload is sorted (scenes by a `BTreeMap`,
    tokens sorted before the extent pass) because the egress loop's change detection compares whole
    payloads and `hecs` iteration order is not stable.
  - **The general lesson, which is why this is stated as a rule and not as a description:** a
    helper written as an internal GATE input carries no egress filtering, so promoting one to a
    wire surface is a permissions change even when no formula changes. `scene_grid_sizes`
    enumerates every scene entity with zero filtering because every prior caller was a gate. Note
    also that `"vision"` never ENUMERATES (it emits only where the recipient's own token has a
    vision source), so any future channel that enumerates entities must state a per-field authority
    for the SET itself, not just for each field's contents.
  - **Fixture gotcha, and it differs from `region_field`'s:** `PermissionSet::default()` is
    `default: DocRole::None`, so a fixture scene/token/actor a `WorldRole::Player` must be able to
    read needs `DocRole::Observer` set explicitly, or a negative test passes vacuously on an empty
    payload. Unlike the region secrecy filter — where `permissions.default` does not gate the
    per-requester field at all — BOTH `permissions.default` and the `/engine` override gate here,
    and each needs its own negative test.
- `scene::movement` — pure `supercover_cells(a0, a1, cell) -> Option<BTreeSet<(i32,i32)>>` —
  every cell the move segment crosses (supercover, not a thin line — an exact corner crossing
  emits BOTH flanking cells so a diagonal can't thread an unseen cell). `None` ⇒ caller fails closed
  (`cell<=0.0` / non-finite endpoint / span > `MAX_MOVE_CELLS`). Clean-room (Amanatides–Woo extension);
  relative-epsilon corner test (over-include is the safe direction).
- `scene::vision` — raycast `visibility_polygon(viewpoint, walls, bound)`,
  `bound_for(...)`, `Seg`/`Rect`/`P`, `point_in_poly` (shared). Public-source computational
  geometry only.
  **Three bound builders, and the two wrappers UNION onto `bound_for` rather than replacing it** —
  each calls it first and then only `.min`s low edges / `.max`es high edges, so a bound can only ever
  GROW. That monotonicity is the invariant: a bound that could shrink is an under-reveal defect on a
  secrecy-bearing path.
  - `bound_for` seeds an AABB at the viewpoint and grows it over EVERY wall endpoint in the slice it
    is handed, then pads by `margin`. Consequence worth knowing before reusing it: on its own it
    makes a viewpoint's reach depend on wall placement anywhere in the scene, and with no walls it
    is just a `margin` box.
  - `bound_for_reach(viewpoint, walls, margin, reach)` — the LIGHTING path. `bound_for_reach::reach` is a WORLD-unit
    distance; a caller converts an authored cell radius through `GridShape::world_units_per_cell`
    (the authored-distance scale — NOT the indexing scale, and NOT the footprint conversion) before
    calling. A non-finite or non-positive `bound_for_reach::reach` contributes nothing rather than substituting a
    fallback distance. This is what stops a placed light's occlusion polygon capping its reach at
    `margin` regardless of the radius it was authored with. An axis-aligned `bound_for_reach::reach` box necessarily
    contains that radius' disc, so the union covers the true reach in every direction.
  - `bound_for_scene` — unions the scene's own world envelope (`GridShape::world_extent`), so a
    wall-less scene reveals its full extent instead of a `margin` box.
  **`max(bright, dim)` sizes the light bound, and over-inclusion there is inert**: `light_illumination`
  returns 0 beyond `dim_radius` before the bright branch runs, so a `bright_radius` authored larger
  than `dim_radius` grows the polygon without ever lighting a cell past `dim_radius`.
  **A FOURTH bound site exists and deliberately does NOT use any of the three** — `env_light_polys`
  constructs its `vision::Rect` inline as `extent ± cell_size.max(1.0)`. That is correct rather than
  an oversight, and the distinction is worth holding: the three builders above are VIEWPOINT-relative
  (they grow around a lamp or an eye and must reach as far as that source can see), whereas
  environment light is projected inward from the scene boundary, so its bound is the scene's own
  envelope and wall-endpoint growth would add nothing outside it. It shares only the
  `visibility_polygon` raycast primitive with the other paths, never the bound construction. **Do not
  "unify" it into `bound_for_scene`** — that would make an inward-projected boundary walk depend on
  wall placement, which is a different mechanism, not a tidier spelling of the same one.
- `scene::lighting` — pure illumination (no I/O — callers pass parsed
  structs): gradation `Band`s (`sorted_bands`/`band_index`/`floor_min`), `Light` radial falloff
  (`light_illumination`), `cell_illumination` (max-compose env + lights, `blocksLight` occlusion via
  `point_in_poly`). Clean-room. Non-finite/empty inputs fail closed (under-reveal).
- `scene::move_exec` — pure, lock-free `execute_move(ecs, gate: MoveGateInputs, token, path,
  is_gm, footprint_radius_cells) -> Result<MoveOutcome, MoveReject>`. `MoveGateInputs` bundles the
  resolved scene state (`scene`, `restriction`, `visible`, `cell`) and is destructured on entry.
  **`is_gm` is deliberately NOT a field of it**: that struct mixes inputs a GM is exempt from
  (`restriction`/`visible`, read only under `execute_move::check_mask`) with inputs that bind a GM
  unconditionally (`scene`, whose absent document is `MoveReject::SceneUnknown`; `cell`, whose
  non-finite or non-positive value is `MoveReject::Degenerate`). The exemption switch must never
  share a value with the guards it may not exempt. (Server-authoritative
  movement; engine-agnostic): `path` may be ANY polyline — grid A* cell-center
  vertices ≤1 cell apart, or any-angle continuous vertices arbitrarily far apart. `gate_walk`
  (a pure primitive in the same file) subdivides it into a DENSE walk where every consecutive
  sample is ≤1 cell apart (Chebyshev), preserving already-≤1-cell input segments EXACTLY —
  identity on grid input (cell-center vertices, ≤1 cell apart on every axis incl. diagonals). This
  identity property is what makes grid-parity a property of the code shape rather than something
  proven only by testing. The permanent regression proof is
  `frozen_parity_king_step_grid_outcomes`, a `#[cfg(test)]` battery of 10 labelled `FrozenCase`
  scenarios whose `ExpectedOutcome` (`stop`/`render_path`/`truncated`/`cost`) is frozen LITERAL
  data. Expected outcomes stay literals on purpose: a second executor computing them would
  reintroduce exactly the fork this shape exists to avoid, and a test that agrees with a
  computation cannot witness the two agreeing on the wrong answer. The per-step gate — (1) wall gate (`blocks_move`, all modes incl. GM), (2)
  vision-mask gate (`GridShape::line_traversal` + `visible` membership, skipped for `Unrestricted`), (3)
  region gate (see below) — runs over this DENSE walk, not the raw authored path; the
  coarse `render_path` returned to the caller is reconstructed as either the authored-vertex
  prefix (when the stop lands exactly on an authored vertex — always true for grid input) or the
  authored-prefix + the exact stop point (when the stop lands mid-subdivision — only possible for
  a genuinely long/any-angle continuous segment). **Multi-cell jumps:** there is no
  adjacency guard on the authored path — a >1-cell jump is subdivided and gated per cell, exactly
  as if the client had sent the explicit intermediate waypoints. Its absence grants no capability:
  security lives entirely in the per-cell gate, never in the shape of the authored path. **DoS bound:** `MAX_GATE_WALK_SAMPLES=4096` (dense
  sample count, arc-length-based) + `MAX_GATE_WALK_COORD=1e9` (a coordinate-magnitude bound inside
  `gate_walk` itself, closing a false-identity failure mode where the identity-comparison's
  magnitude-scaled floating-point tolerance could otherwise grow large enough at extreme
  coordinates to silently misclassify a genuinely-multi-cell segment as identity) are the DoS bound; there is no
  authored-vertex-count cap, and `MoveReject::TooLong` reflects `gate_walk`'s `None` (either
  cap), not vertex count. `MoveReject` variants: `NotAToken`, `EmptyPath`, `TooLong` (as above),
  `Degenerate` (non-finite coords / bad start only — a non-adjacent king-step is subdivided and
  gated, never rejected here). **Region gate (step 3):** always reads
  `ecs.region_field(scene, None)` — the AUTHORITATIVE field, computed once before the walk loop
  begins (never per-step, never filtered) — so a `gm_only` secret region "springs" on execution
  even for a mover whose own route preview couldn't see it. Center-cell only (`to_cell(next)`; no
  footprint check) — a documented asymmetry against the router's footprint-aware
  `cell_enterable` (router stricter, executor looser), but `route ⊆ gate-allowed` still holds
  because the router's mask predicate is already a superset (see the pathfinder invariant below).
  **Keyed on CELL-ENTRY TRANSITIONS, not per dense sample:** a continuous path subdivided
  into several sub-cell samples within the same cell is evaluated exactly once for that cell,
  matching the prior per-authored-step accrual count on grid input (where every step already
  crossed into a distinct new cell); re-entering a cell already crossed earlier in the SAME walk
  (A → B → A) still re-evaluates correctly since the dedup only compares against the IMMEDIATELY
  prior cell, never a stale earlier value. Impassable stops BEFORE entry into the cell (like a
  wall — `stop` lands on the prior cell); arrest stops AT entry (the cell is entered, then the
  walk halts — a final-step arrest still sets `truncated: true` even though `stop_index ==
  path.len()-1`). `MoveOutcome.cost` accumulates `regions.terrain_multiplier(region_cell)` per
  cell-entry (1.0 outside any terrain region — this is a per-step-distance BASELINE, not merely
  additive terrain weighting; a plain grid move with no regions at all still accrues `1.0` per
  step) — center-cell-only, terrain-only; it does NOT apply the diagonal-rule step-cost factor
  (`astar_leg::sc` — 1.0/2.0/√2/alternating) that `pathfinding::astar_leg`'s step-cost function applies. **Known
  inconsistency:** the two `cost` values are numerically comparable only under
  Chebyshev (where the diagonal step cost is 1.0); under any other diagonal rule they diverge. This
  is a deliberate v1 scoping decision, not a bug — nothing currently consumes or
  compares the two costs together. Resolve before any per-turn movement-budget system consumes
  either `MoveOutcome.cost` or `MoveStream.cost`. `supercover_cells`'s
  lattice-corner-tie drift (a diagonal king-step whose leg endpoints both sit exactly on 4-way
  grid-line intersections could otherwise spuriously fail-closed) is prevented by a per-axis
  remaining-step budget gating the diagonal corner branch.
- `scene` — adds `SceneEcs::token_position(token) -> Option<(f64,f64)>` and
  `SceneEcs::resolved_animation_speed() -> f64` (`pub(crate)` seams; the latter sits alongside
  `resolved_diagonal_rule`, sources `world_settings.animation`, defaults to 6 cells/sec).
  **Streamed-vision seam:** `SceneEcs::player_vision_inputs(user, scene, moving_token) ->
  VisionMoveInputs` hoists the per-move-invariant inputs (full `sight_walls` set + the user's
  OTHER owned tokens' static polygons) **once per move**; `VisionMoveInputs::polygons_at(viewpoint)`
  (also exposed as the convenience wrapper `SceneEcs::player_vision_polygons_at(user, scene,
  moving_token, viewpoint)`) is the cheap per-sample call — raycasts the moving token from
  `player_vision_polygons_at::viewpoint` against the SAME full wall set (including `gm_only` sight walls) and unions it with
  the pre-hoisted static polygons. Empty when the user owns no token in the scene (fail-closed).
  Reused primitives, not a new vision model: identical `sight_walls` + `vision::visibility_polygon`
  as `player_vision_polygons`.
- `scene::move_stream` — pure, no-I/O position/vision path sampler for the
  `MoveStream` broadcast: `sample_path(path, cell, duration_ms) -> Vec<PosSamplePt>` (arc-length
  parameterization; ~`SAMPLES_PER_CELL`=3 samples/cell; always includes the exact first/last
  vertex; strictly increasing `t_ms`, exact-equal consecutive dedup). `MAX_VISION_SAMPLES` (96) is
  the SHARED cap for both position samples and vision samples on one `MoveStream` frame — bounds
  the mover's per-move raycast count. `MAX_VISION_POLYGON_VERTS` (512) caps each `VisionSamplePt`
  polygon's vertex count (fail-closed truncation — under-reveal, never over-reveal).
  `Room::execute_move` calls `sample_path` then, for each sample, `player_vision_inputs` (once) +
  `VisionMoveInputs::polygons_at` (per sample) to fill the wire frame's
  `ServerMsg::MoveStream.mover_vision` (`None` for a GM mover — `Unrestricted` sees all, nothing to
  sweep).
- `ws::conn` — **the per-recipient egress clip is the secrecy boundary** for
  `MoveStream`. `Room::execute_move` builds the full (unclipped) `MoveStream` frame itself (via the
  module-private `wire_move_stream`) and registers it in the room's in-flight registry
  (`Room::mover_streams`/`Room::concurrent_streams` read this registry, pruning expired entries on
  every read); `handle_move_request` broadcasts that frame with `Room::broadcast_aux_shared` — the
  full trajectory lives only in-process. `egress_loop`'s dedicated `MoveStream` branch
  (`clip_move_stream`, which delegates the per-sample decision to `ws::move_clip::clip_samples`)
  runs BEFORE the sink write, per connection, in four branches: the mover gets `samples` +
  `mover_vision` unchanged (keyed on the REAL connection `user_id`, never a see-as target — a GM
  previewing as someone else is not "the mover" unless the GM's own token is what moves); a plain
  GM (no active see-as) gets the FULL `samples` unclipped (GMs bypass position secrecy) but
  `mover_vision` forced to `None` (a GM has no fog to sweep); a GM with an active see-as
  (`SceneSubscribe`-set `egress_loop::scene_subs` target) gets `samples` clipped to the see-as
  TARGET's own authoritative vision (`observer_vision_polys_for_scene(target.user_id, scene,
  room)` plus the target's in-flight timelines via `Room::mover_streams`) instead of the plain-GM
  full stream — the see-as does not apply, falling back to the full GM stream, only when BOTH the
  target's committed vision polygons AND their `mover_vision`-filtered in-flight timeline set are
  empty (never the raw `Room::mover_streams` result, which can be non-empty while carrying nothing
  usable — e.g. a registered GM mover's own move, whose frame always carries `mover_vision: None`);
  every other (non-GM, non-mover) recipient gets `samples` clipped by `ws::move_clip::clip_samples`
  against those whose `pos` falls inside the recipient's OWN authoritative vision at that sample's
  instant — their committed vision polygons (recomputed off the current ECS read — never a stale
  cache; the ECS guard drops before any await), superseded per-sample (never combined with the
  committed polygons for that same sample) by the union of their own in-flight `mover_vision`
  timelines once at least one has started — with `mover_vision` also forced to `None`; a
  wholly-invisible move (empty clip) is **not sent at all** (suppressed, not an empty-`samples`
  frame — asserted by a dedicated test). The see-as branch can only NARROW what a GM receives
  relative to the plain-GM fallthrough, never widen a non-GM recipient's own view (see-as is
  GM-only, gated by `SceneSubscribe`'s `as_user` handler). `send_plain` intentionally panics if a
  `MoveStream` reaches it — the clip MUST happen in the dedicated `egress_loop` branch, never the
  generic per-recipient filter path. **A second, per-connection (never broadcast) delivery path:**
  when the triggering frame's own `mover_vision` is `Some(_)` and its mover equals this
  connection's own clip target (the real `user_id`, or the see-as target for a GM), `egress_loop`
  also re-clips every OTHER unexpired stream in the same scene (`Room::concurrent_streams`,
  excluding streams by that same mover) against the just-changed timeline and re-sends each one —
  under its original `token_id` (the client overwrites playback keyed by `token_id`, not
  `request_id`; `request_id` is preserved unchanged and only proves the re-emit is A's own
  original frame) — to this connection only; a zero-progress move (never registered in
  `Room::mover_streams`) or a GM mover's own move (`mover_vision: None`) cannot populate a usable
  timeline and is excluded from triggering this path. `MoveError` stays
  mover-only via `handle_socket::etx`, generic (no path/vision geometry disclosed).
- `scene::explored` — `ExploredSet` fog memory: `mark_polygons(polys, cell_size)`,
  `to_bytes`/`from_bytes` (persistence), cell-based. Lifecycle: `explored_fog` rows are purged on
  scene delete (`delete_document_tx`, both authoritative delete paths), world delete
  (`delete_world`, by the denormalized `world_id`), and user delete (`delete_user`) — rows do not
  orphan on any of these paths.
- `scene::regions` — pure region geometry, no ECS/I/O (mirrors
  `scene::movement`'s module invariant): `RegionShape` (`Rect`/`Circle`/`Polygon`), `RegionBehavior`
  (`Terrain`/`Impassable`/`Arrest`), `RegionEffect` (composed per-cell result), `rasterize(shape,
  cell)` (grid cells whose CENTER falls inside the shape — fails closed to `None` on a degenerate
  shape (non-finite coords, non-positive radius, `<3`-vertex polygon) or an over-cap AABB
  (`MAX_REGION_CELLS`=100_000), never a partial/silently-empty result), `compose(contributions)`
  (precedence `Impassable > Arrest > Terrain`; overlapping Terrain costs take the MAX, never
  summed), `RegionField`/`RegionFieldBuilder` (`.add` silently drops a fail-closed shape —
  contributes nothing, never all-passes; `.build` composes per-cell), and `parse_region_shape`
  (structural-only parse of a region doc's `/shape` body; any malformed field fails closed to
  `None`, dropping the whole region). **`MAX_CELL_COORD` (`i32::MAX - 1.0`) is checked on all four
  AABB edges before any i64 arithmetic, and that ordering is the invariant:** without it an
  extreme-magnitude finite coordinate (e.g. `-1e300`) saturates the float→cell-index cast to
  `i64::MIN/MAX`, and the subsequent `i1 - i0 + 1` cell-count arithmetic overflows BEFORE the
  `checked_mul` DoS-cap check runs — a bypass of the cap, not merely a wrong count. A
  large-magnitude-but-small-span coordinate (e.g. `1e13`) is a separate failure mode also caught by
  the same bound (would otherwise silently truncate/wrap under `as i32`, aliasing onto an unrelated
  real cell).
- `SceneEcs::region_field(scene, viewer)` — the composed `RegionField` for a
  scene. **Two-value contract, never a third mode:** `viewer: None` is the AUTHORITATIVE view
  (every enabled region, unfiltered) — used by the GM and by `move_exec` (which always springs
  secret regions on execution regardless of what the mover's own route preview could see);
  `viewer: Some(user)` is the PER-REQUESTER view used by the grid A* router — a region is included
  only when `user` can see the visibility tier declared on its `/engine` (defaults
  to `All` when undeclared), via `engine_tier_visible(doc, viewer)` — the per-requester wrapper
  over `engine_tier_visible_to`, which is the SINGLE `property_overrides["/engine"]` +
  `Access::can_see` authority the footprints channel and `move_walls` also reach, and the same
  mechanism that already
  gates every other document's egress — no new secrecy machinery. **Callers MUST pass
  `None` for a GM requester** — mirrors `visible_cells`'s GM-skips-the-mask convention; passing
  `Some(gm_user)` would incorrectly filter a GM's own field.
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
  (the union closes a gap — footprint-disc-at-destination alone missed a diagonal
  step's corner-flanker cells for sub-0.5-cell footprints, letting the router approve a step the
  executor then rejected; `None` from `line_traversal` fails closed); (3) center-to-center
  step crosses no wall (`segments_cross`); (4) `RegionField::is_arrest`/impassable check via
  `PathGrid.inputs.regions: Option<&RegionField>` (see below; a `None` grid field means "no region enforcement",
  distinct from an empty `RegionField`). `astar_leg` — king-move A*, 4 diagonal
  rules, 5-10-5 parity tracked in the `(cell, parity)` node and carried across waypoint legs (cost
  1,2,1,2…, never reset per leg), admissible+consistent heuristics per rule, stale-pop skip,
  `MAX_PATH_NODES`/`MAX_WAYPOINTS`/`MAX_FOOTPRINT_CELLS` fail-closed bounds; **Terrain
  weighting:** the step-cost function multiplies the diagonal-rule base cost (`astar_leg::sc`) by
  `grid.inputs.regions.map_or(1.0, |r| r.terrain_multiplier(next))`, so a terrain region raises (never
  lowers — multipliers are validated `>= 1.0` at `region_field` construction) the A* edge weight
  into that cell, honored by the admissible/consistent heuristic (which already lower-bounds the
  UNWEIGHTED cost, so remains admissible under any `>=1.0` weighting). `find` — validates
  request, computes search window (AABB{start∪waypoints∪wall-endpoints}+8-cell margin), threads
  end-parity of each leg into the next, sums cost, returns ordered cell-center scene coords, THEN
  applies **arrest truncation**: cuts the assembled route at the first cell (after the
  start — a token already standing in a cell is not "entering" it) flagged `is_arrest` in the
  region field, sets `arrested: true`, and recomputes the truncated `cost` by REPLAYING
  `step_cost` over the surviving prefix from parity 0 (a cost-replay technique, not trusting
  `astar_leg`'s per-leg running total, because parity threading is purely sequential/order-
  dependent — replaying reproduces the exact cost the original per-leg accumulation would give for
  that same prefix). Returns `PathOutcome { path, cost, arrested }`. This truncation exists so a
  player-facing route preview is honest about a hazard it already knows about — it never shows a
  route running past an arrest cell the requester can see.
  `SceneEcs::pathfind(requester: RouteRequester, scene, start, waypoints, footprint_radius)` —
  `RouteRequester` describes the REQUESTER ONLY (`user`, `is_gm`, `explored`); the route itself
  stays in `pathfind`'s own trailing parameters. It builds a `PathInputs` and passes it to
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
  router's per-requester set showed. Wire frames `Pathfind`/`PathResult` (`{path, cost, arrested}` —
  `cost` is in CELLS on every movement model, which the client scales by `grid.distance.perCell` for
  display; `arrested` is always disclosed to the requester, no secrecy concern: it only tells them a
  route THEY could already see is truncating)/`PathError` — one-shot to the requesting connection only
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
  route overlay on tool swap); ruler `Grid.distance()` gains the `alternating` (5-10-5) rule wired
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
  `navmesh::clip_to_visible_mask` (below). Both branches build the per-`(user,scene)` visibility
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
  see [[shadowcat-codebase-chat]] for the full seam.
- **Regions on the continuous engine.** `SceneEcs::pathfind`'s
  `Continuous` branch (`scene`) computes the per-requester `region_field` once (same call the
  `GridStepped` branch already made — the `GridStepped` branch itself is completely untouched by
  this) and dispatches on `RegionField::has_terrain_or_impassable()` (`scene::regions`: true iff any
  cell is `impassable` or `terrain` with `multiplier > 1.0`; arrest-only fields do NOT trigger this
  — arrest needs only a post-filter, not route-bending). **Terrain/impassable present:** the
  existing `pathfinding::find` runs forced to `DiagonalRule::Euclidean` (continuous base metric —
  only cell topology + the terrain multiplier come from the grid, never the world's configured
  diagonal rule), its cost stays in CELLS, then `navmesh::los_smooth` (new) restores any-angle
  geometry. **The unit contract is that ALL routes report cost in cells, on both movement models and
  both continuous sub-paths** — `PathResult.cost` declares cells and the client multiplies by
  `grid.distance.perCell` to label it, so an engine reporting scene units double-scales that label.
  The pure-polyanya sub-path therefore converts its Euclidean world-unit length back with
  `/ world_units_per_cell` (the authored-distance scale, not the indexing scale), and the weighted
  sub-path performs no conversion at all because it never left cells. A parity test pins both
  directions; the mutation it names is a `* world_units_per_cell` reappearing on either branch. The weighted sub-path
  does NOT call `clip_to_visible_mask` at all — its route⊆mask/wall safety comes entirely from
  `pathfinding::find`'s own per-cell mask gate (already fed the caller's `pathfind::mask` by reference) plus
  `los_smooth::chord_ok`'s own mask check (every cell a straightened chord enters must still be in
  `mask`). **Otherwise:** the unchanged pure-polyanya route runs `clip_to_visible_mask`
  FIRST, then `navmesh::truncate_at_arrest` (new) on the clipped result — clip-then-truncate, so a
  fog-truncated route can never carry a stale `arrested: true` flag past the point the fog itself
  should have cut it. `clip_to_visible_mask` is exclusive to the pure-polyanya sub-path — the two
  continuous sub-paths enforce the SAME mask invariant through different mechanisms, not through a
  shared call.
  - `navmesh::los_smooth(outcome, walls, mask, field, cell, footprint_radius_cells)` — cost-guarded
    LOS string-pull smoothing for the weighted continuous path. A span `path[i]..path[j]`
    straightens only when every cell its chord enters (`grid.footprint_cells ∪ grid.line_traversal`,
    the SAME union `cell_enterable`/`clip_to_visible_mask` use) is in `mask` (when `Some`), not
    impassable, not arrest, and not weighted terrain (`terrain_multiplier > 1.0`), and the chord
    crosses no `blocksMove` wall — so a straightened chord can never shortcut INTO terrain/
    impassable/arrest the weighted search deliberately routed around or truncated at. **The single
    grid step `path[i] -> path[i+1]` is ALWAYS kept unconditionally** (it already passed `find`'s
    per-cell gate), guaranteeing goal progress even when nothing else can straighten. Fail-closed on
    two levels: a whole-input short-circuit (`<3` vertices, degenerate `cell`/`footprint_radius_cells`)
    returns the input unchanged; a per-span fallback (an over-cap/degenerate `line_traversal` for
    one candidate chord) fails only that chord, leaving it at its single grid step while smoothing
    continues over the rest of the path. `cost`/`arrested` are carried through UNCHANGED (not
    recomputed) — the pre-smoothing weighted grid cost is a conservative (never-cheaper) budget for
    the straighter geometry, the same preview-vs-execution divergence class as
    `MoveOutcome.cost`/router-cost (an exact per-span smoothed cost is not currently computed).
  - `navmesh::truncate_at_arrest(outcome, field, cell)` — arrest post-filter for the pure-polyanya
    continuous path (which never runs through `find`, so needs its own arrest truncation, mirroring
    `find`'s arrest logic for the walls-only route). Arc-length-samples the route
    (`move_stream::sample_path`) and cuts at the first sample whose cell **differs from the last
    distinct cell seen** and is `field.is_arrest(...)` — **cell-ENTRY-TRANSITION detection, not raw
    per-sample checking**: the start cell is never a trigger even while several samples still sit
    inside it (a token already standing somewhere is not "entering" it), matching `find`'s
    `.skip(1)`-over-cells convention. A route with no arrest transition is returned UNCHANGED (no
    resample, no cost recompute). On truncation, `cost` is recomputed as the Euclidean length of the
    surviving polyline and `arrested: true` is set.
  - **Both `los_smooth` and `truncate_at_arrest` are called with the PER-REQUESTER `region_field`**
    (`region_field(scene, if is_gm { None } else { Some(user) })`, computed once in `pathfind` and
    reused for the dispatch predicate too) — a secret region is absent from a non-GM's route/cost
    exactly as on the grid engine; `move_exec` alone reads the authoritative field and springs any
    secret region at execution. `move_exec`/`gate_walk` required **zero production changes**
    — proven, not merely asserted: it already cell-samples the region field
    for any polyline, grid or any-angle.
- `scene::navmesh` — pure headless adapter around the `polyanya`
  (any-angle navmesh) + `geo`/`spade` (CDT + Minkowski buffer) crates, engine-owned geometry.
  Carries **walls only** — impassable/terrain regions are not on the
  navmesh, and adding them is a scope change, not a fix.
  - `build_navmesh(extent: WorldExtent, footprint_scene, walls) -> Option<NavMesh>` — triangulates
    the scene's world ENVELOPE (both corners, `min` and `max` — not an origin-anchored rectangle,
    which is why the parameter is a `WorldExtent` rather than a bounds pair plus a cell size) and
    inflates each `blocksMove` wall segment into a capsule obstacle (`geo::Buffer`) by the
    requester's footprint radius, received pre-converted in scene units. Its refusal guards are
    ordered: the four finiteness tests and the two span tests (`width() <= 0`, `height() <= 0`) are
    disjuncts of ONE condition with finiteness FIRST, and the magnitude gate is a SEPARATE later
    condition —
    a NaN therefore refuses on finiteness alone, since `NaN <= 0.0` and `NaN.abs() > MAX` are both
    false. **`MAX_NAVMESH_COORD` (1e15)**
    bounds EVERY value that reaches an `f64→f32` cast in this module (derived pixel bounds,
    raw wall-segment endpoints, AND `build_navmesh::footprint_scene` — all three carry the bound
    independently, and any one of them missing it is a panic surface: an unbounded-but-finite
    coordinate saturates to
    `Infinity` on cast, which `spade`'s triangulation rejects via an unhandled internal `.unwrap()`
    on `Err(InsertionError::TooLarge)` — a panic, not a fail-closed `None`). **Separately**, a
    non-degenerate wall whose `build_navmesh::footprint_scene`-to-segment-length ratio exceeds ~4.9e8 makes
    `geo`/`i_overlay`'s internal fixed-point quantization collapse both endpoints to the same
    integer point, silently returning ZERO polygons from `.buffer()` — a distinct, more severe bug
    class (**silent fail-OPEN**: the wall obstacle vanishes from the mesh under inputs that pass
    every magnitude check, and a route can pass straight through where a wall should block).
    `build_navmesh` now treats an empty-buffer result for a non-degenerate wall as a hard
    whole-build failure (`None`), distinguishing it from a genuinely zero-length segment (a
    legitimate no-op, not a failure). `MAX_NAVMESH_OBSTACLE_SEGMENTS` (5000) caps wall count.
  - `navmesh_find(nav, start, waypoints) -> Result<PathOutcome, PathFail>` — any-angle multi-leg
    routing via `polyanya::Mesh::path`, Euclidean cost. **`polyanya::Path::path` EXCLUDES the query
    start vertex** (verified against the pinned crate source) — the leg-concatenation logic skips
    a returned vertex only if it coincides with the already-known `navmesh_find::leg_start`, which is correct
    regardless of whether the crate includes or excludes it (don't "fix" this dedup logic assuming
    one behavior). Validates `waypoints.len() <= MAX_WAYPOINTS` and finiteness of `start`/every
    waypoint (parity with the grid router's own `Invalid` guard) — this specific magnitude bound is
    defense-in-depth/input-hygiene, NOT a proven panic-prevention fix (empirically verified: the
    query side, `Mesh::path`, is pure point-in-polygon containment and never touches `spade`'s
    triangulation, so it already fails closed to `None`/`Unreachable` without any guard — unlike
    `build_navmesh`'s construction-side guards, which DO close real reproduced panics).
  - `clip_to_visible_mask(outcome, mask, cell, footprint_radius_cells, walls) -> PathOutcome` — the
    **fog-safe + wall-safe preview post-filter**, THE security-critical function in this module
    (this invariant class has received repeated security review across every milestone touching it).
    Arc-length-samples the route (`move_stream::sample_path`) and truncates at the first sample
    whose footprint cells (`grid.footprint_cells ∪ grid.line_traversal`, the SAME predicate
    `pathfinding::cell_enterable`'s mask check applies) leave `mask` — `mask: None` skips this
    check (GM/unrestricted). **Independently**, every chord (from the previous retained sample) is
    also tested against `walls` via `segments_cross`, ALWAYS (even when `mask: None`) — this is a
    router-FIDELITY guarantee, not a secrecy one (walls are public geometry): the true navmesh
    polyline can detour around a wall corner, but once downsampled to ≤`MAX_VISION_SAMPLES` (96)
    arc-length samples, an undersampled chord between two corner-straddling samples could otherwise
    visually cross the wall the true route avoided. Also validates `footprint_radius_cells` (against
    `MAX_FOOTPRINT_CELLS`), `cell`, and skips (not fails) any individual non-finite wall
    endpoint — mirroring `build_navmesh`'s defense-in-depth convention. **Two-checks
    dichotomy, never conflate:** the mask check is a genuine secrecy gate (route ⊆ gate-allowed);
    the wall check is a fidelity/correctness guarantee with no confidentiality stake — don't reuse
    one's severity framing for the other. Cost is recomputed as the Euclidean length of the
    truncated polyline, never the original route's cost.
  - `SceneEcs::navmesh_for(scene, footprint_radius_cells) -> Option<Arc<NavMesh>>` —
    memoized per `(scene, quantized footprint radius)` (nearest 1/1000 cell — the quantization IS
    the bound on cache growth, and keying on exact `f64` bits instead would let a caller mint an
    unbounded number of entries). **Validates `footprint_radius_cells`
    BEFORE computing the quantized key or touching the cache** (doing the
    validation after the cache lookup let `NaN`/small-negative inputs alias onto an already-cached
    LEGITIMATE mesh — e.g. `NaN` saturates to the same quantized key as `0.0` via `f64 as i64` —
    silently returning a valid-looking result instead of `build_navmesh`'s own fail-closed `None`).
    `navmesh_cache: std::sync::Mutex<HashMap<(Uuid,i64), Arc<NavMesh>>>` — `Mutex`+`Arc`, never
    `RefCell`/`Rc` (`SceneEcs` lives behind a `tokio::sync::RwLock` shared across connection tasks;
    the cache must stay `Sync`); never locked across an `.await`. Invalidated wholesale (all
    scenes, not just the touched one — over-invalidation is the safe direction) in `apply_op`
    whenever a `wall` or `scene` document is created/updated/deleted; the `Update` case resolves
    the existing entity's doc_type from the ECS `index`/`world` BEFORE the mutation runs (an
    `Update` never changes doc_type, so this pre-lookup is safe). A failed `build_navmesh` (`None`)
    is never cached.
  - **Grid/continuous engine parity, not just "shippable together":** the dispatch treats a route
    whose destination coincides with the start (any waypoint sequence that collapses to a
    zero-displacement request) as a legitimate zero-cost success on BOTH engines — the grid router
    has always had this via `astar_leg`'s explicit `start == goal` short-circuit; the continuous
    dispatch captures whether `navmesh_find`'s RAW (pre-clip) result was already length-`<2` before
    `clip_to_visible_mask` consumes it, and only maps `clipped.path.len() < 2` to `Unreachable`
    when the raw result was NOT already trivial — otherwise a "route to where you're already
    standing" request would succeed on grid-stepped scenes and spuriously fail on continuous ones.
  - Dependencies (Cargo.toml, `src/server/`): `polyanya = { version = "0.16", default-features =
    false }` (drops `async`/`recast` — blocking `Mesh::path()` only), `geo = "0.32"` (pinned to
    unify with polyanya's own dependency copy — one compiled `geo`, no duplicate), `glam = "0.30"`
    (used directly for `Vec2`; must be a DIRECT dependency even though polyanya also pulls it
    transitively — Rust requires a crate used by name to be declared directly). Binary-size delta
    measured at ~0.94 MiB against the 60 MiB CI ceiling — no bloat concern.
- `src/client/render/src/` — engine-owned PixiJS layer: the `backend` + `pixi-backend`
  modules (renderer host), `engine`, `reconciler` (doc→scene reconcile), `compositor`,
  `layers` (`CORE_LAYERS` z-order, 0-based: `CORE_LAYERS.background` 0, `CORE_LAYERS.grid` 1,
  `CORE_LAYERS.tiles` 2, `CORE_LAYERS.regions` 3, `CORE_LAYERS.drawings` 4, `CORE_LAYERS.walls` 5,
  `CORE_LAYERS.tokens` 6, `CORE_LAYERS.templates` 7, `CORE_LAYERS.lighting` 8, `CORE_LAYERS.mask` 9,
  `CORE_LAYERS.overlays` 10 —
  read the array, not this list, before placing a module layer: a module's fractional `order` is
  relative to these indices, so an off-by-one lands it under the wrong neighbour),
  `camera`, `grid`, `token-view` + `token-animator` (tween),
  `wall-view`, `drawing-view`, `template-view`, `ping-view`. Modules draw through the
  render-layer API; the canvas host is not replaceable.
- **Token visual rendering (faces + animated token visuals).**
  the `token-animation` module — `computeAnimatedFrame(elapsedMs, fps, frameCount,
  loop) -> number`, pure tick-driven frame-index math (extracted for the same reason as
  `fog-blend`: `pixi-backend` is Playwright-only, no jsdom GL context, so frame-selection logic
  needs to live somewhere unit-testable). `loop:true` wraps arbitrarily-large `elapsedMs`;
  `loop:false` clamps to the final frame (a one-shot animation holds, never re-wraps); degenerate
  input (`frameCount<=0`, non-finite `elapsedMs`/`fps`, `fps<=0`) fails closed to frame 0.
  `TokenNodeSpec.visual` (the `types` module) is now a discriminated union: `{kind:"image", url} |
  {kind:"animated", source: ResolvedAnimatedSource, fps, loop}` — a token's URL is reachable only
  through the `image` arm, never as a bare field — `ResolvedAnimatedSource = {type:"frames", urls:string[]} | {type:"sheet", url, rows,
  cols, count?}`, already asset-id-resolved to serve URLs by `AssetResolver` (the backend never
  resolves asset ids itself). `DisplayBackend.tickTokenAnimations(dtMs): void` — the new per-frame
  animation-advance seam, called once per frame alongside `startTicker`; `MockBackend`'s
  implementation is an intentional no-op (frame-advance state lives only in `PixiBackend`'s real
  `AnimatedSprite`s). `TokenView.tick(dtMs)` calls both `this.animator.tick(dtMs)` (transform tween,
  unchanged) AND `this.backend.tickTokenAnimations(dtMs)` (new). `TokenView.toSpec` resolves a
  token's visual via `resolveTokenVisual` (see `shadowcat-codebase-actors-tokens`) then a private
  `resolveSource` maps `AnimatedSource` → `ResolvedAnimatedSource` through `AssetResolver`.
  **`PixiBackend`'s Container-per-token structure** (migrated off a bare
  `Sprite`-per-token + three separately-tracked sibling Maps): one `TokenNode` per token —
  `container` (outer, does NOT rotate, positioned at the token center; `badges` are its DIRECT
  children so condition-marker glyphs stay upright regardless of token facing) →
  `visualContainer` (inner, rotates with the token via `.angle = spec.rotation`) → holds `visual`
  (a `Sprite` or `AnimatedSprite`) + `border` (`Graphics`) as siblings. `AnimatedSprite` playback is
  entirely tick-driven: `autoUpdate = false` (never Pixi's own shared ticker), frame index advanced
  in `tickTokenAnimations` via `computeAnimatedFrame`. `node.sourceKey` short-circuits a re-push
  with an unchanged visual (a tweening token's transform-only updates never touch the visual/sprite
  object). **Load-bearing invariant — guard async texture/frame-load completions on OBJECT
  IDENTITY, not just a string/key match:** `replaceVisualChild` can recreate a token's `visual`
  object (image↔animated kind-swap, or a rapid A→B→A visual-cycling sequence), so an in-flight
  texture/frame-load promise's completion callback MUST check `node.visual === sprite` (the exact
  object captured at load-start) in addition to `sourceKey`/`id` equality — a key-only check lets a
  stale promise write into an already-`.destroy()`'d Pixi object once the visual has been recreated
  more than once while the load was in flight. The animated branch's `replaceVisualChild` call is
  ALSO conditional (`if (!(node.visual instanceof AnimatedSprite))`), mirroring the image branch, to
  reduce how often the object gets recreated in the first place. Any future code touching this
  async-completion pattern (anywhere in-flight code can swap in a different display object) must
  follow the same object-identity-guard shape; a key-equality guard is not sufficient here
  [[async-completion-needs-object-identity-not-key]].
- `engine` (client/render module) — `visionSweeps: Map<tokenId, {samples, elapsed,
  durationMs}>` drives the mover's fog sweep during `MoveStream` playback (keyed per token — unions
  concurrent sweeps' visible sets rather than clobbering). `animateSamples(id, samples, durationMs,
  startServerMs, moverVision?)` starts a sweep only when `moverVision` is present (an observer never
  populates this — observers receive `moverVision: null` from the egress clip and simply tween
  position). While `visionSweeps.size > 0`, the engine feeds the sweep polygon (cross-faded between
  samples, or SNAPPED to the nearest sample when no next sample is available or more than one
  sweep is concurrently in flight — see `pixi-backend` below) to the compositor instead of the
  last `vision` subscription payload; reverts to that payload the instant the sweep map empties
  (sweep end or catch-up completion).
- `fog-blend` (client/render module) — `computeFogBlendFactor(clock, tCur, tNext)`:
  pure, unit-testable blend-factor helper (0 at `computeFogBlendFactor.tCur` → 1 at `computeFogBlendFactor.tNext`, clamped `[0,1]`; a
  degenerate/non-finite span snaps to 1 — fail-safe toward the newer sample, never frozen on a
  stale one). Extracted from `pixi-backend` because that module is WebGL-only (Playwright-covered,
  no jsdom GL context).
- `pixi-backend` (client/render module) — `setVisibilityBlend(from, to, factor)`
  rasterizes both the outgoing and incoming vision-sample fog into `RenderTexture`s via the shared
  `captureFog`/`paintFogSheets` helpers (the SAME paint path `setVisibility` uses — draws IDENTICAL
  fog for a given input) and alpha cross-fades between them; falls back to snapping to the nearest
  sample when a next sample is unavailable or more than one sweep is concurrently in flight. No polygon morphing
  — cross-fades rasterized textures only.
- `lighting` (client/render module) — `Lighting` class (GL-free, unit-tested):
  resolves gradation band→darkening alpha + tint color, applies `renderHint` (e.g. `"darkvision"`
  → gray-wash desaturation overlay), and interpolates day/night fades. Called by `PixiBackend`
  `setLighting` which renders per-cell darkening/tint sprites + a `BlurFilter` for soft band edges.
- `Stage` (`src/modules/stage`) — mounts the render engine over a `ReadableDocuments` view.
- `src/modules/scene-tools/` — the `controller` + `hit-test` modules, tools (place/select/move/
  draw/template/measure/ping/wall/region) dispatching intents. Wall tool writes a **three-flag**
  segment: `blocksSight` + `blocksMove` + `blocksLight`. Region tool (`makeRegionTool`) drags out
  a rect/circle/polygon `region` doc (`ToolController.regionShapeMode`/`regionBehavior`/
  `regionCost`/`regionSecret` reactive fields) via `buildRegionDoc` +, when `regionSecret`,
  `setRegionVisibility(doc, true)` (declares `/engine` `gm_only` at construction — not
  `/system`; the create op never carries the geometry in the clear). Create-only, mirroring
  `makeWallTool`: no edit UI for an already-placed region's behavior/cost/visibility/`enabled` — a
  GM re-authors via delete+recreate, or the server's live `enabled` toggle (region_field already
  honors it) without a UI surface. `buildRegionDoc`/`setRegionVisibility`/`RegionEngine`/
  `RegionShape`/`RegionShapeKind`/`RegionBehavior` are exported from `@shadowcat/core`'s public
  entrypoint module (the client type is `RegionEngine`, not `RegionSystem` — no
  back-compat alias; the entrypoint's export list is written by hand, so any future `scene-docs`
  addition needs its own export line — it is not automatic).
- `scene-docs` (`src/client/core/src`) — **vision/lighting/movement data model: the server mask
  consumes these shapes; the client lighting render (see `lighting` above) is display-only**:
  world-scoped config-docs `world-settings`/`light-gradation`/`vision-modes`
  (builders + deep-frozen defaults `DEFAULT_WORLD_SETTINGS`/`DEFAULT_GRADATION`/`SEED_VISION_MODES`;
  builders `structuredClone` the frozen default), per-scene `SceneSystem.vision?`/`lighting?`
  overrides + `grid.distance?` + `bounds?`, the scene-parented `is_engine_doc_type::light` doc_type
  (`LightEngine` + `buildLightDoc`), and the fail-closed resolvers `resolveSceneSettings`/
  `resolveGradation`/`resolveVisionModes`. **`bounds`:** `SceneDimensions {width,
  height}` (grid units) — the navmesh's triangulation boundary; per-scene ONLY, no
  world-settings layer; `resolveBounds` (private helper called from `resolveSceneSettings`) falls
  back to the deep-frozen `DEFAULT_SCENE_BOUNDS = {width:100,height:100}` on absent OR malformed
  (non-finite/≤0-on-either-axis) input — never a degenerate rectangle, never throws. Authored by
  `src/modules/game-settings/` (see `shadowcat-codebase-client-shell`).
- **Multi-scene viewing / GM local roam.** `resolveViewedScene(store, {gmViewedScene?})`
  (`scene-docs` module) is the single client-side answer to "which scene does THIS client render/
  subscribe to". Resolution order: a resolvable `gmViewedScene` (GM-only local override) → a
  resolvable `world-settings.system.activeScene` (`WorldSettingsSystem.activeScene: string |
  null`, new field, deliberately EXCLUDED from `resolveSceneSettings`'s existing
  structural-completeness triple so an older world-settings doc missing this key stays
  "complete") → the first scene (legacy single-scene fallback) → `null` only when no scene exists
  at all. Fail-closed by construction: an id naming a scene that no longer exists is treated as
  unresolvable and skipped to the next tier, never rendering nothing while scenes exist and never
  leaking a stale scene's channel. `WorldSession.viewedSceneId` (the `worldSession` module) is the
  live getter (`resolveViewedScene(this.#optimistic, {gmViewedScene: role==="gm" ?
  this.#gmViewedScene : null})`); `setGmViewedScene(id)` sets the GM-only `#gmViewedScene` $state
  (warns + no-ops for a non-GM), and also scene-scopes `tokenSelection`: it stashes the live
  `TokenSelection`'s ids into `WorldSession`'s private `#tokenSelectionByScene` map (keyed by the
  scene being left, read via `viewedSceneId` before the switch) and restores whatever was stashed
  for the scene being entered (empty if never visited) — a GM roaming away and back keeps their
  selection instead of leaking it across scenes or losing it. `sendPing`, `onMoveStream`, and the `scene_ping` handler all
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
    the hit-test, the selection ring and the place tool, so they belong beside the document view
    all four read. `AppContext.footprints` is the getter; `RenderEngineOpts.footprints?: () =>
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
  - **Deliberately NOT behind the `appliedSeq` watermark that guards `vision`.** That watermark
    exists because fog is the client's secrecy gate; an extent is a rendering quantity with no
    confidentiality stake, and holding it back would delay a purely cosmetic correction. If a
    future field on this channel ever carries a secrecy stake, that decision has to be revisited —
    it is a property of the payload, not of the channel.
  - Cost of the seam, by design: a freshly placed actor-backed token draws at the scene's unit
    footprint for one round trip, until its own resolved extent arrives.

## Hard invariants

- **The canvas renders the OPTIMISTIC view** (`AppContext.documents` / `OptimisticClient`), NOT
  the authoritative `store` — the store is the rollback base; `appliedSeq` is identical so the
  derived watermark holds [[render-from-optimistic-view]].
- **Fog is the secrecy gate — fail closed.** A client-side visibility gate that is the SOLE thing
  hiding already-delivered data must hide-everything on a missing/garbled signal; container-local
  coords reused across containers must be tagged + filtered to the active container
  [[fog-is-the-secrecy-gate-fail-closed]].
- **A value cached across a client-local scene switch must never be pre-filtered against the
  scene that was active when it was cached — recompute the scene filter at the point of
  application, against whatever scene is current THEN.** This generalizes/complements the
  fog-fail-closed invariant above to a NEW failure axis: multi-scene viewing means the "active
  scene" a cached value should be filtered against can itself change before the cache is
  consumed. `RenderEngine.pendingDerived` is the concrete instance: a `vision` frame
  arriving before `store.appliedSeq` catches up is held behind the watermark. Caching an
  ALREADY-FILTERED `VisibilityInput` (the result of `toVisibility`/`toLighting` run at
  frame-ARRIVAL time) is what must not happen: a client-local scene switch
  (`reapplyViewedScene`) can land while a frame sits pending, and that stale pre-filtered snapshot
  is then silently flushed and painted on top of the SWITCHED-TO scene once the watermark catches
  up — a fog hole computed for scene A rendered on scene B. So `pendingDerived` caches the RAW
  `{payload, seq}` only, and
  `flushPendingDerived()` re-runs `toVisibility(p.payload)`/`toLighting` at FLUSH time, which reads
  `viewedScene()` internally and therefore always filters against the scene that is current AT
  FLUSH, not at arrival. Any future engine cache that spans a client-local scene switch (not just
  vision/fog) must follow this same raw-payload-cache/filter-at-consumption shape — filtering
  eagerly and caching the filtered result is the bug pattern to avoid.
- **`flushPendingDerived` never regresses `lastAppliedSeq` to
  a stale `pendingDerived` entry superseded by an immediately-applied newer frame.** `onSceneFrame`'s
  IMMEDIATE-apply branch (taken when a frame's `computedAtSeq` is not ahead of `store.appliedSeq` at
  arrival) never touched `pendingDerived` — a still-set OLDER deferred entry (e.g. seq 5) could
  survive past a newer frame's (seq 7) immediate apply advancing `lastAppliedSeq` to 7, then get
  wrongly re-applied by a LATER `flushPendingDerived` call (any subsequent store commit), regressing
  the mask back to seq 5. Fix: `flushPendingDerived` now applies a pending entry only when
  `p.seq > this.lastAppliedSeq` at flush time (checked AFTER the `store.appliedSeq >=
  p.seq` watermark check, BEFORE the `toVisibility` re-filter) — otherwise discards it; the pending
  slot is unconditionally cleared as soon as the watermark condition is met, applied or not. This is
  a distinct guard from the scene-refilter-at-flush fix directly above (that fix is about WHAT
  scene a cached payload filters against; this one is about WHETHER a superseded payload should
  apply at all) — both guards live in the same function and must both be preserved by any future
  edit to `flushPendingDerived`.
- **Vision is server-authoritative, no client prediction**; movement that
  crosses a `blocksMove` wall is rejected server-side before the write — validate the **post-image**
  position, not just the pre-move one [[m9-progress]].
- **`Room::publish`'s non-GM block retains only two gates, neither a traversal gate.**
  (1) An `Update` touching a token's `/engine/x`/`/engine/y` is refused
  outright on bitwise `a0 != a1` (position changed at all) — zero wall/mask/traversal-cell checks;
  a select/move-tool drag never writes `/engine/x,y` directly at all — it goes through
  `makeSelectMoveTool.previewMoves`/`makeSelectMoveTool.commitMoves`, request-only via `moveRequest` → `execute_move`, the SOLE remaining
  implementation of the per-cell traversal decision (see the parity-checklist bullet above).
  (2) A `Create` of a `token` doc is still authorized: the target scene must exist
  (`scene_grid_sizes`, fail-closed axis 6 above), the engine body must parse and be finite
  (fail-closed), and the placement's CENTER cell (`resolve_grid_shape(...).cell_of((x,y))` — a
  point, not a traversal, so no `line_traversal`/supercover call here) must lie in the user's mask
  per `movement_restriction`: `Unrestricted` ⇒ no check; `Visible` ⇒
  `visible_cells_cached(user, scene, lenient)`; `Revealed` ⇒ the same mask unioned with
  `get_explored` (deferred past the scene-read-lock scope, since `get_explored` is async and must
  not run under the guard). GMs are exempt from
  both gates entirely. `publish::visible_cache`/`publish::explored_cache` memoize per `(scene, lenient)`/
  `scene` within one `publish` call so a batch of Creates doesn't recompute the mask or refetch
  explored per token. **By design: a dark scene under `Visible` still refuses non-GM token
  placement into an unseen cell** — the same fail-closed reasoning the per-step traversal gate
  uses, scoped here to Create. Do NOT "fix" this by softening the defaults — it is the correct
  fail-closed outcome.
- **Bound recursive walks over self-FK (parent_id) tables with a visited-set** [[m8a-execution-state]].
- **Scene-settings resolvers are fail-closed and inheritance-layered**: `resolveSceneSettings`
  resolves built-in default < `world-settings` doc < per-scene override, never throws (structural
  guard tolerates a partial `world-settings` wire doc), and a per-scene override of `null` means
  **inherit** (resolver `??` chains treat null and undefined identically). The deep-frozen
  `DEFAULT_*`/`SEED_*` constants are immutable-by-design; builders `structuredClone` them so no
  frozen/shared reference reaches a doc.
- **The server lit mask is the lighting-aware secrecy gate**: `player_lit_mask(user)` =
  `LOS ∩ (lit ∨ darkvision)`, union over the user's vision sources (owned tokens ∪ observer-tier
  tokens when `observerVision`), emitted as per-recipient `lit` cells. Wire format:
  5-int `[i,j,band,tint,hint_idx]` + a top-level `renderHints:[String]`
  table (index into the hint name, e.g. `"darkvision"`); `VisionMode` carries `render_hint`;
  `player_lit_mask` resolves a per-cell hint via the highest-floor admitting vision mode (`None` wins
  ties). Fail-closed (no source / dark scene ⇒ empty; cell scans bounded by
  `explored::MAX_CELLS_PER_POLYGON` with a `saturating_mul` span guard). Egress is ADDITIVE —
  `polygons` + the post-lock `explored` are unchanged, GM stays `mode:"all"`. **Environment light
  is edge-projected and `blocksLight`-occludable SERVER-SIDE (`lighting::env_light_polys`,
  `SceneEcs`'s `lighting_inputs_from`) — this is a genuine secrecy input, not cosmetic.** A cell's
  illumination (`lighting::cell_illumination`) composes the boundary-projected environment ambient
  with placed lights and feeds `point_qualifies`/`cell_visible`, which gates both `player_lit_mask`
  and the movement gate (`visible_cells`/`visible_cells_cached`) — so occluding the
  environment ambient behind a `blocksLight` wall genuinely narrows what a non-GM can see and move
  into, the same as a placed light's occlusion. `env_light_polys` samples the scene-bounds
  perimeter (`MAX_ENV_LIGHT_SAMPLES=256`, clamped `[4, 256]`) and reuses the SAME
  `vision::visibility_polygon` primitive + `light_walls` set placed lights already use — no forked
  occlusion computation. **Fail-closed/strictly-narrowing by construction:** the occluded
  environment base is `≤` the pre-occlusion flat-floor level everywhere (an empty `env_polys` set
  or a cell outside every boundary polygon contributes 0, never negative), so the composed
  illumination — and therefore the derived visibility mask — can only SHRINK relative to the prior
  flat-ambient behavior, never grow; this monotonicity is what makes the projection safe to ship as
  a secrecy input even independent of `env_light_polys`'s own occlusion-computation correctness.
  **The CLIENT-side render (the `Lighting` class) is UNCHANGED and remains purely COSMETIC** — it resolves
  band→darkening alpha + tint + `renderHint` desaturation for display only; fog stays the sole
  *rendered* secrecy gate on the client, and the client performs no occlusion computation of its
  own. Do not conflate the two: server-side environment occlusion is a load-bearing secrecy input,
  client-side lighting is display-only.

- **The pathfinder route is footprint-STRICTER than the center-based authoritative gate on WALLS,
  but its MASK predicate is now a superset of the gate's.**
  `cell_enterable`'s wall check (footprint-disc clearance) is stricter than the
  authoritative gate's center-based wall check — a wide token can be dragged
  (gate allows the center path) along a corridor the router refuses (footprint doesn't fit); this
  wall asymmetry is intentional and safe (over-restrictive, never under). The MASK check requires
  `grid.inputs.shape.footprint_cells(to,...) ∪ grid.inputs.shape.line_traversal(from,to,cell)` — the same RESOLVED
  `GridShape` primitives `scene::move_exec` uses per step — so the router's mask predicate is
  provably `≥` the gate's; **route ⊆ gate-allowed holds for every footprint size**, including the
  sub-0.5-cell diagonal case a footprint-disc-only check lets the router approve while the gate
  rejects it. Never make the pathfinder mask test weaker than
  `grid.inputs.shape.footprint_cells ∪ grid.inputs.shape.line_traversal` — that union IS the invariant, not merely
  a suggestion. **Both halves must come from the SHAPE, never the free square functions**
  (`pathfinding::footprint_cells`, `movement::supercover_cells`): those are `SquareGrid`'s own
  internals, and calling them here indexes cells by square coordinates against a mask that may be
  hex-axial — a square-on-hex misclassification the type system does not catch. See
  checklist axis (2) above and the shape-identity invariant below.
- **The `route ⊆ gate-allowed` invariant is engine-agnostic, not grid-specific.**
  `SceneEcs::pathfind` builds the per-`(user,scene)` visibility mask exactly once and passes the
  SAME reference into both the grid (`pathfinding::find`) and continuous (`navmesh::
  clip_to_visible_mask`) branches — never a forked mask computation. `clip_to_visible_mask` applies
  the identical `grid.footprint_cells ∪ grid.line_traversal` predicate `cell_enterable` uses, so a
  continuous-scene route preview is fog-safe by the same mechanism the grid router already proved.
  Any future third routing engine MUST reuse this same mask-passing shape, not recompute visibility.
  **Passing the same MASK is necessary but not sufficient — the same GRID SHAPE must travel with
  it.** Indexing route samples with square `floor(p/cell)` against a `mask`/`RegionField` built on
  a hex-axial grid silently misclassifies cell membership. `clip_to_visible_mask`,
  `los_smooth::chord_ok` and `truncate_at_arrest` all take `&dyn GridShape`, and the caller
  MUST pass the same `resolve_grid_shape`-derived shape those sets were built from — in the weighted
  branch that means `&*grid_shape`, NOT the Euclidean-ruled `pathfind::euclid_shape` in scope (the diagonal
  rule feeds step cost and the heuristic, never cell identity: `rule` is a `SquareGrid`-only field
  read solely by `neighbors_with_cost`/`heuristic`). Shape identity IS the invariant; a shared mask
  indexed in two coordinate systems is not a shared mask.
- **`execute_move`'s per-cell gate is the sole movement gate, footprint-aware for
  walls/mask/impassable, center-cell for arrest/terrain.** There is no second gate
  to keep in parity with — `Room::publish` runs no wall/mask/traversal geometry for a
  non-GM (see the single-gate constraint list at the top of this section) — so this bullet
  describes `execute_move`'s OWN per-step checks, mirroring `pathfinding::cell_enterable`'s four
  checks exactly rather than a second implementation of them:
  (1) **wall gate** — BOTH the footprint disc vs every `move_walls(scene, None)` segment
  (`point_segment_distance`) AND the center-to-center `segments_cross` test, exempt for a GM;
  neither check replaces the other, matching `cell_enterable`'s own two wall checks;
  (2) **mask gate** — `footprint_cells(next) ∪ GridShape::line_traversal(prev, next)` must lie
  entirely in `visible` (for `Revealed`, the caller MUST pass `visible_cells ∪ explored`, same union
  `publish`'s Create gate uses), skipped for GMs and for `Unrestricted`;
  (3) **impassable** — footprint-gated (any footprint-overlapped cell counts, not just the
  destination center), exempt for a GM;
  (4) **arrest and terrain stay CENTER-CELL ONLY** — mirroring `pathfinding::cell_enterable`'s own
  documented asymmetry: footprint-gating arrest would make the executor STRICTER
  than the router and break parity with the router. Terrain cost accrual is independent of the GM
  exemption (cost is information, not a gate).
  Both directions of that parity (`route-admissible ⇔ gate-admissible` for a non-GM mover) hold on
  `GridStepped`; on `Continuous` only the weaker `route ⊆ gate-allowed` is claimed (the continuous
  router's own mask/wall checks are a superset of the executor's, not a bidirectional mirror).
  **GM exemption (supersedes any prior "GM wall-honored" framing):** a GM bypasses
  EVERY gameplay gate — walls, mask, impassable, arrest, footprint clearance — on `execute_move`,
  landing exactly at the requested destination (`truncated: false`), exactly as `publish` has always
  let a GM place a token anywhere. Do NOT read this as "GMs get no checks at all": resource/
  admissibility guards are NEVER exempted for a GM on either path — `gate_walk`'s
  `MAX_GATE_WALK_COORD`/`MAX_GATE_WALK_SAMPLES`, non-finite refusal, `MoveReject::SceneUnknown`, the
  footprint-radius range guard, and `Room::publish`'s Create-gate scene-existence refusal all still
  apply unconditionally. **Admissibility is a SECOND, DISTINCT axis from the gameplay-gate
  exemption, and this holds for every gate, not just movement:** `MAX_GATE_WALK_COORD` binds in every restriction mode
  including `Unrestricted` (which short-circuits the mask check later, not the admissibility check).
  An anti-drift test exercises the exact bound and bound+1.0 through the shared symbol, so a value
  change or a `>`/`>=` flip fails. The executor is not stricter
  on authored path shape than a hand-authored waypoint list: `gate_walk` subdivides any >1-cell
  authored jump into dense ≤1-cell samples and gates each one, equivalent to the client having sent
  the explicit intermediate waypoints (no new capability; security lives entirely in the per-cell
  gate, never the shape check).
- **Streamed vision is strictly leak-free — no fork of the secrecy decision, fail closed
  (`fog-is-the-secrecy-gate-fail-closed`).** The mover's swept vision trajectory raycasts the SAME
  `sight_walls` (full set, incl. `gm_only`) as `player_vision_polygons`; the observer egress clip
  filters against the recipient's OWN authoritative vision (never the mover's) — a `gm_only`-walled
  area is never streamed to a non-owner because the observer's own vision already excludes it. No
  render-path leak: the full trajectory is broadcast in-process only; `egress_loop`'s dedicated
  branch strips it per recipient before the sink write, same discipline as `Event`/`vision` egress.
  A wholly-occluded move is suppressed (zero frames), never sent as an empty-`samples` frame — an
  observer must not learn a move even happened if they can't see any of it. `mover_vision` is
  disclosed to the mover only (nulled for every other recipient, incl. a full-vision GM observer who
  has no fog to sweep anyway). **Scope of the leak-free claim:** "strictly leak-free" covers the
  IN-FLIGHT path only; RESTING token positions still ride the position `Event` + client-side fog
  model (delivered to all scene readers, fogged client-side per `fog-is-the-secrecy-gate-fail-closed`)
  — this does not change that. **Concurrent-move clip, against the recipient's OWN in-flight
  vision timeline, not just their committed vision.** `ws::conn::clip_move_stream` resolves the
  clip target's in-flight streams via `Room::mover_streams` and clips each sample of the OTHER
  token's `MoveStream` per-sample-instant against `ws::move_clip::timeline_polys_at` (falling back
  to committed vision — `player_vision_polygons` — while the target has no active stream): a
  sample is admitted only if it lies inside the union of the target's chosen vision sample
  (`ws::move_clip::chosen_vision_sample`) at that sample's absolute server time. **Re-emit on
  own-move:** when the clip target's own move starts (their vision timeline just came into
  existence), `egress_loop`'s `MoveStream` branch re-clips and re-sends every OTHER in-flight
  stream in the scene via `Room::concurrent_streams`, under its original `token_id` (the client
  overwrites keyed playback in place, per `TokenAnimator.animateSamples`'s replace-in-place
  contract) — this is what reveals a third-party mover the instant the recipient's OWN sightline
  opens mid-walk, rather than only at the mover's stop. **Client parity, mechanically pinned:**
  `chosen_vision_sample`'s rule (greatest `t_ms <= elapsed`, first sample when none precedes) must
  match the client's `chooseVisionSample` (`fog-blend.ts`) exactly, or a sample admitted
  server-side would not be the one the client's sweeping fog shows; both sides assert against the
  shared fixture `src/client/render/src/__fixtures__/chosen-vision-sample.json`. **Known v1
  limitation, now narrower (by design, not a bug):** a THIRD PARTY's moving LIGHT SOURCE opening a
  sightline mid-walk still reveals its mover only at that mover's stop — the light-carrying move's
  own vision would need to be recomputed per sample, which this clip does not do (it clips against
  the RECIPIENT's own vision timelines, never a third party's); reconciles at the stop + the next
  `vision` rebroadcast, same as before. Client computes NO vision in any of this — it renders only
  the streamed, already-clipped polygons.
- **Region secrecy is a two-value contract on `region_field`, never a third mode.**
  `region_field(scene, None)` = authoritative (GM + `move_exec`); `region_field(scene, Some(user))`
  = per-requester (the router only). Callers must never pass `Some(gm_user)`. By construction the
  router's field is a SUBSET of the authoritative field — a secret region can
  narrow a player's route/preview but can never appear to them where it wouldn't to the GM, and it
  always still applies at `move_exec` regardless of what the router showed. Reuses the EXACT same
  `resolve_access` + `property_overrides["/engine"]` mechanism as ordinary document egress (not
  `"/system"`), through `engine_tier_visible` — no new secrecy machinery was introduced for regions.
  **Fixture-construction precision (test/brief authoring convention):** the correct way to mark a
  region `gm_only` in a test fixture is
  `doc.permissions.property_overrides.insert("/engine".into(), Visibility::GmOnly)` — matching the
  read `engine_tier_visible_to` performs on `region_field`'s behalf
  (`doc.permissions.property_overrides.get("/engine")`, default
  `Visibility::All`). Setting `permissions.default = Access::None` instead does NOT gate
  `region_field`'s per-requester filter at all (that field only reads the `/engine`
  `property_overrides` entry) — a test or spec author who reaches for `permissions.default` here
  writes a region that still weights a non-GM's route.
- **The continuous-engine dispatch predicate MUST read the PER-REQUESTER region field, never the
  authoritative one.** `has_terrain_or_impassable()` is evaluated against `region_field(
  scene, Some(user))` for a non-GM — this is the single mechanism preventing a secret
  terrain/impassable region from indirectly leaking its own existence via route-shape or reported
  cost even though its geometry is never disclosed. A future refactor that fed the authoritative
  field into ONLY the dispatch predicate, while still correctly routing/costing off the
  per-requester field, would silently reopen this leak (dispatching to the weighted path at all is
  itself a signal a secret region exists). Treat as load-bearing, not incidental.
- **Polyanya does not weight — the cell `region_field` is the universal weighting overlay for
  BOTH engines.** Polyanya 0.16.1's only cost-affecting knob is the
  `detailed-layers`-gated `Layer.scale` (a per-layer coordinate transform) — off in
  this build's `default-features = false` config and semantically wrong as a per-unit cost
  multiplier even if enabled (crate-source-verified, not README-derived). A continuous route that
  needs weighting is therefore computed by the SAME `pathfinding::find` the grid engine uses
  (forced `DiagonalRule::Euclidean`), never by a polyanya cost-layer/`blocked_layers` mechanism —
  those polyanya features remain available but are deliberately UNUSED for regions in this
  codebase. Do not "improve" continuous weighting by reaching for polyanya's own layer API; the
  cell field is the one and only weighting authority for every routing engine this project has.
- **A whole-region-scalar disclosed on `MoveStream` must default to trusted-recipient-only, not
  broadcast-by-default.** `PathResult.arrested: bool` is always disclosed (no secrecy concern — it
  only tells the requester their OWN already-visible route is truncating). `MoveStream.cost:
  Option<f64>` is `Some` for the mover/GM (trusted, full information) and `None` for a clipped
  observer, mirroring `mover_vision`'s null-for-observers pattern — because the
  authoritative cost may reflect `gm_only` secret-region terrain the observer's own vision would
  never reveal, so broadcasting it unconditionally is a Critical leak. **Load-bearing invariant,
  not a footnote:** any
  FUTURE whole-move scalar added to `MoveStream` must default to the same trusted-only disclosure
  pattern unless explicitly proven safe to broadcast to every recipient.
  - **Exercised once, as `MoveStream.truncated: Option<bool>`** — `Some` for the mover/GM, `None`
    for a clipped observer, set alongside `cost` at all three construction points
    (`handle_move_request`'s broadcast frame, `clip_move_stream::full_gm_stream`, and its
    clipped-observer tail). The leak it prevents is distinct from `cost`'s: an observer's `samples`
    and `stop` are ALREADY clipped to what they witnessed, so a truthful `truncated` would answer a
    question their view cannot — whether anything stopped the token BEYOND their vision, disclosing
    a wall or a `gm_only` region they cannot see. **When adding the next scalar, derive its leak
    from what the clip already hides, rather than copying `cost`'s rationale**; the mechanism is
    shared but the disclosure differs per field.
  - The secrecy is mutation-proven, not merely asserted: setting the clipped tail to `*truncated`
    fails `clip_observer_sees_near_side_prefix_any_angle_diagonal_path` and
    `clip_gm_see_as_clips_to_target_vision`. A future scalar should carry an equivalent negative
    test, since a leaked field is otherwise invisible to every gate.
  - **A wire scalar needs THREE client-side edits or it is silently discarded.** Adding the field
    to the Rust variant is not "wiring it": the client re-validates every inbound frame through a
    hand-written Zod schema (`wire.ts`'s `move_stream` object), and `z.object` STRIPS keys it does
    not name — no parse error, no warning, the value simply never arrives. The full path is the
    Zod schema, the `MoveStream` interface in `ws-client.ts`, and that file's snake_case→camelCase
    mapper in the `"move_stream"` case; miss any one and the field is unreachable from client
    code while every gate stays green. `truncated` is pinned end-to-end by assertions on the
    parsed value and on the mapped object, mover and clipped-observer paths both.
  - **`truncated` is NOT interchangeable with the client's derived move outcome.**
    `WorldSession.moveRequest` derives `WorldSession.moveRequest.executed`/`truncated` from
    geometry (does `stop` equal the
    requested goal), which is a DIFFERENT predicate: a region arrest on the final step sets the
    server's `truncated` while `stop` still equals the goal, and the client deliberately reports
    that as `WorldSession.moveRequest.executed` because the token did reach the goal. Do not
    "simplify" the client to read
    the wire flag — the two answer different questions, and a regression test pins the arrest case.
- **The four shape views are a NEAR-IDENTICAL SIBLING SET, and that is where they diverge silently.**
  `drawing-view`, `template-view`, `region-view`, and `wall-view` share one shape: a
  `reconcile()` diffing scene-scoped docs against tracked ids, and a module-private `toSpec()`
  returning `ShapeNodeSpec | null` where `null` means "don't render". Because they are written by
  copy-and-adapt, a change made to one is easy to omit from the other three, and nothing structural
  catches it. Two divergences the four must not reacquire:
  - **Non-numeric coordinate guards** must be identical in all four, and their placement is
    load-bearing:
    the guard runs on the RAW authored fields BEFORE tessellation, because JS coerces `null` to 0 in
    arithmetic — `circlePoints(null, 5, 10)` yields finite, plausible geometry that a
    post-tessellation check cannot distinguish from an authored shape.
  - **`"rect"` means different geometry per file**: a ROTATED square via `squarePoints` (side
    `2*size`, centred on the anchor) in `template-view`, versus an axis-aligned bbox between two
    authored corners via `rectPoints` in `drawing-view`/`region-view`. Same string, different shape.
  **When you change one of these four, diff it against the other three.** [[docs-sweep8-render]]
- **`RegionView` mirrors `WallView` exactly** — a dumb per-frame reconciler with
  NO client-side secrecy logic. The `"regions"` render layer sits between `"tiles"` and
  `"drawings"` in the `layers` module's `CORE_LAYERS`. Only regions the viewer is permitted to see ever
  reach `store` in the first place: `setRegionVisibility(doc, true)` sets `permissions.default =
  "none"` (NOT just a `/engine` override — not `/system`), so `filter_command` drops a secret region's whole
  `Create` op for non-owner/non-GM recipients — the doc never arrives, not even redacted — while
  `region_field`'s per-requester view independently keeps a secret region out of a non-GM's
  pathfinder/budget field. There is no client-side hide check to get wrong, by design.

## Gotchas

- **Docs-ratchet is live on `data::engine::scene` + `data::engine::geometry`, the
  whole `scene` module tree, and `health`:** every file carries
  `#![deny(missing_docs)]` + the private-items twin — a new undocumented item fails the 3-OS CI
  clippy step, and doc comments on ts-rs types flow into the bindings (regenerate + commit them
  with the change). Movement/traversal docs cite `move_exec::execute_move`/`gate_walk` (never
  `Room::publish` — the stale-citation class); hex `size` docs state the outer-radius
  (circumradius) convention — keep both true when touching those seams.

- **`GridShape::footprint_cells`'s r=0 tie-break is a TRAIT-LEVEL contract, not a
  `SquareGrid`-only accident.** A zero-radius `footprint_cells::ctr` is a literal point, not a
  disc, so "which cell does it belong to" is genuinely ambiguous exactly on a shared boundary or
  corner; both implementations resolve it to `footprint_cells::anchor` (the single cell
  `GridShape::cell_of` would assign), never a multi-cell tie. `pathfinding::footprint_cells` (the
  `SquareGrid` delegate) resolves this via an explicit `r_scene <= 0.0` early return — its
  axis-aligned loop bounds (`floor((ctr∓r)/cell)`) collapse to one index at r=0 independently of
  the guard, so the guard states the invariant explicitly rather than changing behavior.
  `HexGrid::footprint_cells`'s ring-scan + `distance_to_cell_polygon` test has no such collapse and
  genuinely ties across 2-3 hexes at r=0 without an explicit early return — same trait contract,
  independently implemented, independently subject to the identical tie. A
  positive-radius disc on a boundary correctly admits every touching cell on BOTH shapes (genuine
  positive-area overlap, not a bug) — never narrow that case when touching this guard.
  `scene::move_exec::execute_move`'s mask/impassable footprint disc is anchored at the true
  continuous dense-walk sample (`execute_move::next`, not a `cell_center(next_cell)`
  substitution), matching the wall disc's anchor exactly — this guard is what makes that anchoring
  safe on both grid kinds.
- **Scene auto-creates on GM entry** (scene system schema `{grid, background}`); Stage reads the
  grid [[scene-lifecycle-gap]].
- **Clear tool overlays/previews on a mid-gesture tool swap** (draw preview, measure overlay) or
  stale geometry persists.
- **`resolved_diagonal_rule` is world-only** — there is intentionally no per-scene `diagonalRule`
  override in the pathfinder; the same rule applies across all scenes in a world. Matches the client
  `resolveSceneSettings` precedence (the setting lives in `world-settings`, not per-scene).
- **`RegionField::is_arrest`/impassable checking is footprint-gated in the router (`cell_enterable`'s mask
  check, via `grid.inputs.shape.footprint_cells ∪ grid.inputs.shape.line_traversal`) but CENTER-CELL-ONLY in `move_exec` — a
  deliberate asymmetry (route stricter, execution looser), not a bug.** `route ⊆
  gate-allowed` still holds because the router's predicate is already a documented superset of the
  executor's. Do not "fix" `move_exec` to match the router's footprint check without re-deriving
  the parity argument — the asymmetry is load-bearing, matching the wall-check
  asymmetry the pathfinder invariant above already documents.
- **`find()`'s arrest truncation recomputes cost by REPLAYING `step_cost`, never by trusting
  `astar_leg`'s per-leg running total for the truncated prefix.** Parity threading is purely
  sequential/order-dependent (not leg-boundary-dependent), so a naive "sum the per-leg totals up to
  the truncation point" would be wrong whenever the truncation falls mid-leg; the cost-replay
  technique (walk the surviving cell sequence from parity 0, re-run `step_cost` per pair) is the
  only correct way to get an accurate truncated cost.
- **A whole-BAND `GmOnly` override must NULL the field, not remove the key, in
  `filter_properties`.** `Document::system` is a required serde field — dropping the `"system"`
  key from the redacted JSON before re-deserializing into `Document` panics; dropping an optional
  band's key is instead indistinguishable from a document that never carried one, breaking the
  client's stable envelope shape. One shared classifier decides this, not a per-pointer arm:
  `redaction_target` reads the band set stated exactly once in `permission::REDACTABLE_BANDS`,
  classifying an override that names a whole band as `Band` (nulled in place) and one that
  descends into a band as `Within`. A new redactable band is therefore a new entry in that
  constant, never a hand-written branch here. Nested redaction is container-dependent — an object
  key is stripped, an array element is nulled in place; see
  `shadowcat-codebase-documents-permissions` for that within-band rule. A whole-band override is
  currently declared only by secret regions, at `/engine` rather than `/system`; any future doc
  type wanting whole-body secrecy (vs. per-field) rides the same classifier.
- **A fixed-count cube lerp is a THIN LINE, not a supercover.** The standard Red Blob hex
  line-draw samples `n+1` points with `n = max cube-axis delta`, spaced one full hex PITCH
  apart — a hex's minimum width — so corner slivers fall between samples: it omits a
  geometrically crossed hex on ~55% of random segments, and when `n` rounds to 0 it drops the
  destination's own hex, breaking the "both endpoint cells always included" contract. Because
  this is the hex movement gate's primitive `move_exec` relies on for cell-membership checks,
  every omitted hex is one a non-GM could move through unchecked against the visibility mask.
  `HexGrid::line_traversal` instead IS a **ψ-crossing supercover**: `cell_of` is
  nearest-center, so a hex is its center's Voronoi cell and every hex boundary lies on an integer
  level set of ψ₁=x−y, ψ₂=z−y, ψ₃=x−z (fractional cube coords) — enumerate every integer ψ crossing,
  sample each interval's midpoint, plus a perpendicular epsilon probe either side of each crossing
  and both endpoints (edge-riding / vertex / endpoint-on-boundary). Over-inclusion is the only
  failure mode and is safe HERE because this set feeds gates only, never a reveal write (the sole
  explored-set writer, `ws::conn::enrich_vision_explored`, is fed by vision polygons via
  `mark_polygons`) — re-check that property before reusing it anywhere else.
- **"The square failure mode can't happen here" is not a safety argument.** Hex genuinely has no
  analog of the square diagonal-corner-tie bug — 6 uniform neighbors, no orthogonal/diagonal
  split — and that true statement is what let the thin-line traversal ship unexamined: hex had its
  OWN omission class. Establishing that a known failure mode is absent says nothing about which
  failure modes the new geometry has of its own. Related and identical in shape: `scene::navmesh`
  was excused from a hex audit as "the continuous-model router, orthogonal to grid kind" — but grid
  kind and movement model are INDEPENDENT axes, so they COMBINE (`hex` + `continuous` is a live
  scene) rather than exclude, and it was square-on-hex at three sites. Independence is a reason to
  CHECK a site, never to skip it.
- **`supercover_cells`'s corner-crossing branch never drifts
  past the target on a diagonal king-step whose leg endpoints both sit exactly on 4-way grid-line
  intersections.** The diagonal corner-step is gated on a per-axis
  remaining-step budget (`supercover_cells::remaining_i`/`supercover_cells::remaining_j`): it fires
  only when BOTH axes still owe a grid-line crossing, and once either budget hits zero only the
  other axis steps, regardless of any tie between
  `supercover_cells::t_max_i`/`supercover_cells::t_max_j`. A tie alone must never step an axis that
  has already arrived: a forced single-axis step (from an endpoint sitting exactly on a grid line)
  puts the two step-parameter values into permanent lockstep, and every later tie would then
  re-step the arrived axis, drifting past `(ei,ej)` until `MAX_MOVE_CELLS` aborts with `None`.
  Convergence is therefore a property of the bounded step budget, not of floating-point
  tie-breaking; the safe-over-include behavior for genuine mid-path corner
  crossings (both flankers emitted) is covered by dedicated regression tests in
  `scene::movement`. `execute_move`'s frozen-fixture "diagonal 3-step king path, full visible" case
  (`scene::move_exec`) pins the non-truncated outcome.
- **Cross-scene `MoveStream`/`ScenePing` leak class — exists only because per-client scene
  divergence is possible.** When every client renders the SAME scene (`activeScene`, in
  lockstep), there is no per-client "which scene am I looking at" state for a broadcast
  fan-out egress path to diverge against, so this leak class cannot exist.
  `gmViewedScene` (GM local roam) is what introduces per-client scene divergence: a
  room-wide `MoveStream`/`ScenePing` broadcast now reaches connections that may be viewing
  DIFFERENT scenes than the event targets. `WorldSession` closes it client-side by dropping any
  frame whose `scene` doesn't equal `this.viewedSceneId` (`onMoveStream`/the `scene_ping` handler,
  the `worldSession` module) — a GM roaming scene B must not animate/ping-render scene A's event, and
  vice versa. **Any future per-client "which scene am I looking at/subscribed to" feature must
  re-audit EVERY broadcast fan-out egress path for this same divergence class, not just the render
  layer** — `MoveStream`/`ScenePing` are the two that carry the client-side scene filter; a new room-wide
  broadcast type added later (chat, pings, future presence/cursor frames) inherits the same risk
  the instant any client can view something other than the room's single shared `activeScene`.

## Pointers

- **Generated API** — `/api/rust/shadowcat/scene/` (rustdoc, private items included),
  `/api/ts/modules/_shadowcat_render.html` (TypeDoc), `/api/ts/modules/_shadowcat_module-scene-tools.html`,
  `_shadowcat_module-stage.html`. Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 (invariants 3, 5, 6 + the geometry exception) + §7 (rendering provenance).
- Relationships:
  `graphify query "scene ECS derived read-model vision fog stage pixi render tokens regions faces animated"`.
- History/decisions: [[m8-brainstorm]], [[m8d-2-scene-tools]], [[m9-progress]],
  [[server-authoritative-movement-rule]], [[m10-pathfinding-architecture]].
