# Hard invariants: streamed vision, region secrecy and MoveStream disclosure

Part of the shadowcat-codebase-scene-rendering skill; read it before changing streamed vision, region_field secrecy modes, the continuous dispatch predicate or MoveStream-disclosed scalars.

- **Streamed vision is strictly leak-free — no fork of the secrecy decision, fail closed
  (`fog-is-the-secrecy-gate-fail-closed`).** The mover's swept vision trajectory raycasts the SAME
  `sight_walls` (full set, incl. `gm_only`) as `player_vision_polygons`; the observer egress clip
  filters against the recipient's OWN authoritative vision (never the mover's) — a `gm_only`-walled
  area is never streamed to a non-owner because the observer's own vision already excludes it. No
  render-path leak: the full trajectory is broadcast in-process only; `egress_loop`'s dedicated
  branch strips it per recipient before the sink write, same discipline as `Event`/`vision` egress.
  A wholly-occluded move is suppressed (zero frames), never sent as an empty-`samples` frame — an
  observer must not learn a move even happened if they can't see any of it. `mover_vision` is
  disclosed to the mover only (nulled for every other recipient, incl. a full-vision GM observer who
  has no fog to sweep anyway). **Scope of the leak-free claim:** "strictly leak-free" covers the
  IN-FLIGHT path only; RESTING token positions still ride the position `Event` + client-side fog
  model (delivered to all scene readers, fogged client-side per `fog-is-the-secrecy-gate-fail-closed`)
  — this does not change that. **Concurrent-move clip, against the recipient's OWN in-flight
  sight, not just their committed sight.** `ws::conn::clip_move_stream` resolves every in-flight
  stream in the scene via `Room::scene_streams` and clips each sample of the OTHER token's
  `MoveStream` per-sample-instant through `ws::move_clip::ClipInputs::at`, resolved ONCE per
  distinct instant for both gates (`clip_frame`): the target's own in-flight token is re-raycast
  at its chosen position sample (`SightSources::los_at` — for an instant before its move starts
  that is the FIRST sample, the position it still occupies, never the committed END) and every
  registered stream's chosen light sample is composed into the field
  (`RecipientSight::sample_light`), so a sample is admitted only if the target PERCEIVES it
  (`InstantSight::sees_token`: `sees`, or a creature sense reaching the mover) at that sample's
  absolute server time. **Re-emit on own-move or torch arrival:** when the clip target's own move starts
  (their viewpoint timeline just came into existence) or a `mover_light`-carrying move starts
  (the glow changes what they see), `egress_loop`'s `MoveStream` branch re-clips and re-sends
  every OTHER in-flight stream in the scene via `Room::concurrent_streams`, under its original
  `token_id` (the client overwrites keyed playback in place, per
  `TokenAnimator.animateSamples`'s replace-in-place contract) — this is what reveals a
  third-party mover the instant the recipient's OWN sightline opens mid-walk, rather than only at
  the mover's stop. **Client parity, mechanically pinned:**
  `chosen_vision_sample`'s rule (greatest `t_ms <= elapsed`, first sample when none precedes) must
  match the client's `chooseVisionSample` (`fog-blend.ts`) exactly, or a sample admitted
  server-side would not be the one the client's sweeping fog shows; both sides assert against the
  shared fixture `src/client/render/src/__fixtures__/chosen-vision-sample.json` — on BOTH sample
  kinds, since the carried-light timeline selects through the same generic function. **A THIRD
  PARTY's moving LIGHT SOURCE is served by the `mover_light` timeline** (the egress admission
  bullet in references/move-stream-and-egress-clip.md): the light-carrying move's glow is sampled per position sample on the server and
  admitted per recipient by reach, so the corridor lights up mid-walk on the observer's client
  (the `lightSweeps` bullet in references/client-fog-sweeps-lighting-perf.md); the position clip composes that same glow into its
  illumination test (a moving light DOES alter what a normal-vision observer sees), and the
  mover's own fog sweep is unchanged. A recipient the glow alone reaches gets a glow-only frame
  (no position sample, the admitted light timeline) and plays the light sweep without a token
  tween. Client computes NO vision in any of this — it renders only the streamed,
  already-admitted polygons, intersected with its own fog.
- **Region secrecy is a two-value contract on `region_field`, never a third mode.**
  `region_field(scene, None)` = authoritative (GM + `move_exec`); `region_field(scene, Some(user))`
  = per-requester (the router only). Callers must never pass `Some(gm_user)`. By construction the
  router's field is a SUBSET of the authoritative field — a secret region can
  narrow a player's route/preview but can never appear to them where it wouldn't to the GM, and it
  always still applies at `move_exec` regardless of what the router showed. Reuses the EXACT same
  `resolve_access` + `property_overrides["/engine"]` mechanism as ordinary document egress (not
  `"/system"`), through `engine_tier_visible` — no new secrecy machinery was introduced for regions.
  **Fixture-construction precision (test/brief authoring convention):** the correct way to mark a
  region `gm_only` in a test fixture is
  `doc.permissions.property_overrides.insert("/engine".into(), Visibility::GmOnly)` — matching the
  read `engine_tier_visible_to` performs on `region_field`'s behalf
  (`doc.permissions.property_overrides.get("/engine")`, default
  `Visibility::All`). Setting `permissions.default = Access::None` instead does NOT gate
  `region_field`'s per-requester filter at all (that field only reads the `/engine`
  `property_overrides` entry) — a test or spec author who reaches for `permissions.default` here
  writes a region that still weights a non-GM's route.
  **`behavior: "ambient_light"` is the one exception to the two-value contract's own secrecy
  claim, not a third mode.** `SceneEcs::ambient_light_map` (the lighting field's per-cell
  ambient-region reader) always calls `region_field_if(scene, None, ...)` — the AUTHORITATIVE
  viewer, unconditionally, for every recipient — because an ambient-light region edits the
  composed ILLUMINATION every viewer's field is built from, not a movement/route decision the
  per-requester field exists to narrow. So a `gm_only` ambient-light region still darkens (or
  brightens/overrides) a non-GM's lighting field AND, through the shared illumination read, the
  movement gate — without the region's own GEOMETRY/visibility ever reaching that non-GM
  (`region_field`'s ordinary per-requester rule still governs whether they can SEE the region
  document or route around its shape). Two-value contract, one authority per facet: the
  MOVEMENT facet (`compose`, `RegionField::terrain_multiplier`/`resolved_terrain_multiplier`/`is_impassable`/`is_arrest`) still
  reads whichever viewer the caller passed; the AMBIENT facet always reads `None`.
- **The continuous-engine dispatch predicate MUST read the PER-REQUESTER region field, never the
  authoritative one.** `has_terrain_or_impassable(&traits.tags)` is evaluated against `region_field(
  scene, Some(user), elevation)` for a non-GM — this is the single mechanism preventing a secret
  terrain/impassable region from indirectly leaking its own existence via route-shape or reported
  cost even though its geometry is never disclosed. A future refactor that fed the authoritative
  field into ONLY the dispatch predicate, while still correctly routing/costing off the
  per-requester field, would silently reopen this leak (dispatching to the weighted path at all is
  itself a signal a secret region exists). Treat as load-bearing, not incidental.
- **Polyanya does not weight — the cell `region_field` is the universal weighting overlay for
  BOTH engines.** Polyanya 0.16.1's only cost-affecting knob is the
  `detailed-layers`-gated `Layer.scale` (a per-layer coordinate transform) — off in
  this build's `default-features = false` config and semantically wrong as a per-unit cost
  multiplier even if enabled (crate-source-verified, not README-derived). A continuous route that
  needs weighting is therefore computed by the SAME `pathfinding::find` the grid engine uses
  (forced `DiagonalRule::Euclidean`), never by a polyanya cost-layer/`blocked_layers` mechanism —
  those polyanya features remain available but are deliberately UNUSED for regions in this
  codebase. Do not "improve" continuous weighting by reaching for polyanya's own layer API; the
  cell field is the one and only weighting authority for every routing engine this project has.
- **A whole-region-scalar disclosed on `MoveStream` must default to trusted-recipient-only, not
  broadcast-by-default.** `PathResult.arrested: bool` is always disclosed (no secrecy concern — it
  only tells the requester their OWN already-visible route is truncating). `MoveStream.cost:
  Option<f64>` is `Some` for the mover/GM (trusted, full information) and `None` for a clipped
  observer, mirroring `mover_vision`'s null-for-observers pattern — because the
  authoritative cost may reflect `gm_only` secret-region terrain the observer's own vision would
  never reveal, so broadcasting it unconditionally is a Critical leak. **Load-bearing invariant,
  not a footnote:** any
  FUTURE whole-move scalar added to `MoveStream` must default to the same trusted-only disclosure
  pattern unless explicitly proven safe to broadcast to every recipient.
  - **Exercised once, as `MoveStream.truncated: Option<bool>`** — `Some` for the mover/GM, `None`
    for a clipped observer, set alongside `cost` at all three construction points
    (`handle_move_request`'s broadcast frame, `clip_move_stream::full_gm_stream`, and its
    clipped-observer tail). The leak it prevents is distinct from `cost`'s: an observer's `samples`
    and `stop` are ALREADY clipped to what they witnessed, so a truthful `truncated` would answer a
    question their view cannot — whether anything stopped the token BEYOND their vision, disclosing
    a wall or a `gm_only` region they cannot see. **When adding the next scalar, derive its leak
    from what the clip already hides, rather than copying `cost`'s rationale**; the mechanism is
    shared but the disclosure differs per field.
  - The secrecy is mutation-proven, not merely asserted: setting the clipped tail to `*truncated`
    fails `clip_observer_sees_near_side_prefix_any_angle_diagonal_path` and
    `clip_gm_see_as_clips_to_target_vision`. A future scalar should carry an equivalent negative
    test, since a leaked field is otherwise invisible to every gate.
  - **A wire scalar needs THREE client-side edits or it is silently discarded.** Adding the field
    to the Rust variant is not "wiring it": the client re-validates every inbound frame through a
    hand-written Zod schema (`wire.ts`'s `move_stream` object), and `z.object` STRIPS keys it does
    not name — no parse error, no warning, the value simply never arrives. The full path is the
    Zod schema, the `MoveStream` interface in `ws-client.ts`, and that file's snake_case→camelCase
    mapper in the `"move_stream"` case; miss any one and the field is unreachable from client
    code while every gate stays green. `truncated` is pinned end-to-end by assertions on the
    parsed value and on the mapped object, mover and clipped-observer paths both; `mover_light`
    (`WireMoveStreamLightSample` → `MoveLightSample` → the `moverLight` mapper arm) is pinned the
    same way, field for field, on the timeline-present and the `null` paths.
  - **`truncated` is NOT interchangeable with the client's derived move outcome.**
    `WorldSession.moveRequest` derives `WorldSession.moveRequest.executed`/`truncated` from
    geometry (does `stop` equal the
    requested goal), which is a DIFFERENT predicate: a region arrest on the final step sets the
    server's `truncated` while `stop` still equals the goal, and the client deliberately reports
    that as `WorldSession.moveRequest.executed` because the token did reach the goal. Do not
    "simplify" the client to read
    the wire flag — the two answer different questions, and a regression test pins the arrest case.
