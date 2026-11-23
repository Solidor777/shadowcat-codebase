# Continuous navmesh router (polyanya)

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::navmesh, the navmesh cache or the continuous-engine route.

- **Regions on the continuous engine.** `SceneEcs::pathfind`'s
  `Continuous` branch (`scene`) computes the per-requester `region_field` once (same call the
  `GridStepped` branch already made — the `GridStepped` branch itself is completely untouched by
  this) and dispatches on `RegionField::has_terrain_or_impassable(&traits.tags)` (`scene::regions`, taking the mover's tag set: true iff any
  cell is `impassable` or `terrain` weighted FOR THIS MOVER — the disjunction of `has_impassable`
  and `has_weighted_terrain`, both of which take the mover's tags, since a region may carry flat
  cost exactly 1.0 and still weight a tagged mover through `cost_by_tag`; arrest-only fields do NOT
  trigger this — arrest needs only a post-filter, not route-bending). **INVARIANT: the predicate's
  notion of "weighted" must stay identical to the cost function's.** A predicate that reads only
  flat cost sends a tag-weighted mover down the pure polyanya route, which applies NO terrain
  weighting, silently dropping that mover's terrain cost entirely. For an `MoveTraits::ignore_terrain`
  mover the predicate is `has_impassable()` ALONE: terrain is plain ground for them, so a
  terrain-only field takes the pure any-angle route, while impassable still forces the weighted
  sub-path for every mover (a straight chord must never skip the refusal). **Terrain/impassable present:** the
  existing `pathfinding::find` runs forced to `DiagonalRule::Euclidean` (continuous base metric —
  only cell topology + the terrain multiplier come from the grid, never the world's configured
  diagonal rule), its cost stays in CELLS, then `navmesh::los_smooth` restores any-angle
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
  FIRST, then `navmesh::truncate_at_arrest` on the clipped result — clip-then-truncate, so a
  fog-truncated route can never carry a stale `arrested: true` flag past the point the fog itself
  should have cut it. `clip_to_visible_mask` is exclusive to the pure-polyanya sub-path — the two
  continuous sub-paths enforce the SAME mask invariant through different mechanisms, not through a
  shared call.
  - `navmesh::los_smooth(outcome, inputs: &PathInputs)` — cost-guarded
    LOS string-pull smoothing for the weighted continuous path. It takes the SAME `PathInputs`
    bundle `find` searched under (the caller builds one and hands `find` an explicit clone
    differing only in `shape` — `PathInputs` derives Clone but not Copy, because its
    `traits.tags` is an owned tag set), so the mask, walls, region field,
    footprint and traits the chord rule checks are structurally the values the search admitted
    cells under; `regions: None` means no region enforcement here exactly as inside `find`. A span
    `path[i]..path[j]`
    straightens only when every cell its chord enters (`grid.footprint_cells ∪ grid.line_traversal`,
    the SAME union `cell_enterable`/`clip_to_visible_mask` use) is in `mask` (when `Some`), not
    impassable, not arrest, and — for a NON-exempt mover — not weighted terrain
    (`resolved_terrain_multiplier > 1.0` — tag-resolved, so a chord may not straighten through
    terrain that is weighted only for THIS mover's tags; an `MoveTraits::ignore_terrain` mover's chord ignores terrain,
    never impassable or arrest), and the chord
    crosses no `blocksMove` wall — so a straightened chord can never shortcut INTO terrain/
    impassable/arrest the weighted search deliberately routed around or truncated at. **The single
    grid step `path[i] -> path[i+1]` is ALWAYS kept unconditionally** (it already passed `find`'s
    per-cell gate), guaranteeing goal progress even when nothing else can straighten. Fail-closed on
    two levels: a whole-input short-circuit (`<3` vertices, degenerate `cell`/`footprint_radius_cells`)
    returns the input unchanged; a per-span fallback (an over-cap/degenerate `line_traversal` for
    one candidate chord) fails only that chord, leaving it at its single grid step while smoothing
    continues over the rest of the path. `arrested`/`truncated` are carried through unchanged;
    `cost` is RECOMPUTED exactly per smoothed span — `euclidean_span_cells` (the same formula
    `execute_move` prices a Continuous span with) times `terrain_cost` at the span's destination
    cell (1.0 for an exempt mover) — which is what `continuous_smoothed_preview_cost_equals_executor_cost`
    pins.
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
    `build_navmesh` treats an empty-buffer result for a non-degenerate wall as a hard
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
