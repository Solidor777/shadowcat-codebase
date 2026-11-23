Part of the shadowcat-codebase-realtime-sync skill; read it when changing scene-addressed relays (ping, ruler, emote, scrolling text), move streams, gated moves or the Egress frame payload. Part 02 of 02 of "Realtime & Sync: gotchas"; the index is gotchas.md.

Continues "Gotchas" from gotchas-01-egress-resync-correlated-requests.md.

- **`ScenePing` is gated by `ws::scene_broadcast_permitted`, not by scene
  selection.** Unlike `MoveRequest`/`handle_pathfind` (which SELECT server state and so must
  derive-from-token, per the never-fork table in `shadowcat-codebase-core`'s references/invariants-detail.md), `ScenePing` relays
  only the client-supplied `scene`/`x`/`y` to the room via `broadcast_aux` — there is no server
  state to substitute against.
  The guard instead answers "may this sender broadcast onto this scene at all": the doc must
  exist, be `doc_type == "scene"`, resolve to THIS room's `world_id` via `world_of`
  (`shadowcat-codebase-documents-permissions`), and grant the sender `cap::READ`. Deliberately
  ADMITS a token-less spectator (weaker than `handle_pathfind`'s controls-a-token gate) since a
  READ-only viewer legitimately pings a scene they're watching. Denial is a SILENT drop at the
  call site — no error frame, no behavior split — because any distinguishable response would leak
  scene existence to a non-reader. Rate-limited independently (30/min/user via `ping_rate`,
  checked BEFORE the authz lookup so an over-budget sender never pays a doc read).
  **`ws::scene_broadcast_permitted` is the ONE definition of that admission for every
  scene-addressed relay** — `ScenePing`, `PlayVfx` and `RulerUpdate` all reach it; `PlayVfx`
  applies its extra role restriction first, inside `ws::vfx::vfx_permitted`, which then delegates
  to it. A new scene-addressed out-of-band relay calls it rather than re-deriving the four
  conditions, so the admissions cannot drift (the never-fork rule).
- **`ClientMsg::RulerUpdate`/`ServerMsg::Ruler` is the shared live ruler: a ping-shaped aux relay
  with a payload-bound front end.** The `ws::conn` arm's guard order is the cheap rate check
  (`ruler_rate`, in references/key-files-and-seams-01-room-and-rate-limiter.md), then the pure payload bounds — `ws::ruler::points_admissible` (every
  coordinate finite and within `scene::move_exec::MAX_GATE_WALK_COORD`) and
  `ws::ruler::origin_admissible` (at most `ws::ruler::MAX_RULER_ORIGIN_BYTES` bytes) — then
  `ws::scene_broadcast_permitted` (one doc read). Every denial past the parse is a SILENT drop. A
  READ-only spectator may send one (unlike `PlayVfx`). The frame is passed through
  `ws::ruler::canonical` (an update is active only when flagged active AND non-empty; anything
  else is the vertex-less stop, so recipients never see a stop with points or an active ruler with
  nothing to draw), stamped with the SERVER-known sender as `ServerMsg::Ruler::from`, and
  relayed through `Room::broadcast_aux` UNCLIPPED to EVERY connection in the room, the sender's own
  included — there is no `egress_loop` arm and no per-recipient decision (a ruler is coordinates
  the sender chose to share; its admission is decided once, at the sender).
  **`origin` is the echo guard, not an identity.** The client chooses one token per `WsClient`
  (`WsClient.rulerOrigin`, from `randomUuid`) and the server relays it unverified, so the
  originating client drops its own frame by `origin` while the SAME user's other connections
  still render it. A forged `origin` can only make the client holding that token hide the
  forger's own ruler, and receivers key rulers by (`from`, `origin`) precisely because `origin`
  alone is attacker-chosen (`shadowcat-codebase-scene-rendering`'s `RemoteRulerView`).
  **The points cap is enforced at DESERIALISATION, not in the arm:** `ClientMsg::RulerUpdate::points`
  carries a serde field-level custom deserializer, `ws::ruler::deserialize_points`, so a list over
  `ws::ruler::MAX_RULER_POINTS` (256) fails to parse and the sender alone gets the generic
  `BadMessage` reply that every malformed frame gets, before any scene lookup (the reply reveals
  nothing about any scene); a non-finite coordinate fails the same way (JSON carries it as `null`,
  which `f64` rejects); a FINITE coordinate past the bound, an over-long `origin`, an unreadable
  scene and an exhausted budget are the silent drops. **Serde gotcha:** `ClientMsg` is internally
  tagged (`#[serde(tag = "type")]`), and serde buffers an internally tagged enum's fields into its
  generic content representation before any field's custom deserializer runs, so
  `deserialize_points` bounds what is ACCEPTED, never how much is buffered while the frame is
  parsed; do not cite it as a memory bound.
  **Client limits are one shared fact:** `RULER_LIMITS` (`@shadowcat/core`) mirrors
  `MAX_RULER_POINTS`, `MAX_RULER_ORIGIN_BYTES`, `RULER_RATE_PER_MIN` and
  `MAX_GATE_WALK_COORD` (as `maxCoord`), and a single JSON conformance fixture
  (the ruler-limits fixture beside the core sources, read by the core vitest AND by the server's
  `ws::conn::tests::ruler` through `include_str!`) fails whichever side changes a number alone. Client chain:
  `WsClient.sendRulerUpdate` → the `ruler` case of `handleFrame` → `WsClientHandlers.onRuler`
  (`RulerNotice`, no seq) → `WorldSession.onRuler`, which applies the `viewedSceneId` cross-scene
  guard and the own-`origin` drop (`shadowcat-codebase-scene-rendering`). `sendRulerUpdate` takes an
  EXPLICIT scene, unlike `sendPing`/`sendEmote`, so a stop reaches the scene the ruler started on
  after the view has changed.
- **`ClientMsg::Emote`/`ServerMsg::Emote` is the ping-shaped aux frame with TOKEN-level authz.**
  Same relay shape as `ScenePing` — `broadcast_aux`, no seq, cosmetic only, SILENT drop on any
  denial (no error frame to oracle against) — but `token_emote_permitted` gates on the TOKEN,
  not the scene: the token must be known to the room's in-memory ECS (zero pool reads, unlike
  ping's doc lookup), parented to the named scene, and effectively owned by the sender, resolved
  through `SceneEcs::token_scene_and_effective_owner` — the SAME effective-owner rule
  write-authz and `handle_pathfind`'s token gate use, never a forked looser test; a GM is exempt
  from the ownership half, not the scene-membership half. A token-less member has NO standing
  here (ping deliberately admits one; emote does not). Guard order mirrors ping: the cheap rate
  check first (its own `emote_rate` bucket — see the limiter bullet in references/key-files-and-seams-01-room-and-rate-limiter.md), then the authz
  lookup, then the payload bound — 1..=16 bytes (`EMOTE_MAX_BYTES`; 1–4 emoji graphemes, capping
  the relayed frame size). The client chain mirrors ping's: the Zod schema → `WsClient`'s
  `onEmote` handler (`EmoteNotice`, no seq) → `WorldSession.sendEmote`/`onEmote`, carrying the
  same `viewedSceneId` cross-scene guard the `scene_ping` handler has (drop a frame whose
  `scene` isn't the viewed one — `shadowcat-codebase-scene-rendering`'s cross-scene gotcha).
- **`ServerMsg::ScrollingText { scene, token, text, gm_only }` is the SERVER-AUTHORED twin of
  `Emote`, with no client `ClientMsg` counterpart at all** — it originates only from a fired
  region trigger (`TriggerEffect::ScrollingText`, `shadowcat-codebase-scene-rendering`), never
  from a client send. Same aux shape as `ScenePing`/`Emote`: `Room::broadcast_aux`, no seq,
  never touches the `RingBuffer`/gap-resync path — structurally unreachable from replay/resync,
  same as the other two. Unlike ping/emote's binary admit-or-drop, this frame carries its OWN
  per-connection secrecy bit (`gm_only`, set at fire time from the firing region's `/engine`
  visibility): `egress_loop`'s dedicated arm gates delivery through the pure, unit-testable
  predicate `scrolling_text_admitted(gm_only, world_role)` rather than the room/scene-lookup
  guards `ws::scene_broadcast_permitted`/`token_emote_permitted` use — see
  `shadowcat-codebase-scene-rendering`'s `ScrollingText` bullet for the full secrecy derivation,
  the two independent text-length bounds (server ingress vs. client display truncation), and the
  `EmoteKind` producing-call-site rule. Client chain: `WsClient`'s `onScrollingText` handler
  (`ScrollingTextNotice`, no seq) → `WorldSession.onScrollingText`, carrying the same
  `viewedSceneId` cross-scene guard as `scene_ping`/`emote` — one of the six instances of
  `shadowcat-codebase-scene-rendering`'s cross-scene-divergence broadcast gotcha, alongside
  `MoveStream`/`ScenePing`/`Emote`/`Vfx`/`Ruler`.
- **MoveRequest → MoveStream (broadcast):** `MoveStream` is an **aux broadcast frame** — sent
  via `Room::broadcast_aux_shared` like `ScenePing`, carrying NO seq number (it is cosmetic
  playback data, not an authoritative document event; it never touches the `RingBuffer`/gap-resync
  path). `MoveRequest` is still a one-shot correlated pair for the mover's promise (resolves on the
  matching `move_stream` frame via `pending` map), but `MoveStream` is broadcast to ALL scene
  viewers, not just the mover — the **per-recipient egress transform** (mover full incl.
  `moverVision` + `moverLight`; observer clipped to the samples they can SEE — line of sight AND
  illumination, the lit mask's own predicate — with `moverVision: null` and `moverLight` reduced
  to the carried-light samples whose glow lights a cell in their sight (`null` when none does); a
  GLOW-ONLY frame — `samples` empty, `moverLight` present, `stop`/`durationMs` at the last
  admitted light sample — when only the glow reaches them; suppressed entirely — zero frames —
  when neither does, so the wire invariant is "at least one of `samples`/`moverLight` is
  non-empty") is where the leak-free secrecy boundary lives (`egress_loop`'s dedicated
  `MoveStream` branch, detailed in `shadowcat-codebase-scene-rendering`, whose `mover_light`
  egress-admission bullet owns the `glow_reaches` rule). `MoveError` remains mover-only, always generic (no path
  geometry / vision state disclosed — no-geometry-leak invariant). The egress loop may
  additionally re-send a `MoveStream` to a single connection (never a broadcast) on TWO
  triggers, both read off the frame it just delivered — the connection's own move starting
  (`mover_vision: Some(_)` with the mover equal to the clip target) OR any `mover_light`-
  carrying move starting (a glow changes what every bystander sees) — for a CLIPPED recipient
  only (a non-GM, or a GM with a see-as: `egress_loop`'s `own_move || mover_light.is_some()`),
  re-clipping every other in-flight stream in the scene against the changed sight
  (`shadowcat-codebase-scene-rendering` covers this re-emit path in full).
  `handle_move_request` dispatches `Room::execute_move`, then broadcasts `MoveStream` to the scene.
  Client animation is driven by `TokenAnimator.animateSamples` (time-tagged playback, catch-up on
  late arrival, gap/occlusion detection: gap threshold = `minConsecutiveDelta × 1.5` where
  `minConsecutiveDelta` is the minimum positive inter-sample interval across all consecutive pairs;
  Infinity for < 3 samples — no interior gap detectable). `animateSamples` cancels any competing
  ease-to-stop `anim` entry (handles Event-before-MoveStream ordering); `setTarget` is a no-op
  while `samplesAnim` is live (handles MoveStream-before-Event ordering). Wired end-to-end:
  `WsClient.onMoveStream` → `worldSession` → `SceneInteractionBridge.animateSamples` (carrying
  `moverVision` AND `moverLight`; the latter starts the render engine's lighting sweep) →
  `RenderEngine` → `TokenView` / `TokenAnimator`. `onMoveStream` listeners survive reconnects
  (NOT cleared in `failPending`).
- **Gated moves are request-only + server-executed:** the client sends
  `MoveRequest` and waits; the server validates, executes, and broadcasts `MoveStream`. The client
  MUST NOT apply an optimistic position update for a gated move. The atomic position `Event` (from
  `commit_ops_locked`) is the authoritative document update; the `MoveStream.samples` drive
  cosmetic animation for all scene viewers. The `moveRequest` promise resolves on success (the
  `MoveStream` frame) but the animation is broadcast-driven — no local `animateAlongPath` call
  on the mover side.
- **`Egress::Frame`'s payload stays plain `Arc<ServerMsg>`** — every construction site
  (`ws::conn`) is a locally-synthesized non-`Event` frame (a `Reject`, a chat error, a plain
  forwarded frame already reduced from a `RoomEvent::Other`), never a raw `RoomEvent`. Do not
  widen `Egress::Frame` to carry `RoomEvent` without first re-verifying that invariant against
  every current construction site — doing so would let an unredacted `StoredCommand` reach the
  egress sink through a path that skips `send_filtered_event`'s redaction call.

