Part of the shadowcat-codebase-realtime-sync skill; read it when editing ws::room, move execution, the rate limiter or the ws module root. Part 01 of 03 of "Realtime & Sync: key files and seams"; the index is key-files-and-seams.md.

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
    None }` arm (the field is load-bearing — see the Gotchas entry in references/gotchas-01-egress-resync-correlated-requests.md). `resync_floor`
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
