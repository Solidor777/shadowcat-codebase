---
name: shadowcat-codebase-client-shell
description: "Use when touching the Shadowcat UI shell: the contribution/Surface module architecture, Contribution.panel metadata, AppContext (incl. the chat, uiState.panelLayout, panels/PanelsBridge, canCreate/canDelete + role_capabilities, the rejected-intent toast, and multi-scene viewedSceneId/setGmViewedScene/searchDocuments/sceneSelection seams), the hash router + entry views, i18n/locale, or the shell/UI modules (entry, core-ui, topbar, statusbar, settings, scene-browser, notes, tables, onboarding), the interaction primitives (EscapeCoordinator Escape handling, the drag controller and drag-and-drop helpers, the context-menu trigger, KeybindingsController, the guided tour), and the route-prefix rule (base-path apiPath/wsUrl/basePath). Covers src/client/{shell,ui-kit} + those src/modules + the core files tour.ts, dnd.ts, keybindings.ts and base-path.ts. For the panel-manager internals (module-panels, engines, layout tree) invoke shadowcat-codebase-panels; for the render-engine consumption of viewedSceneId invoke shadowcat-codebase-scene-rendering. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Client Shell & UI Modules

Orientation for the SPA shell, the UI-as-modules contribution architecture, and i18n.

## Purpose

The browser UI is layered: a thin app **shell** bootstraps routing/session/AppContext and wires
the default module set; in-game UI is contributed by `src/modules/*` packages into named
**surfaces** via a `provides`/`requires` contract system; entry views (login/world management) are
plain-routed, not contributions. i18n is a framework-neutral core with a thin Svelte adapter.

## Key files & seams

- `Contribution`, `ContributionRegistry` (modules
  contribute UI into named surfaces). `Contribution.panel?` is optional
  plain-data panel metadata (`icon`, `labelKey`, `gmOnly?`, `defaultPlacement`) the panel host
  renders; `labelKey` is an i18n key the HOST resolves (locale-reactive). There is no `tab`
  field — a `Contribution` describes only a panel.
- **Panels are the sidebar**: the sidebar module and ui-kit
  `TabbedSurface` do not exist. `@shadowcat/module-panels` provides the multi
  `shadowcat.panel` contract every panel module contributes into, hosts `PanelHost` in
  core-ui's singleton `shadowcat.surface:panel-host` region and the minimized-chips strip in
  statusbar's `shadowcat.surface:panel-dock`. Keep-mounted rule carries over: panels hide via
  CSS/slot adoption, never `{#if}`; hidden content reads `scrollHeight = 0` (module-chat's
  IntersectionObserver pattern still applies). Internals → [[shadowcat-codebase-panels]].
- `ModuleRegistry`; `ServiceRegistry`; a `singleton`-cardinality `provides` collision is resolved
  by graceful demotion + explicit `ContractProvide.priority` (see `shadowcat-codebase-module-toolchain`),
  not an abort. `reconcileTopology(...)` is a separate, warn-only comparison of the client's own
  resolved `provides`/`requires` against the server-broadcast topology. Contract schemas:
  `ContractProvideSchema`.
- `<Surface>` is the host that renders contributions for a
  surface id; `AppContext`, `setAppContext`/`getAppContext`, `__APP_CONTEXT_KEY__`.
- `src/client/ui-kit/src/{sceneInteraction,actorSelection,tokenSelection}.*` — AppContext seams.
- **Detailed seams live in reference files** (table below). Read the matching file before changing the seam; each entry names what it covers.
  - System contract and server-seeded world-setting defaults, the i18n adapter (translate, plural, compare, fallback locale, module message registration), the actor, token and scene selection classes, serverRole, pathfind, combat, the hook bus fault hook, the component-facing hooks API, the notification cap and the shared sort-key primitive: references/appcontext-i18n-and-session-seams.md.
  - Move request and move stream seams, the shared-ruler seams, cold-start bootstrap from the snapshot, external-module loading and live reload, route-first boot, navigate, bounded boot fetches and the boot deadline, and the WorldSession activation latch and partial teardown: references/world-session-and-boot.md.
  - The ui_state persistence pipeline (leaf-key dirty tracking), theming, the performance mirror, multi-scene and viewed-scene seams, the asset pick seam, where the chat segment renderer lives, the chat and speak-as AppContext seams, canCreate and canDelete with role capabilities, the rejected-intent toast, firstChannel and buildMoveOp, and the single Update-op builder: references/session-state-theming-and-chat-seams.md.
  - Escape coordinator and dialogs, the drag controller, context menus, notification progress, keybindings, folder trees and shared ui-kit components: references/interaction-primitives.md.
  - New AppContext members (presence, member profiles, module status, portal, pause, chat-history recall) and their fixture rule, the route-prefix rule for client URLs, the onboarding tour contract and module, and the settings sections (backups, trash, port forwarding, account): references/session-features-onboarding-and-settings.md.
  - Per-package notes for the entry, core-ui, panels, stage, topbar, statusbar, settings, game-settings, scene-browser, chat, combat-tracker, notes and tables modules, including the layout grid growth cap: references/ui-module-packages.md.

**Reference files:**

| File | Holds | Read it when |
|---|---|---|
| references/appcontext-i18n-and-session-seams.md | System contract, i18n, selection classes, serverRole, pathfind, combat, hook bus, hooks API, notifications, sort keys | changing AppContext seams, i18n, or those helpers |
| references/world-session-and-boot.md | Move seams, shared ruler, cold-start bootstrap, external modules, boot and navigate, activation latch | touching WorldSession, App boot, or the move and ruler seams |
| references/session-state-theming-and-chat-seams.md | ui_state persistence, theming, performance mirror, multi-scene, asset pick, chat and speak-as seams, canCreate and canDelete, reject toast, op builders | touching persistence, themes, scenes, chat wiring, or write helpers |
| references/interaction-primitives.md | Escape, dialogs, drag, menus, notifications, keybindings, folder trees | adding any of those interactions |
| references/session-features-onboarding-and-settings.md | New AppContext members, route prefix, tours, settings sections | adding an AppContext member, a tour, a settings section or a same-origin fetch |
| references/ui-module-packages.md | Per-package notes for the shell and UI modules, layout grid | changing one of those modules or the layout |


## Hard invariants

- **A value put into `setContext`/AppContext must be a stable, in-place-mutated ref** (e.g. a
  `SvelteMap`), not a reassigned `$state`, or consumers hold a stale snapshot
  [[svelte-context-stable-ref]].
- **Contribute/activate before any await that gates the host mount** — an async-populated
  contribution Surface paints blank until activation runs; the minimal fix touches only the
  diverging path [[refactor-async-contribution-paint-timing]].
- **In-game elements communicate ONLY through seams** (module contracts, `ContributionRegistry`,
  `<Surface>`, AppContext, render-layer API) — never import one another or the shell directly.
- **Entry views are plain-routed, not contributions; surfaces are in-world only.**
- **Escape is registered, never listened for:** a component adds a handler to `EscapeCoordinator` instead of its own keydown listener (references/interaction-primitives.md).
- **Overlays draw on `--z-popover`:** dockview stacks floating groups at 999 + 2n, so a dialog, scrim or menu on a literal near 1000 hides behind open floating windows; `--z-popover` (50000, in both `_semantic.scss` and `theme.ts`) stays above that range and below the drag ghost at 99999 (references/interaction-primitives.md).
- **No bare same-origin URL literal in client code:** every `/api`, `/modules` and socket URL is built with `apiPath` / `wsUrl` so a route prefix works; `pnpm lint:route-prefix` fails otherwise (references/session-features-onboarding-and-settings.md).
- **Config docs are server-seeded; a panel never creates one.** Every config singleton
  (world-settings, the faction/condition/channel/resource registries, chat/dice settings,
  system-defaults) exists from world creation/join via the server's `ConfigSeed` path, so a
  panel `$effect` that creates a missing config doc is a defect, not a convention. Panels read
  reactively (`createSubscriber` + `subscribe()` — a plain store read inside `$derived`/`$effect`
  registers no dependency, and panels mount during `#onWelcome` BEFORE the resync stream
  populates the store) and EDIT with real-OCC stored pre-images only
  [[contribution-seed-reactive-before-resync]].

## Gotchas

- **i18n MUST stay framework-neutral** — the core `I18n` is Svelte-free; the Svelte
  `t`/`locale`/`plural`/`compare` adapter wraps it via `createSubscriber`. Don't pull a Svelte i18n
  lib into core.
  **The cross-locale fallback is `fallbackLocale` only, not every loaded locale:** a key/entry
  missing from the ACTIVE locale's catalog is looked up in `fallbackLocale` (`"en"` for the shared
  `i18n` singleton) before falling through to the raw key string — a locale that is neither the
  active one nor the fallback is never consulted. A partial translation in a THIRD locale therefore
  still ships visible key text unless the missing key also lands in `fallbackLocale`'s catalog.
- **`setAppContextForTest` does not emulate optimistic behavior** —
  `documents` defaults to `over.documents ?? over.store ?? new
  DocumentStore()`, so a test overriding only `store` gets that SAME plain store as `documents`.
  Predicted-op overlay and rollback-on-reject are absent; reads through `documents` are plain
  authoritative reads. In production the two are INDEPENDENT siblings fed the same `applyCommand`.
  A test asserting optimistic semantics must supply its own `documents`, or it is asserting
  nothing. (Same fixture-fidelity class as that
  fixture's identity-echo `t: (k) => k`, which resolves every key to itself rather than through a
  catalog.)
- **`WorldSession.canEdit` is an affordance mirror, and it diverges from server authz in BOTH
  directions** — treat it as "which controls to show", never as the
  authority. It can over-permit: the `role === "gm"` short-circuit returns `true` unconditionally and
  never consults `doc.permissions.gm_role`, while the server's GM bypass is CONDITIONAL — a doc
  carrying `gm_role: Some(role)` floors even a GM to ordinary `DocRole` resolution
  (`data::permission::effective_role`/`data::permission::resolve_access`). It can also over-restrict: the Welcome
  union mixes GM-authored `world_cap_requirements` with module-declared manifest requirements, and
  the server does NOT reject a write merely because a module declared a requirement on that path.
  **The two halves are unobservable today for UNRELATED reasons, and arm on unrelated triggers —
  do not give them a shared bound.** The over-permit is neutralized by the server: `SqliteRepository::apply_intent`
  re-checks independently, and `gm_role` is currently written only by chat-message construction
  (`chat::build_message_doc`), whose `message` doc_type the server rejects ordinary client Updates to outright
  regardless of role (`SqliteRepository::apply_intent`; only the server-set `WriteOrigin::ServerMessageRevision`
  bypasses it, which no wire message can name). It arms if `gm_role` is ever set on another
  doc_type. The over-restrict is NOT neutralized by that re-check at all — hiding a control means
  the user never reaches `apply_intent` — it is merely unobservable while no enabled installed
  module declares `requirements`, since the Welcome union then contributes nothing beyond the
  GM-authored record. It arms when an ENABLED, ENGINE-COMPATIBLE module declares a non-empty
  `requirements` — compatibility is re-checked on every Welcome, not just at enable time, so a
  module that has gone stale stops publishing — with no `gm_role` involvement whatsoever
  (`ws::conn::welcome_capability_requirements`, whose own doc marks the union ADVISORY ONLY,
  vs. `SqliteRepository::apply_intent`'s enforcement reading only `world_cap_requirements`).
- **`listWorldMembers` has ONE implementation, not a fork.** It lives in `@shadowcat/core`'s
  `user-rest` module (re-exported from `@shadowcat/core`'s public entry), `encodeURIComponent`s the
  world id, bounds its fetch with a dedicated timeout constant, and surfaces the server's error
  text. `WorldSession` (the shell) imports it directly from `@shadowcat/core`; the shell's own
  `api` module declares no member-roster function of its own. Any new caller should import the
  same `@shadowcat/core` function rather than adding a shell-local copy.
- **Refactors across a callback boundary must preserve decision branches, not just await ordering**
  [[refactor-preserve-decision-branches]].
- UI packaging target: swappable entry package + per-element packages + thin shell
  [[ui-packaging-target]].

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_shell.html`, `_shadowcat_ui-kit.html` (TypeDoc),
  plus the shell/UI module pages `_shadowcat_module-core-ui.html`, `_shadowcat_module-entry.html`,
  `_shadowcat_module-topbar.html`, `_shadowcat_module-statusbar.html`,
  `_shadowcat_module-scene-browser.html`, `_shadowcat_module-settings.html`,
  `_shadowcat_module-game-settings.html`, `_shadowcat_module-notes.html`,
  `_shadowcat_module-tables.html`. Produce with `pnpm build:all`. `@shadowcat/module-settings`
  and `@shadowcat/module-game-settings` are distinct packages with distinct pages.
- Rationale: `docs/design/ARCHITECTURE.md` §1 (client UI packaging) + §2 invariant 7 (framework-neutral API).
- Relationships:
  `graphify query "contribution registry surface appContext shell router i18n locale panel"`.
- History: [[m7-brainstorm]], [[m6b-modules-capabilities]].
