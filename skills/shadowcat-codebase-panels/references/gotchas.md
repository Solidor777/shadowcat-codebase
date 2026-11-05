# Panel Manager: Gotchas

Part of the shadowcat-codebase-panels skill. Read it before changing engine wiring, pop-out windows, floating geometry or registration, and when a panel behaves unexpectedly.

## Gotchas

- `register()` runs once per world entry (fresh ModuleRegistry per WorldSession) — one
  DockviewEngine per session, not app-wide. **FakeEngine reaches NO production path**: it is the
  default only when a caller mounts `PanelHost` WITHOUT an `engine` prop
  (`PanelHost`'s `engine ?? new FakeEngine()`), and the shipped module's `register()` always
  supplies a `DockviewEngine` — so that branch is taken today only by the test suite. It remains a
  real fallback SEAM any bespoke host could use; it is not dead code, and it is not production code.
- **`EngineAdapter.focus` is wired at `PanelHost`'s `onOp` callback, not inside `PanelsController`
  itself** — the controller holds no engine reference (only `PanelHost` does), so `PanelHost` calls
  `eng.focus(op.id)` for every `LayoutOp.open` its `PanelsController` construction-time `onOp`
  callback observes, alongside the existing `describeOp` live-region narration. This reaches
  `PanelsController.focus(id)` (→ `this.open(id)` → `dispatch`) from ANY caller of the reachable
  chain — `sheetsController` → `PanelsBridge` → `PanelsController.focus`, the topbar launcher's
  `open`, and an engine-originated reopen gesture alike. `dispatch`'s same-reference no-op contract
  means `onOp` (and so `eng.focus`) never fires for an "open" that changed nothing (e.g. an
  already-active docked tab or already-topmost floating window) — there is nothing to raise in
  that case. `DockviewEngine.focus` and `FakeEngine.focus` both early-return on `STAGE_ID`
  (structurally identical guard, not a coincidence of neither being called). The same
  no-engine-reference split shapes the restore gesture: the controller only DECLARES the
  `PanelsNoticeAction`; `PanelHost`'s `onNotice` callback assembles the actual `run` from
  `EngineAdapter.restorePopouts` + `PanelsController.restorablePopouts` host-side.
- Panel modules `requires` `PANEL_CONTRACT`, which topologically activates `panels` FIRST —
  late panel registration is the ROUTINE order, not an edge case.
- dockview's `onDidRemovePanel` fires synchronously inside `removePanel` — transition guards
  must be armed before the call.
- FakeEngine sizes its zones explicitly, because a zone `<div>` with no width of its own stretches
  to `host`'s full cross-size under `align-items: stretch`: `init()` nests a `row` flex container
  (left/center/right) with `bottom` full-width below it, and `apply()` applies `ZoneNode.size` as
  each zone's actual px width/height on every reconcile, with `min-width: 0`/`overflow: auto` on
  the zone and `width: 100%; min-width: 0` on each group `<div>` so oversized content scrolls
  within the zone instead of escaping it.
- jsdom cannot simulate a real pointer-drag gesture — `dockview.test` unit-tests
  `DockviewEngine` directly under jsdom (init/apply/DOM adoption) with duck-typed
  `DockviewWillDropEvent`s standing in for drops. NO e2e test exercises a real dockview tab
  drag either (`panels.spec` covers launcher-open→dock→reload-survival, re-toggle→
  minimize-to-chip, and the compact/expanded 48rem axis — launcher-closed defaults mean
  there is no chip on a fresh world until a panel is minimized); real-pointer drop-position
  classification fidelity is a known manual-QA gap — missing e2e coverage for an
  otherwise-correct path, not a defect in the logic itself.
- On any dockview-core version bump, re-verify `--z-popover` (1000, defined in `_semantic.scss`)
  still clears dockview's floating-overlay z-index (`--dv-overlay-z-index`, 999 at 7.0.2) — the
  popover menus stack above floating panel groups only by that numeric margin.
- Dragging a panel into an already-open popout group emits `LayoutOp.popOutInto` (never a
  pseudo-edge dock): `DockviewEngine.#handleWillDrop` and `#handleGroupWillDrop` classify a
  target group found in `#popoutWindowKeys` directly, ahead of `#toDropSite`, and delegate to
  `#handlePopoutWillDrop` — flat placement semantics (every dockview group-model will-drop
  kind — tab, header space, content — means "into this window"; the tree's flat panel list
  cannot represent a sub-window split anyway), an imperative per-panel `PanelApiImpl.moveTo` under the
  moving lock (mirroring `restorePopouts`'s joins, so no spurious `LayoutOp.close` ops),
  floating-source a11y teardown, and a fail-closed veto (preventDefault, no op) when no
  subject resolves to a live panel. A subject already living in the target window skips the
  move but still emits its op — the reducer's `LayoutOp.popOutInto` case is a same-reference no-op
  for an already-listed id, so it self-heals desync. The sync side:
  `DockviewEngine.#popoutGroupSubs` wires the popout group's own `onWillDrop` (closing the veto
  bypass, mirroring `#groupWillDropSubs`'s per-zone-group wiring) plus `onDidAddPanel`/
  `onDidRemovePanel` (keeping `#poppedOutGroupPanels`'s per-group array in sync with dockview's
  own nested-gridview drop target) the moment a pop-out succeeds, in `#popOutPanel`'s success
  branch — the single chokepoint every popout-group creation funnels through (the menu's
  `#requestPopOut` and `restorePopouts` alike), since `apply()`'s zone loop never
  touches one. Disposed in `#handleRemovePopoutGroup` (unconditionally, alongside the existing
  `#poppedOutGroupPanels`/`#poppedOutOriginGroups` cleanup) and in bulk by `destroy()`.
- `restorePopouts` re-opens each saved window on ONE user gesture (the notice action's click
  covers every `window.open` inside): the first restorable panel pops out through
  `#popOutPanel` under the window's ORIGINAL key — the reducer's `LayoutOp.popOut` case treats a
  repeat key as reviving the retained dormant record, redefining its panel list — at the
  window's saved rect, and each remaining panel then joins that window via dockview's own
  panel move-to API (its internal moving lock brackets the move, so no component-level
  add/remove events fire and no spurious `LayoutOp.close` ops result) plus a `LayoutOp.popOutInto`
  op. Partial records are tolerated: panels with no live panel (unregistered since the save)
  or already living in a popout are skipped, and a window with no restorable panel is
  skipped whole. A menu pop-out always mints a FRESH key (`randomUuid` from `@shadowcat/core`, the secure-context-safe
  id source) — a dormant
  record the panel belonged to stays intact for its remaining panels until a restore
  gesture revives it.
- A gesture-time pop-out reuses the panel's saved geometry when a dormant record carries
  one (`#savedPopoutRect`), clamped to the CURRENT screen's available bounds by
  `clampScreenRectToAvailable` before reaching the driver — the machine that saved the rect
  may have had a different display set, and a window reopened fully off-screen is lost UI.
  A degenerate zero-area `screen` read (headless test DOMs report all-zero screens) means
  the bounds are UNKNOWN: the saved rect passes through unchanged rather than clamping to a
  useless 1px box.
- The popped-out window's theme follows every later swap: the popout `Document` is captured
  via the on-did-open callback in the driver's `DockviewPopoutGroupOptions` (fired
  synchronously once `window.open`
  succeeds, before the driver's promise settles) and registered with the ui-kit theme
  controller (`theme.registerDocument`, tracked in `#popoutDocumentUnsubs`); inline theme
  application beats the stylesheets dockview clones into the popup on its later `load`
  event, so registering at that callback's time is not racy. Consequence for tests: an injected
  `popoutDriver` that actually opens a window MUST forward its options argument (including
  that callback) to `addPopoutGroup`, or the popped-out window silently stops following theme
  swaps.
- `DockviewEngine.#expandGroupDockOp`'s "new group" index computation assumes the dragged whole
  group is not already a member of the target zone — a same-zone whole-group reorder is a
  KNOWN, code-documented index-computation gap (an inline `TODO` beside that method),
  distinct from the real-pointer-drop-fidelity manual-QA gap above: that one is about missing
  e2e coverage for an otherwise-correct path, this one is a specific case the logic itself
  doesn't handle correctly yet.
- Popped-out windows never survive a page reload AS WINDOWS — `#rehydratePoppedOut` floats
  every live window's panels at construction (a page load has no user gesture to reopen a
  popup with) — but the ARRANGEMENT does: each window's entry is retained
  `PopoutWindowLayout.dormant`, and the `panels.popoutRestoredFloating` notice's action runs
  `restorePopouts`, the gesture-gated reopen that revives the record under its original key.
  A late-registering panel whose persisted location was popped-out gets the same treatment
  from `placeFromPersistedLocation`'s popped-out branch: floated at the cascade rect, with
  the window's dormant record restored from `source` (repairing what the boot-trickle prune
  dropped — without it the next persist would erase the saved grouping/rect for good; a
  same-keyed LIVE entry is never touched, since the user already re-opened that window this
  session).
- `jsdom` cannot exercise the real `window.open`/`addStyles`/`onDidRemovePopoutGroup` DOM path —
  unit tests drive the translation logic via the injected `popoutDriver` and fire dockview's
  real event emitters directly (e.g. `api.component._onDidRemovePopoutGroup.fire(...)`,
  verified against the vendored source) rather than simulating a real popup; the actual
  cross-window re-parent + stylesheet clone is dockview's own machinery plus a manual-QA item,
  same class as the real-pointer-drag gap above.
- **The default stub `popoutDriver` (`() => Promise.resolve(true)`) never actually moves the
  panel to a new group** — after a "successful" stub pop-out, `api.getPanel(id)?.group.id` still
  resolves to the panel's ORIGINAL, already-`#groupWillDropSubs`-tracked group, not a genuinely
  distinct popout group. A test targeting `#popoutGroupSubs`'s OWN wiring (not the pre-existing
  zone-managed one) needs a driver that behaves like real `addPopoutGroup` and actually relocates
  the panel — `dockview.test`'s `popOutToRealGroup` helper does this via `api.addGroup` +
  `api.removePanel`, then a fresh `addPanel` into that new group, synchronously inside the driver.
- jsdom never runs real layout, so the overlay element's `getBoundingClientRect` (the
  outer-frame box `#handleFloatingLayoutChange` reads via `#floatingOverlayRect`) always
  reads all-zero unless a test stubs it — `dockview.test`'s live floating re-drag/resize sync tests assign a replacement
  `getBoundingClientRect` directly onto the floating window's overlay element, then fire
  `(api as any).component._bufferOnDidLayoutChange.fire()` and `await Promise.resolve()` twice
  (the `AsapEvent` microtask hop) rather than simulating a real resize-handle/title-bar drag.
- Floating-window keyboard move/resize lives in `DockviewEngine.#handleFloatingKeydown`
  (wired per floating dialog by `#wireFloatingA11y`): plain arrows MOVE the window by
  `FLOATING_KEY_STEP` (8px; `FLOATING_KEY_STEP_LARGE`, 32px, with Shift), Ctrl+arrows RESIZE
  it from the bottom/right edges with the same steps, floored at `FLOATING_MIN_SIZE` (100px —
  a zero/negative size would fail `isRect`'s non-negativity guard on the next persist, and a
  tiny window is unreachable UI besides). Every accepted keystroke emits ONE
  `LayoutOp.resizeFloating` through the same op channel a drag uses (auto-repeat included),
  and the op's round trip back through `apply()` is what actually moves the widget — the
  engine never mutates it directly. The handler only acts when the event TARGET is the
  dialog wrapper itself: a keydown bubbled from an input inside the dialog belongs to that
  control, not to window movement. Pointer resize hit targets are CSS, not dockview's
  defaults: `panels.scss` enlarges dockview's transparent `.dv-resize-handle-*` elements to a
  24px floor (44px under a coarse-pointer media query), centered on the same edge so the
  visible border is untouched — re-verify the handle class names against dockview-core's
  stylesheet on any version bump.

