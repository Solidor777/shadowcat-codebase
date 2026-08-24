---
name: shadowcat-codebase-assets
description: "Use when touching Shadowcat assets: upload/replace/serve, the asset store, ETag/version revalidation, upload rate limits, out-of-band AssetChanged broadcasts, or the assets UI module. Covers src/server/src/data/asset.rs + src/server/src/http/assets.rs + src/modules/assets. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Assets

Orientation for asset upload/replace/serving and the client asset panel.

## Purpose

Assets are uploaded, stored on disk, and served over HTTP with ETag revalidation. Each asset is
referenced by a **stable UUID** from first upload (moving/renaming never breaks links); its
`version` bumps on every replace and backs both the ETag and the resync source of truth. v1 stores
and serves uploads unconverted (the conversion pipeline is deferred).

## Key files & seams

- `data::asset` — `Asset { version, … }`; `version` is bumped on every replace and
  backs the ETag + the resync source of truth. `commit_staged_asset`/`create_asset_from_bytes` are
  the shared asset-commit path (see the Hard Invariants entry below).
- `http::assets`:
  - `upload(...)` — streams to disk; `UploadRateLimiter::{check,refund}` enforces tiered per-minute
    limits (configured per role); `detect_image_type`. **The non-GM tier is unreachable from this
    route** — `require_gm` gates it (below), so only the GM tier is ever selected here.
  - `serve(...)` — `GET /api/assets/{uuid}`, membership-gated; ETag = `"{id}-{version}"`;
    `If-None-Match` is an RFC 7232 comma-separated list → 304 if our ETag appears anywhere in it.
  - `replace(...)` — swaps bytes, keeping the stable UUID; broadcasts `AssetChanged`.
- `ws::protocol` — `ServerMsg::AssetChanged { uuid, op: AssetOp, version: i64 }`, broadcast
  **out-of-band** via `Room::broadcast_aux` (not in the per-world event sequence). `version` is
  REQUIRED for both ops: the bumped, authoritative value for `Replaced`, and the version the row
  held immediately before removal for `Deleted` — a real ordering token in both cases, so a
  listing snapshot straddling a delete can be compared against it.
- **`@shadowcat/module-assets`** (`Assets` component) — the client asset panel (upload/list/replace).
- `AssetResolver` (`src/client/core/src/assets.ts`) — client-side cache-bust resolver. Its
  private `adoptVersion` helper is the single gate both `onAssetChanged` and `reconcile` route
  through, updating the cache-busting revision AND the deleted marker together — but its
  rejection strictness is ASYMMETRIC, keyed on `AssetResolver.adoptVersion.isDeleted`: a delete transition adopts at
  `version >= current` (equality is the ordinary case, since deletion never bumps the version
  column, and the delete notice is authoritative and must be honored), while every other
  adoption — always via `reconcile`, which never itself carries a delete signal — requires
  `version > current` strictly, because a reconcile snapshot may predate a delete already
  adopted at that same version and must not resurrect it. `reconcile(assets: Asset[])` re-syncs
  from any touchpoint that already fetches full `Asset` records (`Assets.svelte`'s `reload`,
  `AssetPicker.svelte`, `VisualKindEditor.svelte`'s `refreshAssets`), closing the gap for an
  `AssetChanged` frame this connection never received at all — including a delete: since a
  listing snapshot captured before a delete carries the SAME version the delete broadcast does,
  the strict `reconcile` branch rejects the stale reconcile rather than resurrecting the asset.

## Hard invariants

- **All three mutation routes are GM-ONLY, with no owner exception.** `upload`, `replace`, and
  `delete` each call `require_gm` (`http::routes`), which returns `Forbidden` unless
  `ctx.world_role == WorldRole::Gm`; a server admin reaches GM via `permission_context`
  (`data::sqlite`, `server_role == Admin ⇒ world_role: Gm`, before any membership lookup).
  `Asset.created_by` (`data::asset`) records the uploader but is **never read by any authz
  check** — it is provenance, not authority, so uploading a file grants no subsequent rights over
  it and there is no per-asset permission check. `serve` is the odd one out: membership-gated, not
  GM-gated. Treat any "owner"-gated language about asset mutation as stale.
- **`replace` commits the source-of-truth/cache-key row BEFORE swapping the file** (row-first).
  The inverse strands new bytes under a stale ETag/version — a silent 304 of changed content;
  `replace` has prior bytes to preserve and an existing ETag to protect, so the failure that
  matters most is a stale-but-served file, never an orphan row
  [[commit-db-row-before-swapping-file]]. **`upload` (create) inverts this to file-first**: rename
  the staged temp file into place, THEN insert the row. A create has no prior bytes and no
  existing ETag to strand — the failure that matters is an orphan DB row (a `GET` that 500s
  forever, since no bytes were ever written under that id), while an orphan FILE with no row is
  harmless dead disk space. Two-store writes (file + metadata row) without a spanning txn always
  order around whichever failure mode is unrecoverable for that operation — row-first for
  replace, file-first for create.
- **`upload`/`replace`/`delete` all hold a read permit on `AppState.write_barrier` around their
  commit+rename/commit+unlink critical section** (`http::assets`) — never around the earlier
  network-bound multipart stream, which has no timeout (`DefaultBodyLimit::disable()` on these
  routes) and would otherwise let a slow uploader hold the write-preferring
  `tokio::sync::RwLock`'s read side open indefinitely. `POST /api/admin/backup` holds the write
  side across its `VACUUM INTO` + assets copy, so no asset write's row-commit+file-op pair can
  interleave with an in-server backup snapshot (`shadowcat-codebase-server-ops`).
- **`data::asset::create_asset_from_bytes`/`commit_staged_asset` are the shared commit path**
  both `http::assets::upload` and the chat link-preview/oEmbed background pipeline
  (`chat::post_publish`, see `shadowcat-codebase-chat`'s post-publish section) use.
  `commit_staged_asset` is the common file-first-then-row tail (rename the already-staged temp
  file into place, THEN insert the metadata row — same ordering `upload` follows, see the
  row/file-ordering entry above); `create_asset_from_bytes` wraps it for a caller with an
  already-in-memory byte buffer (the small, capped background image fetch), staging its own temp
  file before calling `commit_staged_asset`, while `upload`'s own arbitrarily-large GM uploads
  stream straight to disk via `store_streamed` and call `commit_staged_asset` directly, never
  buffering the whole body. Both callers' resulting `Asset` rows are committed through
  byte-for-byte the same ordering logic. **`created_by: None`** is the convention for a
  server-authored asset — `Asset.created_by` carries a live `REFERENCES users(id)` foreign key and
  no real user account backs a server-fetched image, so `chat::post_publish`'s
  `resolve_preview_image`/`resolve_thumbnail_asset` both pass `created_by: None` through
  `NewAssetBytes`, the same generalization `Asset.created_by`'s own doc comment already covers for
  a deleted uploader account. **`write_barrier` now has a second reachable caller class**: this
  background pipeline holds the same read permit around its own asset commit that `upload`/
  `replace`/`delete` hold around theirs — the first asset-commit path reachable from outside a
  direct HTTP request, and it must join the same exclusion or an in-server backup's file-copy
  could race a half-committed asset.
- **ETag == `"{id}-{version}"`**; `version` is the single monotonic cache key. Stable UUID identity
  means a replace keeps the id and only bumps the version, so links survive.
- **Upload limits are tiered + configurable** (GM ≈ 2× regular); uploads stream to disk, not buffered.
- **World deletion removes the whole `<assets_path>/<world_id>/` directory AFTER the row
  transaction commits** (`http::routes::delete_world` — the delete convention: rows first, files second;
  a crash orphans files on disk, never a live world missing its files), holding the write
  barrier's read side across the commit + `remove_dir_all` pair like every other asset file-op.
  Asset ROWS go with the `assets.world_id` FK cascade; the dir sweep also collects any orphaned
  `*.tmp` staging residue.

## Gotchas

- **`AssetChanged` is out-of-band** (`broadcast_aux`), so it is not gap-recovered by the event
  RingBuffer — a plain reconnect or a resync (`replay` against the ring/log) never redelivers a
  missed frame. This is self-healed opportunistically rather than avoided: `AssetResolver.reconcile`
  re-syncs any stale uuid the next time a listing (e.g. opening the assets panel) fetches the
  asset's true `version` — not a background poll, a repair path reachable through ordinary use.
- A `replace` rate-limited mid-flight should `refund` the limiter slot.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/asset/`, `/api/rust/shadowcat/http/assets/`
  (rustdoc, private items included), `/api/ts/modules/_shadowcat_module-assets.html` (TypeDoc).
  Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §4 (asset pipeline deferral) + §6 (stable asset identity).
- Relationships:
  `graphify query "asset upload store ETag version AssetChanged streaming limit"`.
- History: [[m8b-assets]], [[commit-db-row-before-swapping-file]].
