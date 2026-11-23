# Hard invariants: secrecy, fog and movement gates

Part of the shadowcat-codebase-scene-rendering skill; read it before changing any fog, lit-mask, publish gate, scene-settings resolver or derived-frame ordering code.

- **A value cached across a client-local scene switch must never be pre-filtered against the
  scene that was active when it was cached — recompute the scene filter at the point of
  application, against whatever scene is current THEN.** This generalizes/complements the
  fog-fail-closed invariant in SKILL.md to a NEW failure axis: multi-scene viewing means the "active
  scene" a cached value should be filtered against can itself change before the cache is
  consumed. `RenderEngine.pendingDerived` is the concrete instance: a `vision` frame
  arriving before `store.appliedSeq` catches up is held behind the watermark. Caching an
  ALREADY-FILTERED `VisibilityInput` (the result of `toVisibility`/`toLighting` run at
  frame-ARRIVAL time) is what must not happen: a client-local scene switch
  (`reapplyViewedScene`) can land while a frame sits pending, and that stale pre-filtered snapshot
  is then silently flushed and painted on top of the SWITCHED-TO scene once the watermark catches
  up — a fog hole computed for scene A rendered on scene B. So `pendingDerived` caches the RAW
  `{payload, seq}` only, and
  `flushPendingDerived()` re-runs `toVisibility(p.payload)`/`toLighting` at FLUSH time, which reads
  `viewedScene()` internally and therefore always filters against the scene that is current AT
  FLUSH, not at arrival. Any future engine cache that spans a client-local scene switch (not just
  vision/fog) must follow this same raw-payload-cache/filter-at-consumption shape — filtering
  eagerly and caching the filtered result is the bug pattern to avoid.
- **`flushPendingDerived` never regresses `lastAppliedSeq` to
  a stale `pendingDerived` entry superseded by an immediately-applied newer frame.** `onSceneFrame`'s
  IMMEDIATE-apply branch (taken when a frame's `computedAtSeq` is not ahead of `store.appliedSeq` at
  arrival) never touched `pendingDerived` — a still-set OLDER deferred entry (e.g. seq 5) could
  survive past a newer frame's (seq 7) immediate apply advancing `lastAppliedSeq` to 7, then get
  wrongly re-applied by a LATER `flushPendingDerived` call (any subsequent store commit), regressing
  the mask back to seq 5. Guard: `flushPendingDerived` applies a pending entry only when
  `p.seq > this.lastAppliedSeq` at flush time (checked AFTER the `store.appliedSeq >=
  p.seq` watermark check, BEFORE the `toVisibility` re-filter) — otherwise discards it; the pending
  slot is unconditionally cleared as soon as the watermark condition is met, applied or not. This is
  a distinct guard from the scene-refilter-at-flush fix directly above (that fix is about WHAT
  scene a cached payload filters against; this one is about WHETHER a superseded payload should
  apply at all) — both guards live in the same function and must both be preserved by any future
  edit to `flushPendingDerived`.
- **`Room::publish`'s non-GM block retains only two gates, neither a traversal gate.**
  (1) An `Update` touching a token's `/engine/x`/`/engine/y` is refused
  outright on bitwise `a0 != a1` (position changed at all) — zero wall/mask/traversal-cell checks;
  a select/move-tool drag never writes `/engine/x,y` directly at all — it goes through
  `makeSelectMoveTool.previewMoves`/`makeSelectMoveTool.commitMoves`, request-only via `moveRequest` → `execute_move`, the SOLE remaining
  implementation of the per-cell traversal decision (see the parity-checklist bullet in references/scene-ecs-and-engine-reroot.md).
  (2) A `Create` of a `token` doc is still authorized: the target scene must exist
  (`scene_grid_sizes`, fail-closed axis 6 in references/scene-ecs-and-engine-reroot.md), the engine body must parse and be finite
  (fail-closed), and the placement's CENTER cell (`resolve_grid_shape(...).cell_of((x,y))` — a
  point, not a traversal, so no `line_traversal`/supercover call here) must lie in the user's mask
  per `movement_restriction`: `Unrestricted` ⇒ no check; `Visible` ⇒
  `visible_cells_cached(user, scene, lenient)`; `Revealed` ⇒ the same mask unioned with
  `get_explored` (deferred past the scene-read-lock scope, since `get_explored` is async and must
  not run under the guard). GMs are exempt from
  both gates entirely. `publish::visible_cache`/`publish::explored_cache` memoize per `(scene, lenient)`/
  `scene` within one `publish` call so a batch of Creates doesn't recompute the mask or refetch
  explored per token. **By design: a dark scene under `Visible` still refuses non-GM token
  placement into an unseen cell** — the same fail-closed reasoning the per-step traversal gate
  uses, scoped here to Create. Do NOT "fix" this by softening the defaults — it is the correct
  fail-closed outcome.
- **The server lit mask is the lighting-aware secrecy gate**: `player_lit_mask(user)` =
  `LOS ∩ (lit ∨ darkvision)`, union over the user's vision sources (owned tokens ∪ observer-tier
  tokens when `observerVision`), emitted as per-recipient `lit` cells. Wire format:
  5-int `[i,j,band,tint,hint_idx]` + a top-level `renderHints` table
  (the cell's last int indexes it; each entry is a tagged `RenderHint` OBJECT such as `{kind:"desaturate"}`, never a
  string); `VisionMode` carries `render_hint: Option<RenderHint>` and the vision-modes ingress validates it;
  `player_lit_mask` resolves a per-cell hint via the highest-floor admitting vision mode (`None` wins
  ties). Fail-closed (no source / dark scene ⇒ empty; cell scans bounded by
  `explored::MAX_CELLS_PER_POLYGON` with a `saturating_mul` span guard). Egress is ADDITIVE —
  `polygons` + the post-lock `explored` are unchanged, GM stays `mode:"all"`. **Environment light
  is edge-projected and `blocksLight`-occludable SERVER-SIDE (`lighting::env_light_polys`,
  `SceneEcs`'s `lighting_inputs_from`) — this is a genuine secrecy input, not cosmetic.** A cell's
  illumination (`lighting::cell_illumination`) composes the boundary-projected environment ambient
  with placed lights and feeds `point_qualifies`/`cell_visible`, which gates both `player_lit_mask`
  and the movement gate (`visible_cells`/`visible_cells_cached`) — so occluding the
  environment ambient behind a `blocksLight` wall genuinely narrows what a non-GM can see and move
  into, the same as a placed light's occlusion. `env_light_polys` samples the scene-bounds
  perimeter (`MAX_ENV_LIGHT_SAMPLES=256`, clamped `[4, 256]`; skipped outright at zero
  environment intensity, where the composition admits no environment at all) and reuses the SAME
  `vision::visibility_polygon` primitive + `light_walls` set placed lights already use — no forked
  occlusion computation. **Fail-closed/strictly-narrowing by construction:** the occluded
  environment base is `≤` the pre-occlusion flat-floor level everywhere (an empty `env_polys` set
  or a cell outside every boundary polygon contributes 0, never negative), so the composed
  illumination — and therefore the derived visibility mask — can only SHRINK relative to the prior
  flat-ambient behavior, never grow; this monotonicity is what makes the projection safe to ship as
  a secrecy input even independent of `env_light_polys`'s own occlusion-computation correctness.
  **The lit set IS the visible set — for the mask, the token stream and the explored memory.**
  A normal-vision observer's visibility on a lighting-enabled scene is `LOS ∩ lit`
  (server-authoritative; darkvision bypasses the light half within its range): `player_lit_mask`
  emits it, the egress clip admits a token's position samples by the same per-source conjunction
  (`InstantSight::sees` — `ws::conn::clip_move_stream`), and `enrich_vision_explored` remembers
  exactly those cells (`ExploredSet::mark_cells`). The `vision` payload's `polygons` remain the
  LOS alone (the fog's holes), so the CLIENT must render "in sight but unlit" itself: the
  `Lighting` class carries darkness regions (`Lighting.setDarkness`, the viewer's current line of
  sight — `renderVisibility`'s `visible` set, or the vision sweep's chosen/blend polygons while
  one plays) that `LightingFrame.darkness` hands the backend, and `PixiBackend.setLighting`
  paints them as a sheet at `MAX_DARK_ALPHA` (the darkest gradation band) inverse-masked by the
  union of the lit cells' polygons (`litHoles`, the same sheet-and-holes technique
  `paintFogSheets` uses) beneath the per-cell fills — with NO lit cell the sheet paints whole
  with its mask cleared, the explicit branch, never through an inverse mask over an empty
  `Graphics` whose rendering the code would otherwise be assuming — so an in-sight unlit cell is
  as dark as the darkest band, never brighter than a dim cell, and a token standing in it is
  drawn under that darkness (send-then-hide, under the UX-outranks-secrecy invariant; the server never streams its
  MOVE to that observer). Darkness is withheld when no lighting model applies
  (`Lighting.setTarget(null)`: a GM's `mode:"all"`), and the client still performs no occlusion
  or illumination computation of its own — band→alpha, tint and `renderHint` desaturation are
  display resolution of server-decided cells.

