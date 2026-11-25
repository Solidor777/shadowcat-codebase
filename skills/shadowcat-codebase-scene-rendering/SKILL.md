---
name: shadowcat-codebase-scene-rendering
description: "Use when touching Shadowcat scenes, the scene ECS, rendering, the PixiJS canvas/stage, vision raycasting, fog of war, lighting, the server visibility/lit mask, movement restriction (the Room::publish move gate, supercover, visible_cells), token footprints (the single `scene::footprint` definition, `resolve_token_footprint`, the `\"footprints\"` derived channel and its client readers `FootprintLookup`/`resolveTokenBox`/`reapplyFootprints`), the grid A* pathfinder (`SceneEcs::pathfind`, Pathfind/PathResult frames, diagonal rules), the continuous/navmesh router (movementModel axis, polyanya, the navmesh cache, `clip_to_visible_mask`), streamed continuous vision (MoveStream, `sight_sources`/`recipient_sight`, the carried-light `mover_light` timeline, the per-recipient egress clip, client fog-sweep/cross-fade playback), regions (weighted/impassable/arrest zones, enter/arrest trigger regions, region docs, the `region-view` render layer), per-token art fx (`TokenFx`, condition-fx and the selection highlight) and emote overlays (`EmoteView`), multi-scene viewing (viewedSceneId, resolveViewedScene, world-settings.activeScene, GM local roam, the `scene-scope` module), or scene-tools (place/select/move/draw/template/measure/ping/wall/region, incl. the measure tool's self-owning route commit, the once-per-gesture move-failure notices and the shared live ruler with its `RemoteRulerView` receiver). Covers src/server/src/scene, src/client/render, src/modules/{stage,scene-tools}. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Scene & Rendering

Orientation for the server scene ECS + vision/fog and the client PixiJS render layer + scene-tools.

## Purpose

Scene/runtime state is **derived** from documents into a per-world ECS (ephemeral). The server
runs engine-owned geometry (movement-collision, per-player vision); the client renders the
**optimistic** document view through an engine-owned PixiJS layer, with interactive tools.

## Key files & seams

The detail for this skill lives in references/. This section is the routing map; open the reference file named for your task before editing the code it covers.

- `scene` / `SceneEcs`, `compute_derived`, the scene resolvers, scene bounds default parity, the `visible_cells` movement-gate mask and the `/engine` typed-accessor re-root: read references/scene-ecs-and-engine-reroot.md.
- `scene::footprint` (the single footprint definition) and the rule for derived channels that restate a document band: read references/footprints-and-derived-egress.md.
- `scene::movement` (supercover), `scene::vision` (raycast) and `scene::lighting`: read references/movement-supercover-and-vision.md.
- Region ambient-light override, `scene::emitters` (carried light) and `scene::elevation`: read references/lighting-regions-emitters-elevation.md.
- `scene::senses`, `scene::move_exec`, `Room::execute_move`'s movement-budget gate and `SceneEcs::token_position`: read references/senses-and-move-exec.md.
- `scene::move_stream`, the `ws::conn` per-recipient egress clip and `mover_light` admission: read references/move-stream-and-egress-clip.md.
- `scene::explored`, `scene::regions`, `region_field`, region triggers and `ScrollingText`: read references/explored-fog-and-regions.md.
- `scene::pathfinding`, `SceneEcs::pathfind`, the `movementModel` and `snapToGrid` axes: read references/grid-pathfinding.md.
- Movement-type tags, the terrain exemption and regions on the continuous engine: read references/movement-types-and-continuous-regions.md.
- `scene::navmesh` and the polyanya continuous router: read references/navmesh-router.md.
- The client PixiJS layer (`src/client/render/src/`) and token visual rendering: read references/client-render-engine.md.
- Client `visionSweeps`/`lightSweeps`, fog blend, `Lighting` and the render performance budget: read references/client-fog-sweeps-lighting-perf.md.
- `Stage`, `src/modules/scene-tools/`, `scene-docs`, explored-fog client seams, multi-scene viewing and client footprint consumption: read references/stage-and-scene-tools.md.
- Facing vision (`source_los_poly`), the token rotation gate, cone lights, `RenderHint` and vision treatments, proximity walls, region occluders: read references/vision-facing-proximity-and-occluders.md.
- Token-attached regions (`anchored_region_parts`), portal offers and `apply_teleport_to`, module placements and their expiry sweep, template-to-region conversion, scene padding, session-pause on tools: read references/regions-portals-placements-and-bounds.md.
- The `"bars"` channel and nameplates, token overlay/art framing/facing wedge, `Camera.panTo`, snap modes and the one dash mechanism: read references/client-token-bars-art-camera-and-dash.md.

## Hard invariants

- **The canvas renders the OPTIMISTIC view** (`AppContext.documents` / `OptimisticClient`), NOT
  the authoritative `store` — the store is the rollback base; `appliedSeq` is identical so the
  derived watermark holds [[render-from-optimistic-view]].
- **Fog is the secrecy gate — fail closed.** A client-side visibility gate that is the SOLE thing
  hiding already-delivered data must hide-everything on a missing/garbled signal; container-local
  coords reused across containers must be tagged + filtered to the active container
  [[fog-is-the-secrecy-gate-fail-closed]].
- **Vision is server-authoritative, no client prediction**; movement that
  crosses a `blocksMove` wall is rejected server-side before the write — validate the **post-image**
  position, not just the pre-move one [[m9-progress]].
- **Bound recursive walks over self-FK (parent_id) tables with a visited-set** [[m8a-execution-state]].
- **Scene-settings resolvers are fail-closed and inheritance-layered**: `resolveSceneSettings`
  resolves built-in default < `system-defaults` < `world-settings` overlay < per-scene override,
  never throws — BOTH middle layers are `Option`-lifted overlays, so a partial doc contributes
  exactly its authored leaves — and a per-scene override of `null` means **inherit** (resolver
  `??` chains treat null and undefined identically). The server twin is `resolve_scene`'s
  per-leaf fold with `WorldSceneDefaults::default` as the ONE innermost source. The deep-frozen
  `DEFAULT_*`/`SEED_*` constants are immutable-by-design mirrors of those server definitions;
  the gradation/vision builders `structuredClone` them so no frozen/shared reference reaches a
  doc.

The remaining hard invariants are in reference files. Read the matching one before editing the code it covers; every invariant there is a hard rule. The bullets below give each rule's lead sentence; the file holds the full text and the reasons.

Read references/invariants-secrecy-and-gates.md before changing fog, the lit mask, the `Room::publish` gate or derived-frame ordering:

- **A value cached across a client-local scene switch must never be pre-filtered against the scene that was active when it was cached — recompute the scene filter at the point of application, against whatever scene is current THEN.**
- **`flushPendingDerived` never regresses `lastAppliedSeq` to a stale `pendingDerived` entry superseded by an immediately-applied newer frame.**
- **`Room::publish`'s non-GM block retains only two gates, neither a traversal gate.**
- **The server lit mask is the lighting-aware secrecy gate**

Read references/invariants-streamed-vision-and-regions.md before changing streamed vision, region secrecy, the continuous dispatch predicate or MoveStream-disclosed scalars:

- **Streamed vision is strictly leak-free — no fork of the secrecy decision, fail closed (`fog-is-the-secrecy-gate-fail-closed`).**
- **Region secrecy is a two-value contract on `region_field`, never a third mode.**
- **The continuous-engine dispatch predicate MUST read the PER-REQUESTER region field, never the authoritative one.**
- **Polyanya does not weight — the cell `region_field` is the universal weighting overlay for BOTH engines.**
- **A whole-region-scalar disclosed on `MoveStream` must default to trusted-recipient-only, not broadcast-by-default.**
  - **A wire scalar needs THREE client-side edits or it is silently discarded.**
  - **`truncated` is NOT interchangeable with the client's derived move outcome.**

Read references/invariants-routing-and-execute-move.md before changing pathfinder footprint or wall rules, the route-subset-of-gate rule or execute_move's per-cell gate:

- **The pathfinder route is footprint-STRICTER than the center-based authoritative gate on WALLS, but its MASK predicate is a superset of the gate's.**
- **The `route ⊆ gate-allowed` invariant is engine-agnostic, not grid-specific.**
- **`execute_move`'s per-cell gate is the sole movement gate, footprint-aware for walls/mask/impassable, center-cell for arrest/terrain.**

Read references/invariants-client-views.md before changing the client shape views, TemplateShape, template authoring controls or RegionView:

- **The four shape views are a NEAR-IDENTICAL SIBLING SET, and that is where they diverge silently.**
- **`TemplateShape` carries THREE geometry dimensions, and two of them are optional with behaviour-preserving defaults.**
- **Template authoring controls are conditional by kind**
- **`RegionView` mirrors `WallView` exactly**

## Gotchas

Gotchas are in reference files. Read the matching one before editing the code it covers.

- Docs ratchet, `footprint_cells` tie-break, scene auto-create, tool-swap cleanup, measure-tool route commit, move-failure notices, the shared live ruler: references/gotchas-tools-and-rulers.md.
- `resolved_diagonal_rule`, arrest/impassable footprint gating, arrest truncation cost, GmOnly band override, hex lerp, supercover corner crossing, cross-scene stream leak class: references/gotchas-routing-and-geometry.md.

- The file that declares the `scene` module sits just under the 5,000-line limit (`pnpm lint:file-size` fails past it): new `SceneEcs` code goes in a sibling submodule (`anchored_regions`, `placed_regions`, `bars` and `elevation` are the pattern), never back into it.

## Reference files

| File | What it holds | Read it when |
|---|---|---|
| references/scene-ecs-and-engine-reroot.md | SceneEcs, derived channels, resolvers, bounds, movement-gate mask, /engine re-root | changing the server scene read-model or its resolvers |
| references/footprints-and-derived-egress.md | `scene::footprint`, derived-channel egress rule | touching footprints or any derived channel |
| references/movement-supercover-and-vision.md | `scene::movement`, `scene::vision`, `scene::lighting` | changing supercover, raycast or illumination |
| references/lighting-regions-emitters-elevation.md | region ambient light, `scene::emitters`, `scene::elevation` | changing carried light, elevation or ambient overrides |
| references/senses-and-move-exec.md | `scene::senses`, `scene::move_exec`, budget gate, `token_position` | changing senses or move execution |
| references/move-stream-and-egress-clip.md | `scene::move_stream`, egress clip, `mover_light` | changing streamed continuous vision |
| references/explored-fog-and-regions.md | `scene::explored`, `scene::regions`, triggers, ScrollingText | changing fog memory or regions |
| references/grid-pathfinding.md | grid A*, `movementModel`, `snapToGrid` | changing the pathfinder |
| references/movement-types-and-continuous-regions.md | movement-type tags, terrain exemption, continuous regions | changing movement-type or region routing |
| references/navmesh-router.md | `scene::navmesh`, polyanya | changing the continuous router |
| references/client-render-engine.md | PixiJS layer, token visuals | changing src/client/render |
| references/client-fog-sweeps-lighting-perf.md | vision/light sweeps, fog blend, Lighting, perf budget | changing client fog/lighting playback |
| references/stage-and-scene-tools.md | Stage, scene-tools, scene-docs, multi-scene viewing, client footprints | changing stage or tools |
| references/vision-facing-proximity-and-occluders.md | facing vision, rotation gate, cone lights, render hints, proximity walls, region occluders | changing those server rules |
| references/regions-portals-placements-and-bounds.md | anchored regions, portals, placements, template conversion, padding, pause | changing region features |
| references/client-token-bars-art-camera-and-dash.md | bars/nameplates, token layers, art framing, camera, snapping, dash | changing token display or camera |
| references/invariants-secrecy-and-gates.md | secrecy and gate invariants | see Hard invariants |
| references/invariants-routing-and-execute-move.md | route and execute_move invariants | see Hard invariants |
| references/invariants-streamed-vision-and-regions.md | streamed vision and region invariants | see Hard invariants |
| references/invariants-client-views.md | shape view, template, RegionView invariants | see Hard invariants |
| references/gotchas-tools-and-rulers.md | tool and ruler gotchas | see Gotchas |
| references/gotchas-routing-and-geometry.md | router and geometry gotchas | see Gotchas |

## Pointers

- **Generated API** — `/api/rust/shadowcat/scene/` (rustdoc, private items included),
  `/api/ts/modules/_shadowcat_render.html` (TypeDoc), `/api/ts/modules/_shadowcat_module-scene-tools.html`,
  `_shadowcat_module-stage.html`. Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 (invariants 3, 5, 6 + the geometry exception) + §7 (rendering provenance).
- Relationships:
  `graphify query "scene ECS derived read-model vision fog stage pixi render tokens regions faces animated"`.
- History/decisions: [[m8-brainstorm]], [[m8d-2-scene-tools]], [[m9-progress]],
  [[server-authoritative-movement-rule]], [[m10-pathfinding-architecture]].
- `shadowcat-codebase-audio` — `scene::audibility` (the spatial-audio channel composed from this
  skill's own occlusion primitives) and `scene::emitters::token_sound_emission` (the carried-
  sound twin of `token_light_emission`).
