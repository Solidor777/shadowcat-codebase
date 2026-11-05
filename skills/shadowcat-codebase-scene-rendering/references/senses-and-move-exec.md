# Creature senses, execute_move and the movement budget gate

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::senses, scene::move_exec, Room::execute_move's budget gate or SceneEcs::token_position.

- `scene::senses` — creature senses (tremorsense & kin). `VisionMode` is the v2 descriptor:
  `perceives: Perception` (terrain | creatures), `requires_los`, `render_hint`, beside
  `illumination_floor`/`default_range`; `VisionModesEngine::seed` adds `tremorsense` (creatures,
  no LOS, 12 cells). A terrain sense behaves exactly as before (`LOS? ∩ illumination ≥ floor`); a
  creature sense perceives TOKENS: `SceneEcs::token_creature_senses` resolves a source's creature
  senses through the SAME `token_vision_assignments` precedence walk the terrain floors use, and
  `SceneEcs::player_perceived_tokens(ctx, world_defaults, &mask)` lists, per scene, the tokens a
  recipient perceives ONLY through one — source and target both grounded (elevation 0; a flying
  token is immune the moment it leaves the ground), within range, READ-gated through the same
  `ctx_access` authority as the document stream (creature senses pierce fog, never the READ gate),
  and disjoint from the `lit` set by construction (the one computed mask is passed in as the
  exclusion set). Emitted as the masked payload's `perceived: [{scene, tokens}]`, absent on the
  GM arm, never accumulated into explored fog. **`senses::sense_perceives` is THE reach
  decision, at rest and in motion:** `player_perceived_tokens` calls it per (source, target), and
  the move-stream clip calls it for the frame's mover through `InstantSight::sees_token`
  (`RecipientSight::sensed` — the mover token, admitted under the same `ctx_access` READ gate;
  each `SightSource` carries its `senses` from `VisSrc.senses`), so a tremorsense observer keeps
  a grounded token WALKING through walls and darkness exactly as it names it standing still,
  and a flying mover is not felt either way. Creature senses perceive tokens, never light: the
  glow gate reads `InstantSight::sees` alone.
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
  because the router's mask predicate is already a superset (see the pathfinder invariant in references/invariants-routing-and-execute-move.md).
  **Keyed on CELL-ENTRY TRANSITIONS, not per dense sample:** a continuous path subdivided
  into several sub-cell samples within the same cell is evaluated exactly once for that cell,
  matching the prior per-authored-step accrual count on grid input (where every step already
  crossed into a distinct new cell); re-entering a cell already crossed earlier in the SAME walk
  (A → B → A) still re-evaluates correctly since the dedup only compares against the IMMEDIATELY
  prior cell, never a stale earlier value. Impassable stops BEFORE entry into the cell (like a
  wall — `stop` lands on the prior cell); arrest stops AT entry (the cell is entered, then the
  walk halts — a final-step arrest still sets `truncated: true` even though `stop_index ==
  path.len()-1`). **`MoveOutcome.cost` is UNIFIED with the router's own diagonal-rule
  pricing, not terrain-only.** On `GridStepped`, each cell-entry transition prices through the
  SAME `GridShape::neighbors_with_cost` lookup `pathfinding::astar_leg` uses (parity threaded
  exactly as `astar_leg`'s arrest replay threads it — never reset per transition), falling back to
  the Euclidean span in cells only for a transition the shape's own neighbor enumeration doesn't
  recognize (a >1-cell jump gated through a `GridStepped` scene); on `Continuous`, each transition
  prices as the Euclidean span in cells since the last transition, the same number
  `navmesh::los_smooth`/the polyanya router report for that geometry. **Continuous "tail charge":**
  the per-transition loop only prices FULL cell-entry transitions, so a `Continuous` move that
  halts mid-cell (wall/mask/region/budget stop, or reaching a goal that isn't itself a transition)
  is additionally priced for the span since its LAST transition, at the STOP cell's own
  `pathfinding::terrain_cost` read (the mover's tag-resolved multiplier, 1.0 for an
  `ignore_terrain` mover) — mirroring the whole-polyline integration `los_smooth`/the polyanya router apply to
  the same geometry. `GridStepped` needs no such tail: its dense samples land exactly on cell
  transitions, so the per-transition price above already reflects the router's own exact quantity.
  A reader trying to reproduce an exact `Continuous` cost figure needs to add this tail span, not
  just sum the per-transition prices. Either way the transition's
  price is then multiplied by `pathfinding::terrain_cost(Some(&regions), next_cell, traits)` —
  the mover's tag-resolved `RegionField::resolved_terrain_multiplier` (the flat cost, or a
  `cost_by_tag` override the mover's tags select; 1.0 outside any terrain region — a
  per-step-distance BASELINE, not merely additive weighting; a plain grid move with no regions at
  all still accrues its diagonal-rule step price), or a constant 1.0 when
  `MoveGateInputs.traits.ignore_terrain` is set (see the movement-tags bullet in references/movement-types-and-continuous-regions.md). Pinned by
  `router_preview_cost_equals_executor_cost_per_diagonal_rule` (`GridStepped` parity, every
  diagonal rule) and `continuous_smoothed_preview_cost_equals_executor_cost` (`Continuous` parity),
  both in `scene::tests::cost_parity`, plus that module's four `exempt_mover_*` cases (grid,
  pure-polyanya continuous, impassable-forced weighted continuous, and the `los_smooth` chord
  path) for an `ignore_terrain` mover. This is what makes `MoveOutcome.cost`
  the number `shadowcat-codebase-combat`'s per-turn movement-budget gate can safely multiply by a
  resource's per-cell conversion (`Room::execute_move`'s `resolved_budget.cost_to_resource`) — a
  route preview and its execution report the identical price for identical geometry on every
  diagonal rule, not only Chebyshev. `pathfinding::astar_leg`'s own step-cost function
  (`astar_leg::sc` — 1.0/2.0/√2/alternating) is the exact same underlying `step_cost` this reaches
  through `neighbors_with_cost`; neither this executor nor the router ever calls `step_cost`
  directly (see the gotcha in `shadowcat-codebase-combat`). `supercover_cells`'s
  lattice-corner-tie drift (a diagonal king-step whose leg endpoints both sit exactly on 4-way
  grid-line intersections could otherwise spuriously fail-closed) is prevented by a per-axis
  remaining-step budget gating the diagonal corner branch.
- **`Room::execute_move`'s per-turn movement-budget gate — owned here for placement/commit
  mechanics; the combat document shapes it reads are owned by `shadowcat-codebase-combat`.**
  Resolved under the SAME ECS read guard as every other gate input
  (`SceneEcs::active_combat_for_scene(token_scene)` then `SceneEcs::combatant_for_token`); a miss
  on either means no gate applies, never a refusal. `BudgetGate` carries no `TurnControl` field at
  all — `Room::execute_move` never reads `TurnControl`/`turn_control` anywhere in its budget-gate
  logic (only `BudgetGate.is_turn_owner`/`interpretation`/`enforcement`/`enforced`).
  **`BudgetGate::enforced` decides whether the gate's refusals and truncation apply to this caller
  at all, and it is whole-document `cap::READ` — never a re-derivation from any single permission
  field.** `SceneEcs::combatant_for_token(combat, token, ctx, world_defaults)` returns the resolved
  `Access` (not a bare hidden flag) from `SceneEcs::ctx_access` — the same `effective_owner_via` +
  `resolve_access_world` pair `filter_command` uses at egress — and `enforced` is
  `access.has(cap::READ)` on it. `false` means the caller moves EXACTLY as if the token named no
  combatant: no `NotYourTurn` refusal, no truncation, no `BudgetUnresolvable`. This is a secrecy
  requirement, not a convenience — either refusal or truncation would disclose both the combatant's
  existence and its exact numeric budget through move behaviour alone, reachable without owning
  that combatant's own token because `combatant_for_token`'s `actor_id` fallback matches ANY token
  instanced from the same actor. The decrement still commits (it writes only that combatant's own
  document, which `filter_command` drops wholesale for a recipient lacking `cap::READ` — uniformly
  across `Create`/`Update`/`Delete`, never Update-specific). Because the flag and egress read the
  same live document, a PER-DOCUMENT
  `permissions.users` grant or override moves both in lockstep — but that parity claim is scoped to
  per-document permissions and does NOT extend to world capability defaults, which `execute_move`
  reads fresh per move while WS egress reads once per connection under a
  takes-effect-on-next-reconnect policy. TWO shapes are reachable there, in opposite directions: a
  world-level READ GRANT binds the gate before egress delivers (narrow — it admits nothing egress
  would not eventually deliver anyway), and a world-level READ REVOCATION fails OPEN, because
  `http::routes::set_world_capability_defaults` REPLACES the whole `WorldCapDefaults` rather than
  extending it, so a caller whose `cap::READ` came only from a world grant sees `enforced` go false
  and moves UNBUDGETED until their next reconnect. `resolve_access_world` being additive does not
  bound this — the defaults VALUE it reads is what shrank. Accepted as a documented residual (a
  gameplay-budget laxity with no disclosure component), and specific to THIS gate:
  `combat::authorize` resolves the same defaults fresh per intent and fails CLOSED on the same
  revocation, so do not reason about the two as one residual. Turn-owner enforcement is
  **Hard-only, and it's an outright REFUSAL, never a truncation to zero**: under
  `Enforcement::Hard`, a non-exempt, non-turn-owner mover's move is rejected outright
  (`Err(DataError::Forbidden)`, logged as `MoveReject::NotYourTurn`) before any budget/cost
  resolution runs; under `Warn`/`None` a non-turn-owner's move is never rejected on this basis at
  all. **`BudgetUnresolvable` refusal axis, independent of enforcement mode:** for a non-exempt
  caller, either the combatant carrying no entry for the combat's movement resource, or (under
  `Interpretation::PerCell`) the scene carrying no `grid.distance` to convert the resource into
  cells, refuses the WHOLE move outright (`Err(DataError::Forbidden)`, `MoveReject::
  BudgetUnresolvable`) — this refusal applies regardless of `enforcement`, including `Warn`/`None`,
  because the decrement needs a resolvable budget even when the gate itself never truncates. For an
  exempt caller, either unresolvable condition instead DEGRADES to "move freely, no decrement" (the
  same outcome as a token bound to no combatant at all) rather than refusing the move. **"Exempt"
  is one expression read by all three of these paths** (`resolve_budget::exempt`, which is
  `is_gm || !bg.enforced`): a GM by the gameplay exemption every other axis of this gate also grants, or a
  caller the gate is not `enforced` against. Both still take the decrement path when the budget
  resolves. The gate inputs are built by `budget_gate_for_token` (the combat lookup, the
  registry binding for the combat's movement resource, the combatant's stored entry, its
  formula-host document via `SceneEcs::combatant_formula_host`, the per-cell scale, `enforced`)
  and decided by `resolve_budget` — ONE shared resolution `handle_pathfind`'s route-preview
  clamp consumes too. The budget itself is `combat::budget::resolve_movement_budget`
  (`shadowcat-codebase-combat`), which `SceneEcs::resolved_combats` reads for the `"combat"`
  channel's `movement_cells` as well: it derives `current`/`max` through
  `combat::eval::resolved_resource` (lazy-full: an ABSENT entry reads as full and the decrement
  materializes it with a Null OCC pre-image; a `Mirror` binding or an evaluation failure is
  unresolvable — on the channel as `None`, at the gate as a refusal), and the gate's
  `BudgetResolution::Resolved` carries the truncation ceiling (non-exempt + Hard only) bounding
  `move_exec::MoveGateInputs.budget`. **Lock ordering carries a step for this
  gate:** `Repository::world_cap_defaults` is awaited AFTER `publish_guard` is taken but BEFORE the
  scene read guard, because `ctx_access` needs it under that read guard and a scene read guard is
  never held across an await. Fetched unconditionally — whether a combat is even running is itself
  only knowable under the guard — and propagated with `?` rather than defaulted, so an unresolvable
  authority input refuses the move instead of being guessed at. The resolved budget's
  execution — `outcome.cost * resolved_budget.cost_to_resource` — commits as a SECOND, SEPARATE
  command from the token's position write: the position `Update` (`/engine/x,y`) commits
  unconditionally under `WriteOrigin::Client`; the combatant resource decrement commits only after
  that succeeds, under `WriteOrigin::CombatTransition`, floored at zero and skipped entirely for a
  zero-cost move. Never bundle these under one origin — see
  `shadowcat-codebase-combat`'s hard invariant on why that specific consolidation is a real authz
  bypass, not a simplification.
- `scene` — adds `SceneEcs::token_position(token) -> Option<(f64,f64)>` and
  `SceneEcs::resolved_animation_speed() -> f64` (`pub(crate)` seams; the latter sits alongside
  `resolved_diagonal_rule`, sources `world_settings.animation`, defaults to 6 cells/sec).
  **Streamed-vision seam — ONE LOS read:** `SceneEcs::sight_sources(user, world_role,
  world_defaults, scene) -> SightSources` resolves the recipient's vision sources ONCE per move
  through `gather_vision_sources_in_scene` (owned ∪ observer-tier tokens — the mask's own
  admission, never a second rule), each raycast by `source_los_poly` at its elevation's
  `blocksSight` walls (the full set incl. `gm_only`); `SightSources::los_at` is the cheap
  per-sample call — re-raycasts only the sources its caller relocates (the mover's own token at a
  sample viewpoint) and borrows the committed polygon for every other source (the test wrapper
  `SceneEcs::player_vision_polygons_at(user, scene, moving_token, viewpoint)` is one `los_at`).
  `player_vision_polygons` (the fog's `polygons`) is `sight_sources(..).polygons()` over every
  token scene, so the fog a client draws, the sweep it plays and the samples the egress clip
  admits cannot disagree about where a recipient can see. Empty when the recipient has no source
  in the scene (fail-closed).
