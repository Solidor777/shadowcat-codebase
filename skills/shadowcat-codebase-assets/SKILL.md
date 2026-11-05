---
name: shadowcat-codebase-assets
description: "Use when touching Shadowcat assets: upload (single-shot or chunked sessions), the WebP conversion pipeline + retained originals + thumb/preview derivatives, explicit/derived tags (incl. Provenance::ChatImage from inline chat images), `asset_folder` documents, the query/PATCH/bulk/reconvert/original routes, serve/replace/delete, ETag/version revalidation, upload rate limits, out-of-band AssetChanged broadcasts (every `AssetOp`), the client asset REST + chunked-upload client + AssetResolver, or the asset-browser UI module (panel, folder tree, pick overlay). Covers src/server/src/data/asset{.rs,/} + src/server/src/data/sqlite/assets.rs + src/server/src/http/assets{.rs,/} + src/client/core/src/asset* + src/modules/asset-browser. Invoke shadowcat-codebase-core first."
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

Covers every file and seam of the asset pipeline: data::asset and its process, audio and tags submodules, the query vocabulary, the sqlite assets store, the assets_fts index, the HTTP routes, the AssetChanged broadcast, the client core asset modules, and the asset-browser UI module. Read references/key-files-and-seams.md before changing or consuming any of them, or when you need to know which file owns a behaviour.

## Hard invariants

- **The asset index is trigger-maintained; no Rust write site touches it.** `assets_fts` is kept
  in sync entirely by the five SQLite triggers named in the `assets_fts` seam in references/key-files-and-seams.md — inserting,
  renaming, deleting an asset row, or adding/removing a tag row, all update the index structurally
  via the schema, never via a Rust call from `commit_staged_asset`, `set_asset_tags`,
  `refresh_derived_tags`, `update_asset_placement`, `delete_asset_files_and_row`, or any other of
  the six-plus write sites that touch `assets`/`asset_tags`. This is a deliberate design choice
  (over threading index-maintenance calls through every write site): a future write path added to
  either table gets the index for free and cannot forget to maintain it.
- **All mutation routes are GM-ONLY, with no owner exception** — `upload`, chunked sessions,
  `replace`, `delete`, `patch`, `bulk`, `reconvert`, `original`, `delete_folder` each go through
  `require_gm`. `serve` (and its `?variant=` form) and `GET /api/assets/{uuid}/meta` are the
  only membership-gated reads.
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
  `complete_session` and the link-preview/`chat::post_publish` pipelines (link previews' `og:image`,
  oEmbed thumbnails, AND `resolve_inline_image`'s `Provenance::ChatImage` commits — all three go
  through the same `create_asset_from_bytes` entry point) join the same exclusion.
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
  (`check_asset_folder_parent`, batch-aware for a same-command parent + child), reached through
  the shared `check_parent_placement` helper the Create AND Move arms both call (and
  `import_world`'s post-loop pass, over an already-inserted bundle). Folders ARE
  re-parentable after Create — via the GM-only `Operation::Move` only, never a field-path
  Update — so the tree is kept acyclic by `check_move_acyclic`'s batch-aware ancestor walk at
  the same chokepoint, on the `apply_intent` AND `apply_command` paths alike (structural
  integrity is not exempted by replay trust). A folder move recomputes the subtree's derived
  tags through `refresh_derived_tags_for_folder_subtree`, the same hook a folder rename runs.
  Deleting a folder cascades its sub-folders
  (document invariant) and `reparent_assets_of_deleted_folder` in `delete_document_tx` moves
  each deleted folder's assets to its parent, children-first; `?assets=delete` purges them
  first through `delete_asset_files_and_row` (client: `deleteAssetFolder`).
- **`GET /api/worlds/{world}/assets` has two shapes**: no query parameter ⇒ bare `Asset[]`
  (the contract `listAssets`, `Assets.svelte`, `AssetPicker` and the e2e rely on); any parameter
  ⇒ `AssetPage`. `queryAssets` always sends `limit` so it never hits the bare form. The regex is
  applied AFTER the SQL filters over at most `MAX_REGEX_PAGES` SQL pages per call. Without a regex
  `next_cursor` is the last row of a page that has a row after it. With `name_regex` it is the last
  row TESTED against the pattern, so following cursors visit every matching row: an exactly
  filled page with nothing after it has no cursor, and a filled page followed only by a
  non-matching row gets a cursor whose next page is empty with none. `AssetSort::Name`'s key is the
  ASCII-lowercased name (`sort_key_of`), the same fold as SQLite's lower function that orders the SQL.
- **Chunk protocol:** fixed `CHUNK_SIZE`; `PUT …/{offset}` accepts exactly `received` (409
  otherwise — a retry of a LOST chunk carries that offset, a duplicate does not), a concurrent
  PUT on the same session is 409 (busy), overflow aborts the session (413), `complete_session`
  requires `received == byte_size` and removes the session before processing. Every session
  call re-runs `require_gm` live (`owned_session`), so a demotion mid-session takes effect at
  the next chunk. `complete_session` re-validates `folder_id` — a folder deleted during the
  session lands the asset at the world root rather than failing the upload. Sessions are
  in-memory only.
- **`serve` never lets a browser render a stored type as a document**: `X-Content-Type-Options:
  nosniff` always — set by `http::router`'s global security-header layer
  ([[shadowcat-codebase-server-ops]]), NOT a per-handler header on `serve` itself (a per-branch
  copy would be dead weight: the router's overriding set-header layer unconditionally replaces any
  existing value on the way out) — and `Content-Disposition: inline` only for the raster types in
  `INLINE_CONTENT_TYPES`; everything else — SVG included — is an attachment (`<img>` embedding
  is unaffected), naming itself via the shared `mutate::attachment_disposition` helper (also used
  by `mutate::original`'s retained-original download, never a bare `"attachment"` restated at a
  second call site). A GM-declared pass-through type is stored verbatim but cannot execute.
- **Every `http::assets::serve` response branch (canonical, every `?variant=`, and its own
  304/not-modified replies) sets `Cache-Control: no-cache`** — the request URL carries no asset
  version, so a cache must always revalidate through `If-None-Match` rather than trust a heuristic
  freshness lifetime; this is what makes the ETag load-bearing rather than a courtesy. Contrast
  the embedded client bundle (`http::embed::static_handler`): a hashed-URL chunk under `assets/`
  (`http::embed::is_hashed_asset_path`, matching `vite.config.ts`'s content-hashed build output —
  `assets/[name]-[hash].js`) gets `public, max-age=31536000, immutable` instead, since a changed
  file there gets a brand-new URL; every other embedded path (`index.html`, `popout.html`,
  favicons, the stably-named `runtime/*.js` import-map chunks) stays `no-cache` because its URL
  never changes when its content does.
- **Every handler that opens an asset file to stream it to a client takes a
  `StreamedFilePermits` permit (`acquire`) BEFORE the open and before any response header; an
  exhausted pool is a 503 with `Retry-After` (`AppError::Unavailable`).** The two streaming paths
  are `file_response::serve_file`'s GET arms (reached by `serve` and `mutate::original`, both
  passing `AppState.file_permits`) and the `http::world_bundle::export_world` handler, which holds
  its permit until its producing task ends. A HEAD with a version-derived validator opens nothing
  and takes no permit. A byte-derived validator (`Validator::OfFile`, used by the Opus derivative
  variants) exists only after the open, so it cannot answer a validator hit before it: its GET takes
  the permit first and holds it through the 304, and its HEAD opens the file for the head read only,
  with no permit. A new streaming handler takes one the same way.
  `shadowcat-codebase-tls` owns the pool (its capacity, wait and the descriptor budget it is
  derived from); this skill owns only the obligation on the handlers.
- **`http::compression::AssetAndWsSafePredicate`** is the response predicate
  `http::router` installs globally on its compression layer — the tower-http default (excludes
  `image/*`, gRPC, SSE, bodies under 32 bytes) PLUS the Opus/WebM audio-derivative content types
  (`data::asset::process::audio::{OPUS_CONTENT_TYPE, WEBM_CONTENT_TYPE}` — already compressed, so
  gzip/br would spend CPU for an equal-or-larger output) PLUS any `101 Switching Protocols`
  response (a WebSocket upgrade hands the raw TCP stream to the WS protocol from that point on;
  wrapping it in a gzip/br encoder would corrupt every frame sent after the upgrade — refused by
  status code alone, since that status never occurs on an ordinary REST/asset response).
- **Every decode is bounded** (`decode_limits`: axis ≤ `MAX_DECODE_AXIS_PX`, allocation ≤
  `MAX_DECODE_ALLOC_BYTES`) — on the reader sites AND on `is_animated`'s raw GIF decoder,
  which the crate constructs with no limits at all and which would otherwise allocate a
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
  pre-pipeline bundle still imports; imported explicit tags pass `normalize_tags`. Import never
  writes `assets_fts` directly — its triggers rebuild it from the imported `assets`/`asset_tags`
  rows, the same never-exported posture the document FTS tables hold (`world_bundle`'s module doc
  and `insert_imported_document`'s doc state it).

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
- Folder re-parenting rides the generic document `Operation::Move` (see the placement
  invariant above and `shadowcat-codebase-documents-permissions` for the op itself) — there is
  still NO asset-specific move route, and no client field-path Update can touch `parent_id`.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/asset/`, `/api/rust/shadowcat/http/assets/`
  (rustdoc, private items included), `/api/ts/modules/_shadowcat_core.html` (TypeDoc:
  `asset-rest`, `asset-upload`, `assets`). Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §4 (asset pipeline) + §6 (stable asset identity).
- Relationships:
  `graphify query "asset upload process derivatives tags folder query AssetChanged"`.
- History: [[m8b-assets]], [[commit-db-row-before-swapping-file]].
- `shadowcat-codebase-chat` — `chat::post_publish::resolve_inline_image`, `Segment::Image`, and
  `chat::body::compose_message`'s `[[asset:<uuid>|alt]]` span — the two chat-side producers of a
  `Provenance::ChatImage` asset and of a message referencing an asset by id.

## Reference files

| File | Holds | Read it when |
|---|---|---|
| references/key-files-and-seams.md | The full Key files & seams section (every file, route, store and client seam) | Changing or consuming any part of the asset pipeline, store, routes or browser module |
