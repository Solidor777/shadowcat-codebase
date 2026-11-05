---
name: shadowcat-codebase-realtime-sync
description: "Use when touching Shadowcat realtime: WebSocket transport, per-world rooms, broadcast/egress, sequence numbers + resync, the client document store and optimistic/rollback, sessions/auth, user accounts (admin-created) and world invite/accept seating, live search, the scene-addressed out-of-band relays (ping/emote/vfx/shared ruler) and their shared `ws::scene_broadcast_permitted` admission, the typed correlated-request rejections, or the `randomUuid` id source. Covers src/server/src/{ws,http,auth} + src/client/core store. Invoke shadowcat-codebase-core first."
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

The per-file map of ws, http, auth and the client store: Room and move execution, rate limiters, shutdown drain, protocol, connection loop, sessions, throttling, accounts and invites, eviction, WsClient and the stores. Read references/key-files-and-seams.md before editing any of those files or when you need to know which seam owns a behavior.

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
  were submitted. **`egress_loop`'s `tokio::select!` is `biased;` with `egress_loop::erx`'s
  receive arm listed ahead of the room-broadcast arm, for exactly this reason** — an unbiased
  `select!` gives NO ordering guarantee between two independently-scheduled channels
  (`egress_loop::erx`, this connection's direct replies, vs `egress_loop::rx`, the room broadcast),
  so it could deliver a LATER intent's broadcast confirmation before an EARLIER intent's `Reject`,
  even though the server processed them strictly in order. **The graceful-shutdown arm
  (`egress_loop`'s `shutdown.changed()` arm) is listed FIRST of all, ahead of even `egress_loop::
  erx`** — a sustained broadcast/intent stream keeps both `egress_loop::erx` and `egress_loop::rx`
  ready on nearly every poll, and an ordering after them would let that traffic defer this
  connection's close indefinitely once shutdown has been requested; putting it first does not
  disturb the erx-before-rx ordering guarantee above, since shutdown firing means the loop exits
  before either of those arms would matter again. **A
  single such inversion — or any self-authored intent that receives
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

Per-feature traps: egress test harnesses, malformed Intent frames, Hello and snapshot, live search, correlated-request rejections, client id source, audio frames, the ping/ruler/emote/scrolling-text relays, MoveRequest and MoveStream, and the Egress::Frame payload. Read references/gotchas.md before changing egress, resync, relays, move streams or client ids. One rule from that file holds on every change: **permissions filter every broadcast per recipient** — hidden fields are stripped before transmission, never sent-then-hidden.

## Reference files

| File | Holds | Read it when |
|---|---|---|
| references/key-files-and-seams.md | The "Key files & seams" section: file-by-file map of ws, http, auth and the client store | Editing or locating code in those areas |
| references/gotchas.md | The "Gotchas" section: egress, resync, correlated requests, relays, audio, move streams, docs ratchet | Changing any of those behaviors, or debugging them |

## Pointers

- **Generated API** — `/api/rust/shadowcat/ws/`, `/api/rust/shadowcat/http/`,
  `/api/rust/shadowcat/auth/` (rustdoc, private items included),
  `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the client `store` module). Produce with
  `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 (invariants 1-4) + §3 (tokio/axum/sqlx/argon2).
- Relationships:
  `graphify query "websocket room broadcast egress optimistic rollback store session auth"`.
- History: [[m6a-client-core]], [[m6c-1-search]], [[m6c-2-live-search]].
