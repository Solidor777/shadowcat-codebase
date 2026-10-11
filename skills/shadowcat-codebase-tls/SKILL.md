---
name: shadowcat-codebase-tls
description: "Use when touching Shadowcat's connection lifecycle from accept to drain: built-in HTTPS (`tls::TlsRuntime` degradation ladder, `tls::resolver` SNI/ALPN selection, `tls::selfsigned`, `tls::pem`, `tls::keyfile`), the sniffing accept path (`tls::listener::SniffListener`, `http::conn_serve::set_accepted_nodelay`), the serve loop that replaces `axum::serve` (`http::conn_serve::serve_router`, `ConnSource`/`ServeIo`, `ConnLimits`, `DrainReport`, `ServeOutcome`), the admission/live caps and descriptor budget (`http::peer_slots`, `fd_budget`), the per-request scheme decider (`http::scheme`), the three egress no-progress units and their wire-fed stream table (`StreamExec`, `Sampler`, `FrameParser`, `StreamTable`, `LeasedBody`, `TunnelProbe`, `ws::tunnel_gate::TunnelGate`), the patched `vendor/h2` and its `lint:vendor` gate, or the measurement harness that exercises them (`shadowcat-test-support`'s `throughput`/`egress`/`observed`/`h2c` modules, the `egress_measure` binary, `h2_send_buf_gate`). Covers src/server/src/{tls,fd_budget.rs,http/{conn_serve*,peer_slots*,scheme*},ws/tunnel_gate.rs}, vendor/h2, scripts/check-vendor.mjs. Invoke shadowcat-codebase-core first."
---

# Shadowcat — TLS, the serve loop, and the egress bounds

Orientation for everything between a SYN and a closed connection. `shadowcat-codebase-realtime-sync`
owns what runs on a connection once a request is routed (WebSocket rooms, egress frames);
`shadowcat-codebase-server-ops` owns `main`/`Config`. This skill owns the layer under both.

## Purpose

One port serves plain HTTP and TLS: `tls::listener::SniffListener` reads the first byte of each
connection (`0x16` is a TLS ClientHello) and either hands the plain socket on or runs the TLS
handshake. `http::conn_serve::serve_router` then owns the accept-to-drain loop itself instead of
calling `axum::serve`, because hyper's HTTP/1 header-read timeout and HTTP/2 keep-alive pings are
inert without a timer and `axum::serve` installs none. Every connection is built with a
hyper-util timer and the bounds in `ConnLimits`; a response that makes no progress for
`ConnLimits::egress_window` is cut by exactly one of three units. `http::serve` and
`http::serve_with` wrap `serve_router` for `AppState` and are what `main` calls.

## Key files & seams

- `tls::TlsRuntime` — `start`/`start_with` is the degradation ladder (operator PEM, then persisted
  self-signed, then in-memory self-signed, then TLS off); `disabled()` is the TLS-off runtime.
  `tls::resolver::Snapshot::select` is the ONE selection call: the certificate a connection gets,
  its `ConnMeta::cert` and the HSTS decision all derive from it. `CertResolver::update` is the
  hot-swap seam an ACME task would use; `TlsSource::Acme` is status vocabulary only. Rationale:
  `docs/design/built-in-https.md` §2 (invariants) and §8 (listener).
- `tls::ring_provider` / `install_default_provider` — the one place the crypto provider is named
  (ring). Never rely on rustls feature auto-selection.
- `tls::listener::SniffListener` — implements `ConnSource`. Its acceptor task admits through
  `PeerSlots` (the pre-hand-off cap), calls `set_accepted_nodelay`, then `negotiate`s under one
  `Limits::deadline` that covers sniffing AND the whole handshake. `ConnStream` is the IO enum
  (`Plain` | `Tls`); its `ServeIo::is_h2` is true only when ALPN negotiated `h2`.
  `tls::listener::TcpAccept` is the raw-accept seam tests substitute.
- `http::conn_serve::ConnSource` / `ServeIo` — the source/IO traits `serve_router` is generic over.
  `impl ConnSource for TcpListener` is the bare-listener source `http::serve` accepts in doc
  examples and tests. `accept_error_pause` is the one accept-error policy.
- `http::conn_serve::set_accepted_nodelay` — decides what the server configures on an accepted TCP
  socket (the TCP no-delay option), called by `impl ConnSource for TcpListener` and by `SniffListener`'s
  acceptor task. The test-support sources that model the listener (`ObservedSource`, `H2cSource`)
  call it when their `nodelay` flag is on. `bare_server` in the throughput harness sets the option
  directly on purpose: it is the bare-hyper control, not production code. The obligation is stated
  in `ConnSource::accept`'s contract: a source that hands out a plain TCP socket configures it
  through this function.
- `http::conn_serve::serve_router` + `ConnLimits` / `ServeOutcome` / `ServeEnd` / `DrainReport` /
  `StallCuts` — the loop, its bounds and its closing report. `ConnLimits::for_config` is the
  derivation `http::serve` uses (it sets `egress_window` from `Config::egress_window`). Drain
  order: `serve_router::on_drain` hook runs once, then graceful shutdown to every connection, then at
  `ConnLimits::drain_timeout` the kill (`kill` module: connection IO is failed with an error, not
  aborted), then `drive` drops a connection that has not ended `KILL_GRACE` later, then
  `ABORT_WAIT` after the IO failed any task still running is aborted. `DrainReport::killed`,
  `dropped` and `aborted` count each step; a nonzero `dropped` or `aborted` is a defect.
- `http::peer_slots::PeerSlots` / `peer_key` — both the pre-hand-off cap (`tls::listener::Limits`)
  and the live cap (`ConnLimits::max_live`, `max_live_per_peer`) are `PeerSlots`. `peer_key` keys an
  IPv4 address as itself and an IPv6 address by its /64 prefix.
- `fd_budget::raise_and_fit` — raises the soft descriptor limit, then fits BOTH caps to the
  budget the limit leaves (`descriptors_needed`, `descriptors_reserved`, which subtracts
  `HANDOFF_QUEUE_CAP` and `STREAMED_FILE_PERMITS`). `main` and the `test_server` binary call it.
- `http::scheme::classify` — the ONE request-scheme decider; `request_scheme` and `hsts_max_age`
  both read it. `into_service` is the `ConnectInfo<ConnMeta>` adapter for transports still served
  by `axum::serve` (the real-socket test harnesses and the audio monitor).
- The egress units (all under `http::conn_serve`, driven from `drive`'s sampler tick):
  - connection unit — `WriteCounter` sits in the connection IO and feeds `Egress`; `Sampler` cuts a
    connection whose writer stayed parked for the whole window while the socket accepted fewer than
    `ConnLimits::egress_floor` bytes. On HTTP/2 only DATA payload counts.
  - ended-unflushed unit — `StreamTable` (per connection, created from request HEADERS read off the
    wire by `ReadObserver`, removed only on wire evidence the stream ended) tracks a finished
    response's still-queued tail; `Egress::cut_ended_unflushed` cuts the connection when that
    stream's OWN DATA progress is under `min(egress_floor, bytes still queued)` per window.
  - stream unit — `LeasedBody` (wrapped around every response body by `LeaseService`) slices the
    body into at most `EGRESS_CHUNK_BYTES` frames and stamps a `StreamMarker` when it hands one to
    hyper; `LiveState::cut_stalled_streams` fires the marker's `StreamCut` when the chunk has waited
    `egress_window` for credit. `StreamExec` is the executor hyper's HTTP/2 server spawns every
    stream through: it races the stream future against its cut, and dropping the future makes h2
    send a CANCEL reset for that stream alone.
- `FrameParser` — one type, two instances per HTTP/2 connection (write side counts DATA payload and
  reports which frames ended which streams; read side reports request HEADERS and RST_STREAM). It
  collects a 9-byte header across partial writes and skips payload by arithmetic.
- `TunnelProbe` / `ws::tunnel_gate::TunnelGate` — a WebSocket inside an HTTP/2 stream has no
  response body to watch and hyper's tunnel task ignores h2's send buffer, so the session's own
  sends never go pending. `LeaseService` puts a `TunnelProbe` in every HTTP/2 request's
  extensions; `TunnelGate` makes the session's sink pending while it is more than
  `H2_SEND_BUF_BYTES` ahead of the DATA the writer put on the wire for its stream, which starts the
  per-send stall bound of `ws::bounded_sink::BoundedSink`. The gate sits INSIDE the bound
  (`BoundedSink<TunnelGate<_>>`), never outside.
- `vendor/h2` — the vendored `h2` 0.4.19 carries four changes, recorded in its patch prose and
  committed diff and pinned by the `lint:vendor` gate: (1) two connection-end arms in the stream
  state machine that convert a stream left in a scheduled-library-reset state, so a stream whose
  response ended behind a zero send window releases its concurrency slot; (2) a request extension
  carrying the stream id, which `LeaseService` reads to key the stream table; (3) the connection
  stops reading frames while pending-accept resets are at their bound, so a burst of cancelled
  requests is served instead of ending the connection; (4) a sustained reset-rate rule (a cell rate
  limit, 16 times the bound per 10 s) that ends a rapid-reset flood with GOAWAY(ENHANCE_YOUR_CALM).
  The exact functions are the data of the gate: `BEHAVIOUR_CHECKS` names each function and the text
  its body must still contain, `EXPECTED_HUNKS_BY_FILE` the hunk count per patched file,
  `PATCHED_FILES` the files; `runGate` is the entry point of both its offline and `--upstream` modes.
- Measurement harness (`shadowcat-test-support`): `throughput::BareApp` (variants `Chunks`,
  `OneBuffer`, `Router`; build the single-buffer one with `BareApp::one_buffer`, which owns its
  `BODY_BYTES` buffer so the other variants allocate none), `bare_server`, `served`, `download`;
  `throughput::Rung` (`name`, `baseline`, `addr`; `Rung::over` names the rung it is compared with)
  and `baseline_index` (panics on an unknown or non-preceding baseline); `parse_worker_count` /
  `DEFAULT_WORKERS`; `select_rungs`. The `egress_measure` binary's signature is
  `layers [downloads [runs [workers [rungs]]]]`: `workers` sets the runtime's worker count,
  the last argument is a comma-separated rung subset (a rung whose baseline is unlisted is compared with its
  nearest listed ancestor). Its `RESULT layers` line prints `baseline` and its throughput against the baseline
  for every rung but the root. The ladder is a TREE, not a line: each rung names one baseline, and
  the three `-no-nodelay` rungs repeat a nodelay rung with the option off.
  The `h2_send_buf_gate` integration test serves three servers (bare at the library
  default send buffer, bare at `H2_SEND_BUF_BYTES`, and `EgressServer::start`) and records ratios.

## Hard invariants

- **A TLS-side failure never stops plain HTTP.** Every `TlsRuntime::start_with` failure path ends in
  a runtime that serves plain HTTP, and `SniffListener` drops TLS-looking
  peers when TLS is off. [`docs/design/built-in-https.md` §2]
- **The scheme is decided once.** `http::scheme::classify` is read by `request_scheme` and
  `hsts_max_age`; a second reader of `X-Forwarded-Proto` or `ConnMeta::tls` is the forked-decision
  defect. A cookie's secure attribute follows the decided scheme, not the bind address
  [[plain-http-login-from-any-address]].
- **Ring only.** Every rustls configuration is built through `ring_provider`.
- **`ConnMeta` reaches handlers from exactly two places:** `conn_serve`'s per-connection
  `Extension(ConnectInfo(meta))` and `scheme::into_service`. `ConnMeta::cap_exempt` is decided once,
  by `Config::is_cap_exempt` in the acceptor task, and travels with the connection so the live caps
  apply the identical rule.
- **The accepted-socket option is decided once, in `set_accepted_nodelay`.** Every production accept
  path calls it; a new `ConnSource` that yields a plain TCP socket must too. Measured effect (Windows
  loopback, release build, 24 MiB over HTTP/2 against a bare hyper server with a 64 KiB send buffer,
  `egress_measure layers 150 5`, rungs `bare-64k` and `bare-64k-no-nodelay`, median of five run
  medians): 11.71 ms with the option, 16.93 ms without (run medians 15.81 to 19.79 ms without). One
  operating system, loopback only; other systems and non-loopback links are NOT measured.
- **HTTP version comes from ALPN (`ServeIo::is_h2`), never by reading the connection.** hyper-util's
  auto builder reads a 24-byte preface before any timer exists. Plain-text connections speak
  HTTP/1.1 only; an `h2` connection's preface is read under the header-read bound by
  `read_h2_preface`.
- **The accept-error pause is the caller's.** `serve_router` and `SniffListener`'s acceptor task
  consult `accept_error_pause`; a pause inside a `ConnSource::accept` future is cut short because
  `serve_router` drops that future on every reaped task. `accept` must be cancel-safe.
- **One definition of "no progress" for three units.** Order on `drive`'s sampler tick: connection,
  ended-unflushed, stream. The last two run only when the writer is not parked, and the stream unit
  runs only when the ended-unflushed unit cut nothing, so a parked writer is the connection unit's
  case alone (a stream cut could not even deliver its RST_STREAM). A cut is counted only when the
  call that fired it ended the connection (`ConnKill::fire` returns whether it was first), through
  `StallCounters::record_stall` and nothing else. A stream's progress is its OWN DATA: another
  stream's, a tunnel's, a PING's or any other write never refreshes it.
- **`EGRESS_CHUNK_BYTES` is public, equals the HTTP/2 default frame size, is the `LeasedBody` slice
  bound, and is the default of `ConnLimits::egress_floor`.** The field is a separate knob (tests
  vary it) and the tail rule judges it to the byte; the stream unit does not read it.
  `H2_SEND_BUF_BYTES >= EGRESS_CHUNK_BYTES` is a compile-time assertion.
- **The stream table is bounded and fails closed.** `H2_MAX_FRAME_BYTES` is set explicitly on the
  h2 builder. `CODEC_READ_MAX_BYTES` (the larger of that and `CODEC_INITIAL_READ_BYTES`) derives
  `PARSE_LAG_SLACK`, which with `H2_MAX_CONCURRENT_STREAMS` gives `STREAM_TABLE_CAP`. A table that
  would outgrow it cuts the connection and counts `StallCuts::tracker_overflow`; the lag test floods
  minimum frames after a full-size frame header and asserts the premises (read size, frame size)
  before the peak.
- **`ConnLimits::egress_window` must give a nonzero sampler period.** `egress_tick` is a quarter of
  the window, so a window under four nanoseconds makes `serve_router` panic (the configuration
  admits 1 to 3600 s). `Sampler` keeps `window / tick + 1` timestamped samples; its span is read
  from timestamps so a bunched runtime cannot fire early; exactly `floor` bytes is progress.
- **Both connection caps derive from one descriptor budget** (`fd_budget` invariants): the budget is
  the soft limit read back AFTER the raise attempt, never the value asked for, and the caps are
  fitted to their SUM plus the hand-off queue.
- **The kill is an IO error, not a task abort.** Every IO method of `Replay` checks `ConnKill`
  (all five: read, write, vectored write, flush, shutdown); aborting a connection task would drop
  the h2 connection under a detached WebSocket tunnel.
- **`lint:vendor` is a CI gate.** `runGate` prints every offline error already collected AND the
  download failure when `--upstream` cannot fetch (it does not return early on the fetch error);
  `download` has a total deadline and follows HTTPS-only redirects, and a malformed redirect location
  fails with a message naming it. A hand edit under `vendor/h2` that is not in the committed diff
  and the records fails the gate.

## Gotchas

- **`axum::serve` is not the production serve loop.** Text that says `http::serve` wraps
  `axum::serve(..).with_graceful_shutdown(..)` is stale. `http::serve_with` runs
  `conn_serve::serve_router` with `WsState::trigger_shutdown` as its `serve_router::on_drain` hook, then waits on
  `WsState::wait_for_drain` bounded by `session_wait` (the shared drain deadline, never under
  `SESSION_GRACE`). `into_service` and the audio monitor are the remaining `axum::serve` users.
- **The WebSocket upgrade task is detached from its connection** (HTTP/1.1: axum's upgrade-callback
  spawn; HTTP/2: hyper's tunnel task). A connection future resolving does not mean the session
  ended, which is why `serve_router::on_drain` runs before the drain and `ConnLease` exists.
- **A harness that skips `set_accepted_nodelay` measures the wrong server.** The production path ran
  at roughly half bare-hyper throughput on Windows loopback until the option was set on every
  accepted socket. New test-support sources must call the helper, not an inline socket-option call.
- **Throughput numbers from `layers` and `h2_send_buf_gate` are NOT reconciled.** On the same
  servers the ladder reads production (`serve_router+full-router`, and the gate's own production
  server, the `serve_router+full-router+observed-source` rung, at +3.2 percent) about 3.1 percent
  slower than `bare-64k` at 2 runtime workers, while the gate's records read the production server 4.9 to 6.2
  percent slower than the bare 64 KiB server at 4 workers; the buffer ratio reads 0.996 in the
  ladder and 0.954 to 0.958 in the gate. A later fresh-process re-run reproduced the ladder at 2
  workers (+3.1 percent) and read about +5 percent at 4 workers, but the host was in a different
  regime from the one that produced the gate's records (absolute times 2.4 times larger and the
  buffer effect with the opposite sign), so worker count is a candidate cause, NOT an established
  one. Treat any single `layers` or gate run as one sample; do not quote either as "the cost of the
  stall machinery". The release-only buffer-ratio assertion stays record-only until records exist
  for Linux and macOS.
- **A wall-clock bound is a derived bound or it is record-only.** The partial-tail end-to-end test
  (`egress_stall_h2`) runs at `PARTIAL_TAIL_WINDOW`, releases the reader at five eighths of the
  window and asserts its premises before the discriminating bound, so each side keeps a three
  eighths-of-window margin; the refresh rule itself is pinned by injected-clock unit tests on
  `StreamTable::scan`. The test restates the sampler's quarter-window period (a named coupling to
  the private `egress_tick`).
- **Debug-only vendor reproducer.** The slot-release assertion that motivates the connection-end
  arms exists only in debug builds, so its reproducer proves nothing in a release build.
- **The vendored read-pause stores no waker.** A caller that polls the vendored h2 connection
  with its closed-poll alone and accepts nowhere never resumes it; hyper's server path accepts in the task
  that polls.
- **Add a hook glob when you add a file here.** Every `SUBSYSTEMS` entry is an unanchored substring
  match on an absolute path, and this skill's entry must stay ordered before `realtime-sync`
  (which claims `src/server/src/http/` and `src/server/src/ws/`) and `server-ops`.

## Pointers

- Design: `docs/design/built-in-https.md` §2 invariants and §8 listener (including §8.1 HTTP/2 and WebSocket).
- The patch prose beside the vendored crate states each of the four changes and its reason.
- Memory: [[https-default-and-oss-deps]], [[plain-http-login-from-any-address]].
- Neighbouring skills: [[shadowcat-codebase-realtime-sync]] (what runs on a connection: rooms,
  egress frames, `ConnectionGuard`/`wait_for_drain`, `BoundedSink`), [[shadowcat-codebase-server-ops]]
  (`main`, `Config`, the `--tls-*` flags), [[shadowcat-codebase-assets]] (the streamed file bodies
  that go through `LeasedBody`, and `StreamedFilePermits`).
- Generated API: rustdoc `/api/rust/shadowcat/` pages for the `tls`, `http::conn_serve`,
  `http::peer_slots`, `http::scheme`, `fd_budget` and `ws::tunnel_gate` modules.
- Graph: `graphify query "serve_router connection lifecycle"`.
