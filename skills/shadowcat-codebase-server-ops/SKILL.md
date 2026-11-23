---
name: shadowcat-codebase-server-ops
description: "Use when touching Shadowcat's server bootstrap/config/CLI/deployment surface: the `main` module (entry point, early one-shot CLI branches), the `config` module (`Cli`/`Config` layering: CLI flag > SHADOWCAT_* env > TOML > default), the `db` module (the shared `connect_pool` single-writer SqlitePool bootstrap plus `open_read_only_pool`'s dedicated read-only bootstrap, every pool-opening site in the crate calls one of the two), the `backup` module (whole-server VACUUM-INTO backup/restore, the in-server backup list and staged restore), the `trash` module (recoverable deletion), the `portmap` module (router port forwarding) or `onboarding_enabled`. Covers the single-binary deployment story, not any one data/document subsystem. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Server Bootstrap, Config, and Backup/Restore

Orientation for the parts of the server crate that exist ABOVE any one data subsystem: how the
binary starts, how configuration is resolved, and how a deployment's data is snapshotted/restored.

## Purpose

`main` is the single entry point for the `shadowcat` binary — normal server startup AND the
one-shot `--backup-to`/`--restore-from` CLI modes share it, mutually exclusive with each other and
with serving. `config` resolves the effective `Config` from four layered sources. `backup`
is a pure-I/O module (no `AppState`/`SqliteRepository` dependency) providing whole-server backup
and restore, driven by the CLI and by the admin routes. `trash` holds every server-side deletion
and `portmap` asks a home router to forward the listening port.

## Key files & seams

Per-module entries for config and Cli, the http router and serve, main, the db helpers, backup and its catalog, staged restore, the trash, portmap, world_bundle, audio_monitor and the admin routes, with the seams between them. Read references/key-files-and-seams.md before editing any of those areas or when a task names one of them.

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
- **Two backup and restore surfaces.** The CLI one-shot mode (`--backup-to`/`--restore-from`,
  cross-process, no running server) and the in-server admin routes (`POST /api/admin/backup`, the
  `http::backups` list/prune/delete/restore routes). A cross-process CLI invocation cannot reach
  the live process's `write_barrier` to quiesce concurrent asset writes; the in-server route can,
  so anything needing a write-quiesced backup uses the admin route. An in-server restore never
  swaps files under the open pool: the route stages `restore-pending.json` and stops the server,
  and `backup::apply_pending_restore` applies it at the next start, before the database opens.
- **Recoverable deletion**: server production code removes files through `trash::Trash::discard`
  (or `discard_sync`), never a raw remove; `AppState.trash` carries the one `Trash`. Backups, the
  restore staging leftovers and deleted assets all move into it.
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
- **A restore never runs against an open database pool** — `restore_backup` never starts the
  server, and the in-server path applies the staged restore before `SqliteRepository::connect`
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
  swap), the staged tree renames into `assets_dir`, then the db rename is the LAST, single step.
  If the db rename fails the assets swap is undone by two renames, so on an error return the live
  db and assets are both the backup's or both what they were. The replaced `.restore-old` tree
  moves into the trash only after the db rename succeeded (a failure to trash it is a warning,
  not a failed restore), and every staging leftover moves into the trash too. Only a crash
  between the final renames can park `.restore-old`; the next restore clears it before staging.
  No `--force`-only special case: both paths use the staging protocol regardless of `force`.
- The CLI backup mode (`create_backup` invoked directly by `main::run_backup`, cross-process,
  no live server) still has NO write-quiesce — its assets-copy is not transactionally coupled to
  the `VACUUM INTO` snapshot, so a CLI backup racing an external process's in-flight asset REPLACE
  can capture updated metadata with pre-replace bytes for a brief window
  ([[commit-db-row-before-swapping-file]]). The in-server `POST /api/admin/backup` route closes
  this for THAT invocation path via `write_barrier` (see Key files & seams in
  references/key-files-and-seams-02-audio-db-backup-bundle.md and Hard invariants above) — the residual gap is CLI-mode-only and inherent to backing up while a separate process
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

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | The Key files & seams section: per-module entries for server ops | Editing bootstrap, config, db, backup/restore, world_bundle, audio_monitor or admin routes |
