# Facing vision, rotation gate, cone lights, proximity walls, region occluders

Server-side vision, light and movement-adjacent rules added on top of the base vision pipeline. Read it before changing facing cones, token rotation writes, cone lights, proximity walls or region occluders.

## Facing vision

- `FacingVision {arc, near}` lives on `ActorEngine`, `TokenOverrides` and `TokenEngine`; the token override replaces the actor's whole object. An invalid value fails closed to the near bubble; an absent value is unrestricted. The `facing_vision` switch rides the scene settings chain (`SceneVisionOverrides` / `SceneDefaultsOverlay` / `WorldSceneDefaults` / `ResolvedScene`, default false). `FACING_MIN_NEAR_WORLD` floors the near radius.
- `vision::FacingArc` + `visibility_polygon_facing` clip a source's polygon to the cone. `source_los_poly` takes the facing and is the ONE producer for every consumer (lit mask, move gate, streamed sight, egress clip, `los_at`); the facing travels in `VisSrc`, `SightSource` and the snapshot tuple. A new consumer of a sight polygon calls `source_los_poly`, never the raw polygon builder. Creature senses carry no facing.
- `SceneEcs::resolve_token_actor_field` is the one token-over-actor field resolver, shared with vision assignments. `move_exec::token_facing_radians` is the exact inverse of `bearing_degrees` (0 = +x, clockwise, y down); change one and the other must follow.
- `/engine/lock_rotation`, `/engine/facing_vision` (token, override and actor bodies) are GM-write-only. The single field list is `gm_only_field_touched` in `data::permission` (carried light, hidden identity, `lock_rotation`, `facing_vision`); `pointer_value_changed` compares by value, so restating the stored value is allowed. `TemplateMerge` skips the `apply_intent` gates, so the same list is applied again in `update_authorized`; a new GM-only field goes into the one list and both sites pick it up.

## Token rotation gate

- `scene::rotation_gate`: `rotation_refusal(locked, rule, standing)` and `lock_refusal` are the single predicate. `FacingTurnRule` is `free` or `own_turn` (scene settings chain, `ResolvedScene.facing_turn_rule`). `TurnStanding` models the mover's combat standing; an unreadable combatant is `Unconstrained` so a refusal never discloses hidden combatants.
- `Room::publish` applies the non-GM rotation gate after the position gate (refusal is `Forbidden`) using `token_rotation_write` (the post-image) and `token_turn_standing`. `execute_move` auto-rotation (the `auto_rotate_tokens` setting on the same chain, written as a third `FieldChange` on `/engine/rotation` in the move's own Update, GM moves included) uses `lock_refusal` and skips when off or locked.
- Gotcha: `world_cap_defaults` is fetched for any Update batch, not only scene writes, because the rotation gate needs the world defaults.
- Gotcha: the stored rotation convention is 0 = +x, clockwise, y down. Client art drawn facing another direction is corrected by `VisualTransform.facing`, never by changing the stored rotation.

## Cone lights and move-stream fields

- `Light::active_at_env` is the single "is this light on at this ambient level" predicate (`LightEmission` `active_below_env`, angle, rotation, `follow_token_rotation`). `lighting::cone_admits` is shared by the committed field and the egress clip; `emitters::effective_rotation` is derived at each read, never stored.
- `LightSample` is self-describing (carries angle and rotation) so the client sweep needs no emitter lookup. The client `coneAdmits` in the light sweep is pinned to the server by the shared 16-case fixture; change either side and the fixture fails. Occlusion of a cone treats the full circle as the bound.
- A new `move_stream` wire field needs the three edits listed in references/invariants-streamed-vision-and-regions.md (wire type, Zod schema, ws-client mapper) plus the render `MoveLightSample` type.

## Render hints and vision treatments

- `RenderHint` is a tagged enum: `Desaturate`, `ColorWash {color, opacity}`, `Outline {color}`, `None`, `Custom {treatment, params}` (the tag field is `kind`, so the custom variant's name field is `treatment`). `scene::VisionMode` re-exports the engine type; `SharedRenderHint` is the `Option<Arc>` form; `LitCell` is the per-cell alias. Every entry of the `renderHints` payload table is a tagged object.
- Client: the `VISION_TREATMENT_CONTRACT` contribution (`Contribution.visionTreatment`, `VisionTreatmentMeta`) registers custom treatments; `Lighting` reads them through `VisionTreatments`. A string, unknown or malformed table entry parses to `none` (`parseRenderHint`), so a stale or hostile entry draws nothing instead of throwing. Wash and outline are part of the lighting frame key. The `vision-custom-kind` Playwright spec drives this seam against the `vision-kind-fixture` installed module (where fixture modules live: shadowcat-codebase-module-toolchain): it reads the stage's `data-light-treatment` attribute, a `wash,outline` cell-count pair, to tell the fill branch from the outline branch, and an unknown treatment name reads `0,0`.

## Proximity walls

- `WallEngine.proximity` is `WallProximity {within, senses, sound_gain}` with `WallSense` per sense and `MAX_PROXIMITY_CELLS`. `Seg.open_within` (`OpenWithin {distance, gain}`) plus `Seg::open_from` (inclusive, fail closed) mark a segment as open to a viewer within range; `nearest_hit` skips open segments. Collectors fill it per sense through `SceneEcs::proximity_open` (cells converted to world units). Movement and `Rect::edges` never see it: a proximity wall still blocks movement.
- The client wall editor (`ToolRail`) writes the WHOLE `/engine/proximity` object as one field change, with the raw stored value (or `null`) as the OCC pre-image, never a per-key edit.
- Audio: `segment_occluded` returns (blocked, gain); an open segment multiplies the gain, and `muffled` is set only on a closed segment.
- Unresolved: streamed move-stream vision with a proximity tier has no test.

## Region occluders

- `RegionEngine.occludes` (`RegionOcclusion {sight, light, sound}`; all-false is rejected) turns a region into an occluder. `regions::cell_outline_segments` builds the outline (square and hex, holes, collinear merge); `occluder_outline` falls back to the bounding box above the cap and that fallback fails closed. `SceneEcs::region_occluder_entries` appends the entries to the sight, light and sound collectors only: movement is untouched and the entries are permission-blind. The `occluder_cache` is self-verifying and trimmed in `apply_op`.
- `RegionEngine::validate` rejects non-finite coordinates.
- An anchored region contributes its RESOLVED parts (see references/regions-portals-placements-and-bounds.md); the occluder memo is keyed by those resolved parts.
