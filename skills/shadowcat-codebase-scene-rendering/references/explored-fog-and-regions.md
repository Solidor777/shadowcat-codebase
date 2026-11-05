# Explored fog memory, region geometry and region triggers

Part of the shadowcat-codebase-scene-rendering skill; read it before changing scene::explored, scene::regions, region_field, region triggers or ScrollingText effects.

- `scene::explored` — `ExploredSet` fog memory: `mark_cells(cells)` (THE explored writer,
  fed by `ws::conn::enrich_vision_explored` with the recipient's currently-VISIBLE cells — the
  `vision` payload's own `lit` groups, line of sight ∩ illumination — never a line-of-sight
  polygon on its own, so a player remembers only terrain they could actually see),
  `to_bytes`/`from_bytes` (persistence), cell-based. Lifecycle: `explored_fog` rows are purged on
  scene delete (`delete_document_tx`, both authoritative delete paths), world delete
  (`delete_world`, by the denormalized `world_id`), and user delete (`delete_user`) — rows do not
  orphan on any of these paths.
  **Which ROW a recipient's memory reads and writes is a per-scene mode**, `FogPooling`
  (`Individual` by default, `Shared` pooled), resolved server-side through `SceneEcs::resolve_scene`
  on the ordinary engine < system-defaults < world-settings < per-scene fold and captured by
  `SceneEcs::scene_fog_pooling` under the SAME ECS read lock as the grid maps, so one evaluation can
  never mix a stale mode with fresh geometry. `scene::explored::explored_fog_key` maps the mode to
  either the recipient's own id or the reserved `Uuid::nil()` sentinel, and
  `ws::conn::enrich_vision_explored` computes it once per (scene, level) group inside its
  per-group loop and uses that one value for both its `get_explored` read and its `set_explored`
  write — a read/write key that could diverge would let a player write into a bucket nobody reads and
  silently stop accumulating fog. Flipping the mode migrates and merges NOTHING in either direction:
  per-user rows go dormant under `Shared` and resume under `Individual`, which is why the fallback
  direction matters — an unresolved mode falls back to `Individual`, never to pooled.
  **A sentinel-keyed row is invisible to any query that INNER JOINs the owner table.**
  `SqliteRepository::export_world_rows` translates a fog row's owner into a portable username for the
  world bundle, and the nil sentinel matches no `users` row, so an inner join drops every pooled
  scene's memory from the bundle with no count and no warning. It LEFT JOINs and classifies from the
  ID (`ExportedFogRow::pool` is `user_id == Uuid::nil()`), never from the username being absent —
  those two cases are different, and treating an unresolvable orphan as the pool would merge a
  deleted user's private fog into the bucket every player reads. The bundle also carries `level_id`,
  which is part of this table's primary key: omitting it collides two levels of one scene onto one
  row. **The import twin is `SqliteRepository::import_world`:** a bundle row with
  `ExportedFogRow::pool` set is inserted under `Uuid::nil()` directly and never goes through
  `SqliteRepository::resolve_username_tx`, because an unresolved username is indistinguishable
  there from a genuine orphan and would be skipped, silently dropping every Shared-mode scene's
  pooled memory. A non-pool row whose username does not resolve is skipped and COUNTED in
  `ImportSummary::skipped_fog`; it is never merged into the pool. Check both halves whenever you
  add a row this table keys by something other than a real user.
  A FOURTH purge trigger is EXPLICIT rather than a side effect of
  removing something else: `SqliteRepository::reset_explored_fog`, reached through the GM-only
  `ClientMsg::ResetExploredFog` intent (`ws::conn::handle_reset_explored_fog`). The repository
  method deletes by scene plus an OPTIONAL level and an OPTIONAL user; at that layer each absent
  scope widens to "every" rather than narrowing, and an unscoped call also deletes the pool's own
  sentinel row. **The handler has three refusal conditions carrying two different error
  values, plus an `Internal` failure path:** a non-GM sender and a scene absent from this world (or not a scene) both get
  ONE identical `Forbidden` value, so a caller cannot tell a missing role from a scene in another
  world; a `user`-scoped reset on a scene whose `FogPooling` resolves to `Shared` (resolved
  through `SceneEcs::resolve_scene`) gets a DISTINCT `BadMessage` error, because no per-user row
  is ever read there and the call would delete nothing while still broadcasting success. That
  refusal is deliberately NOT remapped onto the nil sentinel: "reset this player" silently wiping
  every player's shared memory is worse than refusing, so never add a remap that widens the
  requested `user` to the pool. A repository failure returns `Internal`. Only a request naming a
  `user` is refused under `Shared`; a scene-wide or level-scoped reset with no `user` proceeds. The purge is a hard
  delete with no undo, which is what the fog model supports: a cleared cell re-marks the next time
  the recipient's vision covers it.
- `scene::regions` — pure region geometry, no ECS/I/O (mirrors
  `scene::movement`'s module invariant): `RegionShape` (`Rect`/`Circle`/`Polygon`), `RegionBehavior`
  (`Terrain`/`Impassable`/`Arrest`), `RegionEffect` (composed per-cell result), `rasterize(shape,
  cell)` (grid cells whose CENTER falls inside the shape — fails closed to `None` on a degenerate
  shape (non-finite coords, non-positive radius, `<3`-vertex polygon) or an over-cap AABB
  (`MAX_REGION_CELLS`=100_000), never a partial/silently-empty result), `compose(contributions)`
  (precedence `Impassable > Arrest > Terrain`; overlapping Terrain costs take the MAX, never
  summed), `RegionField`/`RegionFieldBuilder` (`.add` silently drops a fail-closed shape —
  contributes nothing, never all-passes; `.build` composes per-cell), and `parse_region_shape`
  (structural-only parse of a region doc's `/shape` body; any malformed field fails closed to
  `None`, dropping the whole region). **`MAX_CELL_COORD` (`i32::MAX - 1.0`) is checked on all four
  AABB edges before any i64 arithmetic, and that ordering is the invariant:** without it an
  extreme-magnitude finite coordinate (e.g. `-1e300`) saturates the float→cell-index cast to
  `i64::MIN/MAX`, and the subsequent `i1 - i0 + 1` cell-count arithmetic overflows BEFORE the
  `checked_mul` DoS-cap check runs — a bypass of the cap, not merely a wrong count. A
  large-magnitude-but-small-span coordinate (e.g. `1e13`) is a separate failure mode also caught by
  the same bound (would otherwise silently truncate/wrap under `as i32`, aliasing onto an unrelated
  real cell).
- `SceneEcs::region_field(scene, viewer)` — the composed `RegionField` for a
  scene. **Two-value contract, never a third mode:** `viewer: None` is the AUTHORITATIVE view
  (every enabled region, unfiltered) — used by the GM and by `move_exec` (which always springs
  secret regions on execution regardless of what the mover's own route preview could see);
  `viewer: Some(user)` is the PER-REQUESTER view used by the grid A* router — a region is included
  only when `user` can see the visibility tier declared on its `/engine` (defaults
  to `All` when undeclared), via `engine_tier_visible(doc, viewer)` — the per-requester wrapper
  over `engine_tier_visible_to`, which is the SINGLE `property_overrides["/engine"]` +
  `Access::can_see` authority the footprints channel and `move_walls` also reach, and the same
  mechanism that already
  gates every other document's egress — no new secrecy machinery. **Callers MUST pass
  `None` for a GM requester** — mirrors `visible_cells`'s GM-skips-the-mask convention; passing
  `Some(gm_user)` would incorrectly filter a GM's own field.
- **Region triggers (mechanical effects on enter/arrest).** `RegionEngine.triggers:
  Vec<RegionTrigger>` (`TriggerEvent` = `enter`/`arrest`; `TriggerEffect` =
  `condition_add`/`condition_remove`/`resource_delta`/`chat_notice`/`teleport`/`scrolling_text`,
  `chat_notice` with a `NoticeAudience` — see the `ScrollingText` overlay bullet below and the
  Portals bullet in references/lighting-regions-emitters-elevation.md for `teleport`'s own application mechanics) — ingress-validated in
  `normalize_engine`'s `"region"` arm
  (`RegionEngine::validate`), because triggers are engine-EXECUTED payloads, unlike the
  movement fields' read-side fail-closed semantics. The composed `RegionField` erases region
  identity, so a second read model exists beside it: `SceneEcs::trigger_regions(scene)` builds
  `regions::TriggerRegion` identity rows (region id, `visible_to_all` via
  `engine_geometry_visible_to_world`, triggers, cell set) from the SAME `regions::rasterize` —
  one geometry derivation feeds both, pinned by an anti-drift parity test. `move_exec` stays
  pure: `MoveOutcome.entered_cells` (the deduped cell-transition sequence) +
  `MoveOutcome.arrested` report, never write. `regions::fired_triggers(regions, entered,
  arrest_cell)` is the pure firing plan (each trigger at most once per report). The TWO fire
  sites both funnel into `Room::fire_region_triggers` (ONE effect-application path):
  `Room::execute_move` after the position commit + combat decrement, and
  `Room::fire_placement_triggers` for token Creates / genuine position Updates (placement and
  GM teleport; footprint cells via the SAME `resolve_token_footprint` +
  `GridShape::footprint_cells` the move gate uses — never a second footprint formula). A
  region-doc edit never re-fires; a disabled region contributes nothing. Effects commit as ONE
  server-authored batch via `commit_ops_locked` under `WriteOrigin::CombatTransition`, never
  batched with the client-origin write that triggered them (the `execute_move` split
  discipline). `resource_delta` is combat-scoped (`combat::transition::resource` against the
  token's combatant in the scene's active combat; `amount` is a `Formula` evaluated via
  `combat::eval::eval_formula` against the actor host) — no active combat / no combatant /
  `Mirror` binding = no-op + ONE deduplicated GM-only notice. Secrecy: there is no
  per-requester form of the identity table (the server springs secrets); instead every notice
  a not-`visible_to_all` region fires is FORCED `Audience::GmOnly`, and condition/resource
  writes are ordinary egress-filtered document updates.
- **`TriggerEffect::ScrollingText { text }` — a region-trigger floating overlay, the
  server-authored twin of a player `Emote`.** Firing broadcasts `ServerMsg::ScrollingText {
  scene, token, text, gm_only }` via `Room::broadcast_aux` — an OUT-OF-BAND, unsequenced aux
  frame (no document, no seq), mirroring `Emote`'s own shape exactly: it never rides the
  `RingBuffer`/`Room.tx` `RoomEvent::Event` path, so it is structurally unreachable from
  replay/resync (a client that missed it while disconnected has no way to recover it — same
  as a player emote). Rendered by reusing the EXISTING overlay lifecycle:
  `WorldSession.onScrollingText` → `Stage`'s `onScrollingText` subscriber →
  `RenderEngine.addEmote(token, text, "caption")` → `EmoteView`'s age-tracker (client/render's
  `emote-view` module) — never a second floating-text renderer.
  - **Two independent bounds, at two layers — neither is the other's mirror.** The SERVER
    validates the authored `text` at ingress (`RegionEngine::validate`'s `"scrolling_text"` arm,
    `data::engine::geometry`) against `chat::MAX_MESSAGE_CHARS` — the SAME constant and the SAME
    precedent `TriggerEffect::ChatNotice` uses for its own `text` field, never a tighter
    server-side cap of its own — no constant of that narrower shape exists in this codebase;
    do not invent one when citing this bound. The CLIENT independently display-truncates in `EmoteView` via
    `MAX_OVERLAY_DISPLAY_CHARS` (80 codepoints, `truncateForDisplay`) — a much shorter,
    purely cosmetic limit the server's own bound does not know about: the server accepts more
    text than the overlay ever shows.
  - **`EmoteKind` is declared at the PRODUCING call site, never inferred by the renderer from
    string length.** `RenderEngine.addEmote(tokenId, emote, kind: EmoteKind = "glyph")` — a
    player-fired emote (`Stage`'s `onEmote` handler) omits `kind` and gets the default `"glyph"`
    treatment (large single-line glyph font, `PixiBackend.drawEmotes`'s glyph branch never
    wraps); `Stage`'s `onScrollingText` handler passes `"caption"` explicitly
    (`e.addEmote(m.token, m.text, "caption")`), which wraps at `EMOTE_WRAP_WIDTH` in the smaller
    `CAPTION_FONT_SIZE` font. A future overlay use case adds its own `kind` argument at ITS OWN
    producing call site — never a length/content heuristic inside `EmoteView`/`PixiBackend`.
  - **Anchor convention: bottom-centre.** `PixiBackend.drawEmotes` anchors every overlay
    (glyph or caption) at `(0.5, 1)` with `g.y` at the token's TOP edge, so a multi-line caption
    block grows UPWARD from that edge rather than centring over the token.
  - **Secrecy, fail-closed.** `gm_only` is derived server-side in
    `Room::apply_region_trigger_effects` from the SAME `secrecy_rows`/`visible_to_all` lookup
    `TriggerEffect::ChatNotice`'s own forced-`GmOnly` audience uses (`gm_only: !visible_to_all`
    — an unresolvable row fails closed to forced-GM-only, matching `ChatNotice`'s own fallback).
    The per-connection drop is the named, unit-testable predicate `scrolling_text_admitted(
    gm_only, world_role) -> bool` (`ws::conn`) — `!gm_only || world_role == WorldRole::Gm` —
    called from `egress_loop`'s `ServerMsg::ScrollingText` arm, a silent drop (no error frame)
    for a non-GM connection when `gm_only` is set. This — a pure, I/O-free, unit-testable
    predicate reached from `egress_loop`'s per-connection match arm — is the preferred, testable
    shape for any FUTURE secrecy-bearing aux frame; it sits beside the existing per-connection
    decisions `ServerMsg::Evicted` (targeted delivery) and the `ServerMsg::MoveStream` egress
    clip already use.
  - Also joins the cross-scene-divergence broadcast gotcha in references/gotchas-routing-and-geometry.md, whose guarded set is six
    (`WorldSession.onScrollingText` drops any frame whose `scene` doesn't equal
    `this.viewedSceneId`, same shape as `MoveStream`/`ScenePing`/`Emote`/`Vfx`/`Ruler`).
