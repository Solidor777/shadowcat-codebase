# Scene ECS, derived channels and the /engine re-root

Part of the shadowcat-codebase-scene-rendering skill; read it before changing SceneEcs, compute_derived, scene resolvers, bounds defaults, the movement-gate mask or the /engine typed accessors.

- `scene` — `SceneEcs` (derived read-model, hydrated from documents + the
  config-doc/actor side-tables `world_settings`/`gradation`/`vision_modes`/`actors`, set via
  `set_world_config`/`set_actors` and maintained by `apply_op`),
  `compute_derived(channel, ecs, ctx, world_defaults)` (builds derived frames; the `vision` masked
  payload is `{mode, polygons, bands, renderHints, lit, perceived}` — `perceived` being the
  creature-sense token ids, see the `scene::senses` bullet in references/senses-and-move-exec.md —, and `\"footprints\"` is the second per-recipient channel
  — see the derived-channel egress bullet in references/footprints-and-derived-egress.md. `world_defaults:
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
  and the Create placement gate — see the GM exemption bullet in references/invariants-routing-and-execute-move.md.
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
  `movementModel`/`snapToGrid` (in references/grid-pathfinding.md) are likewise typed `SceneEngine` fields, ts-rs exported
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
  **`visible_cells`/`visible_cells_cached` are LEVEL-SCOPED to the mover's own floor.** Both take
  a trailing `mover_elevation: f64` argument (mirroring `move_walls`/`region_field`'s own
  mover-elevation parameter) and filter `gather_vision_sources_in_scene`'s gathered sources down to
  those resolving to the SAME level (`elevation::level_of`) as the mover before any cell is
  accumulated — a source on another level of the same scene contributes nothing, matching
  `player_lit_mask`'s per-level accumulation exactly. Every caller (`Room::execute_move`,
  `Room::publish`'s Create placement gate, `SceneEcs::pathfind`) passes the mover's own resolved
  elevation, never a client-claimed one. **`visible_cells_cached`:** `SceneEcs::visible_cells_cached(user,
  world_role, world_defaults, scene, lenient, mover_elevation) -> BTreeSet<(i32,i32)>` is a
  per-`(user, scene)` memoized wrapper around the same
  mask `visible_cells` computes for the movement gate — `visible_cells` itself and every
  other existing caller (pathfinder, the grid-parity tests) are unchanged and still call the uncached
  primitive. Keyed on `VisibilityInputsSnapshot` (`{lenient, settings, cell, sources: Vec<(id, vp,
  floors)>, levels, mover_level, lights, light_walls, sight_walls}` — `sources` is already
  level-filtered, and `mover_level` is fingerprinted explicitly too rather than relying solely on
  the filtered `sources` list to imply it) — a VALUE-COMPARISON cache like `engine_as_cached`,
  not mutation-site invalidation: a cached mask is reused only when a freshly rebuilt snapshot
  compares equal to the one stored alongside it, so correctness is independent of which code path
  mutated the underlying documents (`apply_op`, `set_world_config`/`set_actors`, or any other
  setter). `sources` is sorted by id before hashing so hecs' non-stable iteration order can't cause
  a spurious mismatch. The snapshot already covers everything `env_light_polys` occlusion depends
  on (`settings.bounds`, `cell`, `light_walls`), so the `env_polys` addition to
  `lighting_inputs_from` needed no cache-key change to stay correct. **The illumination field
  itself is a SECOND memo, one level down:** `SceneEcs::lighting_inputs_excluding` (and
  `lighting_inputs`, its nothing-excluded spelling) returns `Arc<LightingInputs>` from
  `lighting_inputs_cache`, keyed per `(scene, sorted excluded emitters)` behind a
  `LightingInputsSnapshot` (`settings`, `cell`, `lights`, `light_walls`, `sight_walls` — the same
  value-comparison shape), bounded by `MAX_LIGHTING_INPUTS_CACHE_ENTRIES` (cleared wholesale past
  it). `visible_cells_cached`'s miss path, `player_lit_mask` and every recipient's `recipient_sight`
  read it, so a frame's light + environment raycasts run once per scene per in-flight set rather
  than once per recipient; `lighting_inputs_from` is the raycast step run only on a snapshot miss,
  and it skips `env_light_polys` outright at zero environment intensity (the engine default):
  `cell_illumination_from` admits no environment then, so the empty set is the identical field
  at zero raycasts.
