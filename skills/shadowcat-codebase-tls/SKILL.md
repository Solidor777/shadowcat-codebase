---
name: shadowcat-codebase-tls
description: "Use when touching Shadowcat's connection lifecycle from accept to drain: built-in HTTPS (`tls::TlsRuntime` degradation ladder, `tls::resolver` SNI/ALPN selection, `tls::selfsigned`, `tls::pem`, `tls::keyfile`), the sniffing accept path (`tls::listener::SniffListener`, `http::conn_serve::set_accepted_nodelay`), the serve loop that replaces `axum::serve` (`http::conn_serve::serve_router`, `ConnSource`/`ServeIo`, `ConnLimits`, `DrainReport`, `ServeOutcome`), the admission/live caps and descriptor budget (`http::peer_slots`, `fd_budget`), the per-request scheme decider (`http::scheme`), the three egress no-progress units and their wire-fed stream table (`StreamExec`, `Sampler`, `FrameParser`, `StreamTable`, `LeasedBody`, `TunnelProbe`, `ws::tunnel_gate::TunnelGate`), the session egress sink (`ws::bounded_sink::BoundedSink`), the streamed-file permit pool (`http::assets::permits::StreamedFilePermits`), the patched `vendor/h2` and its `lint:vendor` gate, or the measurement harness that exercises them (`shadowcat-test-support`'s `throughput`/`egress`/`observed`/`h2c` modules, the `egress_measure` binary, `h2_send_buf_gate`). Covers src/server/src/{tls,fd_budget.rs,http/{conn_serve*,peer_slots*,scheme*},ws/{tunnel_gate.rs,bounded_sink*},http/assets/permits*}, vendor/h2, scripts/check-vendor.mjs. Invoke shadowcat-codebase-core first."
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
`http::serve_with` wrap `serve_router` for `AppState`; `main` calls only `serve_with` (`http::serve`
is the form tests and doc examples use).

## Key files & seams

Covers every key file and seam of TLS, the sniffing listener, the serve loop and the egress bounds. Read references/key-files-and-seams.md before changing any of those files.

## Hard invariants

- **A TLS-side failure never stops plain HTTP.** Every `TlsRuntime::start_with` failure path ends in
  a runtime that serves plain HTTP, and `SniffListener` drops TLS-looking
  peers when TLS is off. [`docs/design/built-in-https.md` §2]
- **The scheme is decided once.** `http::scheme::classify` is read by `request_scheme` and
  `hsts_max_age`; a second reader of `X-Forwarded-Proto` or `ConnMeta::tls` is the forked-decision
  defect. A cookie's secure attribute follows the decided scheme, not the bind address
  [[plain-http-login-from-any-address]]. HSTS is opt-in and narrower still: `hsts_max_age` reads
  `classify` (never `request_scheme`), sends nothing unless `Config.hsts_max_age_secs` is `Some`,
  and then only for `Reach::Proxy` or `Reach::Native(Selected::Primary)`, so a plain request, the
  self-signed fallback and a challenge certificate never receive it.
- **Ring only.** Every rustls configuration is built through `ring_provider`.
- **`ConnMeta` reaches handlers from exactly two places:** `conn_serve`'s per-connection
  `Extension(ConnectInfo(meta))` and `scheme::into_service`. `ConnMeta::cap_exempt` is decided once,
  by `Config::is_cap_exempt` in the acceptor task, and travels with the connection so the live caps
  apply the identical rule. `ConnMeta::plain` and `ConnMeta::tls` default it to `false`; only
  `SniffListener`'s acceptor sets it, so a new `ConnSource` must set it too.
- **The accepted-socket option is decided once, in `set_accepted_nodelay`.** Its callers are
  `impl ConnSource for TcpListener`, `SniffListener`'s acceptor task and `NodelayListener`; a new
  production accept path that yields a plain TCP socket must call it too (and must set
  `ConnMeta::cap_exempt`, below). Measured effect (Windows
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
  case alone (a stream cut could not even deliver its RST_STREAM). Every cut is counted through
  `StallCounters::record_stall` and nothing else. A connection, ended-unflushed or tracker-overflow
  cut is counted only when the call that fired it ended the connection (`ConnKill::fire` returns
  whether it was first); a stream cut is counted once per marker, because
  `LiveState::cut_stalled_streams` fires a `StreamMarker` only when `StreamMarker::take_if_older`
  yields it. A stream's progress is its OWN DATA: another
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
- **`ConnLimits::egress_window` must give a nonzero sampler period.** `egress_tick` is the window
  divided by `EGRESS_TICKS_PER_WINDOW` (the one definition; tests read the period through
  `egress_tick`, never a copy of the quotient), so a window under that many nanoseconds makes
  `serve_router` panic (the configuration
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
- **A harness that skips `set_accepted_nodelay` measures the wrong server.** Without the option every
  `layers` rung measured 0.64 to 0.69 of the nodelay baseline (Windows loopback, release: 18.22 ms
  for the production server with the observed source, 17.00 ms for `serve_router+full-router`, 16.93
  ms for `bare-64k`). New test-support sources must call the helper, not an inline socket-option
  call.
- **The ladder-versus-gate PRODUCTION-PATH throughput difference is owner-ruled noise; the
  buffer-ratio gap is not covered by that ruling.** On the same servers the ladder (`layers`) reads
  production (`serve_router+full-router`, and the gate's own production server, the
  `serve_router+full-router+observed-source` rung) about 3.1 percent slower than `bare-64k` at 2
  runtime workers, while the gate's records read the production server 4.9 to 6.2 percent slower
  than the bare 64 KiB server at 4 workers. The owner ruled THAT difference noise, so do not reopen
  it or schedule a rerun. The buffer ratio (the default-buffer download-time median divided by the
  64 KiB median, so a value below 1 means the default buffer was faster) differs between the two
  instruments, and the ruling does not reach that gap, which is unexplained. Its readings:
  - Gate, 4 workers, 100 downloads, fast regime: 0.954 to 0.958 per run (three runs).
  - Ladder (`layers`), 2 workers, fast regime, 150 downloads, full ladder: 0.995 per file, over five
    runs (per run 0.994 to 0.997), for the `bare-64k` rung against the default-buffer root; the
    different rung `bare-64k+full-router` prints 0.996.
  - Ladder, 2 workers, 100 downloads, three slow-regime subset files: 1.10 to 1.25 per file. Within
    each file, run 1 reads 0.991 to 0.997 and runs 2 and 3 read 1.06 to 1.27, at identical workers,
    downloads and rungs.
  - Ladder, 4 workers, 100 downloads, slow regime: 1.21, 1.21 and 1.30 per file (1.020 to 1.412 per
    run, nine runs). The gate in the same state reads 0.946 to 1.309 per run across nine runs.
  - No fast-regime reading of the ladder at 4 workers exists; the gate gives the fast 4-worker
    buffer ratio, 0.954 to 0.958.

  Download medians per run (ms), each range named by instrument, workers and rung:
  - Ladder, 2 workers, `bare-default-buf`: fast 11.47 to 11.71 (11.58 to 11.71 over the five runs of
    the 150-download full-ladder record; 11.47 to 11.66 in run 1 of each three-rung subset file);
    slow 38.3 to 42.9 (runs 2 and 3 of the subset files).
  - Ladder, 2 workers, `bare-64k`: fast 11.57 to 11.74 (11.64 to 11.74 in the full-ladder record;
    11.57 to 11.71 in subset run 1); slow 29.2 to 36.7 (subset runs 2 and 3, and a separate 8-run
    `bare-64k`-only record whose first two runs read 11.73 and 11.79 and the other six 29.24 to
    36.62).
  - Ladder, 4 workers, `bare-default-buf`: 25.0 to 54.9 over six 3-run, 100-download files, all in
    the slow regime (no fast-regime record exists at 4 workers); the three files whose ratios are
    quoted above read 27.5 to 54.9.
  - Ladder, 4 workers, `bare-64k`: 16.4 to 41.7 over the same six files; the three files quoted
    above read 20.7 to 41.7.
  - Gate, 4 workers, default-buffer leg: fast 11.94 to 12.07; slow 26.9 to 49.6 (nine runs).
    Buffer leg (the bare server at the production send buffer): fast 12.52 to 12.59; slow 26.1 to
    41.8.

  Differences between the two instruments, none isolated; candidates, not causes. The instruments
  differ in at least:
  - Worker count: `layers` defaults to `DEFAULT_WORKERS` (2) and takes a worker argument; the gate
    runs 4.
  - Host regime, which co-occurs with the shift in the 2-worker `layers` reading from 0.995 to 1.10
    to 1.25 per file. The one controlled observation is within each slow subset file (run 1 reads
    0.991 to 0.997, runs 2 and 3 read 1.06 to 1.27, at identical workers, downloads and rungs), but
    regime is confounded with run position: run 1 is fast in all three files.
  - Downloads per run: the gate 100, the fast-regime ladder record 150, the slow subset files 100.
  - Rung set: the full 11-rung ladder in the fast-regime record; three rungs (`bare-default-buf`,
    `bare-64k`, `serve_router+full-router+observed-source`) in the slow records.
  - Binary: in the fast regime the gate's 64 KiB leg reads 12.52 to 12.59 against the ladder's
    `bare-64k` 11.64 to 11.74.

  Owner ruled: measure the gap later. Treat any single `layers` or gate run as one
  sample; do not quote either as "the cost of the stall machinery".
- **The host can change regime within one process, which makes multi-run results unreliable.**
  Within one ladder process on the `bare-64k` rung (workers 2, 8 runs, 100 downloads), runs 1 and 2
  read 11.73 and 11.79 ms and runs 3 to 8 read 29.24 to 36.62 ms; the cause is not diagnosed and it
  is not a blocker. Read the per-run RECORD lines and discard a result whose runs straddle two
  regimes; a median hides the straddle.
- **`h2_send_buf_gate` has no ratio assertion.** It records the buffer ratio and the production ratio per
  run and asserts only that every download delivers every byte. A release-only assertion that the buffer ratio is at least
  0.90 is specified in the deferred-work backlog and waits on release-profile records from
  Linux and macOS.
- **A wall-clock bound is a derived bound or it is record-only.** The partial-tail end-to-end test
  (`egress_stall_h2`) runs at `PARTIAL_TAIL_WINDOW`, releases the reader at five eighths of the
  window and asserts its premises before the discriminating bound, so each side keeps a three
  eighths-of-window margin, which `PARTIAL_TAIL_WINDOW` holds at or under 1 s (the owner-ruled ceiling on
  any timing assertion's margin: timing tests run on the owner's local machine); the refresh rule itself is pinned by injected-clock unit tests on
  `StreamTable::scan`. The test reads the sampler period through `egress_tick` and asserts
  `EGRESS_TICKS_PER_WINDOW` is the count its margins assume.
- **Debug-only vendor reproducer.** The slot-release assertion that motivates the connection-end
  arms exists only in debug builds, so its reproducer proves nothing in a release build.
- **The vendored read-pause stores no waker.** A caller that polls the vendored h2 connection
  with its closed-poll alone and accepts nowhere never resumes it; hyper's server path accepts in the task
  that polls.
- **Add a hook glob when you add a file here.** Every `SUBSYSTEMS` entry is an unanchored substring
  match on an absolute path, and this skill has two entries. The main one must stay ordered before
  `realtime-sync` (which claims `src/server/src/http/` and `src/server/src/ws/`) and `server-ops`.
  The narrow `src/server/src/http/assets/permits` entry must precede `assets` (which claims the rest
  of `src/server/src/http/assets/`); the hook self-test cases tl16 and tl17 fail if it does not.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | Key files and seams of TLS, the serve loop and egress bounds | changing TLS, listener, serve-loop or egress code |

## Pointers

- Design: `docs/design/built-in-https.md` §2 invariants and §8 listener (including §8.1 HTTP/2 and WebSocket).
- The patch prose beside the vendored crate states each of the four changes and its reason.
- Memory: [[https-default-and-oss-deps]], [[plain-http-login-from-any-address]].
- Neighbouring skills: [[shadowcat-codebase-realtime-sync]] (what runs on a connection: rooms,
  egress frames, `ConnectionGuard`/`wait_for_drain`), [[shadowcat-codebase-server-ops]]
  (`main`, `Config`, the `--tls-*` flags), [[shadowcat-codebase-assets]] (the asset routes; the
  `LeasedBody` and `StreamedFilePermits` mechanisms their file bodies use are documented in this
  skill).
- Generated API: rustdoc `/api/rust/shadowcat/` pages for the `tls`, `http::conn_serve`,
  `http::peer_slots`, `http::scheme`, `fd_budget` and `ws::tunnel_gate` modules.
- Graph: `graphify query "serve_router connection lifecycle"`.
