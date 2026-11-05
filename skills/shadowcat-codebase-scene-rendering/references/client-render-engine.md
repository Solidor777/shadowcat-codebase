# Client render engine and token visuals

Part of the shadowcat-codebase-scene-rendering skill; read it before changing src/client/render, the backend/pixi-backend layer or token visual rendering.

- `src/client/render/src/` — engine-owned PixiJS layer: the `backend` + `pixi-backend`
  modules (renderer host), `engine`, `reconciler` (doc→scene reconcile), `compositor`,
  `layers` (`CORE_LAYERS` z-order, 0-based: `CORE_LAYERS.background` 0, `CORE_LAYERS.grid` 1,
  `CORE_LAYERS.tiles` 2, `CORE_LAYERS.regions` 3, `CORE_LAYERS.drawings` 4, `CORE_LAYERS.walls` 5,
  `CORE_LAYERS.tokens` 6, `CORE_LAYERS.templates` 7, `CORE_LAYERS.vfx` 8, `CORE_LAYERS.lighting` 9,
  `CORE_LAYERS.mask` 10, `CORE_LAYERS.overlays` 11 —
  read the array, not this list, before placing a module layer: a module's fractional `order` is
  relative to these indices, so an off-by-one lands it under the wrong neighbour),
  `camera`, `grid`, `token-view` + `token-animator` (tween),
  `wall-view`, `drawing-view`, `template-view`, `ping-view`, `emote-view`, `vfx-view`. Modules draw
  through the render-layer API; the canvas host is not replaceable.
  **`vfx-view` (the `VfxView` class + `vfxAnchorZIndex`)** renders effect nodes in the `vfx`
  core layer (between `templates` and `lighting`, BELOW `mask`, so lighting tints effects and
  the fog mask still hides them at unseen points): per-token emitters (`emitter:<token>`,
  tracking `TokenView.transformOf`'s live tween — never a second interpolation) and room-wide
  one-shots (`oneshot:<id>`, 64-per-scene cap, oldest evicted). `VfxNodeSpec.anchor` orders
  simultaneous nodes (`below` 0 / `token` 1 / `above` 2, `"point"` also 1) via
  `vfxAnchorZIndex`; the layer's container has child z-sorting enabled (`ensureLayers` sets
  Pixi's sortableChildren flag on it — the only core layer that sorts). See `shadowcat-codebase-vfx`
  for the whole subsystem (pipeline, wire, `/fx`, `SCENE_TOOL_CONTRACT`).
- **Token visual rendering (faces + animated + generated token visuals).**
  the `token-animation` module — `computeAnimatedFrame(elapsedMs, fps, frameCount,
  loop) -> number`, pure tick-driven frame-index math (extracted for the same reason as
  `fog-blend`: `pixi-backend` is Playwright-only, no jsdom GL context, so frame-selection logic
  needs to live somewhere unit-testable). `loop:true` wraps arbitrarily-large `elapsedMs`;
  `loop:false` clamps to the final frame (a one-shot animation holds, never re-wraps); degenerate
  input (`frameCount<=0`, non-finite `elapsedMs`/`fps`, `fps<=0`) fails closed to frame 0.
  `TokenNodeSpec.visual` (the `types` module) is a discriminated union: the two drawable arms —
  extracted as `ResolvedArtVisual`, `{kind:"image", url} |
  {kind:"animated", source: ResolvedAnimatedSource, fps, loop}` — plus
  `{kind:"generated", art: ResolvedArtVisual, crop: "circle"|"square", border?: {color,width},
  background?: {color}}` — a token's URL is reachable only
  through the `image` arm (top-level or under `art`), never as a bare field — `ResolvedAnimatedSource = {type:"frames", urls:string[]} | {type:"sheet", url, rows,
  cols, count?}`, already asset-id-resolved to serve URLs by `AssetResolver` (the backend never
  resolves asset ids itself). `DisplayBackend.tickTokenAnimations(dtMs): void` — the new per-frame
  animation-advance seam, called once per frame alongside `startTicker`; `MockBackend`'s
  implementation is an intentional no-op (frame-advance state lives only in `PixiBackend`'s real
  `AnimatedSprite`s). `TokenView.tick(dtMs)` calls both `this.animator.tick(dtMs)` (transform tween,
  unchanged) AND `this.backend.tickTokenAnimations(dtMs)` (new). `TokenView.toSpec` resolves a
  token's visual via `resolveTokenVisual` (see `shadowcat-codebase-actors-tokens`), then a private
  `resolveArtVisual` URL-resolves the image/animated arms — shared by the top-level path and a
  generated visual's `art` — via its private `resolveSource` mapping `AnimatedSource` →
  `ResolvedAnimatedSource` through `AssetResolver`, `parseColor`-ing the generated frame's css
  colors to packed `0xRRGGBB` like the faction `borderColor`.
  **`PixiBackend`'s Container-per-token structure** (migrated off a bare
  `Sprite`-per-token + three separately-tracked sibling Maps): one `TokenNode` per token —
  `container` (outer, does NOT rotate, positioned at the token center; `badges` are its DIRECT
  children so condition-marker glyphs stay upright regardless of token facing) →
  `visualContainer` (inner, rotates with the token via `.angle = spec.rotation`) → holds `visual`
  (a `Sprite` or `AnimatedSprite`) + `border` (`Graphics`) as siblings. A `kind:"generated"`
  visual adds a `TokenNode.generated` frame INSIDE `visualContainer`, maintained by
  `ensureGeneratedFrame`/`updateTokenGeneratedFrame` (drawn unconditionally per `setToken`, like
  the faction border, so a size-only re-push re-derives the geometry): a `background` fill
  Graphics under the art, a `mask` Graphics cropping it to `crop` (circle = the extent's inscribed
  ellipse, square = the extent rect; assigned to `node.visual.mask` — a Pixi mask object must sit
  in the display list but is never rendered), and a decorative `ring` Graphics above the art —
  authored data, structurally distinct from the faction `border` Graphics, which is untouched.
  The ring's authored `width` is a fraction of the token's smaller extent, scaled to px at draw
  time. Swapping away from a generated visual drops the mask and destroys the frame. A
  `TokenNodeSpec.aura` (pre-resolved `{color, opacity, radius}` — color packed, radius already in
  scene units; the backend does no grid math) adds a `TokenNode.aura` filled-ellipse Graphics as a
  `container` child ordered BELOW `visualContainer` (the art draws over it; badges stay on top),
  maintained by `updateTokenAura` under an `auraKey` memo (same discipline as `badgeKey`/
  `sourceKey`) and destroyed when a re-push carries no aura. `TokenNodeSpec.fx?: TokenFx[]`
  (`tint`/`desaturate`/`highlight` — colors pre-packed `0xRRGGBB` and strengths pre-clamped by
  `TokenView.toSpec`; the backend never parses colors) adds a `TokenNode.fx`
  `ColorMatrixFilter` on `visualContainer.filters` — ONE filter that `composeTokenFxMatrix`
  folds the whole list into, in array order — maintained by `updateTokenFx` under an `fxKey`
  memo (the same memoization discipline) and disposed with the node. Sitting on
  `visualContainer`, art fx rotate with the art while badges (outer-`container` children) stay
  clean. `TokenView.toSpec` builds the list from two producers: each effective condition's
  registry-authored `Condition.fx`, folded in effective-condition order (a condition's tint,
  then desaturate, then highlight; strengths fixed at 0.5 — the registry authors colors, not
  strengths; a non-`#rrggbb` color fails closed to NO effect via `parseFxColor`), and the
  token's SELECTION signifier, appended as a `highlight` entry (the preserved accent `0xffd400`
  at strength 0.4) whenever the view's `selectedTokens` accessor names it — the selection
  signifier IS this fx entry, never a drawn ring (a targeted token would brighten the same way,
  but no targeting producer exists). `AnimatedSprite` playback is
  entirely tick-driven: `autoUpdate = false` (never Pixi's own shared ticker), frame index advanced
  in `tickTokenAnimations` via `computeAnimatedFrame`. `node.sourceKey` short-circuits a re-push
  with an unchanged visual (a tweening token's transform-only updates never touch the visual/sprite
  object); `visualSourceKey` covers every arm — a generated visual keys on its frame
  (crop/border/background JSON) plus its art's own key. **Load-bearing invariant — guard async texture/frame-load completions on OBJECT
  IDENTITY, not just a string/key match:** `replaceVisualChild` can recreate a token's `visual`
  object (image↔animated kind-swap, or a rapid A→B→A visual-cycling sequence), so an in-flight
  texture/frame-load promise's completion callback MUST check `node.visual === sprite` (the exact
  object captured at load-start) in addition to `sourceKey`/`id` equality — a key-only check lets a
  stale promise write into an already-`.destroy()`'d Pixi object once the visual has been recreated
  more than once while the load was in flight. The animated branch's `replaceVisualChild` call is
  ALSO conditional (`if (!(node.visual instanceof AnimatedSprite))`), mirroring the image branch, to
  reduce how often the object gets recreated in the first place. Any future code touching this
  async-completion pattern (anywhere in-flight code can swap in a different display object) must
  follow the same object-identity-guard shape; a key-equality guard is not sufficient here
  [[async-completion-needs-object-identity-not-key]].
  **GPU texture-cache bookkeeping (`PixiBackend`'s `textureCache: TextureCacheManager`,
  `@shadowcat/render`'s `TextureCacheManager` — the eviction POLICY itself is
  `shadowcat-codebase-performance`'s `textureBudgetBytes` budget number applied here; see that
  skill for the budget's shape/persistence, this one for the mechanism).** Every token visual
  (image and animated), the background sprite, and a VFX one-shot/emitter's texture all feed the
  SAME cache instance, keyed by serve URL, via `applyNodeTextures` — a node's `textureUrls` field
  (`TokenNode.textureUrls`/`VfxRenderNode.textureUrls`) records which urls it currently holds a
  reference for. `applyNodeTextures` diffs a node's prior `textureUrls` against the freshly
  resolved set on every visual swap: releases any prior url absent from the new set, and for each
  new url either `acquire`s a fresh reference or `touch`es one the node ALREADY holds (a reload
  triggered by `fps`/`loop` alone, or an A→B→A cycle landing back on A) — re-`acquire`ing an
  already-held url would increment the ref count with no matching release, permanently
  over-referencing that url. `removeToken`/`removeVfx` release the node's whole `textureUrls` set
  on teardown; the background sprite tracks its own single `backgroundTextureUrl` the same way.
  **`PixiBackend#loadAssetTexture` is the ONE producer — it registers every texture with
  `TextureCacheManager` at load, unconditionally, regardless of which caller's race it wins or
  loses; consumers only ever CLAIM references, never register.** On entry it calls
  `TextureCacheManager.beginLoad(url)`; on a successful `Assets.load`, before returning, it calls
  `TextureCacheManager.register(url, estimateTextureBytes(texture), now)` — creating a `refCount:
  0` entry when none exists yet (a no-op on a url already tracked, so it never clobbers a fresher
  `bytes` estimate or an already-live ref count); a finally block calls `endLoad(url)` regardless
  of success or failure. This is what makes a load whose caller lost the object-identity/
  `sourceKey` stale-guard race (described above) still become tracked and evictable instead of
  landing in PixiJS's own `Assets` cache untracked for the tab's life — EVERY call site that loses
  that race (the background branch, the token image/animated branches, both VFX branches) does
  nothing further: the comment at each one says so explicitly, and a fix introducing a per-site
  acquire/release pair there would be redundant with the loader's own unconditional `register`.
  The WINNING call site is what claims a reference, via `applyNodeTextures` — a node's
  `textureUrls` field (`TokenNode.textureUrls`/`VfxRenderNode.textureUrls`) records which urls it
  currently holds a reference for. `applyNodeTextures` diffs a node's prior `textureUrls` against
  the freshly resolved set on every visual swap: releases any prior url absent from the new set,
  and for each new url either `acquire`s a fresh reference or `touch`es one the node ALREADY holds
  (a reload triggered by `fps`/`loop` alone, or an A→B→A cycle landing back on A) — re-`acquire`ing
  an already-held url would increment the ref count with no matching release, permanently
  over-referencing that url. `removeToken`/`removeVfx` release the node's whole `textureUrls` set
  on teardown; the background sprite tracks its own single `backgroundTextureUrl` the same way.
  `estimateTextureBytes` approximates a
  decoded texture's GPU-resident size as `max(1,width) * max(1,height) * 4` (RGBA8), floored at 1
  per dimension so a degenerate 0-size texture (e.g. pixi.js's own empty-texture stub in a test
  double) still contributes a nonzero, budget-comparable estimate. `TextureCacheManager.sweep`'s
  four parameters (`now`, the byte budget, its idle-eviction threshold, and the per-url `unload`
  callback) form a pure, Pixi-free eviction policy (`sweep`/`register`/`beginLoad`/`endLoad`/
  `acquire`/`release`/`touch`/`has`/`totalBytes`, unit-tested with no GL context) — NEVER evicts an
  entry with `refCount > 0` regardless of budget or idle time (this is what makes a live sprite's
  texture safe), and ALSO never evicts a url with a nonzero `beginLoad`/`endLoad` in-flight count
  regardless of `refCount` — this closes the window between a losing load's `register` (refCount
  0, otherwise immediately evictable) and the eventual winner's `acquire`, which a `refCount`-only
  check would miss since `register` and `acquire` are two separate calls with real time between
  them; it first unloads every unreferenced entry idle longer than that threshold
  (`TEXTURE_TTL_MS` = 5 minutes — independent of budget, so a scene visited once and not
  revisited eventually frees
  its art even with budget to spare), then evicts unreferenced entries oldest-`lastUsed`-first
  while `totalBytes()` exceeds the budget. `PixiBackend.tickTokenAnimations` drives the sweep,
  throttled to `TEXTURE_SWEEP_INTERVAL_MS` (5s, an accumulator, NOT a per-call sweep) even though
  that method itself runs every frame; `setTextureBudget` takes effect on the NEXT sweep, not
  immediately, unlike `setFrameCap`/`setRenderScale` which touch the renderer directly. Sweep's
  `unload` callback is the caller's real `Assets.unload(url)`, wrapped in a swallowed `.catch` — a
  url already unloaded or never registered with `Assets` (e.g. a test double's stub url) is not a
  real failure, mirroring `loadAssetTexture`'s own fail-quiet contract.
