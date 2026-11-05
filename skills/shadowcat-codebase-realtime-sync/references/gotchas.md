# Realtime & Sync: gotchas

Part of the shadowcat-codebase-realtime-sync skill; read it before changing egress, resync, correlated requests, scene-addressed relays (ping/emote/ruler/vfx), audio frames, move streams, or the docs ratchet.

## Gotchas

- **`egress_loop` test harnesses under a paused tokio clock must keep post-pause test traffic off
  the SQLite repository.** A sequenced `RoomEvent::Event` is filtered through a per-recipient
  query that sqlx runs on the SQLite driver's own worker thread, not a tokio blocking-pool thread —
  the only wait shape tokio's auto-advance inhibition recognizes. A `tokio::time::pause()`'d
  runtime treats time waiting on that thread as idle and auto-advances the clock straight to the
  next pending timer (a `tokio::time::timeout` deadline, or `egress_loop::ping_timer`'s own
  tick), firing it instantly with no real time having passed. Keep test code issued AFTER the
  pause on an out-of-band path instead: `Room::broadcast_aux`/`broadcast_aux_shared` reach the
  sink through `send_plain` with no repository query at all, unlike `Room::publish`. `egress_loop`
  ALSO creates `egress_loop::ping_timer` only after sending Welcome, so a harness must wait for a
  loop-served reply before pausing/advancing the clock, or the timer is constructed at the
  already-advanced instant and its first tick lands a full `PING_INTERVAL` late; the heartbeat
  test harness's probe for this is an `Egress::TimePong` round trip, since only
  `egress_loop::erx`'s arm answers it.
- **A malformed field anywhere in a client-authored `Intent` frame produces a generic,
  UNCORRELATED `ServerMsg::Error` (`WsErrorCode::BadMessage`), never a `Reject` — and the client
  silently discards it (`case "error": break;`).** `Reject` requires the frame to parse into
  `ClientMsg` first (it carries the server-VALIDATED `intent_id`); a JSON/type-level failure —
  e.g. a `Document.id: Uuid` field that isn't a valid UUID string — fails at
  `serde_json::from_str::<ClientMsg>` before `intent_id` is ever extracted, so `handle_socket`'s
  `Err(_)` arm (malformed-frame branch) has no `intent_id` to attach and sends the generic
  `Error` instead. The optimistic prediction that intent pushed via `applyIntent` is now
  UNRECOVERABLE: no `Event` will ever confirm it (the write never reached `apply_intent`), and no
  `Reject` will ever roll it back — see the FIFO-misalignment invariant in SKILL.md for the cascading
  consequence. Any id-shaped string builder (e.g. `@shadowcat/core`'s `deterministicId`) needs a
  shape-asserting test (`toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-.../)`), not just a stability/
  uniqueness test — those alone cannot catch a shape defect, since two calls with the same
  (broken) inputs still compare equal to each other while still being invalid.
- **`ClientMsg::Hello { world, last_seq }` is live** — `ws::conn`'s ingress match
  reacts to `Hello { last_seq: None, .. }` by calling `Room::establish_resync_floor`; `world` is
  destructured away (redundant with the connection's already-resolved `world_id`/`room` from the
  WS upgrade route). `WsClient` sends it unconditionally as the first frame on every socket open
  (`#hasEverOpened` distinguishes cold start from reconnect — see `shadowcat-codebase-client-shell`
  or `WsClient.seedWatermark`'s own doc), so the floor is established in production today — see
  `Room::resync_floor_enforced`'s own doc.
- **`GET /api/worlds/{id}/snapshot`** (`http::routes::world_snapshot`) — every document the caller
  can currently see, filtered exactly like `list_documents` (READ-gated, `filter_properties`
  redaction, token→actor owner join) but across every `doc_type` via `Repository::query_all_documents`
  in one call, plus the room's `current_seq` at read time (`WorldSnapshot.seq`). The client's
  cold-start bootstrap source: `WorldSession.enter` fetches it before opening the WS connection and
  pre-seeds the watermark via `WsClient.seedWatermark`, replacing full event replay from seq 1 on a
  genuine cold start; per-document-type grants (`WorldCapDefaults::grants_for`) are cached locally
  in the handler since a snapshot spans many types, unlike `list_documents`'s single shared `q.type`.
- **`WsClient.open()` does not re-check `running_` after its connect await** — a `stop()` call
  during a pending connect can leave an adopted-but-unwatched transport assigned to
  `this.transport`.
- **Docs-ratchet is live on the whole `ws/` tree AND the `http/` + `auth/` trees:**
  every file in all three trees carries `#![deny(missing_docs)]` +
  `#![deny(clippy::missing_docs_in_private_items)]` — a new undocumented item fails the 3-OS CI
  clippy step, and `ws::protocol` doc comments flow into the generated `ServerMsg`/`ClientMsg` TS
  types (regenerate + commit bindings with any change; the docs site's protocol page links these
  types). Route-handler docs in `http::routes` cite their authz gate (`require_gm`/`AuthUser`/
  `AdminUser`/`permission_context`) and the 404-uniform existence-hiding contract — keep those
  citations true when changing a route's gating.

- **Permissions filter every broadcast per recipient** — hidden fields are stripped before
  transmission (see `shadowcat-codebase-documents-permissions`), never sent-then-hidden.
- **Live search rides the broadcast** as top-N subscriptions over the same egress
  [[m6c-2-live-search]]. `ClientMsg::Search` and the `Egress::Subscribe`/`Sub` subscription
  record both carry `doc_types: Vec<String>` (`#[serde(default)]` on the frame, so an omitted
  field defaults to empty — no filter, every type). `ws::conn`'s ingress arm cap-checks
  `doc_types.len()` against `data::search::MAX_SEARCH_DOC_TYPES` (16) BEFORE calling the
  repository, on BOTH the one-shot and subscribe arms — sending `ServerMsg::SearchError` on
  violation — as defense-in-depth ahead of `Repository::search`'s own identical check
  (`shadowcat-codebase-documents-permissions`), so a caller that bypassed ingress validation
  entirely still cannot force an unbounded `doc_type IN (...)` clause.
- **One-shot correlated request pairs** (`Search`→`SearchResult`/`SearchError`;
  `Pathfind`→`PathResult`/`PathError`; `MergePull`/`MergePush`/`MergeRevert`→`MergeResult`/
  `MergeError`, the last via `WsClient.mergePending` with a caller-sized `timeoutMs` — see
  `shadowcat-codebase-templates`) route replies to the requesting connection only (never
  broadcast); correlated by `request_id` via the `pending` map in `WsClient`. See
  `WsClient` and `ws::protocol`. **Chat ops
  (`SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll`) also carry `request_id` but are
  ASYMMETRIC**: only
  a REJECTION replies (`ServerMsg::ChatError`, sender-only), while success is confirmed by the
  broadcast `Event` echo. They use a separate `chatPending` map whose timer resolves
  (success-assumed) rather than rejects on timeout — see `shadowcat-codebase-chat`.
  **A THIRD family: the 8 `ClientMsg::Combat*` frames** (`CombatStart`/`CombatPause`/`CombatEnd`/
  `CombatAdvance`/`CombatRewind`/`CombatSort`/`CombatRoll`/`CombatResource`), resolved through
  `WsClient`'s own `combatPending` map by `request_id` on BOTH paths — a dedicated
  `ServerMsg::CombatResult { request_id, seq }` answers an accepted intent (originator-only, never
  broadcast) and `ServerMsg::CombatError { request_id, reason }` answers a rejection; there is no
  echo-matching on success. An entry resolves ONLY once its `combat_result` has arrived
  AND `nextExpected` has advanced past its seq, both keyed by `request_id` — never by matching a
  self-authored broadcast `Event`, which identifies neither the `request_id` nor the specific
  intent an entry is waiting on, and which a client that cannot identify its own authorship never
  sees at all. See `shadowcat-codebase-combat`.
- **Correlated-request rejections are TYPED; a caller chooses by the error's class, never by message
  text.** `WsClient` rejects with `NotConnectedError` (no open socket when the request was issued,
  or the socket closed while it was pending — every reject-all path), `RequestTimeoutError` (the
  reply never arrived; says nothing about whether the request would have succeeded — search,
  subscribe, scene subscribe, pathfind, move, combat and merge all use it), and `PathfindError`
  (the server answered `PathError`; carries the typed `PathfindError.reason`). All three are
  exported from `@shadowcat/core`. **`PathError` carries a typed `reason`
  (`ws::protocol::PathErrorReason`: `Unreachable`/`Invalid`/`Exceeded`) beside its presentable
  text**, and the server derives the text from the reason (`PathErrorReason::message`, via the
  `ws::conn` `path_error` builder) so the two cannot disagree; the one mapping from a pathfinder
  failure is `From<PathFail> for PathErrorReason`. **Every refusal the server deliberately does
  not distinguish (a caller with no token in the scene, a turn or budget refusal) is reported as
  `Unreachable`**, so a client can learn no more than "no route" — a new refusal must reuse
  `Unreachable`, never mint a reason that oracles it. A new wire scalar of this kind needs all four
  edits: the Rust enum, the generated TS (`PathErrorReason`), the Zod schema (`PathErrorReasonSchema`
  / `WirePathErrorReason`) and the `WsClient` mapper that builds the error.
- **Every client-generated id comes from `randomUuid` (`@shadowcat/core`), never
  the browser's crypto.randomUUID.** Plain-HTTP LAN play is a non-loopback insecure origin, where the browser
  withholds secure-context members: crypto.randomUUID is `undefined` there, so a raw call throws
  at world entry, while unit tests (Node) and the loopback e2e project (a secure context) can never
  see it. `randomUuid` falls back to crypto.getRandomValues and still produces a version-4 UUID
  the server's document-id rule accepts. Request ids, document ids, the ruler `origin` token and
  pop-out window keys all route through it; `pnpm lint:secure-context` enforces this structurally
  (`shadowcat-codebase-core`).
- **`ClientMsg::AudioTransport { op }`/`AudioListenAs { token }` and `ServerMsg::AudioError
  { reason }`** — GM-only fire-and-forget playlist/playback transport plus the connection-local
  spatial-audio "listen as" override; `AudioError` is a connection-local refusal toast, never
  broadcast, mirroring `ChatError`'s sender-only shape rather than the request_id-correlated
  Combat/RollRequest pattern above (no `request_id` on either audio frame). The
  `egress_loop::listen_as` override lives entirely in connection-local state and is forwarded
  only to the SENDER's own egress task (`Egress::AudioListenAs`); its arm stores the new value and
  sets that connection's own `egress_loop::reeval_deadline` to now, so the sender's scene
  subscriptions re-derive on the very next loop iteration rather than after the debounce window
  the any-`Event` arm uses. It shares the one deadline timer the scene-channel re-eval loop
  already owns and adds no invalidation hook and no other machinery, and no other connection is
  touched. See `shadowcat-codebase-audio`.
- **Arming a connection's OWN re-eval deadline is the pattern for "server state a per-recipient
  derivation reads has changed underneath it".** `egress_loop::reeval_deadline` is a loop-local in
  `egress_loop`, not a field on any shared state, so what varies between the two users of the
  pattern is WHICH connections arm it. The audio listen-as override (above) is the first user: it
  arms only its own sender's deadline, because the changed state is that connection's own.
  `ServerMsg::ExploredFogReset` is the second: `handle_reset_explored_fog` deletes the rows,
  `broadcast_aux` carries the notice to every connection in the room, and the `egress_loop` arm
  sets EACH connection's own deadline to now, so every recipient re-derives its own
  `vision` payload from the now-empty `explored_fog` rather than serving its previous explored mask
  until something else happens to invalidate it. The derivation itself
  (`ws::conn::enrich_vision_explored`) reads the table fresh on every recompute, so the arm is the
  whole invalidation — there is no cache to evict. Reach for this shape, not a new per-frame
  invalidation hook, whenever a mutation changes what a per-recipient derived channel would compute.
  `handle_reset_explored_fog` refuses before deleting anything: a non-GM sender or a scene outside
  the world gets one identical `Forbidden` error, and a `user`-scoped reset on a `Shared`-pooling
  scene gets a distinct `BadMessage` error (refusal set and rationale:
  `shadowcat-codebase-scene-rendering`'s `scene::explored` bullet); no broadcast is sent for
  either. **Client wire mirror of that frame:** `explored_fog_reset` is a member of the
  hand-written `ServerMsg` union, a member of `serverMsgSchemaImpl`, and a `WsClient.handleFrame`
  case that calls the optional `WsClientHandlers.onExploredFogReset` with an
  `ExploredFogResetNotice` (`scene`, `user`, `level`; no seq). The outbound side is
  `WsClient.resetExploredFog` (`ResetExploredFogOptions`), which sends `reset_explored_fog`
  fire-and-forget with no correlated reply. `WorldSession` registers no `onExploredFogReset`
  handler: the server's re-derived `vision` push is the client's whole update. **Trap for ANY new
  inbound frame:** `parseServerMsg` validates against `ServerMsgSchema` and returns `null` for a
  `type` the schema does not list, and `handleFrame` returns on `null` with no error, so a
  server frame missing its `serverMsgSchemaImpl` member is dropped silently on every client while
  the server side and the type union look complete. A new inbound frame needs all three edits —
  the union member, the schema member and the `handleFrame` case.
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
  (`ruler_rate`, in references/key-files-and-seams.md), then the pure payload bounds — `ws::ruler::points_admissible` (every
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
  check first (its own `emote_rate` bucket — see the limiter bullet in references/key-files-and-seams.md), then the authz
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

