# Hard invariants: pathfinder route and execute_move gate

Part of the shadowcat-codebase-scene-rendering skill; read it before changing pathfinder footprint/wall rules, the route-subset-of-gate invariant or execute_move's per-cell gate.

- **The pathfinder route is footprint-STRICTER than the center-based authoritative gate on WALLS,
  but its MASK predicate is a superset of the gate's.**
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
  checklist axis (2) in references/scene-ecs-and-engine-reroot.md and the shape-identity invariant below.
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
