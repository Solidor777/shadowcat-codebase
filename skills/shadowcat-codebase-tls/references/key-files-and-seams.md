# TLS and serve loop: Key files & seams

Part of the shadowcat-codebase-tls skill. Read it before changing or reviewing TLS, the sniffing listener, the serve loop or the egress bounds.

## Key files & seams

- `tls::TlsRuntime` — `start`/`start_with` is the degradation ladder. The self-signed certificate
  is ALWAYS loaded first (persisted, else in-memory, else TLS off) and is the `Snapshot` fallback
  that IP-literal and SNI-less peers get; an operator PEM is layered on top as the primary
  certificate, and an unusable one records `degraded_from` and keeps serving self-signed. The
  HSTS exclusion for `Selected::Fallback` depends on that fallback always existing. `disabled()` is
  the TLS-off runtime. `tls::resolver::Snapshot::select` is the ONE selection call: the certificate
  a connection gets, its `ConnMeta::cert` and the HSTS decision all derive from it.
  `CertResolver::update` is the hot-swap seam and is live: `TlsRuntime::maintenance_tick` reloads
  the operator PEM when its `tls::pem::PemStamp` changes (a failed reload keeps the previous
  certificate and records the error) and replaces the self-signed certificate when
  `selfsigned::regen_reason` says so. `main` calls `TlsRuntime::spawn_maintenance`, which runs the
  tick once a minute; the PEM stamp is compared on every tick, while the self-signed expiry and SAN
  re-check (`regen_reason`) runs only once `SELFSIGNED_CHECK_SECS` (24 hours) has elapsed since the
  last one. An ACME task would use the same seam; `TlsSource::Acme` is status vocabulary
  only. Rationale: `docs/design/built-in-https.md` §2 (invariants) and §8 (listener).
- `tls::keyfile` / `tls::selfsigned` / `tls::pem` — the certificate material. `keyfile::write_private`
  restricts the still-empty temporary file BEFORE any secret byte is written and returns the error
  when the OS refuses, so the caller (`selfsigned::load_or_generate`'s `persist_error`) degrades to
  an in-memory certificate instead of persisting a key under an inherited ACL; directories the
  operator already had are never re-permissioned (only ones `keyfile::ensure_private_dir` creates
  are restricted); a failed write leaves no `.tmp` file. `selfsigned` issues ECDSA P-256 leaves valid
  `VALIDITY_DAYS` (397) and renews them inside `RENEW_WITHIN_DAYS` (30). `pem::PemPaths::stamp`
  is the modification stamp `maintenance_tick` compares to decide a reload.
- `tls::ring_provider` / `install_default_provider` — the one place the crypto provider is named
  (ring). Never rely on rustls feature auto-selection.
- `tls::listener::SniffListener` — implements `ConnSource`. Its acceptor task admits through
  `PeerSlots` (the pre-hand-off cap), calls `set_accepted_nodelay`, then `negotiate`s under one
  `Limits::deadline` that covers sniffing AND the whole handshake. `ConnStream` is the IO enum
  (`Plain` | `Tls`); its `ServeIo::is_h2` is true only when ALPN negotiated `h2`.
  `tls::listener::TcpAccept` is the raw-accept seam tests substitute.
- `http::conn_serve::ConnLease` — a handler that detaches long-lived work takes it from the request
  extensions (`ws::conn::ws_handler` does and moves it into the session task). It keeps one
  stream counted as in flight and the cap slot held, so `ConnLimits::max_live` counts a connection
  until the connection task AND every lease have ended. It is absent when the router is not served
  through `serve_router`.
- `http::conn_serve::ConnSource` / `ServeIo` — the source/IO traits `serve_router` is generic over.
  `impl ConnSource for TcpListener` is the bare-listener source `http::serve` accepts in doc
  examples and tests. `accept_error_pause` is the one accept-error policy.
- `http::conn_serve::set_accepted_nodelay` — decides what the server configures on an accepted TCP
  socket (the TCP no-delay option), called by `impl ConnSource for TcpListener`, by `SniffListener`'s
  acceptor task and by `NodelayListener` (the `axum::serve` listener the audio-monitor server uses:
  axum's tap-IO listener hook passes only the stream, no peer address, so the helper cannot be called from it). The
  test-support sources that model the listener (`ObservedSource`, `H2cSource`) call it when their
  `nodelay` flag is on. `bare_server` in the throughput harness sets the option
  directly on purpose: it is the bare-hyper control, not production code. The obligation is stated
  in `ConnSource::accept`'s contract: a production source that hands out a plain TCP socket, and
  a source that models the listener's throughput path, configure it through this function; a
  source that only carries test traffic needs no socket policy.
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
  IPv4 address as itself, an IPv6 address by its /64 prefix, and an IPv4-mapped IPv6 address as the
  IPv4 address it maps (the address is canonicalised first).
- `fd_budget::raise_and_fit` — raises the soft descriptor limit, then fits BOTH caps to the
  budget the limit leaves. `descriptors_reserved` is `FD_RESERVE` (512) + `HANDOFF_QUEUE_CAP` +
  `STREAMED_FILE_PERMITS`; `fit_to_descriptor_budget` subtracts it from the soft limit and scales
  the two global caps proportionally to what remains, and the floors `MIN_PRE_HANDOFF_CAP` and
  `MIN_LIVE_CAP` win over the budget for a tiny limit (`Clamp::floors_exceed_budget` reports it).
  `descriptors_needed` is the unfitted demand. `main` and the `test_server` binary call it.
- `http::scheme::classify` — the ONE request-scheme decider, returning a `Reach` (`Plain`, `Proxy`,
  `Native(Selected)`); `request_scheme` and `hsts_max_age` both read it. `hsts_max_age` sends
  nothing unless `Config.hsts_max_age_secs` is `Some` (opt-in, default `None`), and then only for
  `Reach::Proxy` or `Reach::Native(Selected::Primary)`, never `Native(Fallback)` or
  `Native(Challenge)`; `main` warns when it is set with a self-signed certificate and no trusted
  proxy. `http::router` applies it as a per-request middleware closure
  (`router::hsts_header`) that inserts the header when `hsts_max_age` returns `Some`.
  `into_service` is the `ConnectInfo<ConnMeta>` adapter for transports still served by
  `axum::serve` (the real-socket test harnesses and the audio monitor).
- `auth::session::SchemeSessionLayer` — the cookie half of the scheme decision. It holds two session
  layers over one store and signing key and dispatches each request on `request_scheme`: cookie name
  `SESSION_COOKIE_PLAIN` on plain HTTP, `SESSION_COOKIE_TLS` (carrying the `__Host-` prefix) on
  HTTPS, so a login holds one session per scheme (a non-secure cookie cannot overwrite a secure one
  of the same name). `normalise_host_cookies` rewrites every `__Host-` `Set-Cookie` of the HTTPS flavour
  so a removal cookie carries the secure attribute too. Rationale: `docs/design/built-in-https.md` §4.
- `ws::WsState::bounded_sink` — the ONLY constructor of the session sink: it wraps the socket in
  `ws::tunnel_gate::TunnelGate` and that in `ws::bounded_sink::BoundedSink`, whose per-send stall
  bound is `Config::egress_window`. Once shutdown is signalled a pending send gets at most
  `CLOSE_SEND_TIMEOUT`, and `http::SESSION_GRACE` is `CLOSE_SEND_TIMEOUT` plus one second.
- `fd_budget::STREAMED_FILE_PERMITS` sizes the semaphore `http::assets::permits::StreamedFilePermits::production` creates. The asset file-serve paths take a permit
  (`acquire`) before opening a file; `http::world_bundle::export_world` takes ONE permit before any
  header is written and holds it until its producing task ends, so a single permit covers the whole
  export, not each file it reads. `acquire` waits up to `PERMIT_WAIT` (2 seconds); a pool still
  exhausted after the wait answers 503 with `Retry-After` before any header is written. The same
  constant is subtracted in `descriptors_reserved`.
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
  collects a 9-byte header across partial writes and skips payload by arithmetic. A PADDED DATA
  frame counts its whole length field, so it is overcounted by up to 256 bytes (the server writes no
  padding).
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
  `h2_builder` sets `H2_MAX_PENDING_ACCEPT_RESETS` (1024) and `H2_MAX_LOCAL_ERROR_RESETS`
  explicitly; the one value hyper forwards (the pending-accept bound) drives both change (3)'s
  read pause and, times 16 per 10 s, the change (4) reset-rate limit, so changing it moves both.
  The exact functions are the data of the gate: `BEHAVIOUR_CHECKS` names each function and the text
  its body must still contain, `EXPECTED_HUNKS_BY_FILE` the hunk count per patched file,
  `PATCHED_FILES` the files; `runGate` is the entry point of both its offline and `--upstream` modes.
- Measurement harness (`shadowcat-test-support`): `throughput::BareApp` (variants `Chunks`,
  `OneBuffer`, `Router`; build the single-buffer one with `BareApp::one_buffer`, which owns its
  `BODY_BYTES` buffer so the other variants allocate none), `bare_server`, `served`, `download`;
  `throughput::Rung` (`name`, `baseline`, `addr`; `baseline` names the rung it is compared with)
  and `baseline_index` (the lookup of that rung in a built ladder); `parse_worker_count` /
  `DEFAULT_WORKERS`. The ladder is `throughput::ladder`, a list of lazy
  `RungSpec`s (name, baseline, async constructor returning a `RungServer`); `build_ladder`
  validates before any constructor runs that every declared baseline names an EARLIER rung and
  that every selected name is a rung (a violation panics with a message naming it), then starts only the
  selected rungs, so an unselected rung allocates and binds nothing. The `egress_measure` binary's signature is
  `layers [downloads [runs [workers [rungs]]]]` (its other subcommands are
  `grid`, `mixed-serial`, `h1-progress` and `socket-grants`): `workers` sets the runtime's worker count,
  the last argument is a comma-separated rung subset (a rung whose baseline is unlisted is compared with its
  nearest listed ancestor). Its `RESULT layers` line prints `baseline` and its throughput against the baseline
  for every rung but the root. The ladder is a TREE, not a line: each rung names one baseline, and
  the three `-no-nodelay` rungs repeat a nodelay rung with the option off.
  The `h2_send_buf_gate` integration test serves three servers (bare at the library
  default send buffer, bare at `H2_SEND_BUF_BYTES`, and `EgressServer::start`) and records ratios.

