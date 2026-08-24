---
name: shadowcat-codebase-realtime-sync
description: "Use when touching Shadowcat realtime: WebSocket transport, per-world rooms, broadcast/egress, sequence numbers + resync, the client document store and optimistic/rollback, sessions/auth, user accounts (admin-created) and world invite/accept seating, or live search. Covers src/server/src/{ws,http,auth} + src/client/core store. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Realtime & Sync

Orientation for the realtime transport (ws/http/auth) and the client store with optimistic
application + rollback.

## Purpose

The client sends intents over a WebSocket; the server validates, applies, and broadcasts ordered
events to per-world rooms. Every broadcast carries a per-world monotonic sequence number; clients
detect gaps and resync from a bounded event buffer or a snapshot. The client may apply intents
optimistically and roll back on divergence.

## Key files & seams

- `ws::room` — `Room` (per-world), `RingBuffer` (time/size-bounded event buffer)
  + `range_from(from_seq)` for gap resync, `subscribe() -> (Receiver, seq)`, `current_seq()`,
  `broadcast_aux()` (out-of-band), `RoomRegistry`. `get_or_create` cold-hydrates the scene ECS:
  scene entities (`query_scene_entities`) **plus** the world config-docs
  `world-settings`/`light-gradation`/`vision-modes` + actors (`query_documents`), seeded via
  `SceneEcs::set_world_config`/`set_actors`; the live `apply_op` path keeps the side-tables current.
  - `Room::commit_ops_locked(repo, ctx, ops, ts, origin)` (`pub(crate)`) — gate-free authoritative write
    tail (apply_intent → ECS-hydrate → ring/seq → broadcast Event → stats). Extracted from
    `publish`; PRECONDITION: caller MUST already hold `publish_guard`. Non-reentrant — do NOT
    re-acquire `publish_guard` inside (tokio `Mutex` would deadlock). Both `publish` and
    `execute_move` call this as their commit step.
  - `Room::execute_move(repo, ctx, scene_id, token, path, ts)` — server-authoritative token move.
    **`scene_id` IS NOT TRUSTED and selects nothing.** The gate's scene is DERIVED from the token
    via `SceneEcs::token_move(token, &[])`, and every gate input keys on that; the request's
    `scene_id` is only checked for agreement and refused on mismatch (redundant defense-in-depth).
    Taking it as input is a total bypass of the wall + visibility gate with authorization fully
    intact, so any NEW move-like or routing frame added here must derive the same way. A frame naming no token (`Pathfind`) must instead prove presence. Full invariant +
    the failure it prevents: `shadowcat-codebase-scene-rendering`, the derive-from-token INVARIANT.
    Acquires `publish_guard` at the TOP and HOLDS it across the entire validate→commit critical
    section (mirrors `publish` atomicity). Scene read locks are scoped and dropped before the
    `get_explored().await` (no lock across await); `publish_guard` (tokio `Mutex`) is intentionally
    held across awaits. Calls `move_exec::execute_move` (pure, lock-free), then `commit_ops_locked`
    (single acquisition, no re-entry). Atomic single position write (`/system/x` + `/system/y`
    OCC pre-image ops). Returns `MoveExecution { scene, stop, render_path, duration_ms, samples,
    mover_vision, cost }` —
    `scene` is the DERIVED scene, and it is what `MoveStream.scene` is stamped from, so the
    per-recipient egress clip and the client's viewed-scene filter cannot key on a client value.
  - `moving: Mutex<HashMap<Uuid, i64>>` — per-token moving lock: token → move-end epoch-ms. Lazy
    expiry (no timer); absent or expired entry allows the move. Updated after each successful commit
    (still inside `publish_guard`). In-memory only — cleared on server restart (move state is derived,
    not durable).
  - `Room::establish_resync_floor(user_id)` / `Room::resync_floor(user_id)` — the per-user resync
    floor: `session_floors: Mutex<HashMap<Uuid, i64>>`, same in-memory/room-lifetime pattern as
    `moving`. `establish_resync_floor` is called from `ws::conn`'s `ClientMsg::Hello { last_seq:
    None }` arm (the field is no longer vestigial — see the Gotchas entry below). `resync_floor`
    fails closed to `current_seq() + 1` (empty) for a user with no recorded floor, never to `1`.
    Bounds "any member can request the entire world history via `ResyncRequest`" — the reachability
    half of the historical-replay confidentiality gap; the redaction-policy half is untouched.
  - `Room::resync_floor_enforced()` — whether `ws::conn`'s explicit-`ResyncRequest` handler
    (`Egress::Resync`) actually clamps against the floor. `true` for every production
    `RoomRegistry` constructor (`new`, `with_capacity`): the client unconditionally sends a
    cold-start `Hello` as the first frame on every socket open (`WsClient`'s `open()`), so every
    connection establishes its floor before it could plausibly send a `ResyncRequest`. Deliberately
    NOT consulted by `egress_loop`'s broadcast-lag auto-resync branch — that path replays from the
    connection's own live-tracked watermark, not an untrusted client-supplied `from_seq`, so it is
    orthogonal to the gap this flag closes; clamping it there would break ordinary lag recovery
    independent of any client change.
- `ws::protocol` — client/server message frames; `ServerMsg`, `event_seq()`.
- `ws::conn` — per-connection loop + egress; `ws::time` — server time source +
  client offset calibration (exists before its consumer).
  `send_room_event` (takes `room: &Room` alongside `repo`/`ctx`) is the single dispatch point
  every broadcast frame reaches — live delivery (`egress_loop`'s seq-carrying arm) and `replay()`
  (`Room::resync_range`-driven, serving `Egress::Resync` and the lag-driven auto-resync branch)
  both route every `ws::room::RoomEvent` through it. A `RoomEvent::Event(Arc<StoredCommand>)` goes
  to `send_filtered_event`; every other `RoomEvent::Other(Arc<ServerMsg>)` (including `MoveStream`,
  clipped separately by `clip_move_stream`; see the invariant below) passes through unredacted via
  `send_plain`. `send_filtered_event`'s shape: `load_current_docs` awaits the
  Create/Update/Delete pre-images ONCE, before any lock is taken (no lock across await); then a
  short `room.scene()` read guard wraps the synchronous `permission::filter_command(&stored.command,
  &stored.snapshot, ctx, world_defaults, &current, |id| ecs.actor(id))` call — `stored.snapshot`
  is the REAL commit-time redaction snapshot persisted by `apply_intent` and carried end-to-end
  through `Room.tx`/`RingBuffer`/`resync_range` as part of the `StoredCommand` `RoomEvent::Event`
  wraps, not a mirror of current state. The room's in-memory `SceneEcs` actor table is the
  egress-side owner join, so this never touches the pool (the same short-read-guard discipline
  `clip_move_stream` uses for vision). Because both live delivery and replay redact the SAME
  persisted snapshot, a resync-delivered historical `Update` resolves against the permission set
  in force at that event's actual commit, not today's — live delivery and replay redact against
  the identical persisted snapshot.
  `data::permission::mirror_current_snapshot` still exists for the one caller where mirroring
  current state IS commit-time-correct by construction: `http::routes::write_ops`'s own
  read-back of the write it just applied (`shadowcat-codebase-documents-permissions` covers this
  split in full). See `shadowcat-codebase-documents-permissions` for `filter_command`'s own
  internals and the other two owner-join sources (`list_documents`'s batched prefetch,
  `effective_owner_of` on single-doc routes/search).
- `http::routes` (+ the `http` module root) — HTTP routes (login, assets, embed).
- `auth::session` — `SqlxSqliteStore` (DB-backed sessions), `spawn_session_sweep`
  (also GCs `world_invites` rows via `DELETE FROM world_invites WHERE expires_at <= ?`, bound to
  `now_ms - INVITE_GC_GRACE_MS` (30-day grace, not the raw expiry) — an expired-but-recent invite
  survives a while post-expiry for audit/support lookup before GC actually removes it; same timer
  as session sweep, no dedicated invite timer),
  `SessionUser`/`AuthUser`/`AdminUser`; `auth::password`, `auth::role`.
- `http::throttle` — `AuthThrottle` (`check(key, now_ms, per_min) ->
  bool`, sliding 60s window, `Mutex<HashMap<String, Vec<i64>>>`), shared by the two
  Argon2-verifying endpoints (`/api/login`, `POST /api/invites/accept`). **INVARIANT (no
  enumeration oracle):** identity keys (`login:u:<username>`, `invite:u:<uuid>`) count attempts
  against unknown identities exactly like known ones — the throttle must never distinguish an
  existing identity from a nonexistent one, mirroring the routes' own constant-verify
  anti-enumeration property. Keys are opaque strings the CALLER composes
  (`login:u:<>`/`login:ip:<>`/`invite:u:<>`/`invite:ip:<>`); budgets are per-identity AND per-IP
  (`LOGIN_PER_MIN_PER_IDENTITY=10`/`LOGIN_PER_MIN_PER_IP=30`,
  `INVITE_PER_MIN_PER_ACCOUNT=10`/`INVITE_PER_MIN_PER_IP=30`) so identity-rotating stuffing from
  one address is bounded too. `MAX_TRACKED_KEYS=65_536` caps the map; at capacity, expired keys
  are swept first, and if still full a NEW key FAILS CLOSED (throttled) rather than evicting live
  state. `ClientIp` (axum extractor, `FromRequestParts<AppState>`) is infallible: `Some` under
  real `ConnectInfo`, `None` under the axum-test mock transport (IP throttling degrades to
  identity-only there, never a 500) — `AppState.auth_throttle: Arc<AuthThrottle>`. Behind a
  reverse proxy, the raw TCP peer is the proxy itself; `Config.trusted_proxies` (default empty,
  exact-IP match only, never CIDR) opts a peer into `X-Forwarded-For` resolution via
  `throttle::resolve_client_ip`, which walks the header right-to-left skipping further trusted-hop
  entries and stops at the first non-trusted/unparseable one, falling back to the TCP peer if the
  header is absent or every entry is itself trusted. Default configuration preserves TCP-peer-only
  resolution exactly. All four budgets are config-tunable
  (`Config.login_per_min_per_identity`/`login_per_min_per_ip`/`invite_per_min_per_account`/
  `invite_per_min_per_ip`, `None` → the constants above, env/TOML-layered like every other optional
  `Config` field) — the shell e2e suite relaxes them via `playwright.config.ts`'s `webServer.env`
  so its many same-identity logins across specs can't trip the default budget.
- **Accounts + world seating.** `POST`/`GET /api/users` are admin-only, gated by the **`AdminUser`
  extractor** — the chokepoint for every server-tier gate. **INVARIANT: never build a server-tier
  gate on world role.** `permission_context` maps `ServerRole::Admin → WorldRole::Gm`, so any
  world-role check is satisfied by an ordinary GM; `AdminUser` reads the session's `ServerRole`
  directly and, being an extractor, rejects BEFORE body deserialization. `create_user_unique` is a
  single guarded `NOCASE` INSERT (clean 409, never a 500 or a check-then-act pair), and the ASCII
  username policy is applied at every insertion path including `/api/setup`/`bootstrap_admin`.
- **`auth::invite` + the world-invite repository methods** — a GM mints an invite
  for their own world; the invitee redeems it from their OWN session (`POST /api/invites/accept`
  with the code in the BODY, never the URL — a path-borne credential reaches the tower-http trace
  span, browser history, `Referer`, and proxy logs). Two invariants: **(1) redemption failures are
  UNIFORM** — invalid, expired, revoked and already-consumed are indistinguishable in status, body
  AND verify count (exactly one Argon2 verify per path, using a dummy PHC when no row matches,
  mirroring `anti_enumeration_phc`); a distinguishable path relocates the username oracle rather
  than closing it, and the property is pinned by a `#[cfg(test)]` verify counter, not by timing.
  **(2) Consume is a SINGLE guarded `UPDATE … RETURNING`** with every lifecycle predicate in the
  WHERE, seating sharing its transaction, so concurrent redemption cannot double-seat.
  **Why seating is by invite and not by name:** a seat-by-username route answers 404-vs-204 and so
  leaks username existence to any authenticated account (`create_world` requires only `AuthUser`,
  so anyone can become a GM) — contradicting the constant-time verify `/api/login` already pays to
  hide exactly that. A uniform 204 does NOT close it either, because seating-on-hit stays
  observable via `list_members`. Naming a target is the disclosure; the invite removes the naming.
  NOTE this covers the by-NAME shape only: `add_member` is GM-gated, takes a user ID, and 404s on
  an unknown id — what is inadmissible is naming a user by a guessable identifier, not a
  membership write.
- **Deletion & eviction.** `ServerMsg::Evicted { user: Option<Uuid> }` is the terminal
  out-of-band frame: `None` addresses every connection in a room (world deletion, broadcast on the
  removed room), `Some(id)` addresses one user's connections across ALL rooms
  (`RoomRegistry::evict_user`, account deletion). The egress loop delivers the frame, sends a
  protocol Close, and terminates; targeting keys on the server-resolved `ctx.user_id`, mirroring
  the `MoveStream` per-recipient precedent. `RoomRegistry` carries a deletion tombstone
  (`begin_delete` removes the room + blocks `get_or_create` re-creation until `finish_delete`,
  which must run on success AND failure paths; post-insert, `get_or_create` re-checks the
  tombstone AND re-verifies the world row — a delete can complete entirely inside the hydration
  window, lifting the tombstone before the re-check, so only row absence refuses that ghost). **INVARIANT: eviction is load-bearing, not cosmetic** —
  `permission_context` resolves once per connection, so a revoked membership/account is never
  re-checked on a live socket. **INVARIANT: user deletion revokes sessions INSIDE its delete
  transaction** (`json_extract(data, '$.data.user.id')` on `tower_sessions` — no user_id column):
  `AuthUser` trusts the session record without re-reading `users`, so a surviving row would keep a
  deleted account fully authenticated until cookie expiry. Client side: `WsClient` treats
  `evicted` as terminal (`stop()` — no reconnect) and surfaces `onEvicted`, which the shell routes
  to `leaveWorld()`.
- `WsClient` — client WS connection + resync. **Welcome watchdog +
  connection-generation guard, against a silent hang at startup:** `open()` arms a `welcomeTimeoutMs`
  watchdog (default 10s, `opts.welcomeTimeoutMs`) once `opts.connect` resolves; an open-but-
  unwelcomed transport is closed into the normal `scheduleReconnect` path instead of hanging on
  "Connecting…" forever (the browser's socket `open` fires at HTTP 101, BEFORE the server's
  Welcome preamble — see `handle_socket`'s per-connect DB round trips + blocking
  `scan_installed_modules` scan). Every `open()` attempt is tagged with a monotonically
  increasing `connGeneration`; `handleFrame` ignores a `"welcome"` OR `"resync_end"` frame whose
  generation doesn't match the CURRENT connection before acting (clearing the watchdog, setting
  `serverOffsetMs`, emitting `onWelcome`; resp. advancing `nextExpected` + emitting
  `onResyncComplete`) — without the check, a frame already queued as a message task when the
  watchdog fired still arrives after reconnect and acts on (or disarms) the successor
  connection's state. **`armWelcomeWatchdog` itself also guards against
  out-of-order delivery**: a `welcomedGeneration` field (set inside the `"welcome"` case, after the
  generation check) makes arming a no-op when the CURRENT generation is already welcomed — covers a
  `Connect` implementation that delivers Welcome via a microtask BEFORE its own promise resolves
  (the continuation that calls `armWelcomeWatchdog` runs strictly after), which would otherwise arm
  a watchdog nothing will ever disarm. **`reconnectAttempt` resets on WELCOME, not on socket
  `open`** — the reset lives in the `"welcome"` case (after the generation guard), not in
  `open()`: a server that accepts the socket but never sends Welcome must keep backing off
  (`scheduleReconnect`'s exponential-with-full-jitter delay) on every watchdog-close/reconnect
  cycle instead of retrying at the base delay forever, which would amplify load against exactly the
  degraded server the watchdog exists to escape.
- `webSocketConnect(url, connectTimeoutMs = 10_000)`: bounds
  the handshake so an accepted-but-never-upgraded socket settles (rejects + closes) instead of
  leaving `WsClient`'s `scheduleReconnect` path unreachable behind an unsettled connect promise. A single
  shared `webSocketConnect.settled` flag (distinct from `opened`) guards ALL THREE settling paths (timeout, error,
  open) — a `webSocketConnect.connectTimeoutMs` expiry and an already-queued `open` event landing in the same tick
  cannot let `opened` flip true AFTER the promise already rejected, which would otherwise let a
  later `close` event ALSO reach `handlers.onClose` (double-scheduling a reconnect on top of the
  promise-rejection path, and the orphan transport's own close nulling `WsClient.transport` out
  from under the live one). The `open` listener discards the socket (`ws.close()`, no resolve) when
  `webSocketConnect.settled` is already true instead of completing the handshake.
- `DocumentStore implements ReadableDocuments` (authoritative,
  rollback base).
- `OptimisticClient implements ReadableDocuments` (the
  optimistic view the UI/canvas render).

## Hard invariants

- **Ordered, recoverable realtime**: every broadcast carries a per-world
  monotonic seq from an atomic counter; clients gap-detect and resync from the `RingBuffer` or a
  full snapshot.
- **Optimistic with rollback**: `OptimisticClient` applies locally tagged with
  an intent id; the server confirmation reconciles; divergence rolls back to `DocumentStore`.
  `appliedSeq` is identical across the two so the derived watermark holds
  [[render-from-optimistic-view]].
- **`OptimisticClient.applyCommand`'s self-authored confirm is a blind FIFO removal of the
  oldest entry in `OptimisticClient.pending` — it does NOT match the incoming command against the
  intent it actually confirms.** This is intentional (`ws::room::Room::publish`'s own doc: "the
  broadcast `Event` carries `intent_id: None`; an originator confirms its own write by receiving
  this echo"), and it is SOUND only because `Room::publish` serializes every submitted intent one
  at a time under `publish_guard` — each intent's `Reject` (sent via this connection's own
  `egress_loop::erx`) or successful commit (broadcast on `Room.tx`) is fully resolved before the
  NEXT intent's `publish()` call even starts, so responses arrive in the SAME order the intents
  were submitted. **`egress_loop`'s `tokio::select!` is now `biased;` with `egress_loop::erx`'s
  receive arm listed first, for exactly this reason** — an unbiased `select!` gives NO ordering
  guarantee between two independently-scheduled channels (`egress_loop::erx`, this connection's
  direct replies, vs `egress_loop::rx`, the room broadcast), so it could deliver a LATER intent's
  broadcast confirmation before an EARLIER intent's `Reject`, even though the server processed
  them strictly in order. **A single such inversion — or any self-authored intent that receives
  NEITHER a matching `Event` NOR a `Reject` at all — permanently misaligns every later
  self-authored confirm for the rest of the connection's lifetime**: the removal always finds
  something to take, so it silently confirms whatever pending entry happens to be oldest,
  cascading a one-slot-per-slot drift with no error, no resync, and no visible symptom until a
  stale prediction (e.g. an old position) outlives the confirmed value that should have
  superseded it. `OptimisticClient.reject` removes by `intentId` (not position) and is safe on its
  own, but cannot repair an ALREADY-misaligned queue: a failed lookup there is documented as "a
  correlation/reconnect mismatch... nothing to roll back" — this is also the shape a lost/ignored
  response takes. Any future confirm-matching change to `OptimisticClient` must preserve this
  ordering invariant, not merely the removal mechanism.
- **Socket-buffer backpressure is non-portable** — `SO_SNDBUF`/`SO_RCVBUF` are advisory; test the
  generic egress sink with a credit-gated `Sink`, not real-socket TCP backpressure
  [[socket-buffer-backpressure-nonportable]].
- **Debounce on the leading edge, arm only when idle** (or cap max staleness) — re-arming on every
  event starves under load [[debounce-leading-edge-not-trailing-rearm]].
- **Check-then-act across two pool queries needs one transaction** [[two-query-guard-needs-tx]].
- **`Room.tx`/`RingBuffer` carry `RoomEvent`, never `Arc<ServerMsg>` directly, for the `Event`
  case.** `Room.tx: broadcast::Sender<RoomEvent>` and `RingBuffer.events: VecDeque<RoomEvent>` —
  the internal broadcast/ring element is `RoomEvent { Event(Arc<StoredCommand>), Other(Arc<
  ServerMsg>) }` (`ws::room`), not the client-facing wire type. The client-facing
  `ServerMsg::Event` shape is reconstructed only at `send_filtered_event`, the single
  serialization point — every other consumer of a broadcast/ring entry sees the unredacted
  `StoredCommand` (command plus its commit-time snapshot), never a pre-redacted wire frame.

## Gotchas

- **A malformed field anywhere in a client-authored `Intent` frame produces a generic,
  UNCORRELATED `ServerMsg::Error` (`WsErrorCode::BadMessage`), never a `Reject` — and the client
  silently discards it (`case "error": break;`).** `Reject` requires the frame to parse into
  `ClientMsg` first (it carries the server-VALIDATED `intent_id`); a JSON/type-level failure —
  e.g. a `Document.id: Uuid` field that isn't a valid UUID string — fails at
  `serde_json::from_str::<ClientMsg>` before `intent_id` is ever extracted, so `handle_socket`'s
  `Err(_)` arm (malformed-frame branch) has no `intent_id` to attach and sends the generic
  `Error` instead. The optimistic prediction that intent pushed via `applyIntent` is now
  UNRECOVERABLE: no `Event` will ever confirm it (the write never reached `apply_intent`), and no
  `Reject` will ever roll it back — see the FIFO-misalignment invariant above for the cascading
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
  [[m6c-2-live-search]].
- **One-shot correlated request pairs** (`Search`→`SearchResult`/`SearchError`;
  `Pathfind`→`PathResult`/`PathError`) route replies to the requesting connection only (never
  broadcast); correlated by `request_id` via the `pending` map in `WsClient`. See
  `WsClient` and `ws::protocol`. **Chat ops
  (`SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll`) also carry `request_id` but are
  ASYMMETRIC**: only
  a REJECTION replies (`ServerMsg::ChatError`, sender-only), while success is confirmed by the
  broadcast `Event` echo. They use a separate `chatPending` map whose timer resolves
  (success-assumed) rather than rejects on timeout — see `shadowcat-codebase-chat`.
- **`ScenePing` is gated by `scene_ping_permitted`, not by scene
  selection.** Unlike `MoveRequest`/`handle_pathfind` (which SELECT server state and so must
  derive-from-token, per the never-fork table in `shadowcat-codebase-core`), `ScenePing` relays
  only the client-supplied `scene`/`x`/`y` to the room via `broadcast_aux` — there is no server
  state to substitute against.
  The guard instead answers "may this sender ping into this scene at all": the doc must exist, be
  `doc_type == "scene"`, resolve to THIS room's `world_id` via `world_of`
  (`shadowcat-codebase-documents-permissions`), and grant the sender `cap::READ`. Deliberately
  ADMITS a token-less spectator (weaker than `handle_pathfind`'s controls-a-token gate) since a
  READ-only viewer legitimately pings a scene they're watching. Denial is a SILENT drop at the
  call site — no error frame, no behavior split — because any distinguishable response would leak
  scene existence to a non-reader. Rate-limited independently (30/min/user via `ping_rate`,
  checked BEFORE the authz lookup so an over-budget sender never pays a doc read).
- **MoveRequest → MoveStream (broadcast):** `MoveStream` is an **aux broadcast frame** — sent
  via `Room::broadcast_aux` like `ScenePing`, carrying NO seq number (it is cosmetic playback data,
  not an authoritative document event; it never touches the `RingBuffer`/gap-resync path).
  `MoveRequest` is still a one-shot correlated pair for the mover's promise (resolves on the
  matching `move_stream` frame via `pending` map), but `MoveStream` is broadcast to ALL scene
  viewers, not just the mover — the **per-recipient egress transform** (mover full incl.
  `moverVision`; observer clipped to their own visible samples with `moverVision: null`; suppressed
  entirely — zero frames — when the recipient's vision admits none of the move) is where the
  leak-free secrecy boundary lives (`egress_loop`'s dedicated `MoveStream` branch, detailed in
  `shadowcat-codebase-scene-rendering`). `MoveError` remains mover-only, always generic (no path
  geometry / vision state disclosed — no-geometry-leak invariant).
  `handle_move_request` dispatches `Room::execute_move`, then broadcasts `MoveStream` to the scene.
  Client animation is driven by `TokenAnimator.animateSamples` (time-tagged playback, catch-up on
  late arrival, gap/occlusion detection: gap threshold = `minConsecutiveDelta × 1.5` where
  `minConsecutiveDelta` is the minimum positive inter-sample interval across all consecutive pairs;
  Infinity for < 3 samples — no interior gap detectable). `animateSamples` cancels any competing
  ease-to-stop `anim` entry (handles Event-before-MoveStream ordering); `setTarget` is a no-op
  while `samplesAnim` is live (handles MoveStream-before-Event ordering). Wired end-to-end:
  `WsClient.onMoveStream` → `worldSession` → `SceneInteractionBridge.animateSamples` →
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

## Pointers

- **Generated API** — `/api/rust/shadowcat/ws/`, `/api/rust/shadowcat/http/`,
  `/api/rust/shadowcat/auth/` (rustdoc, private items included),
  `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the client `store` module). Produce with
  `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 (invariants 1-4) + §3 (tokio/axum/sqlx/argon2).
- Relationships:
  `graphify query "websocket room broadcast egress optimistic rollback store session auth"`.
- History: [[m6a-client-core]], [[m6c-1-search]], [[m6c-2-live-search]].
