# Client shell - UI module packages

Part of shadowcat-codebase-client-shell: per-package notes for entry, core-ui, panels, stage, topbar, statusbar, settings, game-settings, scene-browser, chat, combat-tracker, notes and tables; read it before changing one of those modules or the layout grid.

- `src/modules/{entry,core-ui,panels,stage,topbar,statusbar,settings,game-settings,scene-browser,
  chat,chat-composer,chat-card,combat-tracker,notes,tables}/` — entry = `@shadowcat/module-entry` (login + world mgmt, behind
  `<Entry onEnterWorld>`); core-ui owns the layout grid + region surfaces into the singleton
  `root` (its main region hosts `shadowcat.surface:panel-host`; BOTH cells of the `1fr` row —
  `.main` AND `.toolrail` — carry the growth cap (`min-height: 0` + a non-visible `overflow-y`),
  because a grid row is at least as tall as its tallest item's minimum contribution: one
  uncapped cell grows the row, the grid and every sibling past 100vh, the document becomes
  scrollable, and a canvas rect measured before a scroll lands raw-coordinate gestures off the
  canvas — which is how a `ToolRail` taller than the row once broke token placement. `.main`
  hides overflow (the panel host owns inner scrolling); `.toolrail` scrolls its stacked
  contributions itself (`overflow-y: auto`, `overflow-x: hidden`). `Layout.test` enumerates
  the row's cells against the cap, reading component styles through jsdom's cascade — core-ui's
  vitest config compiles them with `emitCss: false`, since vitest never attaches an emitted CSS
  asset to the document); the grid's compact/expanded
  switch is keyed SOLELY off `sizeClass()` (48rem, `ui-kit`'s single breakpoint axis) — no
  media query; `grid-template-rows` reserves a fixed `2rem` statusbar row in both states.
  panels = the panel manager ([[shadowcat-codebase-panels]]); stage = the canvas stage well
  (inviolable — never docked/floated/minimized); the panel modules each contribute one
  `shadowcat.panel`; defaults are launcher-closed for every panel except chat (docked right
  by default); game-settings gmOnly. `topbar` = `@shadowcat/module-topbar`: hosts
  `LauncherMenu` (open/close any registered panel by id via `AppContext.panels.toggle` — a
  TOGGLE, so activating an already-open panel closes it; each item is a `role="menuitemcheckbox"`
  whose `aria-checked` reads `AppContext.panels.isOpen(id)` live, `launcher-item-{panelId}`
  testids, a11y menu + focus management; the shell e2e suite's ONE idempotent `openPanel`
  helper in `fixtures.ts` reads that attribute and clicks only when closed, dismissing the
  dropdown with Escape otherwise because the full-viewport launcher backdrop intercepts a second
  trigger click) + `Presence` (member
  roster) + a standing settings-entry button that toggles `settings:panel` through the same
  `AppContext.panels` seam — imports NOTHING from `@shadowcat/module-panels` (seam boundary by
  design: topbar's package.json declares no module-panels dependency and the launcher talks to
  panels only through `AppContext.panels`; NOT lint-enforced — the repo's sole
  `no-restricted-imports` rule covers `dockview-core` only, and .svelte files are unlinted).
  Below 48rem the
  topbar drops the world-name label and the scene-tools `ToolRail` collapses from a vertical
  side rail into a horizontal bottom strip (`sizeClass()`-driven, same axis).
  `game-settings` = `@shadowcat/module-game-settings` (GM-only): EDITS the world's singleton
  config-docs (every one server-seeded at world creation/join) — the vision/lighting trio
  (`world-settings`/`light-gradation`/`vision-modes`, resolved by
  `resolveSceneSettings`/`resolveGradation`/`resolveVisionModes`),
  plus `dice-settings` and `chat-settings` (the `hyperlinks` +
  `link_previews` tri-state toggles). World-defaults inputs display the provenance-resolved
  EFFECTIVE value while writes carry the RAW stored overlay leaf as the OCC pre-image, and the
  reset control CLEARS the leaf (writes null) so resolution falls through — never a
  client-resolved literal. The chat/dice server resolvers + segments are covered by
  `shadowcat-codebase-chat`/`-dice`. `game-settings` also carries three combat editors
  (`CombatSettings`/`CombatSceneOverrides`/`ResourceRegistryEditor`) and `combat-tracker` =
  `@shadowcat/module-combat-tracker` (the default combat tracker panel, order 2, launcher-closed)
  — both own end-to-end here (`CombatController`/`AppContext.combat` in references/appcontext-i18n-and-session-seams.md is their dispatch
  layer); the document/resolver shapes they read and write are `shadowcat-codebase-combat`'s.
  `notes`/`tables` (order 3, launcher-closed, neither `gmOnly`) = `@shadowcat/module-notes`/
  `-tables` — `NotesPanel`'s tree comes from `buildNoteTree` (`tree.ts`, a pure helper: a child
  whose parent is absent from the recipient's own view promotes to root rather than hiding, and
  every level orders by `(engine.sort, created_at)`); `TablesPanel` is a flat name-sorted list.
  Both live-search via `docTypes: ["note"|"table"]` (no client-side re-filter), gate Create on
  `canCreate`/Delete on `canDelete`, and are the panel-level consumers of `buildNoteDoc`/
  `buildTableDoc`/`buildMoveOp`/`firstChannel` in references/session-state-theming-and-chat-seams.md. The doc_type sheets these panels open into
  (`NoteSheet`/`TableSheet`) belong to `shadowcat-codebase-sheets`, not here.
