# Core docs gates and build commands — detail

Part of shadowcat-codebase-core: the docs build and gate commands and the docs-lint and example-compilation constraints; read it when running or changing docs gates.

- `pnpm build:all` is the full build entry point: the client build, then `docs:generate`
  (TypeDoc, `cargo doc`, the VitePress portal, assembly with its link check, and the
  documentation-exemption count). `pnpm docs:build` is a delegating alias for `build:all`, and
  `docs:generate` is the single place the chain is spelled out — don't re-enumerate its stages
  anywhere else. The client build must run first: `rust-embed` validates `dist/` at compile
  time, so `cargo doc` fails without it.
- Docs: `pnpm docs:serve` (view; the assembled `dist-docs/index.html` also opens directly over
  `file://` for static content, styling, and link navigation — anything driven by the site's
  runtime JavaScript, including search, the appearance toggle, and the mobile nav panel, needs the
  server instead), `pnpm docs:check-rust-examples` (every public server item needs a fenced Rust
  example; nightly, own target dir `target/nightly-doc`), `pnpm docs:check-examples` (`@example` `` ```ts `` blocks must typecheck —
  CI-blocking), `pnpm lint:docs` (function doc coverage),
  `pnpm lint:props` (property/type/named-arrow doc coverage), `pnpm lint:comments` (no ephemeral
  references). **All are errors repo-wide with no per-package staging** — see the no-ratchets rule
  in references/gotchas-detail-02-ratchets-typedoc-migrations.md; there is no `rulesAt(severity)` and no advisory tier anywhere in these configs.
  Two structural constraints survive and still bite:
  **(1) A package with COMPONENTS is covered by TWO blocks, not one.** `.ts` and `.svelte` need
  different parsers and one flat-config block cannot carry both, so each config has a `.ts` block
  AND a separate `svelteParser` block; a rule added to only the first silently skips every
  component. **(2) `eslint.docs.config.js` and `eslint.props.config.js` are separate INVOCATIONS
  and must stay that way** — both set the same rule KEYS with different `contexts` lists, and flat
  config resolves a key to the last block that sets it, so merging them would silently replace one
  config's context list with the other's, dropping that coverage with no error and no output
  change. Their `.ts` ignore lists must stay byte-identical; they exempt test files under BOTH
  runners' conventions (`**/*.test.ts` and `**/*.spec.ts`) plus `src/types/generated/**`, while a
  test HELPER MODULE that is not itself a test file stays covered.
- **`@example` blocks compile INSIDE the module that documents them, not in a scratch file.**
  `scripts/extract-ts-examples.mjs` compiles each example through the TypeScript compiler API with
  an in-memory virtual overlay of its host module, under that host's OWN package `tsconfig` — so
  the host's imports, private helpers and this binding resolve exactly as in real code, and an example on
  a class member is injected into the host class body. `.svelte` hosts join the same path via their
  extracted `<script>`/`<script module>` block; runes type correctly because svelte's own
  `types/index.d.ts` declares them as ambient globals (it also declares `module '*.svelte'`, so a
  host's own component imports resolve for free — this script generates no shim of its own).
  Consequences: an example naming a workspace package pulls that package's internals into the
  graph, so `docs:check-examples` can fail at a line the author never touched; and both tagged and
  untagged fences are checked, so an untagged fence is not an escape hatch. A diagnostic is
  attributed by WHERE it lands, not by which example triggered compilation: `classifyCompiledResult`
  counts a result as an example-content failure only when at least one diagnostic maps to
  `"example body"`; a result whose diagnostics are ALL host-attributable (`"host line N"`) is
  reported in its own bucket and still fails the gate (a broken host is real information), but is
  never folded into the example-failure count or blamed on the example's own content.
- **The compilation contract is explicit and named — do not re-derive it per package.**
  `EXAMPLE_HYGIENE_OVERRIDES` turns `noUnusedLocals`/`noUnusedParameters` OFF while leaving every
  correctness check on. Production-hygiene lints are a category error on documentation:
  `const x = await upload(...)` is the CORRECT shape for an example and is not a defect. Inheriting
  those two flags implicitly from a package config once manufactured 95 phantom failures out of
  197 — a wrong ruler is applied uniformly, so every result looks self-consistent and the diff
  reviews clean.
- **`bind:this` targets are resolved, not left as an instrument gap.** A `.svelte` host's
  extracted script never sees the template, so a `let el: T;` a template `bind:this={el}`
  assigns would otherwise read as "used before being assigned". `extractSvelteHost` parses
  `bind:this={name}` out of the raw SFC text (template only — a match inside a `<script>` block
  is excluded) via `extractBindThisSimpleIdentifiers`, then `markBindThisAssigned` adds a real
  TypeScript definite-assignment assertion (`let el!: T;`) to that exact declaration — never a
  suppression: the declared TYPE is untouched, so a genuine type error against the binding still
  fails, and a host variable that is truly read before assignment (not a `bind:this` target)
  still fails too. Only a BARE-IDENTIFIER target is rewritten this way; a member/element-access
  target (`bind:this={refs.foo}`, `bind:this={itemEls[i]}`) needs no rewrite at all, because
  Svelte can only assign into an object/array that already exists — its base identifier's
  declaration necessarily already carries an initializer. Do not restructure a `.svelte`
  component to satisfy this checker.
- **A green `pnpm lint:docs` is NOT evidence the docs are correct.** The `jsdoc/require-*` rules
  gate on tag PRESENCE only: they cannot see a vacuous tag (`@returns The result.`), a false
  statement, or a second doc block appended below an existing one. That last case actively
  misleads — jsdoc, TypeDoc, and editor hover all bind to the NEAREST preceding block, so an
  appended block satisfies the linter while ORPHANING the richer one above it — a real instance on
  `webSocketConnect` sat at 0 warnings the whole time. Detecting it needs a
  manual scan for a `*/` line immediately followed by `/**`. Truthfulness and placement are review
  concerns, not gate concerns: `docs/design/doc-sweep-truthfulness-rules.md`.
- **Generated API root** — `/api/rust/shadowcat/` (rustdoc, private items included), `/api/ts/`
  (TypeDoc, one entry point per workspace package). Produce with `pnpm build:all`; open
  `dist-docs/index.html` directly over `file://` or serve with `pnpm docs:serve`. Each subsystem
  skill listed in SKILL.md points to its own package/crate-module pages under this root.
- `pnpm lint:file-size` (5,000-line soft / 10,000-line hard limit, owner-approved allowlist only)
  and `pnpm lint:inline-tests` (no inline Rust `#[cfg(test)] mod x { … }` bodies) are CI-blocking,
  same no-ratchet posture as the doc gates above.
- `pnpm lint:allowances` bans `svelte-ignore` as one never-approvable suppression (not one per warning code); seed a prop-derived initial value with `untrack()` instead.
- `pnpm lint:secure-context` — no secure-context-only browser API outside its seam (LAN play; see
  the invariant in references/invariants-detail.md).
