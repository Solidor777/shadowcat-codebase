Part of the shadowcat-codebase-server-ops skill; read it before editing server bootstrap, config, db pool options, backup/restore, world bundles, the audio monitor or the admin routes.

# Server ops: key files and seams

Per-module entries for config and Cli, the http router and serve, main, the db helpers, backup, world_bundle, audio_monitor and the admin routes, with the seams between them.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-config-router-serve-admin.md](key-files-and-seams-01-config-router-serve-admin.md) | Key files & seams: `config` and `Cli`; `Config.behind_proxy`; `egress_window_secs`; `db::database_file`; `logs_path`; `http::router`; `main`; `serve`; `create_world`; the user password admin route | Editing bootstrap, config, CLI flags, the router, the serve loop, world creation or user admin routes |
| [key-files-and-seams-02-audio-db-backup-bundle.md](key-files-and-seams-02-audio-db-backup-bundle.md) | Key files & seams: `audio_monitor`; `db` connect options; `backup`; `POST /api/admin/backup`; `world_bundle` | Editing the audio monitor, db pool options, backup and restore, the admin backup route or world bundles |
| [key-files-and-seams-03-backup-catalog-trash-portmap-prefix.md](key-files-and-seams-03-backup-catalog-trash-portmap-prefix.md) | Key files & seams: the backup catalog; staged restore; the trash; router port forwarding; the route prefix; `onboarding_enabled` | Editing the backup list, in-server restore, `Trash`, `PortMapRuntime`, the route prefix or the onboarding flag |
