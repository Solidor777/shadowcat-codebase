---
name: shadowcat-codebase-module-toolchain
description: "Use when touching the external/community module toolchain: server-side installed-module discovery + path-traversal-guarded static serving + per-world enablement (`scan_installed_modules`, `http::module_routes`, `Config.modules_dir`), the engine-compat semver gate, the Welcome server_version + capability-requirements union, or the client consumption path (the `loader`/`modules`/`module-rest`/`manifest` modules' engine checks, shell import-map single-instance build + `WorldSession.#loadExternalModules`, `ModuleManager` UI). Covers out-of-tree modules developed in their own repositories, the authoring guide docs/site/guides/creating-a-module.md (docs/design/module-authoring.md is a pointer stub), and the examples/* scaffold packages. Invoke shadowcat-codebase-core first; for the shell/AppContext seams invoke shadowcat-codebase-client-shell."
---

# Shadowcat — External Module Toolchain

Orientation for how a module built OUTSIDE the engine repo (own git repo, own release cycle) is
installed, discovered, served, enabled, and loaded. Orientation+index only:
points INTO graphify, `docs/design/`, and memory.

## Purpose

An installed module lives at `<data-dir>/modules/<folder-id>/` as a `module.json` manifest plus a
pre-built ESM bundle. The **server discovers and serves it as static files but NEVER executes any
module code**. A GM enables a module per-world; the client shell
supplies exactly one runtime instance of `svelte`/`@shadowcat/*` via an import map, fetches the
enabled set after `Welcome`, dynamically imports each enabled module through the real
modules-folder → server → import-map path (identical in dev and prod), and activates it through the
existing `ModuleRegistry`.

## Key files & seams

**Server (authoritative, never runs module code):**
- `modules` — `scan_installed_modules(dir)` walks `<dir>/*/module.json`, parse +
  validate each (invalid `id`/`version`/JSON → warn + SKIP, never blocks startup or hides siblings).
  `InstalledModule { id, requirements, engines_shadowcat, manifest_json, entry_url }` where **`id`
  is the install FOLDER name, not the author-declared manifest id**. `entry` (module.json field,
  `default_entry` = `index.js`) computes `entry_url` = `/modules/<folder>/<entry>`.
  `semver_satisfies` (exact/`^`/`~`/`*`, caret-0.x leftmost-non-zero fix) + `engine_compat_ok`
  (**fail-closed**: missing `engines.shadowcat` → reject).
- `http::module_routes` — `InstalledModuleInfo { id (folder id), manifest,
  entry_url }` (ts-rs → `src/types/generated/`); `list_installed_modules` (`GET /api/modules`,
  any-auth); `serve_module_file` (`GET /modules/{id}/{*path}` — two-stage canonicalize +
  `is_strictly_within` proper-descendant check, guards BOTH the `id` segment and the `*path`
  segment, rejects path==root equality); `set_world_enabled_modules`/get (`PUT/GET
  /api/worlds/{id}/enabled-modules`, `require_gm`, atomic validate-all + dedup, `MAX_ENABLED_MODULES`).
- `config` — `Config.modules_dir: Option<String>` + `modules_path()`; the
  `test_server --modules-dir` flag (the `test_server` binary) sets it for e2e.
- `ws::conn`/`ws::protocol` — `ServerMsg::Welcome.server_version`
  (`env!("CARGO_PKG_VERSION")`); `welcome_capability_requirements` non-destructively UNIONs the GM's
  `world_cap_requirements` with each `engine_compat_ok` enabled module's `requirements`. Its
  `scan_installed_modules` call runs through `modules::ModuleScanCache` (one instance shared
  server-wide via `ws::WsState::module_scan_cache`), not a fresh scan on every `Welcome` — see the
  Gotchas entry below for the invalidation rule this cache depends on.

**Client core (framework-neutral):**
- The client `loader` module — `loadModules(...) → Promise<ModuleLoadResult { loaded, failed }>`
  — **per-module contained, NON-throwing** (a single module's import/compat failure never aborts
  the batch); `checkEngineCompat`; fail-closed when `opts.shadowcatVersion` is absent.
- The client `modules` module — `ModuleRegistry.activate()` is per-module isolated: a throwing
  `register()` is logged + skipped (rolled back), the topo loop continues. A `singleton`-cardinality
  `provides` collision does NOT abort or skip: `computeSingletonWinners` picks one winner per
  contested contract (an already-active provider wins unconditionally — stability, activation never
  unseats live state; otherwise the highest `ContractProvide.priority`, default `0`, ties broken by
  `topoSort` order) and every losing claimant is demoted (`ModuleRecord.demoted`) rather than
  blocked — it still activates in full, it just doesn't count as an active/declared provider of the
  one contract it lost (`activeProvidersOf`/`declarations()` both filter through `demoted`). A
  module can opt in to checking its own outcome via `ModuleContext.isSingletonProvider`. `provides`
  stays purely declarative: nothing gates a module's own `register()` calls against demotion unless
  the module checks itself. **Rollback-on-throw:** a `register()` throw mid-registration is
  caught, then `activate()` calls the module's own `unload(id)` to roll back any partial side
  effects (hooks/services/middleware/contributions) it already registered before throwing — safe by
  construction since `r.active` is still `false` at the catch point (`activeDependentsOf(id)` is
  therefore always empty, topoSort guarantees no dependent activates before its dependency). The
  `unload(id)` call is itself wrapped in its own try/catch (logged, not propagated) so a SECOND
  throw during rollback can't abort the whole activation loop — modules ordered after the failing
  one still activate.
- The client `module-rest` module — `listInstalledModules` / `getEnabledModules` /
  `setEnabledModules` REST wrappers (consume `InstalledModuleInfo` via unchecked cast — no Zod).
- The client `manifest` module — `engines?: ModuleEngines` (optional; first-party modules never
  set it, community modules MUST); `requirements` are advisory. The client `semver` module —
  caret-0.x fix mirror of the server.

**Client shell:**
- **`RUNTIME_ENTRIES`** — the client shell's multi-entry export list (svelte, svelte/internal/client,
  svelte/internal/disclose-version, svelte/reactivity, @shadowcat/{core,ui-kit,formula,types}) →
  stable `runtime/<name>.js` chunks + **`preserveEntrySignatures: "strict"`**; `index.html` import
  map maps each bare specifier to its chunk.
- The `check-svelte-runtime-entries` script — a build-time CI guard scanning all client/module
  source for `svelte/*` bare-specifier imports, failing if any resolve to a subpath NOT present in
  `RUNTIME_ENTRIES` — catches the "import map serves a FIXED svelte-subpath set" gotcha below at
  build time instead of a runtime `SyntaxError`. Wired into `.github/workflows/ci.yml`'s web job +
  `package.json`'s `check:svelte-runtime` script. Its CLI-entry-point detection routes through the
  shared `isDirectEntry`, which resolves `argv[1]` before comparing it against
  `fileURLToPath(import.meta.url)` — so a relative or unnormalized invocation still matches, while a
  raw `file://${argv[1]}` string compare never matches on Windows (wrong scheme/separator/
  drive-letter handling). Every additional spelling of that decision is free to disagree with the
  others on an `argv[1]` nobody tested, and its failure mode is a gate that scans nothing and exits
  0, so `isDirectEntry`'s own unit pin asserts it is the sole reader of `argv[1]` across the
  scripts tree.
- The shell `worldSession` module — `#loadExternalModules(world, serverVersion)`
  sourced from `w.server_version`; fetch enabled set → `loadModules` → activate; keyed on `info.id`.
  `WorldSession.reconcileInstalledModules()` is the live-reconcile sibling, called after a
  `ModuleManager` save (client-shell skill has the full seam + the folder-id/manifest-id dual
  key-space it must track to unload the right registered module).
- **`ModuleManager`** (`@shadowcat/module-settings`) — GM installed-module management UI; toggle/save
  keyed on the canonical folder `info.id` (manifest id is display-only); a successful save also
  calls `AppContext.reconcileInstalledModules()` so the toggle takes effect in the running session
  immediately.

**Out-of-tree reference + guide:** an external module is developed in its own git repository and
may be nested into a Shadowcat checkout under `src/modules/` so the pnpm workspace resolves
`@shadowcat/core`/`@shadowcat/formula` for dev; it is never bundled statically, even in dev.
**A nested checkout is inside this repo's gate perimeter.** `check-lint-allowances` walks every
entry of its `ROOTS` recursively and prunes only what its `SKIP_DIRS` names — build outputs and
dependency trees — and the ephemeral-reference gate scopes itself the same way. The client source
tree is a root and a nested module checkout lives under it, so this repo's suppression ban and
ephemeral-reference ban apply to the nested repository's SOURCE and the comments in it, and fail
here even though that repository has its own lint config or none. Its Markdown is not gated: the
ephemeral-reference gate's prose corpus is `MD_ROOTS`, which names the skills directory alone; out
of `ROOTS` it reads only the code extensions `EXTS` lists. Nesting is a dev convenience with no entry
in either gate's skip set: unnest before running the gates, or expect the nested contents to be
judged by them.
**The documentation build sits inside the same perimeter, by a different mechanism.**
`entryPoints` includes the client-module glob, and the
root `exclude` is consulted while the packages strategy EXPANDS that glob: an excluded directory is
never selected as a package at all. So a nested checkout carrying a `package.json` becomes a
converted package the moment nothing excludes it. What that does NOT produce is a coverage failure:
`Options.copyForPackage` resets every value to its default, `validation`'s `notDocumented` default
is off, and a foreign package extends none of this repo's shared configuration — so it opts into no
coverage check and `treatValidationWarningsAsErrors` has no warning to escalate. The real break is
coarser: a selected package that fails to CONVERT aborts the whole run, and `skipErrorChecking`
defaults to off, so a TypeScript diagnostic in a checkout this repo does not build (an uninstalled
dependency, a type error), an unreadable options file, or a nested `entryPointStrategy` of packages
takes the documentation build down with it — and one that converts cleanly instead joins the local
API output unannounced. The position is the two gates' above: unnest before running the build. A
nested-checkout exclusion here would make the documentation build the one gate in this repo that
carves them out, and a name-keyed one would go stale the first time a developer chose a different
directory name.
The
authoring guide lives in the docs site: `docs/site/guides/creating-a-module.md` (`docs/design/module-authoring.md` is a
pointer stub to it). Two in-repo CI-built worked examples double as copyable scaffolds:
`examples/module-initiative-tracker/` (panel + document read/write) and `examples/system-minimal/`
(sheet takeover + formula rules) — workspace members, so `pnpm -r test/typecheck` and the web CI
job's example-build step keep them green; the guides code-import their sources region-by-region.

## Hard invariants

- **The server NEVER executes installed module code** — it only discovers + serves it as static
  bytes. Authority over the `system` band stays structural.
- **Exactly one runtime instance** of `svelte`/`svelte/*`/`@shadowcat/*` —
  requires `preserveEntrySignatures: "strict"` so runtime chunks export real API names, verified by
  a test that IMPORTS each chunk (not just checks existence) [[build-artifact-tests-must-consume-not-just-exist]].
- **The enabled-module set is keyed on the install FOLDER id, never the manifest id** — the server
  controls folder names; author-declared manifest ids can collide and are untrusted as the key. Both
  client consumers (ModuleManager, worldSession) MUST key on the wire `InstalledModuleInfo.id`.
- **Engine-compat is fail-closed** (missing/unsatisfied `engines.shadowcat` → reject) at BOTH enable
  time and load time.
- **Module `requirements` are advisory to the client only** — unioned into the world's broadcast
  `capability_requirements`, but NEVER server-enforced at `apply_intent` (server authority stays with
  the GM's `world_cap_requirements`). A future explicit "GM adopts a module's requirements into the
  world policy" mechanism could make them enforced; until then advisory-only is the contract.
- **Path-traversal guard rejects equality, not just prefix** — a two-stage canonicalize must treat
  the modules root as a strict ancestor of both the `id` folder and the served file.

## Gotchas

- **`entry` is a `module.json` field read by the server scanner** (`modules`, default
  `index.js`), NOT part of the client `ModuleManifest` Zod shape — declare it in module.json only.
- **The import map serves a FIXED svelte-subpath set** — a module importing a subpath the host does
  not serve (`svelte/store`, `svelte/transition`, …) hard-fails with a runtime `SyntaxError`; adding
  one is a host change (`RUNTIME_ENTRIES` + import map), not a module change. See the
  creating-a-module guide (`docs/site/guides/creating-a-module.md`).
  The `check-svelte-runtime-entries` script (above) catches an unserved subpath import at CI time.
- **`loadModules` never rejects.** Its contract is the contained `ModuleLoadResult { loaded,
  failed }`, so a caller must read `failed` to see a module's import or compat failure — nothing
  propagates out of the batch.
- **Adding a required field to `Welcome`** (e.g. `server_version`) breaks untyped frame fixtures in
  every package — gate with `pnpm -r test`, not a single filter [[shared-wire-schema-change-needs-full-repo-test]].
- **`InstalledModuleInfo` is ts-rs generated** — edit the Rust struct, regenerate, never hand-edit
  the `.ts`.
- **HTTP path-traversal tests via `axum_test`/`fetch` are vacuous for bare dot-segments.**
  `axum_test::TestServer` builds URLs through the `url` crate's `Url::set_path`, which applies WHATWG
  dot-segment normalization CLIENT-SIDE before the request is sent — a segment that EXACTLY matches
  `.`/`..`/`%2e`/`%2e%2e` (and case variants) is collapsed/popped before it can reach the router or
  `serve_module_file`'s guard. A dot-segment test therefore proves nothing: confirmed —
  `serve_module_file_rejects_an_id_segment_that_escapes_the_modules_root` (`http::module_routes`)
  still PASSES against a deliberately-reverted, vulnerable guard. A NON-exact-match segment (e.g.
  `%2e%2e%2fsecret.txt` as one combined segment) is NOT normalized and DOES reach the handler intact.
  Write such tests as (a) a pure unit test of the containment predicate, (b) a symlink/alias HTTP
  repro (`http::module_routes`'s `self-link`-style test), or (c) an encoded segment embedded in a longer
  non-exact-match string.
- **`ModuleScanCache` invalidates on TWO independent mtimes, not one — dropping either silently
  reintroduces staleness.** There is no server-side install/uninstall route to hook (an operator
  installs by dropping/removing a folder directly under `modules_dir` on disk), so invalidation is
  structural: (1) `modules_dir`'s OWN mtime, bumped by the OS on any entry add/remove, catches
  install/uninstall; (2) each cached module's own `module.json` mtime, tracked separately, catches
  an IN-PLACE edit to an already-installed module's manifest (e.g. hand-editing `engines.shadowcat`
  after a server downgrade) — such an edit does NOT bump the parent directory's mtime. Tracking only
  (1) would silently break `welcome_capability_requirements`'s own documented guarantee that it
  re-checks `engine_compat_ok` per enabled module on every `Welcome`, not just at enable time. Not a
  TTL: a TTL is either too short (defeats the cache under a reconnect storm) or too long (an
  operator-installed module should go live on the next connect, per this project's hot-swappable
  design intent).
- **Scope deliberately excluded** (manual/admin-trusted tier): no module upload/install UI
  (install stays manual-extract into `<data-dir>/modules/<id>/`); no sandboxing/permissions for
  installed module JS (modules are admin-trusted, same tier as the server binary); no
  marketplace/registry, signing, or update channels. Per-world ENABLE/DISABLE of an already-
  installed module DOES hot-reload a running session without a client reload —
  `WorldSession.reconcileInstalledModules()` (client-shell skill) — but that is scoped to
  EXTERNAL/community modules only; a first-party module (`opts.modules`) is never torn down live,
  since first-party modules were never written expecting hot-unload (render/stage resources, WS
  channels, ECS state).

## Pointers

- **Generated API** — `/api/rust/shadowcat/modules/`, `/api/rust/shadowcat/http/module_routes/`
  (rustdoc, private items included), `/api/ts/modules/shadowcat-example-initiative-tracker.html`,
  `shadowcat-example-system-minimal.html` (TypeDoc — the two in-repo worked-example scaffolds).
  Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 invariant 6 (server runs no third-party code);
  `docs/site/guides/creating-a-module.md` (authoring toolchain — `docs/design/module-authoring.md`
  is a pointer stub).
- Relationships: `graphify query "installed module discovery serve enable engine-compat import map loader"`.
- Lessons: [[build-artifact-tests-must-consume-not-just-exist]],
  [[shared-wire-schema-change-needs-full-repo-test]], [[injected-callback-boundary-must-validate-every-site]].
