# Module toolchain: out-of-tree development and nested checkouts

Part of the shadowcat-codebase-module-toolchain skill; read it before nesting a module checkout,
changing a gate's roots or skip set, or adding an example module.

**Out-of-tree reference + guide:** an external module is developed in its own git repository and
may be nested into a Shadowcat checkout under `src/modules/` so the pnpm workspace resolves
`@shadowcat/core`/`@shadowcat/formula` for dev; it is never bundled statically, even in dev.
**A nested checkout is inside this repo's gate perimeter.** `check-lint-allowances` walks every
entry of its `ROOTS` recursively and prunes only what its `SKIP_DIRS` names — build outputs and
dependency trees — and the ephemeral-reference gate scopes itself the same way. The client source
tree is a root and a nested module checkout lives under it, so this repo's suppression ban and
ephemeral-reference ban apply to the nested repository's SOURCE and the comments in it, and fail
here even though that repository has its own lint config or none. Its Markdown is not gated: the
ephemeral-reference gate's prose corpus is the standalone `shadowcat-codebase` skills checkout
(`defaultSkillsRoot()`, outside this repo entirely since the plugin migration), never anything
under a nested module checkout; out of `ROOTS` it reads only the code extensions `EXTS` lists.
Nesting is a dev convenience with no entry in either gate's skip set: unnest before running the
gates, or expect the nested contents to be judged by them.
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

**Browser-test fixture modules:** test-only installed modules live under
`src/client/shell/e2e-support/fixture-modules/<id>/` (`module.json` plus a plain `index.js`; the
bare `@shadowcat/core` specifier resolves through the shell's import map like any installed
module). They are not workspace packages and never enter `dist/` or the release binary. The
Playwright loopback server in `playwright.config.ts` is started with `SHADOWCAT_MODULES_DIR` set
to `FIXTURE_MODULES_DIR`, so discovery lists them; no world enables one unless a spec does, through
the module manager. A loopback server that Playwright reuses (`reuseExistingServer`) keeps the
environment it started with, so restart it when a fixture folder is added or the variable was
missing. `vision-kind-fixture` registers `fixture-glow` on `VISION_TREATMENT_CONTRACT` for the
custom vision-kind spec.
The
authoring guide lives in the docs site: `docs/site/guides/creating-a-module.md` (`docs/design/module-authoring.md` is a
pointer stub to it). Two in-repo CI-built worked examples double as copyable scaffolds:
`examples/module-initiative-tracker/` (panel + document read/write) and `examples/system-minimal/`
(sheet takeover + formula rules) — workspace members, so `pnpm -r test/typecheck` and the web CI
job's example-build step keep them green; the guides code-import their sources region-by-region.
