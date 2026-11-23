Part of the shadowcat-codebase-server-ops skill; read it when editing audio_monitor, the db helpers, backup and restore, the admin backup route or world_bundle. Part 02 of 02 of "Server ops: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-config-router-serve-admin.md.

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
  ([[shadowcat-codebase-realtime-sync]]). There are exactly two pool-options decisions in the
  crate (the write bootstrap and the read-only bootstrap); nothing calls `SqlitePoolOptions::new()`
  directly outside these two functions.
- `backup` — `BackupManifest` (carries `kind: BackupKind` and an optional `note`), `BackupKind`
  (manual, pre-restore, scheduled), `BackupError`, `dir_is_empty_or_absent`,
  `create_backup(db_path, assets_dir, out_dir, trash, kind, note) -> Result<BackupManifest, BackupError>`,
  `restore_backup(backup_dir, db_path, assets_dir, force, trash) -> Result<(), BackupError>`. Every
  removal inside both moves into `trash` (`trash::Trash::discard`), never a raw remove. Opens its
  own short-lived pool via `db::connect_pool` (does not reuse `SqliteRepository`/`AppState`) —
  pure file I/O + one SQL statement, deliberately decoupled from the rest of the server so it
  works even when `main()`'s normal startup path never runs. `restore_backup` opens no SQL pool at
  all (file copy/rename only), so the foreign-keys pragma `connect_pool` always enables has no
  restore-time counterpart to diverge from.
- `POST /api/admin/backup` (`http::backups::admin_backup`, admin-only via `AdminUser`)
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
