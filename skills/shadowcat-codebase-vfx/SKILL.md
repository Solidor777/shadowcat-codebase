# Shadowcat — VFX

Orientation for animated effects on the stage: the server-derived grid-sheet
pipeline, spritesheet pairing, the `PlayVfx`/`Vfx` one-shot relay, the `/fx`
chat command, the render-side `VfxView`/backend seam, and the
`SCENE_TOOL_CONTRACT` extension point.

## Purpose

Two effect formats reach the stage with no new codec: animated WebP/GIF
(server-tiled into a grid sheet at commit time) and a paired
TexturePacker-style spritesheet (atlas + sidecar JSON). Per-token emitters
(`VfxEmission`, the component model's payload) play as `emitter:<token>`
nodes tracking the token's live transform; transient one-shots any world
member may fire at a scene point relay room-wide and play as `oneshot:<id>`
nodes, capped at 64 live per scene (oldest evicted) so a spam burst cannot
stall the stage.

## Key files & seams

- `data::asset::process` — `generate_grid_sheet` (decode via
  `decode_animation_frames`, tile near-square, downscale past
  `SHEET_MAX_PX`=4096, lossless) writes `.sheet.webp` + `.sheet.json`
  siblings at commit/reconvert, NEVER lazily; `SheetMeta` (rows/cols/count/
  `frame_ms`/per-frame width/height) persists on `AssetMeta.sheet` as flat
  `sheet_*` columns (sheet_rows NULL ⇔ None). `SIBLING_SUFFIXES` is 5
  members (`.orig`, `.thumb.webp`, `.preview.webp`, `.sheet.webp`,
  `.sheet.json`); `sheet_path` exposes the sheet sibling's path.
- `http::assets` — `serve` gains `?variant=sheet` (the tiled image; 404 when
  the sibling is absent, never canonical-fallback, never regenerate) and
  `GET /api/assets/{uuid}/meta` (membership-gated metadata, no bytes).
  `assets::mutate::patch` validates `vfx:sheet=<json-asset-id>` pairing:
  one tag max, sidecar is `application/json` in the same world, its
  `meta.image` names the image's `original_name` exactly.
- `ws::protocol` — `ClientMsg::PlayVfx` / `ServerMsg::Vfx` (aux, out-of-band,
  silent-drop on denial; `Vfx.id` keys the one-shot node). `WsState.vfx_rate`
  is a SEPARATE per-user bucket from ping/emote/message (30/min), charged by
  BOTH entry paths (the raw frame and `/fx` — one rate decision per play).
- `ws::vfx` — `VfxRequest`, `validate_bounds` (finite, inside
  `scene::move_exec::MAX_GATE_WALK_COORD`, scale ∈ (0, 8], duration ≤ 60_000,
  ids ≤ 128 bytes), `vfx_permitted` (spectator refused BEFORE any repo call;
  scene must exist, be a scene, be this world's, grant READ) — the ONE
  validation+authz both call sites (`ws::conn`'s `PlayVfx` arm and
  `chat::fx`) share.
- `chat::fx` — `/fx <asset-id-or-name> @<token name>`: intercepted in
  `handle_send_message` BEFORE `parse_command`; resolves the asset (raw UUID,
  else `Repository::asset_id_by_name` case-insensitive) and the token's
  center server-side on the world's ACTIVE scene (`world-settings`
  `activeScene`); charges the shared `vfx_rate` bucket before broadcast;
  success authors NO message (`handle_send_message` returns
  `Ok(None)`), failure whispers a `MessageKind::System` notice via
  `build_system_error_notice`.
- `@shadowcat/core` — `vfx.ts` (`VfxPlayRequest`, `VfxOneShotRequest`,
  `ResolvedVfxSource`, `resolveVfxSource`), `asset-meta.ts`
  (`AssetMetaCache` with `invalidate(id)` — wired to the asset-changed
  notice at the consumption site so a replaced asset's stale `SheetMeta`
  is dropped), `getAssetMeta`, `SCENE_TOOL_CONTRACT` +
  `SceneToolMeta` (`contributions.ts`), `WsClient.playVfx`/`onVfx`
  (`VfxNotice`), `AppContext.vfx` (`ui-kit`).
- `@shadowcat/render` — `"vfx"` in `CORE_LAYERS` (index 8: between
  `templates` and `lighting`, BELOW `mask`); `vfx-view.ts` (`VfxView`,
  `vfxAnchorZIndex`); `DisplayBackend`/`PixiBackend`/`MockBackend`
  `setVfx`/`removeVfx`/`tickVfx`; `computeVfxFrame` (`token-animation.ts`,
  per-frame durations, 100 ms default tail); `TokenView.transformOf` (live
  tweened transform); `RenderEngine.playVfx` + `RenderEngineOpts.vfxAssets`/
  `vfxEnabled`/`reducedMotion`/`onVfxChanged`.
- `@shadowcat/module-vfx` — the FX scene tool + `FxToolPanel` (launcher-only
  config: last-picked asset/scale/sound in the module-scoped `fxToolState`;
  the scene-tool contribution registers from the panel's own `$effect`
  because `ModuleContext.register` has no `AppContext`).
- `EmissionEditor` (ui-kit) — VFX-tag filter + preview thumbnail for emitter
  authoring (`TokenEmissionControl`, actor sheet/create form).

## Hard invariants

- **Sheet generation is commit-time only.** An upload/reconvert is never
  rejected for a sheet-generation reason, and a missing `.sheet.webp` is a
  404, never a lazy re-derive (the pipeline's pass-through-on-failure
  convention).
- **One validation+authz source for one-shots.** `ws::vfx` is the only
  implementation; the raw frame and `/fx` must agree (never-fork). Denial is
  a SILENT drop — no error frame, so a non-reader never learns whether the
  scene exists.
- **`/fx` never oracles.** A token the sender cannot READ produces the same
  "No such token." text as a nonexistent name; a UUID-shaped asset ref is
  used as-is (existence is the render layer's fail-closed problem, matching
  `PlayVfx`'s unchecked `asset`).
- **Emitters track the SAME interpolation as the token sprite** —
  `TokenView.transformOf` (the animator's live transform), never the
  doc-projected target and never a second tween.
- **The fog mask still hides effects.** The `vfx` layer sits BELOW `mask`:
  a one-shot reaches every recipient over the wire (`docs/design/ARCHITECTURE.md` §2 invariant 11) but is
  visually masked at points they cannot see.
- **Anchor rule, all inside the `vfx` layer** (which sits above `tokens`, so
  no effect ever draws under token art): `below` = footprint base, zIndex 0;
  `token` = center, 1; `above` = top edge, 2. The layer's container has
  sortableChildren enabled (PixiJS sorts by each sprite's zIndex).
- **A paired sidecar MUST define `animations["default"]`** — the resolver is
  synchronous over asset metadata and never reads the sidecar's bytes.
- **Performance flags are read fresh, never cached** — `vfxEnabled`/
  `reducedMotion` are re-read on every `reconcile()`/`play()`;
  `PerformanceSettings.vfx == false` tears down EVERY node (emitters AND
  live one-shots) and makes `play` a no-op; reduced motion freezes emitters
  at their sequence's LAST frame ON LOAD (`VfxNodeSpec.startAtEnd` — never a
  play-through first) and skips one-shots entirely.
- **Emitters track mid-tween** — `VfxView.tick` re-reads every emitter's
  live `TokenView.transformOf` per frame and re-pushes transform-only
  changes (the backend's source-key short-circuit makes that cheap); the
  full reconcile diff runs only on store commits/scene switches.
- **One-shots never linger** — natural completion, `durationMs` expiry, a
  scene switch (each one-shot records its scene; `reconcile` drops
  off-scene ones), and a FAILED load (the backend destroys the zombie node
  and surfaces completion through the next `tickVfx`'s `onDone`) all remove
  the backend node AND the view's bookkeeping.

## Gotchas

- **The two "sheet" discriminants are deliberately different keys**:
  `ResolvedAnimatedSource`'s `{type: "sheet", url, rows, cols, count?,
  frameMs?}` (server-derived grid) vs `ResolvedSheetSource`'s
  `{kind: "sheet", imageUrl, sheetUrl, animation}` (PixiJS pairing) — check
  `"imageUrl" in source` first. `@shadowcat/core`'s `ResolvedVfxSource`
  declares the identical union independently (render cannot be imported from
  core); any change must update both declarations.
- **The grid sheet is a SIBLING, not the canonical** — resolving it to the
  canonical serve URL slices the raw animated source as if it were tiled;
  always `?variant=sheet`.
- **The `vfx` tag is a browsing aid, never a gate** — an untagged animated
  asset is a valid emitter; the tag only feeds the picker/filter chips.
- **`ToolController.active` stays the closed `ToolId` union** — contributed
  tools activate through `activeContributedId` (parallel, mutually
  exclusive). A module CONTRIBUTING a scene tool never declares
  `SCENE_TOOL_CONTRACT` in `manifest.requires` (zero contributors is the
  normal case; `requires` is a hard provider gate).
- **`VfxEmission.loop` is spelled `loop` in TS** (serde renames `loop_`).
- **Sound is carried, not played** — `VfxPlayRequest.sound`/`ServerMsg::Vfx
  .sound` travel end-to-end unconsumed until an audio integration wires
  `AudioApi.playOneShot`.

## Pointers

- **Generated API** — `/api/rust/shadowcat/ws/vfx/`,
  `/api/rust/shadowcat/chat/fx/`, `/api/ts/modules/_shadowcat_render.html`
  (`VfxView`), `/api/ts/modules/_shadowcat_core.html` (`vfx`, `asset-meta`),
  `/api/ts/modules/_shadowcat_module-vfx.html`. Produce with `pnpm build:all`.
- User docs: `docs/site/modules/vfx.md`; the `SCENE_TOOL_CONTRACT` worked
  example in `docs/site/guides/creating-a-module.md` +
  `examples/module-initiative-tracker`.
- `shadowcat-codebase-assets` (the pipeline/store this rides),
  `shadowcat-codebase-scene-rendering` (the render layer + layer order),
  `shadowcat-codebase-realtime-sync` (the aux-frame shape),
  `shadowcat-codebase-chat` (`/fx` ingest), `shadowcat-codebase-performance`
  (the `vfx`/`reducedMotion` budget knobs).
- Relationships: `graphify query "vfx emitter one-shot grid sheet scene tool PlayVfx"`.
