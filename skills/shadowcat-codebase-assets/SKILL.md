---
name: shadowcat-codebase-assets
description: "Use when touching Shadowcat assets: upload (single-shot or chunked sessions), the WebP conversion pipeline + retained originals + thumb/preview derivatives, explicit/derived tags, `asset_folder` documents, the query/PATCH/bulk/reconvert/original routes, serve/replace/delete, ETag/version revalidation, upload rate limits, out-of-band AssetChanged broadcasts (every `AssetOp`), the client asset REST + chunked-upload client + AssetResolver, or the assets UI module. Covers src/server/src/data/asset{.rs,/} + src/server/src/data/sqlite/assets.rs + src/server/src/http/assets{.rs,/} + src/client/core/src/asset* + src/modules/assets. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Assets

Orientation for the asset pipeline (upload → conversion → commit), the asset store and its
metadata, the query/mutation routes, serving, and the client asset seams.

## Purpose

Assets are uploaded, converted (images → WebP, original retained beside the canonical when
`Config.retain_originals`, thumb/preview derivatives generated), stored on disk, and served over
HTTP with ETag revalidation. Each asset is referenced by a **stable UUID** from first upload
(moving/renaming/replacing/reconverting never breaks links); its `version` bumps on every byte
swap (replace, reconvert) and backs both the ETag and the resync source of truth. Placement
(name, `folder_id`, tags) changes never bump the version. Assets are filed under `asset_folder`
documents (ordinary engine documents; `None` = world root) and carry explicit GM tags plus
pipeline-derived tags.

## Key files & seams

- `data::asset` — `Asset { …, folder_id, tags, derived_tags, meta: AssetMeta }` (`AssetMeta` is
  `#[serde(flatten)]`ed: `width/height/has_alpha/animated/original_content_type/
  original_byte_size/original_retained/conversion_note`). `Provenance { Uploaded, LinkPreview }`.
  The shared commit tail: `process_staged_blocking` (runs `process::process_staged` on the
  blocking pool, removes the staged stem on failure) → `commit_staged_asset(repo, tmp, final,
  asset, derived_tags)` (moves canonical + siblings, inserts the row, writes both tag sets).
  `move_asset_files`/`remove_asset_files` are the only file-set movers — every path that touches
  a canonical touches its siblings through them. `create_asset_from_bytes` wraps stage + process
  + commit for the in-memory link-preview caller.
- `data::asset::process` — BLOCKING image work. `process_staged(staged, arrived_type,
  arrived_size, retain)` → `Processed { content_type, byte_size, meta, converted }`. Constants
  `THUMB_PX`/`PREVIEW_PX`/`LOSSY_QUALITY`, `MAX_DECODE_AXIS_PX`/`MAX_DECODE_ALLOC_BYTES` (the
  bound every decode AND the animation probe run under), `WEBP_CONTENT_TYPE`, `SIBLING_SUFFIXES`
  (`.orig`, `.thumb.webp`, `.preview.webp` — the single statement of the sibling set;
  `sibling_paths`, `derivative_path`, `original_path` derive from it), `write_derivatives`
  (regenerate-on-demand), `Variant`.
- `data::asset::tags` — `derive(DeriveInput { content_type, meta, folder_names, provenance })`
  → sorted derived set: kind ("image" + subtype, or "other"), "animated"/"gif-animated",
  "square", "large" (either axis ≥ `LARGE_AXIS_PX` = 2048), "transparent", every ancestor
  folder name, and the provenance tag (`UPLOADED_TAG` | `LINK_PREVIEW_TAG`).
  `provenance_of(derived)` recovers provenance from a stored set. `normalize_tags` (+
  `MAX_TAG_CHARS`/`MAX_TAGS`) is the one rule for GM-set tags, applied by the routes
  (`uploads::validate_tags`) and by bundle import alike.
- `data::asset::query` — the repo's vocabulary: `AssetFilter { folder: Option<FolderFilter>,
  tags, kind: Option<AssetKind>, name }`, `AssetSort { Name, Created, Size }`, `AssetCursor`, `sort_key_of`.
- `data::sqlite::assets` (sibling `impl SqliteRepository`) — `insert_asset`, `get_asset`,
  `list_assets_by_world`, `query_assets` (QueryBuilder; recursive CTE for folder subtrees;
  keyset `(sort_key, id) >`), `replace_asset_bytes(…, meta)`, `set_asset_tags(id, explicit,
  derived)`, `update_asset_placement`, `bulk_update_assets`, `refresh_derived_tags`
  (+ `refresh_derived_tags_tx`), `refresh_derived_tags_for_folder_subtree`,
  `folder_ancestor_names` (+ `folder_ancestor_names_of`), `assets_in_folder_subtree`
  (+ `assets_in_folder_subtree_of`), `check_asset_folder_parent`,
  `reparent_assets_of_deleted_folder`, `fill_tags`.
- `data::engine::asset_folder` — `AssetFolderEngine { sort }`; folder name = `Document.name`,
  parent = `Document.parent_id`, `ASSET_FOLDER_DOC_TYPE`.
- `http::assets` — `upload` (single-shot multipart), `serve` (`?variant=thumb|preview`),
  `replace`, `delete`, `detect_image_type`, `label_content_type`, `UploadRateLimiter`,
  `commit_replacement` (the row-first byte-swap tail `replace` and `mutate::reconvert` share),
  `delete_asset_files_and_row` (the delete tail `delete` and the folder purge share).
  - `http::assets::uploads` — chunked sessions: `CHUNK_SIZE` (8 MiB), `SESSION_IDLE_MS`,
    `UploadSession::accept_chunk`/`finish_chunk`, `UploadSessions` (`AppState.uploads`),
    `spawn_sweeper`, routes `create_session`/`put_chunk`/`complete_session`/`abort_session`,
    shared validators `validate_tags`/`validate_folder`.
  - `http::assets::query` — `GET /api/worlds/{world}/assets`: bare `Asset[]` with NO params,
    `AssetPage { items, next_cursor }` with any; `compile_regex` (≤256 bytes, 1 MiB size/DFA
    caps), `encode_cursor`/`decode_cursor`.
  - `http::assets::mutate` — `patch` (`PATCH /api/assets/{uuid}`), `bulk`
    (`POST /api/worlds/{world}/assets/bulk`), `original` (`GET …/original`, GM), `reconvert`
    (`POST …/reconvert`, GM), `delete_folder` (`DELETE /api/asset-folders/{id}?assets=reparent|delete`).
- `ws::protocol` — `ServerMsg::AssetChanged { uuid, op: AssetOp, version }`, broadcast
  **out-of-band** via `Room::broadcast_aux`. `AssetOp` has four variants — `AssetOp::Created`,
  `AssetOp::Replaced`, `AssetOp::Moved`, `AssetOp::Deleted` — and `version` is always a real
  ordering token: `1` for `Created`, bumped for `Replaced`, unchanged for `Moved`, the
  pre-removal value for `Deleted`.
- `Config.retain_originals` (default `true`; CLI `--retain-originals`, env
  SHADOWCAT_RETAIN_ORIGINALS) — host-level disk policy, forwarded into `NewAssetBytes`/`PostPublishDeps`/`FetchDeps`.
- Client core (`src/client/core/src/`): `asset-rest.ts` (`listAssets`, `uploadAsset`,
  `replaceAsset`, `deleteAsset`, `queryAssets`, `patchAsset`, `bulkPatchAssets`,
  `reconvertAsset`, `originalUrl`, `restErrorText`), `asset-upload.ts` (`startChunkedUpload`,
  `CHUNK_THRESHOLD_BYTES`, `ChunkedUploadError` — whose `partial` carries the asset a
  single-shot upload created when only the follow-up placement failed, so a caller repairs it
  instead of re-uploading), `assets.ts` (`AssetResolver` — `url(uuid,
  variant?)`, `onAssetChanged`, `reconcile`, `onListingInvalidated`; `AssetOp`,
  `AssetVariant`, `AssetChangedNotice`). `@shadowcat/types` re-exports the ts-rs `Asset`,
  `AssetMeta`, `AssetOp`, `AssetPage`, `PatchAssetRequest`, `BulkAssetRequest`,
  `CreateUploadRequest`/`CreateUploadResponse`, `AssetFolderEngine`.
- **`@shadowcat/module-assets`** (`Assets` component) — the pre-browser client panel
  (upload/list/replace/delete); it consumes the widened `Asset` and notice set unchanged.

## Hard invariants

- **All mutation routes are GM-ONLY, with no owner exception** — `upload`, chunked sessions,
  `replace`, `delete`, `patch`, `bulk`, `reconvert`, `original`, `delete_folder` each go through
  `require_gm`. `serve` (and its `?variant=` form) is the only membership-gated read.
  `Asset.created_by` is provenance, never authority. A chunked session is additionally bound to
  the user who opened it (403 for anyone else).
- **Commit ordering is per operation, and every file-op moves the whole sibling set.** Create
  (`commit_staged_asset`) is file-first-then-row; byte swaps (`commit_replacement`: replace,
  reconvert) are row-first-then-file [[commit-db-row-before-swapping-file]]; delete is
  row-first-then-unlink. A sibling absent at the staged stem REMOVES the stale one at the final
  stem (a pass-through replace has no `.orig`; an undecodable one has no derivatives).
- **Every commit+file-op pair holds the read side of `AppState.write_barrier`** — and never
  the network-bound stream or the CPU-bound conversion (`process_staged_blocking`, on the
  blocking pool) before it. The chunked
  `complete_session` and the link-preview pipeline join the same exclusion.
- **The bytes decide the content type.** `detect_image_type` sniffs PNG/JPEG/GIF/WebP/BMP/TIFF
  magic and SVG text (every type `process` has a branch for); a client's declared `image/*` the
  bytes disprove becomes `application/octet-stream` (`label_content_type`); a non-image
  declaration is kept as a label. Nothing is rejected for conversion reasons: SVG,
  animations, static WebP, non-images and undecodable files are stored pass-through with a
  `conversion_note`.
- **Derived tags are never client-writable and are recomputed on every commit, replace,
  reconvert, placement change, folder delete (reparent) and folder Update** — the last through
  `refresh_derived_tags_for_folder_subtree` in BOTH write paths (`apply_intent` and
  `apply_command` Update arms). An explicit tag of the same text outranks the derived copy.
- **`asset_folder` placement:** `parent_id` must be an `asset_folder` in the same scope
  (`check_asset_folder_parent`, batch-aware for a same-command parent + child; enforced on the
  `apply_intent` path — `apply_command`'s trusted replay relies on the tree already being valid
  from the original intent, like its other placement checks). `parent_id` is
  an immutable envelope path, so the tree is acyclic BY CONSTRUCTION — no cycle walk exists and
  folders cannot be re-parented after Create. Deleting a folder cascades its sub-folders
  (document invariant) and `reparent_assets_of_deleted_folder` in `delete_document_tx` moves
  each deleted folder's assets to its parent, children-first; `?assets=delete` purges them
  first through `delete_asset_files_and_row`.
- **`GET /api/worlds/{world}/assets` has two shapes**: no query parameter ⇒ bare `Asset[]`
  (the contract `listAssets`, `Assets.svelte`, `AssetPicker` and the e2e rely on); any parameter
  ⇒ `AssetPage`. `queryAssets` always sends `limit` so it never hits the bare form. The regex is
  applied AFTER the SQL filters over at most 10 SQL pages per call; `next_cursor` is the last row
  EXAMINED, so following cursors never skips a row.
- **Chunk protocol:** fixed `CHUNK_SIZE`; `PUT …/{offset}` accepts exactly `received` (409
  otherwise — a retry of a LOST chunk carries that offset, a duplicate does not), a concurrent
  PUT on the same session is 409 (busy), overflow aborts the session (413), `complete_session`
  requires `received == byte_size` and removes the session before processing. Every session
  call re-runs `require_gm` live (`owned_session`), so a demotion mid-session takes effect at
  the next chunk. `complete_session` re-validates `folder_id` — a folder deleted during the
  session lands the asset at the world root rather than failing the upload. Sessions are
  in-memory only.
- **`serve` never lets a browser render a stored type as a document**: `X-Content-Type-Options:
  nosniff` always, and `Content-Disposition: inline` only for the raster types in
  `INLINE_CONTENT_TYPES`; everything else — SVG included — is `attachment` (`<img>` embedding
  is unaffected). A GM-declared pass-through type is stored verbatim but cannot execute.
- **Every decode is bounded** (`decode_limits`: axis ≤ `MAX_DECODE_AXIS_PX`, allocation ≤
  `MAX_DECODE_ALLOC_BYTES`) — on the `ImageReader` sites AND on `is_animated`'s raw
  `GifDecoder`, which starts with `Limits::no_limits()` and would otherwise allocate a
  header-sized canvas before reading a pixel. The chat link-preview path reaches this decoder
  without elevated privilege, so the bound is load-bearing, not defense-in-depth.
- **ETag == `"{id}-{version}"`** for the canonical AND its derivatives (a derivative is
  regenerated whenever the canonical's version changes, so the version keys it).
- **World deletion removes the whole `<assets_path>/<world_id>/` directory AFTER the row
  transaction commits** (`http::routes::delete_world` — rows first, files second; a crash
  orphans files on disk, never a live world missing its files), holding the write barrier's
  read side across the commit + `remove_dir_all` pair like every other asset file-op. Asset
  rows, tag rows and folder documents go with the FK cascades; the sweep also collects every
  sibling and any `*.tmp` staging residue.
- **The world bundle carries the sibling set**: `assets/<id>` canonical plus `assets/<id><suffix>`
  for each `SIBLING_SUFFIXES` member present; any other suffix is `Malformed`. Import clears
  `original_retained` when no `.orig` travelled. `ExportedAssetRow`'s new fields are
  `#[serde(default)]` and `AssetMeta` is `#[serde(default)]` at the struct level (a
  field-level default on a flattened struct does not default its missing keys), so a
  pre-pipeline bundle still imports; imported explicit tags pass `normalize_tags`.

## Gotchas

- **`AssetChanged` is out-of-band** (`broadcast_aux`), never replayed on resync;
  `AssetResolver.reconcile` repairs from any full listing. `Created`/`Moved` never change a
  URL — they invalidate LISTINGS (`onListingInvalidated`); `Replaced` changes bytes (rev bump);
  `Deleted` resolves to the placeholder. The upload's own `created` frame precedes any later
  frame a test waits for on a socket opened before the upload.
- The schema is the single pre-ship baseline `0001_init.sql`, edited in place; there is no
  backfill.
- `AssetMeta::unprocessed` is the pass-through shape (`process::pass_through` builds on it);
  tests use it for seeded rows.
- A rate-limited or failed session/upload refunds its slot (`UploadRateLimiter::refund`); the
  sweeper refunds idle sessions.
- Folder MOVE has no route: `parent_id` is immutable (see invariants). A change that needs
  folder re-parenting must add a server-authored move (or delete + recreate with asset
  reparenting); no client Update can do it.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/asset/`, `/api/rust/shadowcat/http/assets/`
  (rustdoc, private items included), `/api/ts/modules/_shadowcat_core.html` (TypeDoc:
  `asset-rest`, `asset-upload`, `assets`). Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §4 (asset pipeline) + §6 (stable asset identity).
- Relationships:
  `graphify query "asset upload process derivatives tags folder query AssetChanged"`.
- History: [[m8b-assets]], [[commit-db-row-before-swapping-file]].
