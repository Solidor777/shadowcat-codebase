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

Covers every key file and seam of the panel manager: the layout reducer, engine adapters, controller, host components and the shell bridge. Read references/key-files-and-seams.md before changing any of those files or tracing how a panel gesture reaches the layout tree.

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
  reopen to the gesture-gated `restorePopouts`. `LayoutOp.popOutInto` likewise has exactly
  two producers — the restore gesture and a drag into an open popout window classified by
  `#handlePopoutWillDrop`. The `#popOutPanel` success continuation runs a late-resolution
  guard: a `close` op landing in the driver's async `window.open` → re-parent gap has
  already detached the panel (and the reconciling `apply()` orphan-removed its widget), so
  when `api.getPanel(id)` is gone or the last-applied tree no longer lists the id
  (`#treeListsPanel`, mirroring `locate`'s dormant-skip) the continuation skips both the
  bookkeeping AND the op — recording either would ghost the panel as popped-out with no
  live widget behind it.
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
- **A persisted floating `Rect` is re-clamped against the CURRENT container on every `apply()`,
  read-time only, never written back.** `clampFloatingRectToContainer(rect, containerW,
  containerH)` fires ONLY when `rect` has NO overlap with the container at all (a rect persisted
  from a wider viewport, or a container that has since shrunk — a window resize, a mobile
  rotation) — a rect with ANY overlap, including one legitimately dragged partway off-screen
  (`Rect`'s own contract permits that), passes through completely unchanged; a continuous
  re-clamp must never undo a deliberate partial-off-screen placement. On a clamp, the rect is
  pinned to the container's top-left-most reachable slot at its own (container-capped) size. The
  clamped rect — never the tree's raw `f.rect` — is what `apply()`'s floating loop hands to
  `addPanel`/`#reconcileFloating` AND what it snapshots into `#lastFloatingRect`; snapshotting the
  unclamped rect there would desync the baseline `#handleFloatingLayoutChange` diffs against from
  the actually-rendered widget, manufacturing a spurious re-emit on the next layout-change event.
  `#floatingContainerSize()` is the SOLE degenerate-bounds guard for this clamp: it returns `null`
  for a missing `#host` OR a zero-area read (mirroring `clampScreenRectToAvailable`'s own
  degenerate-bounds fallback), and its one caller skips `clampFloatingRectToContainer` entirely on
  `null` — that function's own width/height parameters are therefore always positive, and the
  function carries no degenerate-bounds check of its own by design, so the decision has exactly one
  owner. **It reads `this.#host.getBoundingClientRect()` (the caller-supplied container `init()` is
  given), never `component.element`'s (dockview-core's OWN internally-created root)** —
  dockview-core assigns that root a fixed placeholder size at construction and corrects it only
  once its internal resize observer first fires, asynchronously, so a read taken right after a
  page reload (before that observer has fired) sees the placeholder rather than any real layout
  state and mis-clamps an already in-bounds persisted rect down to the placeholder's own size.
  `#host` is a real page-layout element sized correctly by CSS from first paint, with no
  placeholder-then-correct lifecycle of its own. `#floatingOverlayRect` (in references/gotchas.md) reads `#host` for
  the identical reason. Any future size/origin read this engine adds must do the same.

## Gotchas

Covers the panel manager gotchas: per-session registration, FakeEngine scope, engine and pop-out behaviours, and dockview-version-sensitive details. Read references/gotchas.md before changing engine or pop-out code and when debugging panel behaviour.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | Key files and seams of the panel manager | changing or tracing panel layout, engine, controller, host or bridge code |
| references/gotchas.md | Panel manager gotchas | touching engine wiring, pop-outs, floating geometry or registration, or debugging a panel |

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_module-panels.html` (TypeDoc —
  `@shadowcat/module-panels`), `_shadowcat_ui-kit.html` (`PanelsBridge`). Produce with
  `pnpm build:all`.
- Design: `docs/superpowers/specs/` (panel-manager + pop-out windows); implementation plans
  under `docs/superpowers/plans/`.
- Relationships: `graphify query "panels controller layout tree engine adapter dockview bridge chips popout"`.
- Shell/AppContext side: [[shadowcat-codebase-client-shell]].
