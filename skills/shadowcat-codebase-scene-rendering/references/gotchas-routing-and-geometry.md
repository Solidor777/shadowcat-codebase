# Gotchas: router, arrest, band overrides, hex lerp, supercover and cross-scene leaks

Part of the shadowcat-codebase-scene-rendering skill; read it before changing diagonal rules, arrest truncation, GmOnly band overrides, hex line sampling, supercover corner crossings or cross-scene stream leaks.

- **`resolved_diagonal_rule` is world-only** — there is intentionally no per-scene `diagonalRule`
  override in the pathfinder; the same rule applies across all scenes in a world. Matches the client
  `resolveSceneSettings` precedence (the setting lives in `world-settings`, not per-scene).
- **`RegionField::is_arrest`/impassable checking is footprint-gated in the router (`cell_enterable`'s mask
  check, via `grid.inputs.shape.footprint_cells ∪ grid.inputs.shape.line_traversal`) but CENTER-CELL-ONLY in `move_exec` — a
  deliberate asymmetry (route stricter, execution looser), not a bug.** `route ⊆
  gate-allowed` still holds because the router's predicate is already a documented superset of the
  executor's. Do not "fix" `move_exec` to match the router's footprint check without re-deriving
  the parity argument — the asymmetry is load-bearing, matching the wall-check
  asymmetry the pathfinder invariant in references/invariants-routing-and-execute-move.md already documents.
- **`find()`'s arrest truncation recomputes cost by REPLAYING the per-step cost via
  `GridShape::neighbors_with_cost`, never `step_cost` directly and never by trusting `astar_leg`'s
  per-leg running total for the truncated prefix.** Parity threading is purely
  sequential/order-dependent (not leg-boundary-dependent), so a naive "sum the per-leg totals up to
  the truncation point" would be wrong whenever the truncation falls mid-leg; the cost-replay
  technique (walk the surviving cell sequence from parity 0, re-run `neighbors_with_cost` per pair)
  is the only correct way to get an accurate truncated cost — consistent with "neither the
  executor nor the router ever calls `step_cost` directly" in references/senses-and-move-exec.md: this replay is no exception.
- **A whole-BAND `GmOnly` override must NULL the field, not remove the key, in
  `filter_properties`.** `Document::system` is a required serde field — dropping the `"system"`
  key from the redacted JSON before re-deserializing into `Document` panics; dropping an optional
  band's key is instead indistinguishable from a document that never carried one, breaking the
  client's stable envelope shape. One shared classifier decides this, not a per-pointer arm:
  `redaction_target` reads the band set stated exactly once in `permission::REDACTABLE_BANDS`,
  classifying an override that names a whole band as `Band` (nulled in place) and one that
  descends into a band as `Within`. A new redactable band is therefore a new entry in that
  constant, never a hand-written branch here. Nested redaction is container-dependent — an object
  key is stripped, an array element is nulled in place; see
  `shadowcat-codebase-documents-permissions` for that within-band rule. A whole-band override is
  currently declared only by secret regions, at `/engine` rather than `/system`; any future doc
  type wanting whole-body secrecy (vs. per-field) rides the same classifier.
- **A fixed-count cube lerp is a THIN LINE, not a supercover.** The standard Red Blob hex
  line-draw samples `n+1` points with `n = max cube-axis delta`, spaced one full hex PITCH
  apart — a hex's minimum width — so corner slivers fall between samples: it omits a
  geometrically crossed hex on ~55% of random segments, and when `n` rounds to 0 it drops the
  destination's own hex, breaking the "both endpoint cells always included" contract. Because
  this is the hex movement gate's primitive `move_exec` relies on for cell-membership checks,
  every omitted hex is one a non-GM could move through unchecked against the visibility mask.
  `HexGrid::line_traversal` instead IS a **ψ-crossing supercover**: `cell_of` is
  nearest-center, so a hex is its center's Voronoi cell and every hex boundary lies on an integer
  level set of ψ₁=x−y, ψ₂=z−y, ψ₃=x−z (fractional cube coords) — enumerate every integer ψ crossing,
  sample each interval's midpoint, plus a perpendicular epsilon probe either side of each crossing
  and both endpoints (edge-riding / vertex / endpoint-on-boundary). Over-inclusion is the only
  failure mode and is safe HERE because this set feeds gates only, never a reveal write (the sole
  explored-set writer, `ws::conn::enrich_vision_explored`, is fed by the lit mask's own visible
  cells via `mark_cells`) — re-check that property before reusing it anywhere else.
- **"The square failure mode can't happen here" is not a safety argument.** Hex genuinely has no
  analog of the square diagonal-corner-tie bug — 6 uniform neighbors, no orthogonal/diagonal
  split — and that true statement is what let the thin-line traversal ship unexamined: hex had its
  OWN omission class. Establishing that a known failure mode is absent says nothing about which
  failure modes the new geometry has of its own. Related and identical in shape: `scene::navmesh`
  was excused from a hex audit as "the continuous-model router, orthogonal to grid kind" — but grid
  kind and movement model are INDEPENDENT axes, so they COMBINE (`hex` + `continuous` is a live
  scene) rather than exclude, and it was square-on-hex at three sites. Independence is a reason to
  CHECK a site, never to skip it.
- **`supercover_cells`'s corner-crossing branch never drifts
  past the target on a diagonal king-step whose leg endpoints both sit exactly on 4-way grid-line
  intersections.** The diagonal corner-step is gated on a per-axis
  remaining-step budget (`supercover_cells::remaining_i`/`supercover_cells::remaining_j`): it fires
  only when BOTH axes still owe a grid-line crossing, and once either budget hits zero only the
  other axis steps, regardless of any tie between
  `supercover_cells::t_max_i`/`supercover_cells::t_max_j`. A tie alone must never step an axis that
  has already arrived: a forced single-axis step (from an endpoint sitting exactly on a grid line)
  puts the two step-parameter values into permanent lockstep, and every later tie would then
  re-step the arrived axis, drifting past `(ei,ej)` until `MAX_MOVE_CELLS` aborts with `None`.
  Convergence is therefore a property of the bounded step budget, not of floating-point
  tie-breaking; the safe-over-include behavior for genuine mid-path corner
  crossings (both flankers emitted) is covered by dedicated regression tests in
  `scene::movement`. `execute_move`'s frozen-fixture "diagonal 3-step king path, full visible" case
  (`scene::move_exec`) pins the non-truncated outcome.
- **Cross-scene `MoveStream`/`ScenePing`/`Emote`/`ScrollingText`/`Vfx`/`Ruler` leak class — exists only because
  per-client scene divergence is possible.** When every client renders the SAME scene
  (`activeScene`, in lockstep), there is no per-client "which scene am I looking at" state for a
  broadcast fan-out egress path to diverge against, so this leak class cannot exist.
  `gmViewedScene` (GM local roam) is what introduces per-client scene divergence: a room-wide
  `MoveStream`/`ScenePing`/`Emote`/`ScrollingText`/`Vfx`/`Ruler` broadcast reaches connections that may be
  viewing DIFFERENT scenes than the event targets. `WorldSession` closes it client-side by
  dropping any frame whose `scene` doesn't equal `this.viewedSceneId` (`onMoveStream`/the
  `scene_ping`/`emote`/`onScrollingText`/`onVfx`/`onRuler` handlers,
  the `worldSession` module) — a GM roaming scene B must not animate/ping-render scene A's event, and
  vice versa. **Any future per-client "which scene am I looking at/subscribed to" feature must
  re-audit EVERY broadcast fan-out egress path for this same divergence class, not just the render
  layer** — `MoveStream`/`ScenePing`/`Emote`/`ScrollingText`/`Vfx`/`Ruler` are the six that carry the
  client-side scene filter; a new room-wide broadcast type added later (chat, future
  presence/cursor frames) inherits the same risk the instant any client can view something other
  than the room's single shared `activeScene`.

