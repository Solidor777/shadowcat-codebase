# MoveStream, per-recipient egress clip and mover_light

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::move_stream, ws::conn's egress clip or mover_light admission.

- `scene::move_stream` — pure, no-I/O position/vision path sampler for the
  `MoveStream` broadcast: `sample_path(path, cell, duration_ms) -> Vec<PosSamplePt>` (arc-length
  parameterization; ~`SAMPLES_PER_CELL`=3 samples/cell; always includes the exact first/last
  vertex; strictly increasing `t_ms`, exact-equal consecutive dedup). `MAX_VISION_SAMPLES` (96) is
  the SHARED cap for all THREE sample kinds on one `MoveStream` frame — position, vision and
  carried-light samples are taken over the same list — bounding the mover's per-move raycast
  count. `MAX_VISION_POLYGON_VERTS` (512) caps each `VisionSamplePt`
  polygon's vertex count (fail-closed truncation — under-reveal, never over-reveal).
  `Room::execute_move` calls `sample_path` then, for each sample, `sight_sources` (once) +
  `SightSources::los_at` (per sample) to fill the wire frame's
  `ServerMsg::MoveStream.mover_vision` (`None` for a GM mover — `Unrestricted` sees all, nothing to
  sweep). **Carried light ("cost only on request"):** over the SAME sample list it also fills
  `ServerMsg::MoveStream.mover_light` (`LightSample {t_ms, pos, bright, dim, color, intensity,
  falloff, polygons}` — `intensity`/`falloff` make the sample SELF-DESCRIBING, so the egress clip
  composes an in-flight light into the illumination field from the frame alone via
  `RecipientSight::sample_light`, with `emitters::field_falloff`/`wire_falloff` the one
  wire↔field curve mapping, round-trip pinned; internal `LightSamplePt`) via
  `SceneEcs::mover_light_inputs(scene, token, cell, committed_rotation)` (`Room::execute_move` derives the committed bearing ONCE with `move_exec::bearing_degrees` and feeds it both to `SightSources::turn_source` for the streamed facing vision and to this call for the carried cone, the same value its `/engine/rotation` commit writes, so the stream never looks along a different heading than the commit) — `None`, and
  therefore zero light raycasts, when the scene is all-bright (`ResolvedScene::all_bright`, THE
  one lighting-off/`GlobalIllumination` predicate `lighting_inputs`, the visibility-cache
  snapshot and this seam all read) or the token's `token_light_emission` is absent/disabled;
  otherwise a `MoverLightInputs` hoisted once per move (the emission as a `Light` template, the
  `blocksLight` walls filtered at the token's elevation, `world_units_per_cell`) and
  `MoverLightInputs::sample_at(t_ms, pos)` per sample — one `emitters::light_polygon` raycast,
  the committed field's own. `bright`/`dim` reach the wire in SCENE units (`dim` doubles as the
  egress admission disc) and `MAX_VISION_POLYGON_VERTS` caps the polygon like a vision sample.
  **Not gated on the mover's role**: a GM walking a torch-bearing NPC lights the corridor for the
  players watching it — the observers, not the mover, are who the timeline is for.
- `ws::conn` — **the per-recipient egress clip is the secrecy boundary** for
  `MoveStream`. `Room::execute_move` builds the full (unclipped) `MoveStream` frame itself (via the
  module-private `wire_move_stream`) and registers it in the room's in-flight registry
  (`Room::scene_streams`/`Room::concurrent_streams` read this registry, pruning expired entries on
  every read); `handle_move_request` broadcasts that frame with `Room::broadcast_aux_shared` — the
  full trajectory lives only in-process. `egress_loop`'s dedicated `MoveStream` branch
  (`clip_move_stream`, which delegates the per-sample decisions to `ws::move_clip::clip_frame` —
  both gates from ONE resolution of each distinct sample instant)
  runs BEFORE the sink write, per connection, in four branches: the mover gets `samples` +
  `mover_vision` unchanged (keyed on the REAL connection `user_id`, never a see-as target — a GM
  previewing as someone else is not "the mover" unless the GM's own token is what moves); a plain
  GM (no active see-as) gets the FULL `samples` unclipped (GMs bypass position secrecy) but
  `mover_vision` forced to `None` (a GM has no fog to sweep); a GM with an active see-as
  (`SceneSubscribe`-set `egress_loop::scene_subs` target) gets `samples` clipped to the see-as
  TARGET's own authoritative sight (`SceneEcs::recipient_sight(&target, .., token_id)` — the
  target's `PermissionContext` and the frame's mover token) instead of
  the plain-GM full stream — the see-as does not apply, falling back to the full GM stream, only
  when the target has no vision source in the move's scene (`RecipientSight::has_sources`; an
  in-flight move of theirs changes nothing, since `ClipInputs::at` substitutes a viewpoint only
  for a token that IS one of their sources); every other (non-GM, non-mover) recipient gets
  `samples` clipped by `clip_frame` to those the recipient PERCEIVES at that sample's instant —
  `InstantSight::sees_token`: `sees` (inside some source's LOS polygon AND `point_qualifies` at
  the point's cell center — illumination ≥ an in-range mode's floor: normal vision needs light,
  darkvision within range does not — the SAME per-source conjunction `player_lit_mask` answers
  for a cell, pinned cell-for-cell by `recipient_sight_agrees_with_player_lit_mask_cell_for_cell`)
  OR a source's creature sense reaching the mover (`senses::sense_perceives`, the decision
  `player_perceived_tokens` makes at rest). The sight is resolved off the
  current ECS read (never a stale cache; the guard drops before any await) with every in-flight
  mover's carried emission EXCLUDED from the committed field (`recipient_sight::exclude_emitters`
  → `lighting_inputs_excluding` → `scene_lights_excluding`, since their committed position is
  the move's END) and composed back in per instant from the registered frames' `mover_light`
  timelines (`InstantLight`), so a torch lights the cell its bearer is IN, not the cell it will
  stop in; the recipient's own in-flight token is re-raycast at its chosen position sample per
  instant (`SightSources::los_at`). **Every registered move contributes at EVERY instant,
  started or not:** for an instant before a move starts, `chosen_vision_sample` yields its FIRST
  sample — the position the token (and its torch) still occupies, since `Room::execute_move`
  commits the END before broadcasting — so the target's pre-start instants are never judged
  from its END viewpoint and a not-yet-started torch still shines from its start. `mover_vision`
  is forced to `None`. **Frame delivery is decided by BOTH clips:** a recipient neither clip
  reaches gets no frame at all (suppressed — asserted by a dedicated test); a recipient the glow
  alone reaches gets a GLOW-ONLY frame (`samples` empty, `mover_light` the admitted timeline,
  `stop`/`duration_ms` at the last admitted light sample — pinned by
  `glow_only_recipient_gets_a_frame_with_no_position_samples`). The wire invariant is therefore
  "at least one of `samples`/`mover_light` is non-empty", never "`samples` non-empty". Secrecy of
  an unlit token: a dark walk in plain line of sight streams to a darkvision observer within
  range and a plain GM but NOT to a normal-vision observer
  (`an_unlit_token_in_line_of_sight_streams_only_to_darkvision_and_the_gm`). The see-as branch can only NARROW what a GM receives
  relative to the plain-GM fallthrough, never widen a non-GM recipient's own view (see-as is
  GM-only, gated by `SceneSubscribe`'s `as_user` handler). `send_plain` intentionally panics if a
  `MoveStream` reaches it — the clip MUST happen in the dedicated `egress_loop` branch, never the
  generic per-recipient filter path. **A second, per-connection (never broadcast) delivery path:**
  for a clipped recipient (a non-GM, or a GM with a see-as), when the triggering frame is the
  clip target's OWN move (`mover_vision: Some(_)` and its mover equals the target) OR carries a
  `mover_light` timeline (a torch arriving changes what every bystander sees), `egress_loop`
  also re-clips every OTHER unexpired stream in the same scene (`Room::concurrent_streams`,
  excluding streams by that same mover) against the just-changed sight and re-sends each one —
  under its original `token_id` (the client overwrites playback keyed by `token_id`, not
  `request_id`; `request_id` is preserved unchanged and only proves the re-emit is A's own
  original frame) — to this connection only, a re-emit being a glow-only frame when only the
  glow reaches (`egress_reemit_yields_a_glow_only_frame_when_only_the_glow_reaches`); a
  zero-progress move (never registered in `Room::scene_streams`) cannot populate a usable
  timeline and is excluded from triggering this path. `MoveError` stays
  mover-only via `handle_socket::etx`, generic (no path/vision geometry disclosed).
- **`mover_light` egress admission (`ws::move_clip::clip_frame`'s light half; `admit_light_samples`
  is its test-only single-gate spelling) — the SAME per-instant sight AND the SAME visibility
  predicate the position clip reads, never a second rule.** `clip_move_stream`'s four branches
  treat the carried-light timeline as: the mover gets it unchanged; a plain GM gets it in full
  (like `cost` — nothing to hide the glow from); a GM see-as and every observer keep only the
  samples whose glow LIGHTS A CELL THE TARGET SEES at that sample's instant — `glow_reaches`
  against `ClipInputs::at`'s `InstantSight` and composed field: some cell center within `dim`
  of `pos` that the sample's own light reaches (`InstantSight::light_reaches` →
  `lighting::source_level` over the sample composed as an `InstantLight`, so its occluder
  polygon and taper apply) AND that the target `sees` with the instant's lights composed (line
  of sight, the composed illumination against the source's floor, darkvision range — the field
  carries this very sample as its own timeline's chosen light). So an ember below a
  normal-vision recipient's dim floor lights nothing they see and is NOT admitted (no glow-only
  frame discloses its bearer), a darkvision recipient within range is shown it, and a
  `blocksLight`-occluded glow whose disc merely crosses into sight is dropped — exactly what
  `player_lit_mask` decides for the same cells at rest. The disc test (`disc_intersects_polys`:
  center inside via `point_in_poly`, or an edge within `dim` via `point_segment_distance`, read
  in place through `InstantSight::disc_touches_los`) is the cheap pre-filter ONLY. The fine
  test always runs and never falls open: it scans the disc box ∩ the target's line-of-sight box
  (`InstantSight::los_bbox`) ∩ the sample's own occluder box through `InstantSight::cell_centers_in`
  → `GridShape::cells_in_bounds` under the lit mask's own bound (`explored::MAX_CELLS_PER_POLYGON`),
  and a box past even that admits nothing; a `dimRadius` is ingress-bounded by
  `MAX_FOOTPRINT_CELLS` (`LightEmission::validate`, run at every carrier — `LightEngine::validate`,
  `ActorEngine::validate`, `TokenEngine::validate` for `overrides.light`), so no authored light
  reaches it. A non-finite or non-positive reach admits nothing. PRECONDITION of the light half:
  the frame's own move is among `ClipInputs::in_flight` (as `clip_move_stream` guarantees), so a
  sample is composed into the field it is judged against exactly once. A timeline no sample of
  which reaches the recipient is `None`, never an empty list. `chosen_vision_sample` is generic
  over `Timed` (`VisionSample`, `LightSample`, `PosSample`) — one selection rule,
  fixture-pinned. The own-move re-emit (`Room::concurrent_streams` → `clip_move_stream`)
  re-admits the light timeline through the identical path, pinned by
  `egress_reemit_re_admits_the_concurrent_streams_light_timeline`.
  A recipient the glow alone reaches gets the GLOW-ONLY frame (see the `ws::conn` bullet).
  Within an admitted timeline the polygons are NOT clipped to the recipient's sight — the client
  intersects them with its own fog — and the glow geometry outside it (which also implies the
  emitter's position, its polygon's kernel) is an accepted disclosure — game-state secrecy yields to
  experience, configurability and performance; only personal user information (IP addresses,
  account details, credentials) and remote-device security are absolute — bounded by the
  emission's own reach: the admission is what bounds the radius of disclosure.
