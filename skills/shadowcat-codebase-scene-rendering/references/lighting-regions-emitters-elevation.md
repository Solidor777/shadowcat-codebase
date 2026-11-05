# Region ambient light, carried-light emitters and elevation

Part of the shadowcat-codebase-scene-rendering skill; read it before changing the region ambient-light override, scene::emitters or scene::elevation.

- **Region ambient-light override — a FINAL per-cell adjustment step over the composed
  illumination, applied by `LightingInputs::cell_light`** (`scene::visibility_compute`) after
  either base: the additive `cell_illumination_from` sum, or the flat `all_bright` level-1.0
  base. **INVARIANT: the adjustment applies EVEN under `LightMode::GlobalIllumination`** (and
  under lighting-off) — the `all_bright` short-circuit skips gathering placed lights and light
  walls, never this edit; a scene with no `"ambient_light"` region stays byte-identical either
  way (`LightingInputs.ambient.is_empty()` fast path). The read path is
  `SceneEcs::ambient_light_map(scene, levels, level)`, NOT `SceneEcs::region_field` directly —
  `ambient_light_map` calls the shared `region_field_if` body with a LEVEL-SPAN predicate
  (`elevation::band_overlaps_level`, matching any elevation of the level's span), while
  `region_field` itself tests a single mover POINT elevation (`elevation::band_contains`) and
  takes no `level`/`levels` parameter at all. Both facets share that ONE iteration body
  (doc_type/parent/`enabled`/`/engine`-tier-visibility/shape-parse filtering + the
  `behavior`→`RegionBehavior` mapping), so region admission can never drift between the two
  reads — only the elevation predicate and the viewer differ (see the `region_field`
  two-value-contract bullet in references/invariants-streamed-vision-and-regions.md for the viewer split).
  **Fold rules** (`regions::compose_ambient`, folding every enabled `AmbientLight` contribution
  covering a cell into one `regions::AmbientAdjustment`): `Override` wins OUTRIGHT over any
  `Darken`/`Brighten` on the same cell (mirrors `Impassable > Arrest > Terrain`'s
  strongest-wins shape); overlapping `Darken`s and `Brighten`s SUM their signed deltas into one
  net delta — additive perturbations over a baseline, NEVER a max (unlike terrain cost, which
  takes the max of overlapping multipliers); two different `Override`s on the same cell resolve
  to the DARKER of the two levels — the subsystem's fail-closed/under-reveal convention applied
  to an authoring conflict rather than to a missing input. `AmbientAdjustment::apply` clamps an
  `Override` into `[0, 1]` and a `Delta` result into `[0, 1]` after adding to the base.
  New types (`data::engine::geometry`): `AmbientLightMode` (`darken | brighten | override`),
  `AmbientLightOverride { mode, level }`, `RegionEngine::ambient_override:
  Option<AmbientLightOverride>` (`RegionEngine::validate` enforces that a present
  `ambient_override` implies `behavior == "ambient_light"`, a finite `level`, `[0,1]` for
  `override`, `>= 0` for `darken`/`brighten`); `behavior` gains the `"ambient_light"` string
  value alongside `"terrain"`/`"impassable"`/`"arrest"`.
  **Cache gotcha, guarded against by dedicated tests rather than by inspection alone:** both
  `LightingInputsSnapshot` and `VisibilityInputsSnapshot` carry the composed ambient map
  (`self.ambient_light_map(scene, &levels, &mover_level)`, the AUTHORITATIVE read) as a
  cache-key field precisely because `cell_light` consumes it — a snapshot field that instead
  held a placeholder/default value (rather than a genuine re-read of the region set) would
  leave that key INERT: the fingerprint would never change on a region edit, so a stale
  cached lighting/visibility field would keep serving after an `"ambient_light"` region was
  added, edited or deleted, until some UNRELATED input happened to also change. This is
  exactly the class of bug an equality-based cache (see the `engine_as_cached`/
  `visible_cells_cached` bullets in references/scene-ecs-and-engine-reroot.md) is silently vulnerable to for any field it forgets to
  thread — the cache-invalidation tests
  (`lighting_inputs_cache_invalidates_when_an_ambient_region_is_added_or_edited`,
  `visible_cells_cache_invalidates_when_an_ambient_region_is_added`) are what catch a
  regression of this shape, by asserting a fresh recompute (not a stale hit) after exactly
  such an edit — a green build with no such test would not.
- `scene::emitters` — the carried-light seam. `eng::LightEmission` `{color, intensity,
  brightRadius, dimRadius, falloff?, enabled}` (radii in cells; `Falloff.curve` is the closed
  `FalloffCurve` enum `linear | quadratic | none`) is the ONE emission payload: a standalone
  `LightEngine` is `{x, y, elevation?, emission}` and `ActorEngine.light` / `TokenOverrides.light`
  carry the same struct (wholesale override; `enabled: false` is the suppress path).
  `SceneEcs::token_light_emission(token)` resolves a token's effective emission with
  `token_vision_floors`' linked/instanced/override precedence (dangling link ⇒ none; the
  instanced branch reads the embedded actor through the uncached `engine_as`, same rule as the
  floors), and `SceneEcs::scene_lights(scene)` is THE one read into the illumination field's
  light set — standalone `light` docs ∪ every token's carried emission at its LIVE position,
  sorted by a fully deterministic chain — so the lit mask, the movement gate
  (`visible_cells_cached`'s snapshot fingerprints the union) and environment composition all
  inherit a carried light with no second path. **The emitter's visibility is not consulted**: a
  fogged or permission-hidden token still illuminates (the glow precedes the bearer; the GM
  authored the emission — mirrors a `gm_only` wall still blocking sight). `emitters::light_reach`
  (max finite positive radius × `world_units_per_cell`, the authored-distance scale) and
  `emitters::light_polygon(pos, walls, reach)` (`bound_for_reach` + `visibility_polygon`) are
  THE light occlusion raycast — `lighting_inputs_from` and the carried-light move timeline
  (`MoverLightInputs::sample_at`, in references/move-stream-and-egress-clip.md) both call it, never a second raycast rule.
  `SceneEcs::token_sound_emission(token)` shares this SAME linked/instanced/override resolution
  precedence for the audio subsystem's carried `SoundEmission` — see `shadowcat-codebase-audio`
  for `scene::audibility`'s falloff/occlusion/listener-selection geometry, which composes
  `segments_cross`/`elevation::wall_occludes` rather than re-deriving occlusion.
  **Carried-light authoring is GM-only, server-enforced:** `permission::carried_light_touched` /
  `carried_light_in_body` classify any write that creates, changes or removes an emission (direct
  pointer writes, value-compared ancestor writes, removals, create bodies), and `apply_intent`
  refuses them for a non-GM on both arms — an emission edits the SHARED field every viewer's
  mask reads, unlike the owner-writable presentation fields.
- `scene::elevation` — the 2.5D multi-level elevation model. `TokenEngine.elevation` /
  `LightEngine.elevation` (absent = `GROUND`; `elevation_or_ground` clamps a non-finite stored
  value to ground) are POINT elevations; `WallEngine.elevation`/`RegionEngine.elevation`/
  `DrawingEngine.elevation`/`TemplateEngine.elevation` share ONE band type,
  `eng::ElevationBand {bottom?, top?}` — a wall's sight/light occlusion band and a
  region/drawing/template's floor band are the SAME shape, never a per-engine copy: absent band ⇒
  every elevation, absent end ⇒ unbounded.
  `band_contains(band, e)` is `bottom ≤ e ≤ top`, and it FAILS CLOSED to "contains everything" on
  a malformed interval or a non-finite band endpoint — `wall_occludes(band, e)` wraps it with one
  more fail-closed case (a non-finite SOURCE elevation also occludes). `band_contains` is the ONE
  point-in-band predicate every consumer calls: `wall_occludes`, the movement gate
  (`SceneEcs::move_wall_entries`'s per-mover filter), `SceneEcs::region_field`'s and
  `SceneEcs::trigger_regions`'s per-mover selection, and the render filters — mirrored exactly by
  `@shadowcat/core`'s `bandContains` (`sceneScopedDocs`'s TS twin), pinned by the shared
  conformance corpus. Elevation only ever FILTERS the occluder set per source — the star-shaped
  raycast pipeline is untouched and sight/light ranges stay 2D: `sight_wall_entries`/
  `light_wall_entries` collect the scene's walls as `elevation::WallEntry` values once, and every consumer filters
  them through `walls_at_elevation` at ITS source's elevation (`sight_walls_for`, each light in
  `lighting_inputs_from` at the light's own elevation, a carried emission at its token's) — except
  environment ambient, which keeps the FULL light-wall set at every elevation (walls always shadow
  sky-light, or daylight would flood interiors). The visibility-cache snapshot fingerprints each
  source's elevation, so the same walls at two elevations never share a cached mask. Accepted
  residual (owner-writable token elevation lifts a GM-authored carried light over a deliberately
  banded wall) is bounded by the emission's own reach — the light discloses nothing farther than
  its `dim` radius would at ground level, and no token, wall or region geometry the READ gate
  withholds.
  **`SceneEngine.levels: Vec<SceneLevel>`** (each `{id, name, bottom, top, background}`, ts-rs
  exported) declares a scene's named floors; `level_of(levels, elevation)` resolves the level
  whose `[bottom, top)` band contains a point elevation — a roof (past every level's top) resolves
  to the highest level whose `bottom` it clears, and an elevation below every level's bottom
  resolves to the lowest level; `levels: []` resolves `None` (the degenerate pre-levels case,
  identical to legacy single-floor behavior). Mirrored exactly by `@shadowcat/core`'s `levelOf`,
  same conformance corpus. `SceneSubscribe.level` (an optional field on the `scene_subscribe`
  wire frame) is consumed ONLY by `enrich_vision_explored`, which uses it to select which floor's
  persistent EXPLORED-FOG memory gets echoed into the `"vision"` payload's `explored` key — it does
  NOT scope what `compute_derived`'s `"vision"` arm computes overall: that arm always returns EVERY
  level's polygons/lit-cells in one payload, each group individually tagged with its own `level`
  (the multi-scope pattern `"footprints"`/`"audibility"` also use). The display-time restriction to
  one floor happens on the CLIENT: `RenderEngine.toVisibility`/`toLighting` filter the
  `polygons`/`lit` groups on `(g.scene === activeScene && (g.level ?? "") === (viewedLevel ?? ""))`
  before building the fog/lighting mask, `""` being the ground/level-less-scene spelling both sides
  use. Level-less scenes and an absent `level` leave `enrich_vision_explored`'s own scoping
  unaffected. No
  server-side resting-token fog-stripping exists per level: a level's explored fog is keyed by the
  level id in addition to the scene, and which USER key it accumulates under follows the scene's
  `FogPooling` mode (the recipient's own id under `Individual`, the shared sentinel under `Shared`
  — see the `scene::explored` bullet). `"footprints"` is NOT itself level-scoped by subscription (always the whole
  scene); each `TokenFootprint` entry instead carries its own resolved `level`
  (`level_of` at the token's stored elevation, `null` for a level-less scene OR an unstated token —
  the two are indistinguishable in the wire payload), redacted by
  ABSENCE like every other footprints field — see `shadowcat-codebase-documents-permissions` for
  the egress-conjunct shape this composes with. The movement/placement GATES
  (`SceneEcs::visible_cells`/`visible_cells_cached`, reached from `Room::execute_move`,
  `Room::publish`'s Create placement gate, and `SceneEcs::pathfind`) are level-scoped
  independently of this subscription field — see the `visible_cells_cached` bullet in references/scene-ecs-and-engine-reroot.md — by
  filtering gathered vision sources to the mover's OWN resolved level before accumulating cells,
  never by anything `SceneSubscribe.level` sets.
  **Portals**: a region's `TriggerEffect::Teleport { target: PortalTarget }` (`PortalTarget
  {scene, x, y, elevation, vfx}` — `scene: None` = the portal's own scene) repositions the
  entering token, committed under `WriteOrigin::Trigger` (a server-authored, capability-gate-
  skipping origin — full mechanism: `shadowcat-codebase-documents-permissions`), gated to ONE hop
  per move by `ws::room::Room::fire_region_triggers`'s own recursive re-fire (a boolean guard
  disallowing a second teleport on the destination cells' own `Enter` triggers — a chained portal
  is refused with a GM-only notice, never looped). A token teleported off its combat's scene
  keeps its combatant record and turn.
