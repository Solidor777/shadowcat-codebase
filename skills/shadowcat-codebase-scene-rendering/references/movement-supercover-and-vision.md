# Supercover movement and vision raycasting

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::movement, scene::vision or scene::lighting.

- `scene::movement` — pure `supercover_cells(a0, a1, cell) -> Option<BTreeSet<(i32,i32)>>` —
  every cell the move segment crosses (supercover, not a thin line — an exact corner crossing
  emits BOTH flanking cells so a diagonal can't thread an unseen cell). `None` ⇒ caller fails closed
  (`cell<=0.0` / non-finite endpoint / span > `MAX_MOVE_CELLS`). Clean-room (Amanatides–Woo extension);
  relative-epsilon corner test (over-include is the safe direction).
- `scene::vision` — raycast `visibility_polygon(viewpoint, walls, bound)`,
  `bound_for(...)`, `Seg`/`Rect`/`P`, `point_in_poly` (shared). Public-source computational
  geometry only. `visibility_polygon` pre-filters `walls` through `seg_overlaps_rect` (a plain
  AABB-overlap test against `bound`) before cloning/angle-sampling — safe because every caller
  constructs `bound` to CONTAIN the viewpoint (`bound_for`/`bound_for_scene`), so a wall whose bbox
  has zero overlap with `bound`'s bbox lies entirely outside it; by convexity, a ray from an
  interior point already crosses one of `Rect::edges()` (always present in the filtered set)
  before it could reach that wall, so `nearest_hit` never needed to consider it — excluding it
  changes no polygon vertex, only how many segments get scanned per ray. `nearest_hit` has an unflagged fast path: a segment set with none of the per-ray flags (`one_way`, `limited`, `open_within`) never skips a hit, so it takes the first minimum-`t` hit in one allocation-free pass (strict `<` keeps the earliest input-order hit on a tie, as the sorted walk does); only a flagged set collects and sorts the hits. Pinned by `nearest_hit_unflagged_fast_path_matches_the_sorted_walk`. Pinned by a mutation
  test (`scene::vision::tests`): a wall straddling `bound`'s edge (half in, half out) must still
  occlude a point directly behind its in-bound sliver — flipping the filter from an overlap test
  to a strict-containment test makes that test fail exactly as expected, confirming it is a real
  negative control and not a happy-path-only check.
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
  (`light_illumination`, refusing a non-finite distance for EVERY `Falloff` curve — the flat
  arm would otherwise light every cell of a NaN-positioned light), `source_level` (ONE source's
  contribution at a cell center: `0.0` when its own occluder polygon excludes the center, else
  `light_illumination` at the distance in cells — THE per-source reach rule, summed by the
  composition and read alone by the egress clip's `InstantSight::light_reaches`), and
  `cell_illumination_from` — `cell_illumination` is its index-aligned-slices spelling, and
  `LightingInputs::cell_light` is THE one illumination read every gate takes (`player_lit_mask`'s
  band/tint bookkeeping, `point_qualifies`, the clip) — which
  is **additive superposition with saturation**: `clamp01(Σ contributions)` over every placed or
  carried light (each `source_level`) plus the boundary-projected environment ambient as one more contributor, with
  an illuminance-weighted tint mix `Σ(levelᵢ × colorᵢ) / Σ(levelᵢ)` — never max-of-sources or a
  dominant tint. Two dim lights brighten their overlap; composition only ever brightens for the
  same content, and it stays inside the LOS gate, so no cell outside a source's reach becomes
  visible. Clean-room. Non-finite/empty inputs fail closed (under-reveal).
