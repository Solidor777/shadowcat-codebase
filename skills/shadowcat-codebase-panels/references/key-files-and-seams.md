# Panel Manager: Key files & seams

Part of the shadowcat-codebase-panels skill. Read it before changing or reviewing any panel-manager code (layout reducer, engine adapters, controller, host, shell bridge, pop-out windows).

## Key files & seams

- `panels/layout`'s `applyOp` (the pure layout-tree reducer) — `PanelLayoutV1` (expanded zones right/bottom/left +
  floating + minimized + `popouts: PopoutWindowLayout[]`, compact view state), `LayoutOp` (incl.
  `LayoutOp.popOut`/`LayoutOp.popOutInto`/`LayoutOp.updatePopoutGeometry`/`LayoutOp.popIn`,
  `LayoutOp.resizeFloating` — an already-floating panel's
  in-place rect update, mirroring `LayoutOp.resizeZone`/`LayoutOp.resizeGroup` rather than
  `LayoutOp.float`'s detach-and-reinsert), `applyOp` reducer,
  `defaultLayout`, `locate`, `prune`,
  `placeNewRegistrations`, `placeFromPersistedLocation`. One `PopoutWindowLayout` record per
  pop-out window: an engine-minted `key` the tree never interprets (ops address a window by
  it), the window's `panels` in tab order (INVARIANT: never empty — an emptied window is
  dropped from the tree, see `detach`), its last known `rect` (a `ScreenRect` —
  screen-absolute `window.open`-feature semantics, unlike `Rect`'s host-relative
  coordinates), and an optional `dormant` marker on a record retained after
  reload-rehydration floated its panels — not a live window, purely the arrangement a later
  restore gesture re-opens (`locate` skips dormant entries, so a listed panel is never
  resolved through one). **Same-reference no-op contract**: an
  op that changes nothing returns the SAME layout object (callers/tests rely on `toBe`).
  `SHEET_CASCADE_BASE`/`SHEET_CASCADE_STEP` (the late-registration rehydration cascade) must stay
  numerically identical to `PanelsController`'s `REHYDRATE_FLOAT_BASE`/`REHYDRATE_FLOAT_STEP`
  (below) — two separate constants by design (no cross-module import, to avoid coupling the two
  call sites), but the SAME logical operation (persisted popped-out id → floating on reload) must
  land at the same position regardless of which registration-timing path runs. **Nothing in either
  module's types enforces that pairing — the anti-drift gate is `controller.test`'s "cascade
  parity at index %i" test**, which drives both call sites to the same floating index and demands
  the identical rect at n=0 (pins BASE), n=1 (pins STEP) and n=7 (pins the shared `% 6` wrap). Each
  side's OTHER cascade tests assert only that one side's own offsets differ from each other, which
  stays green when either pair drifts; only the parity test fails on divergence.
- `panels/layout`'s `encodeLayout`/`decodeLayout` (structural
  validation, unknown-id prune, reset-to-default on garbage). `decodeLayout` also returns the
  pre-prune `source` layout so late registrations restore their persisted spot (below).
  `popouts` back-compat: absent on a blob predating the field normalizes via `withPopouts` —
  a legacy poppedOut id array on such a blob migrates to one single-panel window per id
  (rect null, the key derived deterministically from the panel id, since decode-time uuid
  minting would be impure); a present `popouts` is the canonical shape, validated strictly
  (present-but-malformed fails the whole blob), and takes precedence over a legacy array
  carried alongside it.
- `EngineAdapter` seam (incl. optional
  `onNotice?(cb):()=>void` and optional `restorePopouts?(windows)` — the gesture-gated reopen
  of saved pop-out windows, which engines without real cross-window pop-out omit; callers
  treat its absence as "no restore affordance"); `FakeEngine` = test double /
  bespoke-fallback (degrades pop-out to a
  floating window — production pop-out is dockview-only — and omits `restorePopouts`);
  `DockviewEngine` = production engine,
  the only module (plus its test, `dockview.test`) allowed to import dockview-core
  (`dockview-core@7.0.2` EXACT pin; boundary enforced by the ESLint `no-restricted-imports` rule
  in `eslint.config.js` — .ts files only; .svelte files are unlinted, where the boundary holds
  by the EngineAdapter seam's design).
- `panels/engine`'s `classifyDrop`/`opForMenuCommand` →
  `ClassifyResult` (op or veto); `MenuCommand` includes `"popOut"`, but `opForMenuCommand`'s
  domain deliberately excludes it — a `LayoutOp.popOut` carries the engine-minted window
  `key`, which exists only after the gesture-time `addPopoutGroup` succeeds, so the command
  is imperative (`DockviewEngine.#requestPopOut` → `#popOutPanel`), never declarative.
  `STAGE_ID` vetoes live here
  AND as early-returns in `DockviewEngine` (two independent layers, both apply to pop-out too).
- `PanelsController` ($state layout owner):
  bridges engine gestures + imperative `PanelsApi` onto `applyOp`, persists via
  `getPanelLayout`/`setPanelLayout` (per-world `ui_state.worlds[w].panelLayout`), filters regs
  via `regsForRole` (gmOnly = client-advisory only, NOT security), `syncRegistrations` places
  late-registering panels from the retained persisted `source` (never resets a saved layout),
  `onOp` hook drives `PanelHost`'s a11y live-region, `onReset` fires the layout-reset toast key.
  `#rehydratePoppedOut()` (construction-time): every persisted LIVE (non-dormant) pop-out
  window's panels convert to floating via the `REHYDRATE_FLOAT_BASE`/`REHYDRATE_FLOAT_STEP`
  cascade, window-by-window in tab order so one saved window's panels cascade adjacently
  (never re-opens a real popup — no user gesture at load), and each converted window's entry
  is RETAINED — marked `PopoutWindowLayout.dormant`, panel set and rect intact — as the
  arrangement record a later restore gesture re-opens; the change persists. A
  `panels.popoutRestoredFloating` notice is queued via `#pendingNotice`/
  `flushPendingNotice()` whenever dormant entries EXIST after rehydration — keyed on the
  saved arrangement, not on what this load converted (a blob of already-dormant entries
  still offers the restore) — carrying a `PanelsNoticeAction` (label
  `panels.reopenWindows`). The notice is deferred past first mount (fired from
  a `PanelHost` post-mount `$effect`), NOT called synchronously in the constructor: an
  `aria-live="polite"` region never announces content present at its own initial render.
  `flushPendingNotice()` additionally WITHHOLDS an action-carrying notice until
  `restorablePopouts()` is non-empty — panel registrations trickle in after construction, so
  at first flush no saved window may have a registered panel yet; the host re-calls it on
  every registration change (no toast is better than a toast whose button restores nothing).
  `restorablePopouts()` reads the retained pre-prune `#persistedSource`, NOT the live tree:
  decode-time and `syncRegistrations` pruning shrink a dormant entry's `panels` to
  currently-registered ids during the boot trickle, while the source record keeps the full
  panel set the user saved; windows with ZERO currently-registered panels are filtered out
  (a restore gesture could re-open nothing from them).
- `PanelHost` — owns DOM/engine adapter + compact(<48rem)/
  expanded switch; builds the controller lazily at mount from AppContext and `bind()`s it into
  the shell's `PanelsBridge`. **Keep-mounted**: panels hide via CSS/slot adoption
  (`appendChild`), never `{#if}` — pop-out re-parents the same mounted instance into a second
  same-heap `Window`, it does not remount. `CompactSwitcher` adopts the stage into
  `.compact-stage`. `PanelMenu` = per-tab command menu (dock/float/minimize/pop-out, a11y).
  The post-mount flush `$effect` reads `ctrl.visibleRegs` so a withheld action-carrying
  notice re-flushes as panels register; a notice carrying a `PanelsNoticeAction` routes to
  `notifications.push` (the toast host — the only surface that renders a clickable action)
  with a `run` that calls `eng.restorePopouts?.(ctrl.restorablePopouts())`, re-read at click
  time so a panel registered between delivery and click is included; an engine without
  `restorePopouts` degrades the notice to the plain live-region announce.
- `PanelsBridge` (`AppContext.panels`):
  stable shell-owned handle; `#impl` is `$state` so pre-bind readers (chips) unfreeze when the
  host binds; pre-bind calls warn once. Implements `PanelsApi` + `PanelsChipsView`
  (`minimized`/`metaMap`/`restore`) — `DockChipsContribution` (statusbar `panel-dock` region)
  reads the same bridge reactively, no second controller. `PanelsApi.isOpen(id)` is the live
  open-state read (`PanelsController.isOpen` via `locate`; the bridge answers `false` pre-bind)
  that `LauncherMenu`'s `aria-checked` and the e2e `openPanel` helper depend on — `toggle` is
  a genuine toggle, so any caller that means "ensure open" must read `isOpen` first.
- `panels: Module` (module wiring) — provides multi `PANEL_CONTRACT`
  (`shadowcat.panel`), contributes `PanelHost` into core-ui's singleton
  `shadowcat.surface:panel-host` with a fresh `new DockviewEngine(...)` per world session
  (`register` runs per install), and chips into statusbar's `shadowcat.surface:panel-dock`.
- `src/modules/stage/` — the canvas stage module; the stage center well is INVIOLABLE:
  never dockable-over, never floatable, never minimizable — `STAGE_ID` vetoed in both the drop
  and menu paths.
- Panel modules declare `Contribution.panel` metadata (`icon`, `labelKey`, `gmOnly?`,
  `defaultPlacement`); defaults: chat docked right, every other panel launcher-closed (absent
  from the layout tree, not a minimized chip) until opened from the topbar `LauncherMenu`
  ([[shadowcat-codebase-client-shell]]) — toggling the same launcher item again minimizes it
  back to a statusbar chip.
- `src/client/shell/public/popout.html` — same-origin loader document served at
  `/popout.html` by `static_handler` (exact-match lookup, real 404-on-miss — NOT a
  SPA catch-all; verified against `static_handler`). A popped-out panel's `Window`
  navigates here; `dockview-core`'s own `addStyles` clones stylesheets into the cross-document
  popup. `[[embed-dist-compile-ordering]]`: the client build must run before the server embeds
  `dist/` (`dist/popout.html` presence is part of the build-verification step).

