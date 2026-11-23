# Client fog sweeps, light sweeps, lighting and render budget

Part of the shadowcat-codebase-scene-rendering skill; read it before changing visionSweeps, lightSweeps, fog blend, the Lighting class or the render performance budget.

- `engine` (client/render module) — `visionSweeps: Map<tokenId, {samples, elapsed,
  durationMs}>` drives the mover's fog sweep during `MoveStream` playback (keyed per token — unions
  concurrent sweeps' visible sets rather than clobbering). `animateSamples(id, samples, durationMs,
  startServerMs, moverVision?)` starts a sweep only when `moverVision` is present (an observer never
  populates this — observers receive `moverVision: null` from the egress clip and simply tween
  position). While `visionSweeps.size > 0`, the engine feeds the sweep polygon (cross-faded between
  samples, or SNAPPED to the nearest sample when no next sample is available or more than one
  sweep is concurrently in flight — see `pixi-backend` below) to the compositor instead of the
  last `vision` subscription payload; reverts to that payload the instant the sweep map empties
  (sweep end or catch-up completion).
- `lightSweeps` (`engine`, client/render) — the lighting twin of `visionSweeps`, keyed by token
  id, started by `animateSamples`'s `moverLight` argument (`MoveLightSample[]`, forwarded
  `WsClient.onMoveStream` → `WorldSession` → `SceneInteractionBridge.animateSamples` →
  `RenderEngine`; any recipient may carry one, not just the mover). While a sweep plays,
  `Lighting.setSweep` unions the sweep's cells over the fade-interpolated committed frame
  (`mergeSweepCells`: a sweep cell REPLACES its same-key base cell, new cells append), and a
  committed lighting frame arriving meanwhile APPLIES AT ONCE except for each sweep's end
  cells: `holdLightingCells` keeps every cell in the sweep's `endKeys` — the cells its LAST
  light sample lights, `lightSampleCellKeys` (`lightSampleCells` with no line-of-sight clip) — at
  the value the lighting held when the first light sweep started (`lightingBeforeLightSweep`),
  because the post-commit `vision` rebroadcast already carries the light at its FINAL position
  and painting those cells mid-walk would light the corridor's far end before the torch gets
  there, while an unrelated change the same frame carries (another light switched on) must not
  wait for the walk — and `setDarkness`, which applies immediately, no longer pairs darkness
  from one generation with lit cells from another. `tickLightSweep` clears the hold once the
  last sweep ends, and `reapplyViewedScene` ends every light sweep (they belong to the scene
  being left). `applyCommittedLighting` is THE one path that retargets `Lighting` from a
  committed frame: while the viewer's OWN vision sweep plays, the `unionLightingInputs` of the
  lighting held when the sweep began (`lightingBeforeSweep`, the cells lit from the START) and
  the newest frame (lit from the STOP), since the sweeping line of sight runs between the two;
  the newest frame alone otherwise — then, while a light sweep plays, with the held end cells
  taken from `lightingBeforeLightSweep`. A GLOW-ONLY frame (`samples`
  empty, `moverLight` present) starts the light sweep alone — `RenderEngine.animateSamples`
  forwards no position samples to `TokenAnimator`, so no token tweens. The cells come from the
  pure `light-sweep` module: `lightSampleCells`
  rasterizes the chosen sample (`chooseVisionSample`, the ONE generic rule the fog sweep uses)
  onto every grid cell whose center is within `dim` of `pos`, inside the sample's polygons AND
  inside the viewer's own line of sight (`currentLosPolygons` — the vision sweep's chosen sample
  while one plays, else the last derived `visible` set; the server never clips the glow to the
  recipient's sight, so this intersection is the client's job) — brightest band within `bright`,
  band 1 beyond, tinted with the light's color via `bandAlpha`/`TINT_ALPHA` (a cosmetic
  approximation of the server's falloff, never a second illumination rule; the committed frame is
  the truth at rest), candidates enumerated through the axial bounding box of the disc's pixel
  box via `Grid.cellOf` (one enumeration for square and hex), fail-closed on a degenerate sample
  or more than `MAX_LIGHT_SWEEP_CELLS` candidates. A single sweep cross-fades consecutive samples
  with `blendLightCells` at the `computeFogBlendFactor` factor; concurrent sweeps union their
  chosen samples. A sweep's duration extends to its last admitted sample's `tMs` (an observer's
  clipped `durationMs` can end before a still-admitted glow does). With no darkness model
  (`lastLightingInput === null`, e.g. a GM's `mode:"all"`) the sweep paints nothing.
  `RenderEngineOpts.onLightingApplied(frame, sweeping)` is the host observability hook `Stage`
  turns into read-only "data-light-sweep" / "data-lit-cells" / "data-lit-bbox" attributes, which
  is what the moving-light e2e observes — each written only when its value changes, since the
  hook fires on every fade tick and sweep step and a dataset write is a DOM attribute mutation.
- `fog-blend` (client/render module) — `computeFogBlendFactor(clock, tCur, tNext)`:
  pure, unit-testable blend-factor helper (0 at `computeFogBlendFactor.tCur` → 1 at `computeFogBlendFactor.tNext`, clamped `[0,1]`; a
  degenerate/non-finite span snaps to 1 — fail-safe toward the newer sample, never frozen on a
  stale one). Extracted from `pixi-backend` because that module is WebGL-only (Playwright-covered,
  no jsdom GL context).
- `pixi-backend` (client/render module) — `setVisibilityBlend(from, to, factor)`
  rasterizes both the outgoing and incoming vision-sample fog into `RenderTexture`s via the shared
  `captureFog`/`paintFogSheets` helpers (the SAME paint path `setVisibility` uses — draws IDENTICAL
  fog for a given input) and alpha cross-fades between them; falls back to snapping to the nearest
  sample when a next sample is unavailable or more than one sweep is concurrently in flight. No polygon morphing
  — cross-fades rasterized textures only.
- `lighting` (client/render module) — `Lighting` class (GL-free, unit-tested):
  resolves gradation band→darkening alpha + tint color, applies each cell's `RenderHint` through `hintTreatment`
  (`desaturate` gray wash, `colorWash`, `outline`, `custom` via a registered `VisionTreatmentMeta`; `parseRenderHint`
  narrows each wire entry and turns a string, unknown kind or malformed entry into `none`), and interpolates day/night fades. Called by `PixiBackend`
  `setLighting` which renders per-cell darkening/tint sprites + a `BlurFilter` for soft band edges.
- **Performance render budget (client/render; the seam type lives in `@shadowcat/core` — see
  `shadowcat-codebase-performance`).** `RenderEngineOpts.performance` (a getter, the
  `RenderEngineOpts.viewedSceneId` pattern, read fresh every tick, never cached) feeds
  `RenderEngine`'s budget branches; absent ⇒ `PRESETS.quality` with `idleSkip: false` (legacy/
  test callers keep the unconditional per-tick render). `DisplayBackend` gained
  `setFrameCap`/`setRenderScale`/`render` for it (`MockBackend` records structurally;
  `PixiBackend.setRenderScale` re-applies the last CSS-pixel viewport after changing
  `resolution`, since `renderer.resize` takes CSS dimensions), and `createPixiBackend` removes
  the renderer's own auto-render ticker listener so `RenderEngine` owns the render call.
  **Idle-skip:** the constructor wraps `opts.backend` in `wrapDirtyTracking` (the ONE dirty-flag
  seam — every reconciler/view/compositor/lighting object is built against the wrapped backend)
  and the ticker renders only when the flag is set, when `TokenView.hasAnimatedVisual` is true
  (`tickTokenAnimations` is deliberately excluded from dirty-tracking because `TokenView.tick`
  calls it unconditionally every tick), or when `PerformanceSettings.idleSkip` is off;
  `RenderEngine.start` renders one initial frame unconditionally so the idle accounting starts
  clean. `RenderEngine.start` applies the initial budget (frame cap via `fpsCapToTickerValue`,
  render scale) BEFORE the first frame and seeds a `lastPerf` snapshot the ticker diffs ONCE
  per tick — the one comparison site every live budget key reacts through: a render-scale push
  marks dirty (the push reallocates and blanks the backing store, and the wrapper deliberately
  does not dirty-track it), a `PerformanceSettings.lighting` flip re-runs
  `RenderEngine.applyCommittedLighting`, and a `PerformanceSettings.tokenFx` flip re-reconciles
  `TokenView`; `RenderEngineOpts.onStats` pushes an fps/frameMs sample at most 4×/s. **Layer budgets:** `PerformanceSettings.tokenFx` off ⇒ `TokenView.toSpec` drops every
  condition-driven fx entry and keeps only the selection highlight (bounded by the selection
  size); `PerformanceSettings.lighting` `"static"` ⇒ `RenderEngine.applyLightSweep` clears
  in-flight sweeps and re-applies the committed frame (no per-frame interpolation), `"off"` ⇒
  `RenderEngine.applyCommittedLighting` targets `null` and the sweep paints nothing — the
  overlay is cosmetic, fog/vision secrecy is untouched; `PerformanceSettings.reducedMotion`
  snaps `TokenAnimator.startAnim`/`animateSamples` to the end pose and forces the fog/light
  cross-fade factor to 1. Antialias cannot change post-init: `Stage` re-creates the backend
  only when the `antialias` derived value flips (any other budget edit applies live), and —
  because a destroyed renderer's WebGL context can never be re-initialized on the same
  element — re-creates the canvas itself via `{#key}` so the mount effect's `canvas` binding is
  always pristine; the budget observability attributes
  ("data-fps-cap"/"data-render-scale"/"data-idle-skip") are markup-OWNED reactive attributes
  on the (never re-created) host div, not an effect writer, so no writer can go stale against
  a re-created element.
