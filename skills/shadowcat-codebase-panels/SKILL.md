---
name: shadowcat-codebase-panels
description: "Use when touching the Shadowcat panel-manager: @shadowcat/module-panels (layout tree + LayoutOp reducer, EngineAdapter/DockviewEngine/FakeEngine, PanelsController, PanelHost/PanelMenu/DockChips/CompactSwitcher), the shell's PanelsBridge (AppContext.panels), the shadowcat.panel contract panels contribute into, per-world panelLayout persistence, pop-out (same-heap window) panels + their restorable dormant arrangement records, or the stage-well veto rules (STAGE_ID — enforced inside panels; stage's own source is scene-rendering territory). Covers src/modules/panels/** + ui-kit panelsBridge. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Panel Manager (dockable panels)

Orientation for the dockable-panel system (dock/float/minimize/compact + pop-out
windows) that is the shell's sole panel surface — there is no tabbed sidebar.

## Purpose

In-game UI panels (chat, assets, actors, factions, conditions, game-settings, settings) are
dockable/floatable/minimizable windows managed by `@shadowcat/module-panels`. Layout truth is a
**pure tree** (`PanelLayoutV1`) mutated only through a **reducer** (`applyOp`); the docking
engine (dockview-core) is an interchangeable presentation adapter behind `EngineAdapter` —
every engine gesture is intercepted, classified into a `LayoutOp`, and re-dispatched through
the reducer (intercept-and-redispatch), so the engine never owns state.

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
  reads the same bridge reactively, no second controller.
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

## Hard invariants

- **All layout mutations flow through `applyOp`** — no direct engine-state writes; engine
  events are preventDefault-ed and re-dispatched as classified ops in BOTH the drop and menu
  wires.
- **Stage well is inviolable** — `STAGE_ID` ops are vetoed at policy AND handler layers; the
  stage never becomes a dockview panel.
- **dockview imports confined to `DockviewEngine` (+ its `dockview.test` module)** — everything
  else sees `EngineAdapter`.
- **Same-reference no-op**: `applyOp`/`prune` return the input object unchanged when nothing
  changes (persistence debounce + tests depend on it).
- **Keep-mounted panels**: hide via CSS/adoption, never `{#if}` — panel state and seed
  `$effects` must survive dock/float/minimize/compact transitions.
- **Late registrations must not reset a saved layout** — placement resolves against the
  retained pre-prune `source`, not `defaultPlacement` [[contribution-seed-reactive-before-resync]]-adjacent boot-order hazard.
- **`gmOnly` is client-advisory** — server remains sole authority over panel data.
- **Async engine callbacks need object identity, not just id-key guards** — a panel recreated
  mid-flight (float transition) invalidates key-equality staleness checks
  [[async-completion-needs-object-identity-not-key]]; see `DockviewEngine.#floatTransitionIds`.
- **Pop-out is gesture-time imperative, never routed through `apply()`'s declarative
  reconcile.** The only producers of a `LayoutOp.popOut` tree op are the menu-command handler
  `DockviewEngine.#requestPopOut` and the restore gesture `DockviewEngine.restorePopouts`,
  both funneled through the shared `#popOutPanel` core, which calls the
  `window.open`-backed driver FIRST and emits the op only after that promise resolves `true`
  (a blocked/failed open degrades to `LayoutOp.float` at `MENU_FLOAT_RECT` plus a
  `panels.popoutBlocked` notice). No code path can need pop-out
  reconciled through the reducer's `apply()` diff and silently miss it, because `apply()` never
  originates a `LayoutOp.popOut`/`LayoutOp.popIn` op — it only consumes ones already emitted
  imperatively; its own popout handling is hands-off seeding (a live window's panels and
  their origin groups go into the seen sets so the orphan-removal pass leaves the popout
  untouched). A
  browser popup cannot be opened outside a user gesture; this is why rehydration-on-load
  floats a persisted window's panels and retains the record as dormant, leaving the actual
  reopen to the gesture-gated `restorePopouts`.
- **`#pendingPopouts` in-flight guard is required because dockview-core's `mutation()` wrapper
  does not span `addPopoutGroup`'s async gap** — its finally clause fires the instant the async
  function RETURNS the pending promise, not when it settles, and `getNextGroupId()` is fresh on
  every call. A second "Pop out" click on the same panel before the first resolves would
  otherwise fire two independent `window.open()` calls and corrupt `#poppedOutGroupPanels`. Set
  the guard before calling the driver; clear it in both `.then()`/`.catch()` and in `destroy()`.
  The same set also guards BOTH of `apply()`'s placement loops (zone tabs and floating): a
  panel whose pop-out is in flight has already left its old group in dockview's model while
  the tree a stale `apply()` reconciles still lists it (e.g. the zone-shrinking
  `LayoutOp.resizeZone` op the move triggers reconciles the pre-`LayoutOp.popOut` tree) — relocating
  the widget back would yank the panel out of its new popout window (and throw on the hidden
  origin group, which `addPanel` cannot address as a reference group), so the loops skip it
  and let the imminent `LayoutOp.popOut` op's own `apply()` reconcile.
- **A popped-out panel's origin group must be seeded into `DockviewEngine.apply.seenGroupIds`, via
  `#poppedOutOriginGroups`, or it is orphan-removed on the very next `apply()`.** dockview-core
  keeps that origin group alive-but-hidden (`setVisible(false)`) internally — its own
  window-close path expects to hand the panel back to that exact group object — but the
  reducer's tree no longer names it once `detach()` strips the now-empty group. Capture
  `panel.group.id` SYNCHRONOUSLY before the driver call (capturing after resolves to the wrong
  group). This and the in-flight guard above are properties of the vendored `dockview-core@7.0.2`
  CJS source (`DockviewComponent`, `PopoutWindowService`), not of the wrapper code — read that
  source, and re-verify against it on any dockview-core version bump.
- **`#handleRemovePopoutGroup` (real window-close → `LayoutOp.popIn`) has three branches that must
  all be covered by a test that actually fires `onDidRemovePopoutGroup`, not a synthetic op**: the
  `#applying`-suppression branch (a `LayoutOp.popIn` must NOT fire when OUR OWN `apply()` reconcile is
  what caused the popout group's removal, e.g. a menu "dock" on a popped-out panel), the
  fallback that reads the panel ids off the removal event's own group when the panel isn't in
  `#poppedOutGroupPanels`, and the
  `STAGE_ID` skip. All three read correct on inspection, which is exactly the property this class
  of bug has in this file — do not trust inspection alone for changes here. The bookkeeping
  cleanup runs unconditionally on EVERY branch, window gone regardless of cause:
  `#poppedOutGroupPanels`/`#poppedOutOriginGroups`, the gid→window-key translation
  `#popoutWindowKeys`, the per-group subscription bundle `#popoutGroupSubs`, and the popout
  `Document`'s theme registration `#popoutDocumentUnsubs`.
- **Pop-out geometry is captured from the live `Window`, NEVER from the event payload.**
  `#handlePopoutGeometryChange` (both `DockviewApi.onDidPopoutGroupSizeChange` and
  `DockviewApi.onDidPopoutGroupPositionChange` funnel into it, component-level subscriptions
  for the component's whole lifetime) reads `screenX`/`screenY`/`innerWidth`/`innerHeight`
  off the popout entry's own live window (`DockviewApi.getPopouts()` matched on the group),
  because the vendored `dockview-core@7.0.2` window-move-end listener inside
  `DockviewComponent`'s pop-out wiring fires its position
  event with `screenY` populated from `window.screenX` — a confirmed upstream defect that
  makes the payload unusable. The emitted `LayoutOp.updatePopoutGeometry` is addressed by the
  tree's window key via `#popoutWindowKeys`, and a degenerate mid-close box (non-positive
  width/height) is never persisted — `isScreenRect` requires strictly positive dimensions.
  No `#applying` guard here: `apply()` never touches a popout window, so these events can
  never be self-caused. Re-verify the payload defect against the vendored source on any
  dockview-core version bump.
- **`#applying` is a synchronous-only guard — it cannot suppress an `AsapEvent` listener**
  (live floating re-drag/resize sync). `DockviewApi.onDidLayoutChange` is dockview's `AsapEvent`:
  `.fire()` schedules delivery via `queueMicrotask`, so every listener runs on the
  NEXT microtask, after `apply()`'s synchronous `finally { this.#applying = false }` has already
  reset the flag. A handler bound to this event that checks `#applying` gets a permanent `false`
  regardless of cause — worse than no guard, since it reads as protected. `#handleFloatingLayoutChange`
  instead diffs the freshly-read overlay-outer rect (`#floatingOverlayRect` — the group-level
  `boundingBox` is deliberately NOT used: it measures the content element below the titlebar,
  so a rect round-tripped through it drifts by the titlebar's height on every
  gesture→persist→recreate cycle) against `#lastFloatingRect`, a per-id cache
  `apply()`'s floating loop snapshots to the TREE's own rect on every reconcile (whether or not
  that iteration touched dockview); a `LayoutOp.resizeFloating` op's own round trip re-snapshots the
  identical rect, so the diff reads unchanged and nothing re-fires, with no dependency on
  `apply()`'s synchronous window. Also why re-position sync can't reuse the per-group
  `onDidDimensionsChange` pattern used for docked zones — that event, owned by dockview-core's
  `PanelApiImpl`, only ever carries width/height, so a pure drag with no size change never fires
  it at all; only `onDidLayoutChange` (fed by `Overlay`'s `onDidChangeEnd`) covers both
  gestures. Both facts live in the vendored `dockview-core@7.0.2` source, not the wrapper code —
  read it, and re-verify on any dockview-core version bump, same as the pop-out invariants above.

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
- Dragging a panel into an already-open popout group now flows through `applyOp` too:
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
  skipped whole. A menu pop-out always mints a FRESH key (`crypto.randomUUID`) — a dormant
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

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_module-panels.html` (TypeDoc —
  `@shadowcat/module-panels`), `_shadowcat_ui-kit.html` (`PanelsBridge`). Produce with
  `pnpm build:all`.
- Design: `docs/superpowers/specs/` (panel-manager + pop-out windows); implementation plans
  under `docs/superpowers/plans/`.
- Relationships: `graphify query "panels controller layout tree engine adapter dockview bridge chips popout"`.
- Shell/AppContext side: [[shadowcat-codebase-client-shell]].
