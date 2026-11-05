# Realtime & Sync: key files and seams

Part of the shadowcat-codebase-realtime-sync skill; read it when working in ws, http, auth or the client store and you need the file-by-file map, room/move/rate-limiter/session details.

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
  - `Room::execute_move(repo, ctx, req: MoveRequestInputs)` — server-authoritative token move.
    `MoveRequestInputs` groups `scene_id`/`token`/`path`/`ts`/`request_id` (avoiding a
    >7-argument signature). **`scene_id` IS NOT TRUSTED and selects nothing.** The gate's scene is
    DERIVED from the token via `SceneEcs::token_move(token, &[])`, and every gate input keys on
    that; the request's `scene_id` is only checked for agreement and refused on mismatch (redundant
    defense-in-depth). Taking it as input is a total bypass of the wall + visibility gate with
    authorization fully intact, so any NEW move-like or routing frame added here must derive the
    same way. A frame naming no token (`Pathfind`) must instead prove presence. Full invariant +
    the failure it prevents: `shadowcat-codebase-scene-rendering`, the derive-from-token INVARIANT.
    Acquires `publish_guard` at the TOP and HOLDS it across the entire validate→commit critical
    section (mirrors `publish` atomicity). Scene read locks are scoped and dropped before the
    `get_explored().await` (no lock across await); `publish_guard` (tokio `Mutex`) is intentionally
    held across awaits. Calls `move_exec::execute_move` (pure, lock-free), then `commit_ops_locked`
    (single acquisition, no re-entry). Atomic single position write (`/engine/x` + `/engine/y`
    OCC pre-image ops). Returns `MoveExecution { frame, .. }` — production code reads only `frame`
    (the full unclipped `Arc<ServerMsg::MoveStream>`, already registered in `moving`); the other
    fields (`scene`, `stop`, `duration_ms`) restate a subset of `frame`'s content and are compiled
    only for test builds — `mover_vision` (and its carried-light twin `mover_light`) is NOT one of
    them: it lives solely on
    `frame`'s `ServerMsg::MoveStream` variant, and a test reads it by pattern-matching `frame`
    rather than through a dedicated `MoveExecution` field. `MoveStream.scene` — the field `frame` wraps — is the
    DERIVED scene the per-recipient egress clip and the client's viewed-scene filter key on,
    never a client-supplied value.
  - `moving: Mutex<HashMap<Uuid, ActiveStream>>` — per-token in-flight registry doubling as the
    moving lock: token → `ActiveStream { mover, scene, end_ms, frame }` (`frame` is the full
    unclipped `Arc<ServerMsg::MoveStream>`, not merely an epoch-ms value). Lazy expiry (no timer);
    absent or expired (`now >= end_ms`) entry allows the move. Updated by a direct `moving.insert`
    inside `execute_move`, still under `publish_guard`, after each successful commit; the caller
    (`handle_move_request`) separately broadcasts `exec.frame` to the room via
    `Room::broadcast_aux_shared` — the registry write and the broadcast are two distinct actions on
    the same frame, not one call. In-memory only — cleared on server restart (move state is
    derived, not durable). Also backs `Room::scene_streams(scene, now)` /
    `Room::concurrent_streams(scene, exclude_mover, now)`, which read `ActiveStream.frame` as the
    in-flight movers' position + carried-light TIMELINES so the egress clip (`ws::move_clip`) can
    clip a concurrent move against the recipient's own in-flight sightline and the torches in
    flight, not just their committed sight — see `shadowcat-codebase-scene-rendering`'s
    streamed-vision bullet for the full clip + re-emit mechanism.
  - `Room::establish_resync_floor(user_id)` / `Room::resync_floor(user_id)` — the per-user resync
    floor: `session_floors: Mutex<HashMap<Uuid, i64>>`, same in-memory/room-lifetime pattern as
    `moving`. `establish_resync_floor` is called from `ws::conn`'s `ClientMsg::Hello { last_seq:
    None }` arm (the field is no longer vestigial — see the Gotchas entry in references/gotchas.md). `resync_floor`
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
- `ws` (the module root) — `WsState`, and the flood budget its message rate limiter spends.
  `WsState::message_rate` is ONE `Arc<PingRateLimiter>` cloned into every handler (never a
  per-handler copy), so all its callers share a single per-user trailing-60s hit list; the budget
  they spend against it is `MESSAGE_RATE_PER_MIN`, declared exactly ONCE beside that limiter.
  **INVARIANT: one limiter, one constant.** Its callers are the chat handlers (`SendMessage`/
  `EditMessage`/`DeleteMessage`/`RecalcRoll`) and `combat::handle_combat_intent`; a second constant
  naming the same budget would be a forked decision landing on a security control — raising one
  copy silently changes the other's effective behaviour against the very same counter, with
  nothing failing to report it. `WsState::ping_rate` is a genuinely SEPARATE limiter instance with
  its own per-user hit list, spent by `ScenePing` alone against a budget written inline at that one
  call site — it is not a second name for `MESSAGE_RATE_PER_MIN` and the two never interact.
  `WsState::emote_rate` is a further instance, again with its own per-user hit list — a bucket
  separate from `ping_rate` deliberately, so emote spam cannot starve pings nor vice versa —
  spent by `ClientMsg::Emote` alone against its own inline 30/min/user budget.
  `WsState::vfx_rate` is a further instance, again with its own per-user hit list — charged by
  BOTH VFX entry paths (the raw `ClientMsg::PlayVfx` arm and the `/fx` chat command, via
  `MessageRequestCtx::vfx_rate`) at the same inline 30/min/user budget, so neither front door
  bypasses the other. `WsState::ruler_rate` is a further instance (`WsState` holds six `PingRateLimiter` instances:
  `message_rate`, `ping_rate`, `emote_rate`, `audio_rate`, `vfx_rate`, `ruler_rate`; the separate
  `preview_rate`, a `chat::PreviewRateLimiter`, is the per-user outbound link-preview fetch budget) — its own per-user hit list, spent
  by `ClientMsg::RulerUpdate` alone against the NAMED constant `ws::ruler::RULER_RATE_PER_MIN`
  (720/min/user, twelve frames a second: above the ten a second one honest connection can send),
  so a live ruler drag cannot starve the other relays and vice versa. The budget is per USER, so
  one user measuring on several connections shares it.
  - **Graceful-shutdown drain.** `WsState.shutdown_tx`/`WsState.shutdown` is a
    `tokio::sync::watch` pair the state itself owns and keeps alive (the sender never drops, so the
    channel never closes on its own — a closed `watch` would make every connection's shutdown-select
    arm resolve immediately, closing every socket as though a real shutdown had been requested);
    `WsState::trigger_shutdown` is the ONLY place that sends. `WsState.live_connections`
    (`Arc<AtomicUsize>`) + `WsState.drain_notify` (`Arc<tokio::sync::Notify>`) back `ConnectionGuard`,
    an RAII handle `WsState::connection_guard` returns. It is acquired synchronously inside
    `ws_handler`, BEFORE `.on_upgrade(...)` is called; the upgrade closure takes ownership of it
    and hands it to `ws::conn::handle_socket` as a parameter (`_connection_guard: ConnectionGuard`) that
    it holds for its whole task lifetime — `handle_socket` never acquires a second one. Acquiring
    inside `.on_upgrade(...)`'s own callback instead would leave a window where `WsState::
    live_connection_count` could read zero (and `wait_for_drain` return) before axum's internally
    spawned task — which starts running strictly AFTER the 101 response is written — has run its
    first line. Its drop decrements the count and, on reaching zero, wakes every `wait_for_drain`
    waiter. This exists because axum's WebSocket-upgrade callback spawns as a task DETACHED from
    the hyper connection future that produced the 101 handshake, so `conn_serve::serve_router`'s
    connection drain resolves once the connections end and does NOT itself wait for an HTTP/1.1
    WebSocket session's task to exit (an HTTP/2 session is a stream, so `serve_router` first runs
    `WsState::trigger_shutdown` as its `serve_router::on_drain` hook; see [[shadowcat-codebase-tls]]). `WsState::
    wait_for_drain(timeout)` is the race-free wait (constructs the notify future BEFORE
    re-checking the count, the standard lost-wakeup-avoidance pattern) that `http::serve_with`
    ([[shadowcat-codebase-server-ops]]) calls after `conn_serve::serve_router` returns, bounded by
    `http::session_wait`. `egress_loop` clones `WsState.shutdown` into its own
    `EgressConnState.shutdown` and selects on `shutdown.changed()` as the FIRST arm of its biased
    select (see the FIFO-ordering invariant in SKILL.md for why it sits ahead of `egress_loop::erx` too)
    — on a real shutdown or a dropped sender it sends a Close frame and exits the loop, which is
    what lets its `ConnectionGuard` drop and the count reach zero.
  - **Heartbeat.** `egress_loop` owns a `tokio::time::interval(PING_INTERVAL)` (30s, a
    delayed-not-bursty missed-tick policy, first tick consumed up front so a fresh connection
    isn't pinged the instant it opens) that on each fire checks `EgressConnState.last_activity`
    against `PING_TIMEOUT` (90s = 3x `PING_INTERVAL`, giving a client that misses one heartbeat a
    full second interval to answer before being dropped) — past the timeout it sends a Close frame
    and exits the loop; otherwise it sends `ServerMsg::Ping`. `last_activity`
    (`Arc<std::sync::Mutex<std::time::Instant>>` — a MONOTONIC clock, shared between
    `handle_socket`'s ingress task and `egress_loop`, so an NTP correction or a manual wall-clock
    change can neither fabricate nor erase silence) is stamped by `handle_socket` on EVERY inbound
    frame it receives, not only a recognized `ClientMsg::Pong` reply — a client quiet on the
    heartbeat but actively sending other traffic (intents, search, etc.) is just as alive as one
    that dutifully answers pings. The ping-timer arm sits SECOND in `egress_loop`'s biased
    `select!`, immediately after `shutdown.changed()` and ahead of `egress_loop::erx`/
    `egress_loop::rx`/the search-reeval timer — listed after those always-ready room/egress arms, a
    continuously-broadcasting room would starve it indefinitely, the same starvation the shutdown
    arm's own first-place position guards against.
  - **`WS_MAX_MESSAGE_BYTES`** (`ws::conn`, set on both the max-message-size and max-frame-size
    limits `ws_handler` configures on the WebSocket upgrade) is derived from `MAX_INTENT_DOCS` (16)
    documents each at
    `3 * MAX_DOCUMENT_BLOCK_BYTES` (`MAX_DOCUMENT_BLOCK_BYTES = data::validation::MAX_SYSTEM_BYTES`,
    the per-block `system`/`engine`/`base` cap), plus 64 KiB of JSON structural headroom — never a
    bare magic number, and well below `Config::default`'s `upload_max_bytes` (a WS frame is never
    the transport for a large asset). `MAX_INTENT_DOCS` is enforced as a real structural chokepoint,
    not just implied by the byte cap's sizing: `handle_socket`'s `ClientMsg::Intent` arm rejects
    (`ServerMsg::Reject { reason: RejectReason::Invalid, .. }`, before any op reaches
    `apply_intent`) an intent whose `ops.len()` exceeds it — a frame under the byte cap could
    otherwise still carry an unbounded op count of tiny documents; both caps bound the same
    quantity from opposite ends.
  buys more plays than the other and a VFX spam burst cannot starve ping, emote, or message
  relays.
- `ws::protocol` — client/server message frames; `ServerMsg`, `event_seq()`.
  `ClientMsg::PlayVfx`/`ServerMsg::Vfx` is the ping-shaped aux pair for VFX one-shots:
  `ws::conn`'s arm checks `vfx_rate` first, then `ws::vfx::validate_bounds` (no I/O), then
  `ws::vfx::vfx_permitted` (spectator refused outright; scene must exist, be this world's,
  grant the sender `cap::READ`) and `broadcast_aux`s the frame with a fresh per-broadcast
  `id` (the render layer's `oneshot:<id>` node key). Denial is a SILENT drop, exactly like
  `ScenePing` — see `shadowcat-codebase-vfx` for the full subsystem and the `/fx` chat
  command, which shares `ws::vfx`'s validation/authz verbatim.
- `ws::conn` — per-connection loop + egress; `ws::time` — server time source +
  client offset calibration (exists before its consumer).
  `send_room_event` (takes `room: &Room` alongside `repo`/`ctx`) is the single dispatch point
  every broadcast frame reaches — live delivery (`egress_loop`'s seq-carrying arm) and `replay()`
  (`Room::resync_range`-driven, serving `Egress::Resync` and the lag-driven auto-resync branch)
  both route every `ws::room::RoomEvent` through it. A `RoomEvent::Event(Arc<StoredCommand>)` goes
  to `send_filtered_event`; every other `RoomEvent::Other(Arc<ServerMsg>)` (including `MoveStream`,
  clipped separately by `clip_move_stream`; see the invariant in the MoveRequest → MoveStream entry of references/gotchas.md) passes through unredacted via
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
- `auth::session` — `SqlxSqliteStore` (DB-backed sessions), `spawn_housekeeping_sweep`
  (also GCs `world_invites` rows via `DELETE FROM world_invites WHERE expires_at <= ?`, bound to
  `now_ms - INVITE_GC_GRACE_MS` (30-day grace, not the raw expiry) — an expired-but-recent invite
  survives a while post-expiry for audit/support lookup before GC actually removes it; same timer
  as the session and link-preview cache sweeps, no dedicated invite timer),
  `SessionUser`/`AuthUser`/`AdminUser`; `auth::password`, `auth::role`. `SchemeSessionLayer` and
  the cookie names (`SESSION_COOKIE_PLAIN`, `SESSION_COOKIE_TLS`) are in `shadowcat-codebase-tls`,
  as are `WsState::bounded_sink` / `BoundedSink` (the session sink) and the `Config::egress_window`
  bound.
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
- **`ServerMsg::Welcome.role_capabilities: RoleCapabilities`** — the connecting user's own
  world-level capabilities, computed by `ws::conn` beside its own actor-grants projection via
  `data::permission::project_role_caps_for(&world_defaults.role_caps, ctx.world_role)` and sent on
  every Welcome (fresh connect AND reconnect — this subsystem's own frame, not a one-shot). Full
  projection semantics (isolation from other roles) live in
  `shadowcat-codebase-documents-permissions`; the client's advisory `canCreate` mirror lives in
  `shadowcat-codebase-client-shell`. This subsystem's own concern is only that the field rides the
  existing Welcome frame — no new frame, no new connection-generation/watchdog interaction beyond
  what every other Welcome field already gets.
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

