---
name: shadowcat-codebase-performance
description: "Use when touching Shadowcat's per-device performance / render-budget settings: the `PerformanceSettings`/`PerformancePreset`/`DeviceSignals`/`PersistedPerformance`/`PRESETS`/`resolveAuto`/`effectiveSettings`/`fpsCapToTickerValue`/`parsePersisted`/`serializePersisted`/`PERFORMANCE_STORAGE_KEY` seam in @shadowcat/core's performance module, the ui-kit `PerformanceController` (the `performanceController` singleton, `activePerformance`, `PerformanceStats`, `PerformanceListener`) exposed as `AppContext.performance`, the shell's `readDeviceSignals`/`readPerformanceMirror`/`writePerformanceMirror`, the render-side budget seams (`RenderEngineOpts.performance`/`RenderEngineOpts.onStats`, `DisplayBackend.setFrameCap`/`DisplayBackend.setRenderScale`/`DisplayBackend.render`, `createPixiBackend`'s auto-render-listener removal, `wrapDirtyTracking`, `TokenView.hasAnimatedVisual`, `TokenAnimator`'s reduced-motion snaps, the `TokenView.toSpec` tokenFx gate), the settings module's `PerformanceEditor.svelte`, or the statusbar's `PerfStats.svelte`. Covers src/client/core/src/performance.ts, src/client/ui-kit/src/performance.svelte.ts, src/modules/settings/src/PerformanceEditor.svelte, src/modules/statusbar/src/PerfStats.svelte, and the budget seams of src/client/render/. Invoke shadowcat-codebase-core first; for the ticker/render-layer machinery itself invoke shadowcat-codebase-scene-rendering; for the shell persistence pattern invoke shadowcat-codebase-client-shell."
---

# Shadowcat — Performance Settings & Render Budget

Orientation for the per-device render-budget seam (frame cap, render scale, layer budgets,
idle redraw skipping, reduced motion) that lets a phone or a GPU-less host run the stage
without burning a core.

## Purpose

The stage's ticker redraws the full canvas every tick whether or not the scene changed (see
`shadowcat-codebase-core`'s renderer bullet). This subsystem caps that cost: a
`PerformanceSettings` budget resolved from a named preset (or `"auto"` from live device
signals), persisted per-device in localStorage — never the server `ui_state`, because a
phone and a desktop on the same account want different budgets — and consumed by the render
engine through getters read fresh every tick.

## Key files & seams

- `src/client/core/src/performance.ts` — the OWNED seam type every consumer reads:
  `PerformanceSettings` (`fpsCap`/`renderScale`/`antialias`/`tokenFx`/`lighting`/`vfx`/
  `dice3d`/`spatialAudio`/`idleSkip`/`reducedMotion`), `PerformancePreset`, `DeviceSignals`,
  the three static `PRESETS`, `resolveAuto` (mobile when coarse-pointer + compact, or
  `DeviceSignals.hardwareConcurrency` ≤ 4, or `DeviceSignals.deviceMemoryGb` ≤ 4; the
  `DeviceSignals.reducedMotion` signal is OR-ed onto whatever preset resolves),
  `PersistedPerformance` (`{preset, overrides}`), `parsePersisted`/`serializePersisted`
  (fail-closed per KEY, never per record), `effectiveSettings`,
  `fpsCapToTickerValue` (the ONE `"uncapped"` → 0 mapping — the engine ticker and the stage
  `data-fps-cap` writer both consume it), and
  `PERFORMANCE_STORAGE_KEY`. The `PerformanceSettings.vfx`/`dice3d`/`spatialAudio` keys are
  reserved for their owning subsystems (VFX, 3D dice, audio): when those consumers land they
  MUST read these fields through this same type — never a private copy.
- `src/client/ui-kit/src/performance.svelte.ts` — `PerformanceController`, mirroring
  `ThemeController`'s shape exactly (`$state`-backed getters, `subscribe`/`load`/`serialize`,
  a module singleton `performanceController`, and `activePerformance` for reactive component
  reads), plus the live `PerformanceStats` sample and the `showStats` toggle (neither
  persisted). Exposed as `AppContext.performance`; the controller never touches Storage
  itself — `PerformanceController.onChange` is the persistence hook the shell registers.
- `src/client/shell/` — `readDeviceSignals` (every global probe guarded on existence, so each
  field is present only when its probe exists in this environment — jsdom has no matchMedia,
  while Node ≥ 21.5 reports a value for `DeviceSignals.hardwareConcurrency`), `readPerformanceMirror`/`writePerformanceMirror` (the localStorage
  mirror, the theme mirror's exact shape), and the pre-mount `PerformanceController.load` +
  `onChange` wiring in the shell entry point.
- `src/client/render/` — the budget consumers: `RenderEngineOpts.performance` (a getter, the
  `RenderEngineOpts.viewedSceneId` pattern, read fresh per tick) and
  `RenderEngineOpts.onStats` (host observability hook, at most 4×/s);
  `DisplayBackend.setFrameCap`/`DisplayBackend.setRenderScale`/`DisplayBackend.render`
  (`MockBackend` records structurally); `createPixiBackend` removes the renderer's own
  auto-render ticker listener so `RenderEngine` owns the render call; `wrapDirtyTracking`
  intercepts every mutating draw call into the engine's dirty flag;
  `TokenView.hasAnimatedVisual` keeps animated sprites rendering every tick under idle-skip;
  `TokenAnimator`'s reduced-motion snaps (`TokenAnimator.startAnim`/`animateSamples`); the
  `PerformanceSettings.tokenFx` gate in `TokenView.toSpec` (condition fx dropped, the
  selection highlight exempt).
- UI surfaces — `src/modules/settings/src/PerformanceEditor.svelte` (a BUILT-IN Settings
  section, the theme editor's precedent: preset radios, per-key controls, show-stats toggle,
  reset-to-auto) and `src/modules/statusbar/src/PerfStats.svelte` (the fps/frameMs readout,
  rendered only while `showStats` is on). The stage component re-creates the backend only
  when `antialias` flips and exposes the live budget as the "data-fps-cap" /
  "data-render-scale" / "data-idle-skip" host attributes.

## Hard invariants

- **`effectiveSettings` is the ONE place preset + overrides + device signals combine.** The
  editor and the shell's load call both go through it; nothing re-derives effective settings.
  `renderScale` is re-clamped to `[0.5, 1]` at every read site, and `parsePersisted` drops a
  bad key while keeping the rest (fail closed per key, never per record).
- **`wrapDirtyTracking` is the ONE dirty-flag source.** Every reconciler/view/compositor/
  lighting object is constructed against the wrapped backend, so intercepting at that one
  boundary needs no per-view changes; `RenderEngine`'s ticker renders only when the flag is
  set, when an animated visual is in flight (`TokenView.hasAnimatedVisual`), or when
  `PerformanceSettings.idleSkip` is off.
- **Antialias is fixed at renderer init — a change re-creates the backend, never a live
  toggle.** The stage reads the flag through a derived boolean so ONLY an antialias flip
  re-runs the mount effect; any other budget edit applies live through the engine's
  `RenderEngineOpts.performance` getter with no teardown.
- **`lighting: "off"` is a COSMETIC budget, never a secrecy knob.** It skips the
  darkening/tint overlay only; fog of war and the vision mask (the actual secrecy gate) are
  untouched. `"static"` likewise keeps the overlay but snaps carried-light sweeps to their
  committed end frame instead of interpolating per tick.
- **Settings are per-device.** Persisted in localStorage under `PERFORMANCE_STORAGE_KEY`,
  resolved pre-mount from this device's own signals; never read from or written to the
  server `ui_state` (which is per-account).

## Gotchas

- **The ui-kit singleton is `performanceController`, NOT `performance`** — so no importer
  shadows the ambient Performance global (`performance.now()`). The seam-fixed
  `AppContext.performance` member keeps its name; a component that destructures
  `const { performance } = getAppContext()` must reach the real Performance API as
  `globalThis.performance`, never the bare identifier. `RenderEngine` measures frame time
  through `globalThis.performance?.now?.()` for the same reason.
- **`tickTokenAnimations` is deliberately EXCLUDED from dirty-tracking** — `TokenView.tick`
  calls it unconditionally every tick whether or not any animated sprite exists, so wrapping
  it would mark every tick dirty and defeat idle-skip entirely.
  `TokenView.hasAnimatedVisual` is the real "is a redraw needed for animation" signal the
  ticker consults instead.
- **`PerformanceController.set` moves the preset to `"custom"` and writes the FULL resulting
  settings object as `overrides`** — never a bare single-field patch — so a later resolution
  never falls back to a base preset for an untouched field. The carry-forward is computed
  with the live OS `DeviceSignals.reducedMotion` signal SUPPRESSED, so a transient signal
  never persists as a permanent override (the read-time OR still applies, which is why a
  custom-preset user cannot uncheck Reduce motion while the OS signal is on).
  `parsePersisted` still validates
  overrides field-by-field, since a hand-edited blob may be genuinely partial.
- **`PerformanceController.recordStats`/`setShowStats` never fire `onChange`** (neither is
  part of `PersistedPerformance`): a component reading `stats` observes the `$state` write
  natively, and the persistence hook must not fire up to 4×/s for an unpersisted value.
- **`RenderEngine.start` renders one initial frame unconditionally** — the reconciles pushed
  every initial draw (marking the flag through the wrapper), so rendering immediately paints
  the scene and consumes that initial dirty state, starting the ticker's idle accounting
  clean.

## Pointers

- User-facing guide (what each knob costs, the presets table): `docs/site/guides/performance.md`.
- Architecture invariants this seam answers to: `docs/design/ARCHITECTURE.md` §2 (server by
  default — per-device presentation budgets are the legitimate client-side exception).
- Generated API: `/api/ts/modules/_shadowcat_core.html` (the performance module),
  `/api/ts/modules/_shadowcat_render.html`, `/api/ts/modules/_shadowcat_ui-kit.html`.
- Relationships: `graphify query "performance render budget idle skip frame cap render scale"`.
