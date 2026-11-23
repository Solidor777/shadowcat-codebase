---
name: shadowcat-codebase-core
description: "Use for any Shadowcat task: project architecture overview, how to build/test/lint, code & cross-platform conventions, the module/contribution model, and which knowledge layer (this skill / graphify / docs/design / memory) answers which question. The always-relevant base skill — invoke it first, then the matching shadowcat-codebase-<subsystem> skill."
---

# Shadowcat — Codebase Core

Orientation + index for the whole repo. This is the base every agent reads first; it points
INTO graphify (relationships), `docs/design/` (rationale), and memory (lessons) rather than
restating them.

## Purpose

Shadowcat is a self-hostable, fully-moddable open-source virtual tabletop shipped as **one
native executable**: a Rust (Cargo) server holds authoritative state + persistence +
networking, and a Svelte 5 (Runes) browser client + PixiJS canvas is built by Vite into `dist/`
and **embedded into the binary** (`rust-embed`). SCSS for styles. Source lives strictly under
`src/`; build output in `dist/` (client) and `target/` (server).

## Key files & seams

- `src/server/` — Rust workspace (authoritative). Subsystems: `data/` (documents, permissions,
  search, assets), `ws/` (realtime), `http/`, `auth/`, `scene/` (ECS, vision, fog).
- `src/client/{core,render,shell,ui-kit}` — `core` = framework-neutral headless TS (store, wire,
  module loader, hook bus; **no Svelte in its dep closure**); `render` = engine-owned PixiJS
  layer; `shell` = `@shadowcat/shell` app bootstrap/routing/session (builds `dist/`); `ui-kit` =
  `@shadowcat/ui-kit` Svelte runtime (AppContext, `<Surface>` host, i18n adapter).
- `src/modules/*` — first-party contribution packages (`actors`, `assets`, `core-ui`, `entry`,
  `factions`, `scene-tools`, `settings`, `stage`, `statusbar`, `topbar`). In-game UI is
  UI-as-modules; elements talk ONLY through seams (`provides`/`requires` contracts,
  `ContributionRegistry`, `<Surface>`, AppContext, render-layer API) — never importing each other.
- `src/types/generated` — **ts-rs output**: Rust types → TS. Edit the Rust source, regenerate;
  never hand-edit the `.ts`.

pnpm workspace = `src/types`, `src/client/*`, `src/modules/*`.

## Hard invariants

The full list is `docs/design/ARCHITECTURE.md` §2 (10 invariants) — load-bearing, treat as the
source of truth. The ones agents break most:

- **Server-authoritative, permissions per-recipient.** Client sends intents; server validates,
  applies, broadcasts. Hidden fields are stripped **before** transmission by default. Two classes
  rank differently (`docs/design/ARCHITECTURE.md` §2): personal user information (IP addresses, account
  details, credentials, remote-device security) is never traded for anything; game state yields to
  user experience, configurability and performance, so send-then-hide is accepted there with the
  client's fog or redaction as the gate. See `shadowcat-codebase-documents-permissions`.
- **Optimistic with rollback.** Documents are source of truth; ECS/runtime is derived & ephemeral.
- **NEVER FORK A DECISION ACROSS TWO PATHS — the defect class this codebase produces most.**
  Whenever two code paths are *documented* to agree on something, they eventually disagree on an
  input nobody thought to check, and the disagreement is a security defect rather than a bug. Six
  instances across four subsystems:
  (The six-instance table behind this rule is at the top of references/invariants-detail.md.)
  **How to apply.** (1) When you find two paths that must agree, do not verify they agree today —
  make one *derive* from the other, or have both read one shared symbol, so agreement is structural.
  (2) When you fix one instance, grep for the other copies **in the same commit**; a fix that lands
  at one site of a forked decision is what produces the next row of this table. (3) Pin parity with an anti-drift test
  that exercises BOTH paths through the shared symbol (see `MAX_GATE_WALK_COORD`'s, which catches a
  value change or a `>`/`>=` flip on either side). (4) A test that passes because both paths are
  wrong the same way proves nothing — mutate one side and confirm the test fails.
- **Cross-platform from day one (CI-verified).** `std::path` only (no hardcoded separators),
  `#[cfg]`-gate OS-specific code for every target, three-OS CI matrix, responsive/touch UI.
  [CLAUDE.md Cross-Platform; `docs/design/ARCHITECTURE.md` §2 invariant 10]
- **`dist/` must be built before any cargo build of the server** — `rust-embed` validates
  `../../dist/` at COMPILE time. [[embed-dist-compile-ordering]]
- **Capability/permission model** layered server/world/document roles. [[capability-permissions]]
- **Further invariants** (full text in references/invariants-detail.md; read it before touching the area named):
  - Three-band document shape (envelope name, typed engine body, opaque system body): the server never interprets system values; engine-defined doc types get real server ingress validation.
  - A type built via Extract on a union cannot be documented; declare a named exported interface and make it a union member. WirePermissionSet exists because one access-control shape spans two files.
  - File-size limits and test-file placement: pnpm lint:file-size and pnpm lint:inline-tests are CI-blocking; never add an allowlist entry on your own authority, split the file.
  - Test resource budgets: the Playwright worker count is pinned and the timeouts are sized against it; do not raise it.
  - Check which renderer the browser picked before optimizing anything about the canvas.
  - Drive the stage canvas as an element through the shared e2e gesture module, never at computed page coordinates.
  - A unit test that never touches the DOM declares the node environment; every vitest.setup.ts guards DOM globals.
  - Client code runs on a plain-HTTP LAN origin: no secure-context-only browser member outside its seam (pnpm lint:secure-context).
  - End-to-end specs latch transient state with the shared latch helpers; they never poll a value that returns to rest by itself.
  - The lan-plain-http Playwright project is the runtime proof of the LAN invariant.
  - A jsdom package whose tests reach local storage lists the shared jsdom local-storage setup file first in its setupFiles.

## Gotchas

- **No data migrations pre-customers** (user directive): edit the single baseline migration in place, never add an incremental migration file, and keep the document-schema migrate step-free until a milestone marks live customer databases. Full text: references/gotchas-detail-02-ratchets-typedoc-migrations.md.
- **Server-crate Rust tests never call a permanent-delete function on their own fixtures** (use the tempfile directory guard, or rename a file aside), and **a Rust mod item never carries an outer doc** (document it with the inner doc block; pnpm lint:module-docs enforces it). Full text: references/gotchas-detail-01-test-deletes-module-docs-citations.md.
- **NEVER work around a rule — follow its INTENT; if unsure, ASK (user directive).**
  Verbatim: *"we do not try to work around rules, ever. we accept the intent of the rule and follow
  it. if we are unsure of the intent, ask the user."* Reworking text or code until a rule stops
  applying is never acceptable — not when the result is technically true, not when the gate goes
  green. Every rule here was written after a defect, so the letter encodes one instance and the
  intent covers the class; honoring the letter against the intent reproduces the original defect in
  a new shape while reporting clean. Related shapes: an empty `/** */` that satisfies a docs gate, a
  test that asserts nothing, reading a rule narrowly to shrink scope (also a descope — see
  [[never-descope-without-consulting-user]]). A rule that is genuinely wrong gets raised and
  changed, never quietly routed around. [[never-work-around-a-rule-follow-its-intent]]
- **Comments cite SYMBOLS, never file names or line numbers (user directive).** Write
  ``see `egress_loop`'s `SceneSubscribe` arm ``, never ``see conn.rs:1313`` and never ``the handler in
  `conn.rs` ``. Qualify by owner (`AssetResolver.url`, `chat::broadcast`), not location. Applies to
  all committed prose — doc comments and the live tracking docs. A line number is invalidated by any
  insertion above it; a symbol breaks only on rename, which a grep finds — and for this skill
  family specifically, that grep runs automatically: `node scripts/check-skill-symbol-refs-cli.mjs` (fatal, CI-wired).
  Every code span lands in exactly one printed bucket — verified, acknowledged non-symbol, broken,
  EXAMPLE-exempt, not citation-shaped, or empty — and every backtick run that is not a bucketed
  span's delimiter left before classification by one of the ways out printed beside the buckets:
  block-blanked, unpaired inside a span, unpaired at top level — the two lists are `SPAN_BUCKETS`
  and `RUN_EXCLUSIONS`, and a test pins these two sentences to them.
  The remainder of this bullet (the gate's span accounting, bounds, residuals and local-name rules) is in references/gotchas-detail-01-test-deletes-module-docs-citations.md; read it before changing citation conventions or the gate.
- **As far as code is concerned, ephemeral documents, plans, dates, history and tasks DO NOT EXIST**
  (user directive, iron-clad; RULE 16). This is an ontology, not a style preference: the test is
  never "is this reference useful?" but "is this thing visible from the code?" Every exception
  argues from usefulness, and usefulness was never the test — so there are none.
  **Banned in `.ts`/`.rs`/`.svelte` comments**, and in code-facing strings (`assert!` messages, test
  names — ruled in scope by the user; program data like a fixture's world name is untouched):
  - milestone/task ids in ANY form — `M13-0`, `M11d-3`, `T1/T3`, and the bare `M8`  <!-- EXAMPLE: RULE 16 specimen -->
  - phase, workstream and numbered-invariant ids — `post-D9`, `W1`, `I4` — **including local  <!-- EXAMPLE: RULE 16 specimen -->
    numbering defined only in a sibling comment**, ruled in scope by the user: a number no
    compiler, test or tool binds to anything still forces the reader to go find it
  - repo document pointers — `` `docs/TODO.md` ``, `ARCHITECTURE §2 invariant 4`, bare `invariant 6`  <!-- EXAMPLE: RULE 16 specimen -->
  - dated plan/spec files, and unnamed spec references (`per spec §3.2`, `the spec'd default`)  <!-- EXAMPLE: RULE 16 specimen -->
  - sweep / fix-round / `buddy-check finding N` markers, `POST_WORK:`, and date stamps  <!-- EXAMPLE: RULE 16 specimen -->
  - **history narration** — `previously`, `formerly`, `before the fix`, "used to return X"  <!-- EXAMPLE: RULE 16 specimen -->
  - local letter+digit markers — a single letter from the set A, C, F, H, R, V plus one digit
    (`C-2`, `F3`), including a **version-label writer** (`V1 desaturate approximation`) using the  <!-- EXAMPLE: RULE 16 specimen -->
    same shape for a version number instead of a review finding — resolvable only by a reader
    holding the artifact that assigned it, same as the milestone-id class above. A citation of a
    versioned SYMBOL (`` `PanelLayoutV1` ``, `` `Vec2` ``) is unaffected: the letter-run before the
    digit excludes it.
  The remainder of this rule (why it is one class, the state-the-constraint conversion, the scope for skills and its guard, the example exemption, detector bounds and the scan subject) is in references/gotchas-detail-01-test-deletes-module-docs-citations.md; read it before writing or reviewing comments, doc prose or skill text that names anything outside the code.
- **There are no justified keeps, exemptions or carve-outs unless the user explicitly signs off** (user directive): report a candidate as unconverted and awaiting a ruling, remove the need for the exemption first, and print the active count of any exemption that exists. Full text: references/gotchas-detail-02-ratchets-typedoc-migrations.md.
- **No ratchets, only gates** (user directive): nothing is grandfathered, every doc and comment check is an error that fails CI, and there is no warn tier. The gate list, the nightly rustdoc examples gate and how it can pass while enforcing nothing: references/gotchas-detail-02-ratchets-typedoc-migrations.md.
- **`.claude/CLAUDE.md` is TRACKED and shared** — edits there reach other contributors and the
  open-source repo. `.gitignore`'s `/CLAUDE.md` rule is root-anchored and matches no file (no
  root-level `CLAUDE.md` exists); the genuinely-ignored entries under `.claude/` are
  `settings.local.json` and `skills/graphify/`; `settings.json` is tracked.
  `docs/design/ARCHITECTURE.md` §2 remains the invariant source of truth, but not
  because `CLAUDE.md` is unshared.
  [[claude-md-is-git-ignored]]
- **ts-rs types are generated** — change the Rust enum/struct, regenerate, then mirror in the
  client Zod schema (a drift guard enforces parity).
- **Decide on technical merits, not "how Foundry does it."** [[decide-on-merits-not-foundry]]
- **Tests yield to correct code** — fix code only if objectively wrong; else fix the test.
  [[tests-yield-to-correct-code]]
- **TypeDoc gotchas** (references/gotchas-detail-02-ratchets-typedoc-migrations.md): a doc comment on the same line as its target is silently dropped; a link tag to a private member fails the docs build; most root-level typedoc settings are inert under the packages entry-point strategy (only the root decides whether a warning is fatal); the only documented-coverage exemption is the enumerated set of ts-rs synthesized discriminants.

## Pointers

**Knowledge-layer map** (which layer answers which question):
- **this skill family** (`shadowcat-codebase-*`) — orientation: what a subsystem is, its seams,
  invariants, gotchas.
- **docs site** (`docs/site/` → `pnpm docs:build` → `dist-docs/`, `pnpm docs:serve` to view) —
  the user-facing layer: guides (hosting / creating-a-module / creating-a-system), per-module
  pages, wire-protocol page, and the generated API references (TypeDoc under `/api/ts/`, rustdoc
  with private items under `/api/rust/shadowcat/` — `/api/rust/` itself has no index page, since
  rustdoc emits none under `--no-deps`). Guides code-import the CI-built `examples/*` packages.
- **graphify** (`graphify-out/`) — relationships: `graphify query "<q>"`,
  `graphify path "<A>" "<B>"`, `graphify explain "<concept>"`.
- **`docs/design/`** — rationale: `ARCHITECTURE.md` (invariants/tech), `docs/design/M2-data-foundation.md`,
  per-system docs.
- **memory** (`~/.claude/projects/C--Dev-Shadowcat/memory/`) — cross-session lessons + resume state.

- **Generated API root**, build entry points and the file-size and secure-context lint commands: references/docs-gates-and-build.md.

**Build / test / lint commands:**
- Client build (produces `dist/`): `pnpm build` (= `pnpm --filter @shadowcat/shell build`).
- Client tests: `pnpm -r test` (Vitest). Typecheck: `pnpm -r typecheck`. Lint: `pnpm lint` (ESLint).
- Server (from `src/server/`): `cargo test`, `cargo fmt`, `cargo clippy`.
  Docs gate commands (docs:serve, docs:check-rust-examples, docs:check-examples, lint:docs, lint:props, lint:comments), the two-block and two-invocation lint constraints, how examples compile inside their host module, and the bind:this handling: read references/docs-gates-and-build.md before running or changing them. All docs checks are errors repo-wide with no advisory tier.
- CI builds the client **before** cargo (embed ordering) across the three-OS matrix.

**Subsystem skills:** `documents-permissions`, `actors-tokens`, `scene-rendering`,
`realtime-sync`, `client-shell`, `assets`, `dice`, `chat`, `formula`, `module-toolchain`,
`sheets`, `panels`, `server-ops`, `templates`, `combat`, `tables-notes`, `performance`,
`sandbox`, `vfx`, `dice-3d`, `audio`, `tls`, `portmap` (all `shadowcat-codebase-*`).

**Reference files:**

| File | Holds | Read it when |
|---|---|---|
| references/invariants-detail.md | Fork-decision case table; full text of the three-band shape, Extract/WirePermissionSet, file-size, test budget, renderer, canvas, vitest, secure-context, latch, LAN and jsdom invariants | touching the area an invariant summary names |
| references/gotchas-detail.md | Full text of the migrations, test-delete, module-doc and no-justified-keeps gotchas, the symbol-citation gate, the ephemeral-reference rule, no-ratchets and TypeDoc | writing comments or docs, changing a docs gate, or editing a skill |
| references/docs-gates-and-build.md | Generated API root, file-size and secure-context lint commands, docs build and gate commands, lint-block constraints, example compilation | running or changing docs gates |

## Maintaining this skill family

This family is not fixed — **create a new `shadowcat-codebase-<subsystem>` skill whenever work
opens a subsystem none of the existing skills covers** (e.g. a new milestone like effects,
pathfinding, chat, or audio). Don't stretch an unrelated skill to fit.

When adding one:
1. Follow the fixed shape — Purpose / Key files & seams / Hard invariants / Gotchas / Pointers —
   and keep it orientation+index: point INTO graphify, `docs/design/`, and memory; never duplicate
   them. Cite each invariant's memory slug or design-doc section.
2. Add it to the **Subsystem skills** list above, and add its path globs to the activation hook
   (the plugin checkout's `hooks/codebase-skill-reminder.py`, its `SUBSYSTEMS` map). Every hook entry is an
   UNANCHORED substring match, because the Edit/Write payload's `file_path` is always absolute; a
   `^`-anchored pattern is inert while still passing repo-relative test fixtures. Pair each new
   entry with at least one absolute-path assertion in the hook's self-test.
3. This creation step is part of the reviewed skill-update gate (see CLAUDE.md
   `## Codebase Skills & Agents`): a new subsystem with no skill is itself a gate violation.

### Keeping the plugin current

This skill family is the standalone `shadowcat-codebase` plugin repository, checked out at
`~/.claude/skills/shadowcat-codebase/` and addressed as `shadowcat-codebase@skills-dir`. A
`skills-dir` plugin is read live from the checkout: an edit there is visible in the next session,
with no version bump, marketplace refresh or `claude plugin update` step. Shadowcat's own `.claude/`
directory holds repo settings and hooks, not this plugin. Skill edits are committed and pushed from
inside the checkout, whose git history is separate from Shadowcat's. The plugin is disabled by
default and each repo enables it for itself with
`claude plugin enable shadowcat-codebase@skills-dir --scope local`; a consumer updates the skills
by running `git pull` in the checkout.

Consumers also see these skills under a plugin prefix (`shadowcat-codebase:shadowcat-codebase-core`)
rather than the bare id. Take the exact name from the skill listing.
