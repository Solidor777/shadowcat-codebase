# Movement-type tags and regions on the continuous engine

Part of the shadowcat-codebase-scene-rendering skill; read it before changing movement-type tags, the terrain exemption, or how regions apply on the continuous engine.

- **Movement-type tags and the terrain exemption — ONE resolver, ONE flag, ONE cost read.**
  `scene::movement_tags` owns the server side: `TERRAIN_EXEMPT_TAGS` (`"flying"`,
  `"incorporeal"` — the only tags the engine interprets; every other tag is inert system
  vocabulary), the single reserved-semantics predicate `ignores_terrain_cost(&tags)`, and
  `SceneEcs::token_movement_tags(token) -> BTreeSet<String>` — the linked/instanced/override
  precedence `token_vision_floors` uses (a present `TokenOverrides::movement` REPLACES the set
  wholesale; otherwise `ActorEngine::movement` ∪ the faction record's `Faction::movement`, joined
  through `SceneEcs::faction_registry_engine`, the faction registry now hydrated into the ECS
  config side-tables beside `vision_modes`/`gradation`; a dangling actor link or a raw/unknown
  token yields the EMPTY set — a mover whose tags cannot be resolved is never exempt; the
  instanced branch reads the embedded actor through the uncached `engine_as` path, same rule as
  `token_vision_floors`). The two request seams — `ws::conn::handle_pathfind` (for the named,
  authorized token only; a hypothetical-footprint preview is non-exempt) and
  `Room::execute_move` (in the same read-guard block as `footprint`) — resolve the flag ONCE
  into `pathfinding::MoveTraits` — which carries `ignore_terrain` AND `tags: BTreeSet<String>`,
  both resolved from the SAME `token_movement_tags` call so the exemption and the per-tag cost can
  never disagree about a mover — and carry it in `RouteMover.traits` / `MoveGateInputs.traits`;
  neither the router nor the executor re-derives it. `MoveTraits` is Clone but not Copy
  (it owns a tag set), so `terrain_cost` and its callers take it by reference; never clone it
  inside a per-cell loop. The GM
  gameplay-gate exemption does not touch this: a GM moving a flying token is priced as flying.
  Every pricing site reads the flag through the ONE chokepoint `pathfinding::terrain_cost(
  regions, cell, traits)` — `astar_leg`'s edge weight, `replay_step_costs` (arrest + budget
  truncation), `navmesh::los_smooth`'s per-span cost, and `execute_move`'s per-transition and
  Continuous tail pricing — plus the two non-price reads: the continuous dispatch predicate
  (`has_impassable()` alone for an exempt mover) and `los_smooth`'s chord rule (terrain dropped
  from the refusal set). The chokepoint also resolves `RegionEngine::cost_by_tag` for the mover
  via `RegionField::resolved_terrain_multiplier` — per covering terrain region the MINIMUM cost
  whose tag the mover carries, falling back to that region's flat cost when none matches, then
  the MAX across overlapping regions (the same rule `compose` applies to flat costs). Both the
  flat and the per-tag values are clamped `.max(1.0)` in `SceneEcs::region_field_if`, the one
  body every region-field read shares (`RegionFieldBuilder::add_parts` itself does not clamp), so
  a negative or `NaN` authored cost collapses to `1.0` before any reader sees it. The two
  multiplier readers, `RegionField::terrain_multiplier` (flat) and
  `RegionField::resolved_terrain_multiplier` (tag-resolved, which falls back to the flat reader
  for a cell no `cost_by_tag`-bearing region covers), therefore cannot diverge on a bad authored
  value. **Tag costing only PRICES movement; it never changes which cells are enterable.**
  `cost_by_tag` is read only through `resolved_terrain_multiplier` (pricing, plus the
  weighted-terrain predicates that pick a router engine and gate `los_smooth`'s chord
  straightening), and none of the enterability decisions reads a mover's tags:
  `pathfinding::cell_enterable`'s wall, mask, wall-crossing and impassable-footprint checks and
  `execute_move`'s wall, mask, impassable and arrest gates are identical for every mover, so the
  route-is-a-subset-of-gate-allowed invariant and the mask/wall checks are untouched by tags. A
  tag can change which enterable route is cheapest and what it costs, never which cells a mover may
  enter. **The exemption is terrain COST only**: walls, impassable, arrest and
  the visibility mask gate an exempt mover exactly as anyone else (pinned by
  `exemption_never_covers_impassable_or_arrest` in the `move_exec` unified-cost suite), and the
  per-requester region-field secrecy rules are untouched — an exempt mover's route simply ignores
  terrain it can see AND terrain it cannot, since terrain never stops a move. The combat
  movement-budget gate consumes `MoveOutcome.cost` unchanged, so an exempt mover spends less
  identically in preview and execution
  (`exempt_mover_decrements_the_exempt_cost_where_the_ground_mover_pays_the_multiplier`).
  `navmesh_find` prices its returned polyline as an f64 sum over its own spans, never polyanya's
  own f32 per-leg length: `clip_to_visible_mask` passes a wall-less, mask-less (GM) outcome through
  unrecomputed, so an f32-rounded preview would be a cost the executor's f64 span sum cannot
  reproduce.
