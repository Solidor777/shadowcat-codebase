# Server ops: key files and seams

Part of the shadowcat-codebase-server-ops skill; read it before editing server bootstrap, config, db pool options, backup/restore, world bundles, the audio monitor or the admin routes.

## Key files & seams

- `config` — `Cli` (a flat `clap::Parser` struct PLUS one `#[command(subcommand)] command:
  Option<CliCommand>` field, for `shadowcat audio-monitor` — every existing flat
  flag still parses unconditionally; `CliCommand` is a `clap::Subcommand` enum with exactly one
  variant today, named so it never shadows `std::process::Command` in the CLI tests) →
  `Config::load(cli)` layers CLI flag > `SHADOWCAT_*` env > TOML file > built-in default.
  `Config.db: String` (default `./shadowcat.db`), `Config.assets_dir: Option<String>` (`None` →
  sibling `assets/` beside the db file via `Config::assets_path()`, falling back to the current
  directory when the db has no on-disk location — see `db::database_file` below). `Cli.backup_to`/
  `restore_from: Option<String>` and `Cli.force: bool` are CLI-ONLY triggers — never on `Config`,
  never read from TOML/env (a one-shot operation is not persistent server configuration).
- `Config.behind_proxy` (default `false`, CLI/env-settable, never inferred) declares a reverse
  proxy fronts `bind` on the same host, making an otherwise-loopback bind internet-reachable.
  `Config::is_exposed()` is the ONE derived predicate every "is this deployment exposed"
  security-POLICY decision reads — `setup_token_policy`'s `"auto"` arm and
  `AppState::resolve_setup_token`'s warning call it rather than `is_loopback_bind()` directly, so
  those cannot drift out of agreement on this input. **Whether a request arrived over HTTPS is a
  different question, answered per request and only by `http::scheme::classify`** (native TLS
  via `ConnMeta`, or `X-Forwarded-Proto` from a peer listed in `Config.trusted_proxies`): the
  session cookie flavour (`auth::session::SchemeSessionLayer` dispatches on `request_scheme`, which
  reads `classify`) and the `Strict-Transport-Security` response header (`http::scheme::hsts_max_age`,
  which reads `classify` too, applied by `http::router`) both follow it, never `is_exposed()` and
  never the bind address. HSTS is opt-in: nothing is sent unless `Config.hsts_max_age_secs` is
  `Some`, and then only for a trusted-proxy HTTPS request or a native TLS connection on the primary
  certificate. A plain-HTTP request, loopback or LAN, gets neither a secure cookie nor HSTS: a
  browser refuses to store a secure-attribute cookie set from a non-secure, non-loopback origin,
  which would make LAN login impossible, and ignores HSTS over plain HTTP. The retired
  pre-`behind_proxy` key (`RETIRED_BEHIND_TLS_PROXY_KEY`) fails boot from the environment, TOML and the
  CLI (the `retired_behind_tls_proxy_*` tests) rather than being ignored. `Config::startup_warnings` warns when
  `behind_proxy` is set with an empty `trusted_proxies` (every request would then read as plain
  HTTP). See [[shadowcat-codebase-tls]] for the scheme decider and the two session cookies.
- `Config.egress_window_secs` (`Config::egress_window` is its `Duration`; 1 to 3600 s, checked
  against `EGRESS_WINDOW_SECS_MIN`/`EGRESS_WINDOW_SECS_MAX` at config resolution) is the one
  no-progress window every stalled-peer bound uses; [[shadowcat-codebase-tls]] owns what it bounds.
- `db::database_file(url: &str) -> Result<Option<PathBuf>, sqlx::Error>` is the ONE decider for
  which file on disk a `Config.db` connection string names — the sole function every sibling-
  directory resolver and one-shot backup/restore path is required to route through rather than
  treating `Config.db` as a bare path itself. Parses `url` only through `db::parse_connect_options`
  (never a second URL parser) and returns `None` for both in-memory spellings (`:memory:`/
  `sqlite::memory:`, detected via sqlx's connect-options filename accessor returning a generated
  `file:sqlx-in-memory-` marker — the only public signal of sqlx's private in-memory flag) and a
  `mode=memory` query parameter on any URL (re-read from the URL's own query string via the `url`
  crate's form-urlencoded parser, since sqlx consumes that flag internally with no getter); otherwise
  `Some` of the real path — a bare filesystem path, or the path component of a `sqlite:`/
  `sqlite://` URL, including one containing the literal substring "memory" (not itself an
  in-memory signal). `Config::db_sibling_dir(name: &str) -> Option<PathBuf>` (private) is the only
  resolver that calls `database_file` directly, joining `name` onto its parent directory via the
  private `Config::sibling_of`; `assets_path`, `modules_path`, and `logs_path` all route through
  `db_sibling_dir`. `backups_path_for(&self, db_file: &Path) -> PathBuf` takes an ALREADY-resolved
  db file instead (its one production caller, `http::routes::admin_backup`, has already called
  `database_file` itself to decide how to react to `None`/`Err`, so a second internal call would
  re-derive the same decision a second way; `main::run_backup` takes an explicit output directory
  and never calls it) and spells the same sibling layout through
  `sibling_of` directly. **Never derive a filesystem path from `Config.db`
  directly** — a `sqlite:`-scheme URL or a bare path containing "memory" both defeat a naive string
  check, which is the defect class `database_file` exists to close.
- `Config::logs_path() -> Option<PathBuf>`: an explicit `Config.log_dir` always wins (even over an
  in-memory `db`); otherwise `db_sibling_dir("logs")` — `None` whenever the db has no on-disk
  location (either in-memory spelling, `mode=memory`, or an unparseable connection string), meaning
  file logging is off entirely rather than a directory this function invents on the caller's
  behalf; otherwise a sibling `logs/` dir beside the db file, the same convention `assets_path`/
  `modules_path` use. `main::init_tracing(log_dir:
  Option<&Path>) -> anyhow::Result<Option<WorkerGuard>>` reads `config.logs_path().as_deref()` at
  every `Config`-dependent call site and propagates a failure via `?`; ADDITIONALLY writes
  daily-rotated log files (the `tracing_appender` crate's rolling-file appender, DAILY rotation,
  `filename_prefix("shadowcat")`, retention bounded by `main::MAX_LOG_FILES` = 14) alongside the
  always-on stdout layer when its argument is `Some`. `main::build_rolling_appender(dir: &Path) ->
  anyhow::Result<RollingFileAppender>` is the ONE log-directory-creation seam: it calls
  `std::fs::create_dir_all(dir)?` BEFORE `tracing_appender::rolling::Builder::build(dir)`, because
  the vendored crate's own `Inner::new` prunes old log files (a directory read) before it creates
  the target directory itself — creating the directory here first is what keeps that prune from
  ever observing a missing directory (which would otherwise `eprintln!` an unconditional,
  uncatchable error on a fresh install's first-ever start). `init_tracing` returns the
  `tracing_appender`
  crate's non-blocking-writer guard type (`Option<WorkerGuard>`) rather than dropping it
  internally — the caller (`main`) must hold it for the process's whole lifetime, since a dropped
  guard stops the background writer thread and silently drops buffered lines. `None` reaches
  `init_tracing` two ways: the `audio-monitor` subcommand branch runs before `Config::load` and has
  no `Config` to derive a directory from at all; every other caller passes `config.logs_path()`
  through unchanged, which is itself `None` whenever `logs_path()`'s own rule above says so.
- `http::router` installs a global response-header layer via tower-http's overriding
  set-header layer (`X_FRAME_OPTIONS: DENY`, `X_CONTENT_TYPE_OPTIONS: nosniff`,
  `REFERRER_POLICY: same-origin`, unconditional on every route) plus a conditional
  `Strict-Transport-Security` header, set by a per-request middleware closure
  (`router::hsts_header`) that calls `scheme::hsts_max_age(req.extensions(), req.headers(), &config)` and
  inserts the header when it returns `Some` — a Content-Security-Policy is deliberately NOT set here. Both sit
  INSIDE the request-id/trace layers, which wrap them (not the reverse), so a request-id is
  stamped and the trace span opened before these headers run, and both still land on error
  responses, not just successful ones. The override mode unconditionally replaces any existing
  value with the same name on the way out, so a per-handler copy of one of these headers (e.g.
  a per-branch X_CONTENT_TYPE_OPTIONS on `http::assets::serve`) is dead weight — remove it
  rather than duplicate it ([[shadowcat-codebase-assets]] for the asset-serve headers this
  affects).
- `main` — `main()`'s FIRST branch: if both `backup_to` and `restore_from` are
  `Some`, `anyhow::bail!` before `Config::load` even runs. The three fields are cloned OUT of
  `main::cli` before `Config::load(cli)` consumes it by value. Either flag alone short-circuits to
  `run_backup`/`run_restore` and `return Ok(())` — `SqliteRepository::connect` (the long-lived
  pool) and `http::serve_with` are structurally unreachable on that path, not just conditionally
  skipped.
- `serve(listener, state, shutdown_fut)` (`http::serve`) is the testable core of normal server
  startup; `http::serve_with` is the same with explicit `conn_serve::ConnLimits`. Both run
  `conn_serve::serve_router` (NOT `axum::serve`: see [[shadowcat-codebase-tls]] for why the
  serve loop is owned here) with `WsState::trigger_shutdown` as its `serve_router::on_drain` hook, which runs
  once before the connection drain for both a shutdown request and a source that ended. After
  `serve_router` returns, `serve_with` calls `WsState::wait_for_drain` bounded by `http::session_wait`
  (what remains of the drain deadline, never under `http::SESSION_GRACE`) — because an HTTP/1.1
  WebSocket-upgrade callback spawns as a task DETACHED from the hyper connection that produced the
  101 handshake, so the connection drain does NOT wait for a live session's task to exit; without
  the drain step, `main` could return (dropping the tokio runtime) while a `ws::conn::egress_loop`
  task is still mid-`send` on its Close frame. A source that ended without a shutdown request makes
  `serve_with` return an error so a supervisor restarts the process. See
  [[shadowcat-codebase-realtime-sync]] for the `WsState.live_connections`/`ConnectionGuard`/
  `wait_for_drain` mechanism this drains and for `egress_loop`'s own shutdown-select arm. `main`'s
  `shutdown_signal()` is the `serve::shutdown_fut` passed in: it resolves on Ctrl+C
  (`tokio::signal::ctrl_c`) or, under a Unix build, SIGTERM (`tokio::signal::unix::SignalKind::
  terminate` — Windows has no SIGTERM, so the pending-forever future substituted there never
  resolves and the `select!` reduces to Ctrl+C alone with no extra conditional compilation at the
  call site; macOS and Linux both take the real branch). `main` builds the listener stack before
  serving: `fd_budget::raise_and_fit` fits both connection caps to the descriptor budget, then
  `tls::listener::SniffListener::new` wraps the bound `tokio::net::TcpListener` (see
  [[shadowcat-codebase-tls]]).
- `create_world` (`http::routes::create_world`) is throttled per-account via `AppState.
  auth_throttle` (the same sliding-window limiter the login/invite endpoints share), budget
  `state.config.world_create_per_min_per_account.unwrap_or(throttle::
  WORLD_CREATE_PER_MIN_PER_ACCOUNT)` — `Config.world_create_per_min_per_account: Option<usize>`
  (env `SHADOWCAT_WORLD_CREATE_PER_MIN_PER_ACCOUNT`; no CLI flag) layers exactly like
  `login_per_min_per_identity`/`invite_per_min_per_account`, `None` falling back to the 10/min
  built-in constant. The shell's `playwright.config.ts` sets this env var to relax the budget for
  its e2e suite, the same pattern its login/invite overrides already use, since one long-lived
  in-memory-DB server process (`reuseExistingServer`) accumulates world-creation calls across many
  local runs against one seeded account. `create_world` requires only an authenticated `AuthUser`
  with no per-world capability check, so an unthrottled account could otherwise mint unbounded
  worlds (each seeding a full config-doc set via `apply_intent`), exhausting storage/DB rows with
  no signal beyond ordinary write volume.
- `POST /api/users/{id}/password` (`routes::reset_user_password`, server-admin-only via
  `AdminUser` — the same guard `create_user` uses) and `create_user` both validate the plaintext
  password through the ONE shared `routes::validate_password_policy` (length floor/ceiling), so the
  two password-setting paths can never drift on what password is admissible.
  `reset_user_password` hashes it, calls `SqliteRepository::set_user_password` (updates the hash
  AND, via the shared `SqliteRepository::purge_sessions_for` helper, revokes every existing
  session for that account in the SAME transaction — the identical live-eviction reasoning
  `delete_user` already documents: a surviving session would keep the OLD password's authenticated
  state alive), then kicks live WS connections via `state.ws.rooms.evict_user` — the SAME call
  `delete_user`'s route makes, never a second eviction mechanism. `purge_sessions_for` is the ONE
  session-purge helper in the crate, called by both `delete_user` and `set_user_password`
  immediately before their respective `tx.commit()` on the SAME transaction as their own write; an
  admin resetting their OWN password is not special-cased — their own sessions and live
  connections are evicted too, intended, since a password change invalidates every session for the
  account, self included. Failure mapping is condition-specific, not uniform: an unknown target id
  is `AppError::NotFound` (404, existence-hiding, matching `create_user`/`delete_user`'s own
  routes); a password failing `validate_password_policy` is `AppError::Unprocessable` (422); an
  Argon2 hashing failure is `AppError::Internal` (500).
- `audio_monitor` (`src/server/src/audio_monitor/`) — the `CliCommand::AudioMonitor` branch's
  target: a localhost-only `SessionMonitor` trait plus one `#[cfg(target_os = ...)]` backend per
  OS (`windows`/`macos`/`linux`), constructed by `platform_monitor()`. `main.rs`'s `Cli::parse()`
  does the CLAP parsing and extracts `CliCommand::AudioMonitor(args)` before calling `run(args)`;
  `server::run(args: AudioMonitorArgs)` receives the ALREADY-parsed args and builds the real
  platform monitor — it parses nothing itself. `server::run_with_monitor`
  is the same origin-allowlist + `hello`/`levels`/`watch` frame-serialization loop factored out
  behind an injected `SessionMonitor`, so it is testable against a scripted `FakeMonitor`
  (`#[cfg(test)]`-only, never compiled into the release binary) without a real OS audio API on
  the test runner. Its server runs `axum::serve` over `http::conn_serve::NodelayListener` (see
  `shadowcat-codebase-tls`).
  - **`linux.rs`'s `CaptureStream` unregisters its listener before the stream frees**: the
    pipewire crate's stream listener handle must tear down (unregister the `process` callback
    from the stream's internal listener list) before the stream handle frees the memory that
    listener pointed into. `CaptureStream.listener` is an `Option<StreamListener<()>>` that its
    explicit `Drop` takes and `unregister()`s ahead of the field drops, so the order does not
    depend on field declaration order. `stream` is read via a real `is_connected()` accessor
    (backed by the pipewire crate's own stream-state query) that the capture loop's shutdown-poll
    timer calls to sweep dead streams.
  - **`macos.rs` calls raw Core Audio HAL functions (`AudioObjectGetPropertyData`,
    `AudioHardwareCreateProcessTap`, etc.) via a hand-written `extern "C"` block that needs
    `#[link(name = "CoreAudio", kind = "framework")]` directly above it** — omitting this
    compiles cleanly (extern declarations don't need their symbols to resolve until link time)
    and fails ONLY at the final link step with "undefined symbols for architecture arm64", which
    is easy to miss if an earlier, unrelated compile error in the same file already stops the
    build before link and hides it.
  - **`macos.rs` hand-rolls Objective-C `objc_msgSend` calls (no third-party Objective-C-bridge
    crate)** — since
    `objc_msgSend`'s real signature varies by the receiver method's arity, declare the symbol
    exactly ONCE via `extern "C"` (minimal/generic signature) and transmute its
    function pointer to whatever specific `unsafe extern "C" fn(...)` type each call site needs.
    Declaring the same `#[link_name = "objc_msgSend"]` symbol twice with different Rust
    signatures trips rustc's clashing-extern-declarations lint (warn by default, an error only under `-D warnings`).
  - **`macos.rs`'s process-tap seam pairs each pid with its Core Audio process object id.**
    Enumeration reads `'prs#'` (the process object list) and each object's `'ppid'` (its pid), and
    yields (pid, process object id) pairs. Taps are created from the object ids
    (`initStereoMixdownOfProcesses:` takes them), and a tap's identity is the (pid, object id)
    pair; the live-tap and peak maps stay pid-keyed. A live pid enumerating under a changed object
    id has its tap torn down and recreated. The tap description carries its own UUID (an NSUUID set
    through `setUUID:`), reused as the aggregate description's sub-tap `uid`
    (`aggregate_description`). The output device is the default system-output device (`'sOut'`);
    its UID, read via `'uid '` in `read_default_system_output_uid`, is the aggregate's main
    sub-device and time source. `read_tap_format` reads the tap's `'tfmt'`; `verify_tap_format` is
    a pure check that the format is packed little-endian 32-bit float linear PCM with at least one
    channel, counting one channel per frame for a non-interleaved description. `create_tap_for_pid`
    destroys the tap before any aggregate device exists when the read fails or the check refuses.
    `buffer_list_peak` takes the maximum over all `number_buffers` entries. A failed tap creation
    is retried per (pid, object id) after `TAP_RETRY_DELAY` (`TapRetryBackoff`).
  - **The vendored PipeWire crate's stream-flags bitflags do NOT include a passive-mode flag** — verified against the
    vendored crate source; the real set is `AUTOCONNECT, INACTIVE, MAP_BUFFERS, DRIVER,
    RT_PROCESS, NO_CONVERT, EXCLUSIVE, DONT_RECONNECT, ALLOC_BUFFERS, TRIGGER`. For a
    buffer-reading capture stream, `AUTOCONNECT | MAP_BUFFERS` (optionally `| RT_PROCESS` if the
    `process` callback stays realtime-safe) is the crate's own `examples/audio-capture.rs`
    precedent.
  - CI must install `libpipewire-0.3-dev` on every `ubuntu-latest` job that compiles this crate —
    not just the `rust` job. `libspa-sys`'s build script needs the system PipeWire headers/
    pkg-config on `e2e`/`ui-e2e`/`docs` too, since each of those also runs `cargo build`/`cargo
    doc` on the same workspace; a job missing the install step fails at the `libspa-sys` build
    script, not with a Rust-level error.
- `db` — `parse_connect_options(url) -> Result<SqliteConnectOptions, sqlx::Error>` parses a URL
  into connect options exactly ONCE; `connect_pool_with_options(options) -> Result<SqlitePool,
  sqlx::Error>` is the SHARED single-writer pool-open bootstrap over already-parsed options
  (`SqlitePoolOptions::max_connections(1)` + a `PRAGMA foreign_keys = ON;`
  `SqlitePoolOptions::after_connect` hook); `connect_pool(url)` is the URL-string convenience that
  chains the two for callers with no need to share the parsed connect options with a second pool.
  Every
  write-pool-opening call in the crate routes through `connect_pool`/`connect_pool_with_options`:
  `data::sqlite::SqliteRepository::connect` (which then runs migrations — `connect_pool`
  deliberately does not, since a caller opening a short-lived pool against an already-migrated
  database, e.g. `backup::create_backup`'s `VACUUM INTO` connection, must never trigger a schema
  migration as a side effect of backing up), `backup::create_backup`, and every ad hoc
  test-scaffolding pool in `backup`'s own `tests` module. A second, dedicated function,
  `open_read_only_pool(options) -> Result<SqlitePool, sqlx::Error>`, opens a small
  (`max_connections(4)`) read-only pool against the SAME already-parsed connect options passed in
  — never a fresh parse of the URL string, since a second parse of an in-memory URL creates an
  unrelated, empty in-memory database (see `parse_connect_options`'s doc).
  `data::sqlite::SqliteRepository::open_read_pool`
  is the sole caller, clone-ing the repository's own stored `connect_options`; `auth::session`'s
  `SqlxSqliteStore` is the one consumer, using this read pool for its hot `load`/`id_exists` path
  ([[shadowcat-codebase-realtime-sync]]). There are now exactly two pool-options decisions in the
  crate (the write bootstrap and the read-only bootstrap); nothing calls `SqlitePoolOptions::new()`
  directly outside these two functions.
- `backup` — `BackupManifest`, `BackupError`, `dir_is_empty_or_absent`,
  `create_backup(db_path, assets_dir, out_dir) -> Result<BackupManifest, BackupError>`,
  `restore_backup(backup_dir, db_path, assets_dir, force) -> Result<(), BackupError>`. Opens its
  own short-lived pool via `db::connect_pool` (does not reuse `SqliteRepository`/`AppState`) —
  pure file I/O + one SQL statement, deliberately decoupled from the rest of the server so it
  works even when `main()`'s normal startup path never runs. `restore_backup` opens no SQL pool at
  all (file copy/rename only), so the foreign-keys pragma `connect_pool` always enables has no
  restore-time counterpart to diverge from.
- `POST /api/admin/backup` (`http::routes::admin_backup`, admin-only via `AdminUser`)
  — in-server backup trigger, layered ABOVE `backup`. Resolves the source db file via ONE
  `db::database_file(&state.config.db)` call: `Ok(Some(path))` proceeds; `Ok(None)` (an in-memory
  `Config.db`) is a caller-facing configuration mistake, rejected with `AppError::Unprocessable`
  (422) — `"backup requires a file-backed database; {config.db} is in-memory"`, the same message
  text `main::run_backup`'s own `database_file` call uses for the CLI path; `Err(e)` (a malformed
  `Config.db` string) is logged via `tracing::error!` and rejected with the opaque
  `AppError::Internal`, since that failure is a server-config defect rather than a caller mistake.
  The output root comes from `Config::backups_path_for(&db_path)` (explicit `Config.backups_dir`,
  else a sibling `backups/` beside the resolved db file), one timestamped subdirectory per run.
  Holds `AppState.write_barrier`
  (`Arc<tokio::sync::RwLock<()>>`, `http`) in WRITE mode across the whole snapshot; asset
  `upload`/`replace` (`http::assets`) each acquire it in READ mode around their own commit+rename
  step, so no asset write can interleave with an in-server backup's file copy. DB writers need no
  gating — `VACUUM INTO` is transactionally consistent against a live writer on its own.
- `world_bundle` (top-level, pure tar I/O, mirrors `backup`'s no-`AppState`-dependency separation)
  — `write_bundle`/`read_bundle` build/parse the `.tar` bundle format (`manifest.json` +
  `rows/<table>.jsonl` + `assets/<asset_id>`); `data::world_bundle` holds the row/manifest DTOs
  (`BundleManifest`, `Exported*Row`, `WorldExportData`/`WorldImportData`, `ImportSummary`) plus
  `BUNDLE_SCHEMA_VERSION`. `data::sqlite::SqliteRepository::export_world_rows`/`import_world` are
  the DB-facing halves — `import_world` rejects a world-id collision before any row is written,
  inserts `worlds` then every table `delete_world` already walks (read instead of deleted) in
  FK-safe order, and finalizes staged asset files only after every row is accepted. A bundle's
  documents are untrusted: `import_world` runs `check_command_scope` on EVERY document's own
  `scope` before its row is written (`document_row_columns` persists `world_id`/`scope_kind`
  straight from `scope`, and nothing else in the pipeline checks a leaf's scope), inserts them in
  parent-before-child order via Kahn's algorithm over the bundle's own `parent_id` edges (cycle
  members never reach indegree 0 and stay at the tail in `ORDER BY id` order, so the immediate
  `documents.parent_id` FK rejects them on first insert — there is deliberately no multi-hop
  cycle walk), then runs ONE post-loop placement pass over every imported document —
  `validate_containment` → `check_parent_placement` with EMPTY batch maps (every row is already
  in the tx, the `apply_command` Move-arm precedent) → `Self::self_parent_error` — in the Create
  arm's own order. `import_world`
  also rejects (whole-transaction rollback) a bundle whose `data.documents` carries two documents
  of the same `SINGLETON_DOC_TYPES` doc_type, mirroring `apply_intent`'s own intra-batch
  `apply_intent::claimed_singletons` tracking (`import_world` builds its own equivalent local) —
  a bundle is untrusted input assembled outside any live
  `apply_intent` call, so nothing else in the insert loop would otherwise catch this.
  `http::world_bundle::export_world`/`import_world` are the two routes, both server-admin-only
  (`AdminUser`) and both participating in `AppState.write_barrier` alongside `assets`
  `upload`/`replace` and `POST /api/admin/backup`: `export_world` takes one
  `StreamedFilePermits` permit before any header (`shadowcat-codebase-tls` owns the pool) and holds
  it, with the read side, across its row read + `write_bundle`'s chunk-production phase,
  `import_world` holds the read side across the upload +
  extraction + `SqliteRepository::import_world`'s asset-finalization rename step — so neither can
  interleave with a concurrent in-server backup snapshot.
