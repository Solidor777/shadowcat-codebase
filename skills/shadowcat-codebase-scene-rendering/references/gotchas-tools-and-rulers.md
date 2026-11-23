# Gotchas: docs ratchet, footprint ties, scene-tools gestures and the live ruler

Part of the shadowcat-codebase-scene-rendering skill; read it before changing the measure tool, tool-swap cleanup, move-failure notices, the shared live ruler or GridShape::footprint_cells.

- **Docs-ratchet is live on `data::engine::scene` + `data::engine::geometry`, the
  whole `scene` module tree, and `health`:** every file carries
  `#![deny(missing_docs)]` + the private-items twin — a new undocumented item fails the 3-OS CI
  clippy step, and doc comments on ts-rs types flow into the bindings (regenerate + commit them
  with the change). Movement/traversal docs cite `move_exec::execute_move`/`gate_walk` (never
  `Room::publish` — the stale-citation class); hex `size` docs state the outer-radius
  (circumradius) convention — keep both true when touching those seams.

- **`GridShape::footprint_cells`'s r=0 tie-break is a TRAIT-LEVEL contract, not a
  `SquareGrid`-only accident.** A zero-radius `footprint_cells::ctr` is a literal point, not a
  disc, so "which cell does it belong to" is genuinely ambiguous exactly on a shared boundary or
  corner; both implementations resolve it to `footprint_cells::anchor` (the single cell
  `GridShape::cell_of` would assign), never a multi-cell tie. `pathfinding::footprint_cells` (the
  `SquareGrid` delegate) resolves this via an explicit `r_scene <= 0.0` early return — its
  axis-aligned loop bounds (`floor((ctr∓r)/cell)`) collapse to one index at r=0 independently of
  the guard, so the guard states the invariant explicitly rather than changing behavior.
  `HexGrid::footprint_cells`'s ring-scan + `distance_to_cell_polygon` test has no such collapse and
  genuinely ties across 2-3 hexes at r=0 without an explicit early return — same trait contract,
  independently implemented, independently subject to the identical tie. A
  positive-radius disc on a boundary correctly admits every touching cell on BOTH shapes (genuine
  positive-area overlap, not a bug) — never narrow that case when touching this guard.
  `scene::move_exec::execute_move`'s mask/impassable footprint disc is anchored at the true
  continuous dense-walk sample (`execute_move::next`, not a `cell_center(next_cell)`
  substitution), matching the wall disc's anchor exactly — this guard is what makes that anchoring
  safe on both grid kinds.
- **Scene auto-creates on GM entry** (scene system schema `{grid, background}`); Stage reads the
  grid [[scene-lifecycle-gap]].
- **Clear tool overlays/previews on a mid-gesture tool swap** (draw preview, measure overlay) or
  stale geometry persists. The overlay is the only thing a swap tears down: a route COMMIT the user
  already made is not an overlay and survives the swap (next bullet).
- **A measure-tool route commit OWNS ITSELF; a tool swap detaches it, never cancels it.**
  `makeMeasureTool`'s `commitRoute` takes ownership (a fresh per-commit token held in the tool's
  active-commit variable) BEFORE any async work, which suppresses the tool's pointer handlers until
  the commit settles, and its pathfind/`moveRequest` continuations never consult the tool's
  preview-sequence counter — that counter guards PREVIEW responses only, so a swap
  (`SceneTool.onDeactivate`) cannot drop a move the user already decided on. Deactivation clears
  the active-commit token (DETACHING the commit): the
  request still executes, and the detached commit's settle leaves the overlay alone because the overlay
  belongs to whichever tool is active next (`ToolContext.scene`'s overlay is shared). A commit begun
  after re-activation is a different token, so a detached commit's settle can never release a newer
  commit's suppression. Two commits for one token therefore send two `move_request`s; the
  server's per-token moving lock refuses the second and that refusal reaches the player through the
  move-outcome consumer below. Two branches, both ending in release. With a
  cached preview route the commit sends `moveRequest` at once: a synchronous throw is caught,
  raises one notice under the commit's gesture and releases ownership, and the request's settle
  (either outcome) releases it. Without one, a `pathfind` runs first: a rejection raises the
  route-failure notice and releases, and a throw inside the pathfind continuation is caught by a
  trailing catch that releases (that trailing catch exists only on this uncached chain).
- **Move failures reach the player ONCE per gesture, chosen by TYPE, from one owner.**
  `noticeOncePerGesture` (`@shadowcat/core`) runs a notice unless the gesture object already raised
  one through it (a weakly held set; no gesture means it always raises), and is the single notice
  owner for every source a gesture can reach: the tools' own route-failure notices (the measure
  tool's commit uses the commit's identity as its gesture; the select tool's drag release makes one
  object per drag covering one `pathfind`+`moveRequest` pair per token) AND the host's rejection
  notice. `AppContext.moveRequest` takes the optional `gesture`; `WorldSession.moveRequest` echoes
  it on every published `onMoveOutcome` record, and `Stage` is the ONE consumer of those outcomes —
  a tool never raises a notice for a rejected `moveRequest` itself, or the player sees two. Tool
  route-failure notices choose their i18n key from the rejection's TYPE in `routeFailureKey`
  (`NotConnectedError` gives the disconnected notice, `RequestTimeoutError` the timeout notice,
  `PathfindError` by its `reason`: `unreachable` is no route, `invalid`, `exceeded` is too complex;
  any other rejection gets the generic move-rejected notice), never by message text and never by
  defaulting an unknown failure to "no route". A new move-issuing path must accept or mint a
  gesture and route every notice through `noticeOncePerGesture`.
- **The shared live ruler.** A measure-tool route (the routed preview, or the plain two-point
  measure) can be broadcast to everyone viewing the scene. Sharing is OFF by default and is a
  per-user, per-device preference (`ShareRulerPreference`, persisted under a per-user
  `shareRulerStorageKey`, held by `WorldSession.shareRuler` and surfaced as
  `AppContext.shareRuler`; `ToolRail` writes it, the tool reads it) — never a document field. The
  wire contract and server admission live in `shadowcat-codebase-realtime-sync`. Sender:
  `makeMeasureTool` owns a `RulerSharer` (injected: enable switch, viewed scene, transport, clock,
  timers). It sends at most one update per `RULER_SEND_INTERVAL_MS`, defers a single trailing send
  so the newest route always goes out, re-sends an unchanged shown ruler every
  `RULER_KEEPALIVE_MS` (kept well inside the receiver's `RULER_STALE_MS`), and on each timer firing
  re-checks that sharing is still on and the ruler's scene is still viewed. INVARIANT: every
  local-preview teardown ends the broadcast (`clearRoute`, the plain-measure release, `onDeactivate`
  and a "no route" result), and `RulerSharer.stop` sends exactly one terminating `active: false`
  frame — on the scene the route was SENT on — only if a route was actually sent, so switching
  sharing off mid-drag still ends a shown ruler and an observer is never sent a stop for a ruler
  it was never shown. The sender never emits a non-finite or out-of-bound vertex (the server would
  answer with an error or drop it silently) and thins a route over `RULER_LIMITS.maxPoints` with
  `thinPolyline`: a route already within the cap is returned as an unchanged copy; otherwise a
  LOSSLESS first stage drops every collinear interior vertex (`isCollinear`, 1e-9 relative
  tolerance; a backtrack is a real spike, not collinear), and only if more than the cap remain
  does greedy vertex elimination run, always removing the vertex with the smallest
  `chordDeviation` (its distance to the chord between its CURRENT surviving neighbours, the
  Hausdorff error of that one removal), endpoints fixed, ties to the lower index, O(n log n) via a
  linked list and a lazily invalidated heap. Removals COMPOUND, so the result has no global bound
  on its deviation from the original route; do not cite one. Chosen over triangle area
  (the Visvalingam and Whyatt vertex-elimination method) because area scales with chord length and would remove a larger
  real loss before a smaller one. Receiver: `Stage` feeds `onRuler` into
  `RenderEngine.setRemoteRuler`/`RenderEngine.clearRemoteRuler`; `RemoteRulerView` keys each ruler
  by `rulerKey` (server-stamped user PLUS the connection `origin`, so one user measuring on two
  devices shows two rulers and one user cannot overwrite another's by reusing that user's token),
  assigns a stable per-user `rulerColor` distinct from the local route color, ages every ruler on
  the engine ticker and drops one not refreshed within `RULER_STALE_MS` (a dead sender or a lost
  stop leaves no ghost), and `DisplayBackend.drawRulers` redraws only while rulers live plus one
  clearing frame. `RenderEngine.reapplyViewedScene` clears every remote ruler (they belong to the
  scene being left). The relay is unclipped by design: a ruler is coordinates its sender chose to
  share.
