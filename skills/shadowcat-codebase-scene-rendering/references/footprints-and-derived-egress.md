# Token footprints and derived-channel egress

Part of the shadowcat-codebase-scene-rendering skill; read it before touching scene::footprint, the footprints channel, or any derived channel that restates a document band.

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
