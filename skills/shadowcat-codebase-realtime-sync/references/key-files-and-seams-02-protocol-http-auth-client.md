Part of the shadowcat-codebase-realtime-sync skill; read it when editing ws::protocol, ws::conn, http routes, auth sessions, throttling, accounts, invites, eviction, WsClient or the client stores. Part 02 of 02 of "Realtime & Sync: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-room-and-rate-limiter.md.

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
  clipped separately by `clip_move_stream`; see the invariant in the MoveRequest → MoveStream entry of references/gotchas-02-scene-relays-and-move-streams.md) passes through unredacted via
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

