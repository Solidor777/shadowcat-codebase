---
name: shadowcat-codebase-server-ops
description: "Use when touching Shadowcat's server bootstrap/config/CLI/deployment surface: the `main` module (entry point, early one-shot CLI branches), the `config` module (`Cli`/`Config` layering: CLI flag > SHADOWCAT_* env > TOML > default), the `db` module (the shared `connect_pool` single-writer SqlitePool bootstrap plus `open_read_only_pool`'s dedicated read-only bootstrap, every pool-opening site in the crate calls one of the two), or the `backup` module (whole-server VACUUM-INTO backup/restore). Covers the single-binary deployment story, not any one data/document subsystem. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Server Bootstrap, Config, and Backup/Restore

Orientation for the parts of the server crate that exist ABOVE any one data subsystem: how the
binary starts, how configuration is resolved, and how a deployment's data is snapshotted/restored.

## Purpose

`main` is the single entry point for the `shadowcat` binary — normal server startup AND the
one-shot `--backup-to`/`--restore-from` CLI modes share it, mutually exclusive with each other and
with serving. `config` resolves the effective `Config` from four layered sources. `backup`
is a pure-I/O module (no `AppState`/`SqliteRepository` dependency) providing whole-server backup
and restore as a deployment-operator tool, not an in-app feature.

## Key files & seams

- `config` — `Cli` (flat `clap::Parser` struct, no `clap::Subcommand`) →
  `Config::load(cli)` layers CLI flag > `SHADOWCAT_*` env > TOML file > built-in default.
  `Config.db: String` (default `./shadowcat.db`), `Config.assets_dir: Option<String>` (`None` →
  sibling `assets/` beside the db file, via `Config::assets_path()`). `Cli.backup_to`/
  `restore_from: Option<String>` and `Cli.force: bool` are CLI-ONLY triggers — never on `Config`,
  never read from TOML/env (a one-shot operation is not persistent server configuration).
- `main` — `main()`'s FIRST branch: if both `backup_to` and `restore_from` are
  `Some`, `anyhow::bail!` before `Config::load` even runs. The three fields are cloned OUT of
  `main::cli` before `Config::load(cli)` consumes it by value. Either flag alone short-circuits to
  `run_backup`/`run_restore` and `return Ok(())` — `SqliteRepository::connect` (the long-lived
  pool) and `axum::serve` are structurally unreachable on that path, not just conditionally
  skipped.
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
  — in-server backup trigger, layered ABOVE `backup`. Writes into
  `Config::backups_path()` (`config`, `None` → sibling `backups/` beside the db file, mirroring
  `assets_path()`'s convention), one timestamped subdirectory per run. Holds `AppState.write_barrier`
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
  FK-safe order, and finalizes staged asset files only after every row is accepted. `import_world`
  also rejects (whole-transaction rollback) a bundle whose `data.documents` carries two documents
  of the same `SINGLETON_DOC_TYPES` doc_type, mirroring `apply_intent`'s own intra-batch
  `apply_intent::claimed_singletons` tracking (`import_world` builds its own equivalent local) —
  a bundle is untrusted input assembled outside any live
  `apply_intent` call, so nothing else in the insert loop would otherwise catch this.
  `http::world_bundle::export_world`/`import_world` are the two routes, both server-admin-only
  (`AdminUser`) and both participating in `AppState.write_barrier` alongside `assets`
  `upload`/`replace` and `POST /api/admin/backup`: `export_world` holds the read side across its
  row read + `write_bundle`'s chunk-production phase, `import_world` holds it across the upload +
  extraction + `SqliteRepository::import_world`'s asset-finalization rename step — so neither can
  interleave with a concurrent in-server backup snapshot.

## Hard invariants

- **Pool-open options are derived from shared constructors, never restated per site** —
  `db::connect_pool_with_options` is the sole place `max_connections(1)` and the foreign-keys
  `SqlitePoolOptions::after_connect` hook are set for a WRITE pool, and `db::open_read_only_pool`
  is the sole place a READ-ONLY pool's `max_connections(4)` + `.read_only(true)` are set; a new
  pool-opening call site must call one of these rather than reconstructing `SqlitePoolOptions`
  inline, or the decisions silently fork again the moment one site's requirements change and the
  other isn't updated to match. A second pool sharing an existing pool's database must be built by
  cloning that pool's already-parsed connect options, returned by `db::parse_connect_options` and
  stored on `data::sqlite::SqliteRepository.connect_options`, never by re-parsing the URL string —
  a fresh parse of an in-memory URL is a unique, unrelated, empty database.
- **`VACUUM INTO`, never a raw `.db` file copy** — a raw byte-copy of a live SQLite file is unsafe
  (a concurrent writer or WAL journal can leave it mid-write); `VACUUM INTO` is SQLite's own
  atomic, consistency-guaranteed live-snapshot primitive.
- **Assets copy ALWAYS runs after the db snapshot, never before/concurrently** — asset uploads
  write bytes to disk BEFORE inserting the referencing DB row
  ([[shadowcat-codebase-assets]]-adjacent: `http::assets` create path), and asset files are
  never deleted except by explicit delete, so db-then-assets ordering guarantees every asset a
  snapshot's rows reference is already present in the assets copy. `manifest.json` is written
  last, after both.
- **Two backup surfaces, not one.** The CLI one-shot mode (`--backup-to`/`--restore-from`,
  cross-process, invokable from cron/Task Scheduler/systemd-timer with no running server) remains
  the ONLY restore path — restore never runs in-server (see below). Backup ALSO has an in-server
  admin route (`POST /api/admin/backup`) because a cross-process CLI invocation cannot
  reach the live process's `write_barrier` to quiesce concurrent asset writes; the in-server route
  can. Anything needing a write-quiesced backup (e.g. a future scheduled-backup feature) must use
  the admin route, not the CLI mode.
- **Fail-closed restore**: `restore_backup` validates `manifest.json` + `world.db` presence
  BEFORE touching any destination file — a missing/malformed/foreign backup directory returns
  `BackupError::InvalidBackupDir` with zero destination writes.
- **Force-gated overwrite, both directions**: `--backup-to` refuses a non-empty output directory
  without `--force`; `--restore-from` refuses when the destination db file already exists OR the
  destination assets dir exists and is non-empty, without `--force`. A rejected restore is
  structurally inert — the control flow cannot reach any destination-mutating call before the
  gate's `return Err`. Asymmetric ownership: `restore_backup` enforces its own gate internally
  regardless of caller, but `create_backup` does NOT check `create_backup::out_dir` for prior contents — the
  refuse-non-empty gate for backup lives at the CLI layer (`main::run_backup`, via the
  exported `dir_is_empty_or_absent`). A future caller invoking `create_backup` directly (e.g. an
  in-app export feature) would bypass that gate.
- **Restore never starts the server** — restore and serve are always two separate invocations
  (a live connection can't safely have a different file swapped in as its backing file; Windows
  can even fail that swap outright on an open handle).
- **No shell-out for the recursive directory copy** (`tokio::fs` walks only — no `cp -r`/`xcopy`/
  `robocopy`), every path built via `Path`/`PathBuf::join` — cross-platform invariants per project
  CLAUDE.md, verified by a dedicated nested-directory (3+ levels) round-trip test.

## Gotchas

- **Docs-ratchet is live in this subsystem:** the `config`, `db`, `backup`,
  `modules`, `main`, and `bin::test_server` modules all carry `#![deny(missing_docs)]` +
  `#![deny(clippy::missing_docs_in_private_items)]` — a new item without a doc comment fails the
  3-OS CI clippy step. Every lib function also carries a `# Examples` doctest (`no_run` for
  infra-bound; bins use ` ```text ` — rustdoc runs no doctests for bin targets). The crate root has
  NO deny attr (a crate-root inner attr would flip the whole crate early — that's the final ratchet).
- `backup::copy_dir_recursive` silently skips symlinks (documented on the function itself)
  — the assets tree is server-managed and never contains one today, so this avoids following into
  an unexpected target rather than guessing at semantics. Revisit if `assets_dir` is ever pointed
  at a symlinked/shared directory.
- `sqlx = 0.9`'s `SqlSafeStr` bound rejects a bare dynamic `String` passed to `sqlx::query(...)` —
  a `VACUUM INTO '<dynamic path>'` string needs `sqlx::AssertSqlSafe(...)`, the documented 0.9
  audit escape hatch, NOT a bound parameter (bind params aren't valid in the `VACUUM INTO`
  filename position across driver versions). Safe here specifically because the interpolated
  value is a server-operator-supplied CLI path (never network-derived) and is single-quote-escaped
  (`.replace('\'', "''")`) before interpolation — re-verify both conditions still hold if this
  code is ever reused somewhere the input could be less trusted.
- `cargo fmt` with a path argument still reformats the WHOLE crate if not scoped correctly,
  leaving unrelated drift across modules the change never touched. Use `cargo fmt --check` first,
  or scope explicitly, and diff before committing.
- `restore_backup`'s destination writes are a stage-then-swap, not an in-place write: the db
  copies to `<db_path>.restore-tmp` then a single `rename` swaps it in (rename atomically replaces
  an existing FILE on all three target OSes); the assets tree copies to
  `<assets_dir>.restore-tmp`, the live `assets_dir` renames out to `<assets_dir>.restore-old`
  (directory rename does NOT replace a non-empty destination on any target OS, hence the two-step
  swap), the staged tree renames into `assets_dir`, then `.restore-old` is removed. A failure at
  any point leaves `restore_backup::db_path` either fully pre-restore or fully post-restore, and independently
  leaves `assets_dir` either fully pre-restore or fully post-restore — worst case
  (crash between the two directory renames) parks the old tree at `.restore-old`, which the next
  restore attempt clears before staging. No `--force`-only special case: both paths use the
  staging protocol regardless of `force`, since without `force` the pre-restore-destination-empty
  gate has already run. The db swap and the assets swap are two INDEPENDENT atomic operations,
  not one joint transaction — the db rename completes in full before the assets copy/swap starts,
  so a crash in that window pairs a new db with old (or momentarily absent) assets; recovery is
  re-running `restore_backup` with `force` (the db swap already completed, so a force-less retry
  would refuse on the now-existing `restore_backup::db_path`).
- The CLI backup mode (`create_backup` invoked directly by `main::run_backup`, cross-process,
  no live server) still has NO write-quiesce — its assets-copy is not transactionally coupled to
  the `VACUUM INTO` snapshot, so a CLI backup racing an external process's in-flight asset REPLACE
  can capture updated metadata with pre-replace bytes for a brief window
  ([[commit-db-row-before-swapping-file]]). The in-server `POST /api/admin/backup` route closes
  this for THAT invocation path via `write_barrier` (see Key files & seams / Hard invariants
  above) — the residual gap is CLI-mode-only and inherent to backing up while a separate process
  writes assets outside the barrier's reach.
- Per-world export/import ships as a SEPARATE surface from `backup`/`restore_backup` — not
  whole-server snapshot/restore, and not gated the same way. BOTH `POST /api/worlds/{id}/export`
  and `POST /api/worlds/import` are server-admin-only (`AdminUser`) — export is not GM-gated
  because `export_world_rows` selects every `documents` row verbatim with no `gm_role`-based
  redaction, which would let a world's own GM read whisper content the live API denies them;
  import is admin-only for the separate reason that it's a bulk multi-table insert bypassing every
  capability/schema/OCC gate the live write paths enforce — more privileged than ordinary world
  CREATION, which is open to any authenticated user, not admin-gated. World id
  is preserved verbatim on import; a colliding id refuses cleanly before any row is written.
  `users(id)` references export as portable usernames (the source server's `users` table itself is
  never exported) — resolved back to a target-local id, or NULL/row-drop for the two `NOT NULL`
  user columns with no `SET NULL` degradation (`world_members.user_id`/`explored_fog.user_id`),
  only at import time.

## Pointers

- **Generated API** — `/api/rust/shadowcat/config/`, `/api/rust/shadowcat/db/`,
  `/api/rust/shadowcat/backup/` (rustdoc, private items included); the `main` module's own doc
  comment is on the crate root, `/api/rust/shadowcat/` (no `main` module has its own generated
  page — it's a binary entry point, not a documented public item). Produce with `pnpm build:all`.
- This subsystem is classified as file I/O + one SQL statement risk, not the
  security/concurrency/determinism risk class that requires independent review.
- Relationships: `graphify query "config cli main backup restore server bootstrap"`.
- Data-layer side (what `create_backup::db_path`/`Config.assets_dir` ultimately point at): [[shadowcat-codebase-assets]],
  [[shadowcat-codebase-documents-permissions]] (`SqliteRepository`, `src/server/src/data/`).
