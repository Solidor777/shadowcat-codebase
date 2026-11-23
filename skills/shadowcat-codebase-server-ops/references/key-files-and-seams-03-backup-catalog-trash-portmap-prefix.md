Part of the shadowcat-codebase-server-ops skill; read it when touching the in-server backup list and staged restore, the trash, router port forwarding, the route prefix or `onboarding_enabled`. Part 03 of 03 of "Server ops: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-02-audio-db-backup-bundle.md.

- **Backup catalog** (`backup::catalog`, routes in `http::backups`, all `AdminUser`): `BackupEntry`
  per directory under `Config::backups_path_for`, `BackupRetention` (config `backup_keep_last` /
  `backup_keep_days`), `list_backups`, `plan_prune`, `prune`. An id from a path reaches the
  filesystem only through `resolve_backup` (a well-formed-id allowlist), never a raw join. Routes:
  `GET /api/admin/backups`, `POST .../prune`, `DELETE .../{id}` (moves into the trash),
  `POST .../{id}/restore`, `DELETE .../restore-failed`. Pruning and delete go through `Trash`.
- **Staged restore** (`http::backups::restore_from_backup` -> `backup::apply_pending_restore`):
  the route writes a `BackupKind` pre-restore backup of the current state, then
  `restore-pending.json` (`catalog::RestorePending`) beside the database, then
  `WsState::trigger_shutdown`. The server does not restart itself. The next start runs
  `main::apply_staged_restore` BEFORE the pool opens (a live connection cannot survive a swapped
  database file; Windows refuses the rename). It restores with `force = true`, discards the
  marker into the trash (so a restart never re-applies it), and on any failure writes
  `restore-failed.json` (`RestoreFailed`, listed in `BackupListing.restore_failed`) and starts on
  the data it had. A successful restore clears an older failure marker. The CLI
  `--restore-from` path is no longer the only restore path.
- **Trash** (`trash`, routes in `http::trash`, admin-only): production code removes a file or
  directory through `Trash::discard` / `Trash::discard_sync`, never a raw
  standard-library remove call. Each entry is a `<trashed_at_ms>-<uuid>/` directory holding
  `manifest.json` and the discarded item, built under a `.staging-` name and renamed into place last so a listing never sees
  a half-built entry. `TrashRetention` is `Days`, `Never` or `Disabled` (`Disabled` removes at
  once and creates no directory); `Config::trash_path` and `Trash::from_config` resolve it;
  `spawn_retention_sweep` runs hourly. An id from a path is parsed by `EntryId`, a positive
  allowlist regex. Routes: `GET /api/admin/trash`, `POST .../empty`, `DELETE .../{entry_id}`.
  `AppState.trash` is `Arc<Trash>`; every function that discards takes `&Trash`, so a new
  deleting call site needs the state threaded to it. Recovery is manual (move the item back to the manifest's original path).
- **Router port forwarding** (`portmap`, route `http::port_forward`, `GET`/`PUT
  /api/admin/portmap`, `AdminUser` only because the status carries the external address):
  `PortMapRuntime` (`AppState.portmap`) holds at most one mapping, in `Shared::slot`, written with
  no await after the router's grant so aborting the task leaves the slot equal to what the router
  holds and `shutdown` deletes exactly that. The enable decision is the one function
  `runtime::effective_enabled` (the `port_forward` config key when set, else the stored
  `STORED_TOGGLE_KEY` setting); the runtime, the route and the status all call it. The ladder is
  NAT-PMP, PCP, then UPnP IGD (`igd::IgdGateway`); UPnP endpoints must be the discovering device
  on a LAN address (`soap::is_lan_address`). A permanent lease (`lease_secs` 0) is still deleted at
  shutdown. The module denies `unwrap`, `expect`, `panic!`, slice indexing and unchecked
  arithmetic outside tests because it parses unauthenticated LAN bytes; adding one is a defect.
- **Route prefix** (`Config.route_prefix`): see the realtime-sync skill for the router nesting
  and the client `apiPath`. Config surface: set it the same four-layer way as any other key.
- **`onboarding_enabled`**: `Config.onboarding_enabled` (default true, `Cli.onboarding_enabled`
  overrides) is published as `onboarding_enabled` in the `/api/config` response
  (`http::routes`); clients read it from there, never from their own storage.
