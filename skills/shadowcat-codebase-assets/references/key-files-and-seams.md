# Assets: key files and seams

Part of the shadowcat-codebase-assets skill; read it when changing or consuming any asset file, route or client seam. Mentions of the Hard invariants, the Gotchas or the Purpose live in SKILL.md.

## Key files & seams

- `data::asset` — `Asset { …, folder_id, tags, derived_tags, meta: AssetMeta }` (`AssetMeta` is
  `#[serde(flatten)]`ed: `width/height/has_alpha/animated/original_content_type/
  original_byte_size/original_retained/conversion_note`). `Provenance { Uploaded, LinkPreview,
  ChatImage }` — `ChatImage` marks an asset created by `chat::post_publish::resolve_inline_image`
  from a Markdown/HTML image URL in a chat message (see `shadowcat-codebase-chat`'s
  `chat::body::compose_message`/`InlineImage` job); a `[[asset:<uuid>|alt]]` span instead
  references an EXISTING asset directly and creates nothing, so it carries no provenance tag of
  its own.
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
  (`.orig`, `.thumb.webp`, `.preview.webp`, `.sheet.webp`, `.sheet.json` — the single statement
  of the sibling set; `sibling_paths`, `derivative_path`, `original_path` derive from it),
  `write_derivatives` (regenerate-on-demand), `Variant`. For an animated source
  (`is_animated`), `process_staged` additionally derives a grid sheet ONCE at commit/reconvert
  via `generate_grid_sheet` (never lazily, never a hard failure): `.sheet.webp` (frames tiled
  near-square, downscaled past `SHEET_MAX_PX`=4096, lossless) + `.sheet.json`, with the
  geometry/timings recorded on `AssetMeta.sheet` (`SheetMeta`) as flat `sheet_*` columns
  (`sheet_rows` NULL ⇔ `None`). `sheet_path` exposes the sheet sibling's path; `serve` gains
  `?variant=sheet` (404 when absent — never canonical-fallback, never regenerate) and
  `GET /api/assets/{uuid}/meta` (membership-gated metadata without bytes). See
  `shadowcat-codebase-vfx` for the consumers.
- `data::asset::process::audio` — the audio sibling of the pipeline above, dispatched from the
  same `process_staged`: `symphonia` probe+decode → `rubato` resample to 48kHz (if needed) →
  Opus VBR encode → Ogg and/or WebM mux (`AudioContainers`, selected at import). **The
  canonical asset is NEVER swapped to Opus** — the original stays canonical. **Unlike
  `Variant::Thumb`/`Variant::Preview`, the `.opus.ogg`/`.opus.webm` siblings are explicitly NOT
  `Variant`s and are never regenerated on serve** — a missing one 404s rather than re-transcoding.
  `AssetMeta.duration_ms`/`sample_rate` (both `Option<i64>`) are populated by this pipeline. See
  `shadowcat-codebase-audio` for the full transcode/mixer picture.
- `data::asset::tags` — `derive(DeriveInput { content_type, meta, folder_names, provenance })`
  → sorted derived set: kind ("image" + subtype, or "other"), "animated"/"gif-animated",
  "square", "large" (either axis ≥ `LARGE_AXIS_PX` = 2048), "transparent", every ancestor
  folder name, and the provenance tag (`UPLOADED_TAG` | `LINK_PREVIEW_TAG` | `CHAT_IMAGE_TAG`).
  `provenance_of(derived: &[String]) -> Provenance` (single-arg — recovers provenance from the
  DERIVED tag set alone, never the explicit GM-set tags) recovers provenance from a stored set.
  `normalize_tags` (+
  `MAX_TAG_CHARS`/`MAX_TAGS`) is the one rule for GM-set tags, applied by the routes
  (`uploads::validate_tags`) and by bundle import alike.
- `data::asset::query` — the repo's vocabulary: `AssetFilter { folder: Option<FolderFilter>,
  tags, kind: Option<AssetKind>, query: Option<String> }` (`query` is a
  full-text query over the display name AND every explicit/derived tag, not a name substring; see
  `assets_fts` below; `AssetKind::Audio` is the audio counterpart of the image kinds),
  `AssetSort { Name, Created, Size }`, `AssetCursor`, `sort_key_of`.
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
- `http::assets` — `upload` (single-shot multipart), `serve` (`?variant=thumb|preview|opus|opus-webm`),
  `replace`, `delete`, `detect_image_type`, `label_content_type`, `UploadRateLimiter`,
  `commit_replacement` (the row-first byte-swap tail `replace` and `mutate::reconvert` share),
  `delete_asset_files_and_row` (the delete tail `delete` and the folder purge share).
  - `http::assets::uploads` — chunked sessions: `CHUNK_SIZE` (8 MiB), `SESSION_IDLE_MS`,
    `UploadSession::accept_chunk`/`finish_chunk`, `UploadSessions` (`AppState.uploads`),
    `spawn_sweeper`, routes `create_session`/`put_chunk`/`complete_session`/`abort_session`,
    shared validators `validate_tags`/`validate_folder`.
  - `http::assets::query` — `GET /api/worlds/{world}/assets`: bare `Asset[]` with NO params,
    `AssetPage { items, next_cursor }` with any; `AssetQuery.q: Option<String>`
    maps to `AssetFilter.query`, matched via `assets_fts` (below), NOT a substring/LIKE; `is_bare`
    checks whether `q` is absent. `compile_regex` (≤256 bytes, 1 MiB size/DFA
    caps), `encode_cursor`/`decode_cursor`.
  - `http::assets::mutate` — `patch` (`PATCH /api/assets/{uuid}`), `bulk`
    (`POST /api/worlds/{world}/assets/bulk`), `original` (`GET …/original`, GM), `reconvert`
    (`POST …/reconvert`, GM), `delete_folder` (`DELETE /api/asset-folders/{id}?assets=reparent|delete`).
- `ws::protocol` — `ServerMsg::AssetChanged { uuid, op: AssetOp, version }`, broadcast
  **out-of-band** via `Room::broadcast_aux`. `AssetOp` has four variants — `AssetOp::Created`,
  `AssetOp::Replaced`, `AssetOp::Moved`, `AssetOp::Deleted` — and `version` is always a real
  ordering token: `1` for `Created`, bumped for `Replaced`, unchanged for `Moved`, the
  pre-removal value for `Deleted`.
- **`assets_fts`** — an FTS5 virtual table (`content`, `asset_id UNINDEXED`, `world_id
  UNINDEXED`, unicode61) declared in `0001_init.sql` alongside the documents FTS tables (see
  `shadowcat-codebase-documents-permissions`'s `data::search` seam for the document-side index,
  a SEPARATE table by design — assets have no permission tiers to partition by visibility). FIVE
  triggers keep it live (named assets_fts_insert/assets_fts_update_name/assets_fts_delete/
  assets_fts_tag_insert/assets_fts_tag_delete in `0001_init.sql`): one AFTER INSERT on `assets`,
  one AFTER UPDATE OF `original_name` on `assets` (delete+reinsert), one AFTER DELETE on
  `assets`, and one each AFTER INSERT/DELETE on `asset_tags` (delete+reinsert,
  keyed off `old.asset_id` on the delete side, a safe no-op if the asset row is
  already gone). `query_assets`'s full-text branch (`AssetFilter.query`) compiles the query via
  `data::search::build_match` and joins `a.id IN (SELECT asset_id FROM assets_fts WHERE
  assets_fts MATCH ...)`; an empty/punctuation-only query short-circuits to an empty page rather
  than reaching FTS5 with a syntax error.
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
- **`@shadowcat/module-asset-browser`** (`AssetBrowser` + focused sub-components) — the GM
  browser panel: reactive `FolderTree` (create/rename/delete-dialog/drag + accessible Move-to,
  dispatching `Operation::Move` via `buildMoveOp`), `FilterBar` mapped 1:1 onto `queryAssets`
  (`FilterState.query`/`queryIsRegex` drive `AssetQuery.q` when
  not in regex mode, `nameRegex` when in it; testid `filter-query`),
  the `computeGridWindow`-virtualized multi-select `AssetGrid` (its tile track minimum is 96px,
  sized so a tile's centre stays clear of the 44px favourite star's touch target; the minimum
  follows the star, so a narrower track puts the star over the tile centre), `PreviewPane` (tags/rename/
  replace/download-original/reconvert/delete), `BulkBar`, and the sequential `UploadQueue`
  (model in `uploadQueueModel.svelte.ts` — a case-insensitive filesystem cannot hold
  `uploadQueue.svelte.ts` beside `UploadQueue.svelte`). Pick mode: the `assetPick` /
  `pickAsset` AppContext seam opens `AssetPickOverlay` (contributed into
  `shadowcat.surface:overlay`, deliberately NOT GM-gated — any member picks; the managing
  panel contribution is `gmOnly`). Replaces the retired `@shadowcat/module-assets`.
  Browser additions: the grid has no native drag (the shared drag controller drives `FolderTree`
  and `AssetGrid`, with `ROOT_DROP_ID` clearing the folder; see `shadowcat-codebase-client-shell`);
  `FolderTree` is a thin wrapper over ui-kit's `DocFolderTree` and carries a context menu that calls
  the same handlers as its buttons. `AssetList` is the list view (icon, name, `fmtBytes` size, tags;
  `computeListWindow` virtualizes it), chosen by persisted view-mode buttons; `applySelectionGesture`
  is the selection rule both views share. Favourites (`getFavorites` / `toggleFavorite`, re-read
  before each flip) are per user and live under `ui_state.modules['asset-browser']`, the module
  settings namespace; `FilterState.favoritesOnly` filters CLIENT-SIDE over the loaded pages and
  keeps paging until the list fills, so it is not an `AssetQuery` field. `UploadQueue` takes a third
  constructor argument for the progress notification; it reports per-file progress through
  `AppContext.notifyProgress`, and `PreviewPane` does the same for reconvert. `fmtBytes` lives in
  `@shadowcat/core` `format`.
  `folderOps.ts`'s `folderChildren(docs, parentId, nameCompare?)` takes an INJECTED name-tie-break
  comparator (defaulting to a plain locale-compare, so the module stays independently
  testable with no `@shadowcat/ui-kit` dependency) — `FolderTree.svelte`, the production caller,
  passes `ctx.compare` (ui-kit's locale-reactive collator; see `shadowcat-codebase-client-shell`'s
  `I18n.compare`, in its references/appcontext-i18n-and-session-seams.md), so this pure sort module never constructs its own collator.
  `appendFolderSortKey(docs, parentId) -> number` (`folderOps.ts`) is the folder-tree caller of
  `@shadowcat/core`'s shared `appendSortKey`/`SORT_KEY_DENSITY` sibling-ordering primitive (see
  `shadowcat-codebase-client-shell` (references/appcontext-i18n-and-session-seams.md) for that primitive's general contract, shared with
  `appendNoteSortKey` in `shadowcat-codebase-tables-notes`): it derives its siblings from
  `folderChildren(docs, parentId)` (using `folderChildren`'s default comparator — the append key
  depends only on the numeric `sort` values, not name order) and feeds their `sort` values
  through. `buildFolderDoc(world, name, parentId, sort = 0)` takes the allocated key as an
  explicit fourth argument; the `0` default serves a caller with no sibling list to allocate an
  append key from.

