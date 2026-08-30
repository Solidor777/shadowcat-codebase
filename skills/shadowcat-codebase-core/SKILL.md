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
  applies, broadcasts. Hidden fields are stripped **before** transmission, never sent-then-hidden.
  See `shadowcat-codebase-documents-permissions`.
- **Optimistic with rollback.** Documents are source of truth; ECS/runtime is derived & ephemeral.
- **NEVER FORK A DECISION ACROSS TWO PATHS — the defect class this codebase produces most.**
  Whenever two code paths are *documented* to agree on something, they eventually disagree on an
  input nobody thought to check, and the disagreement is a security defect rather than a bug. Six
  instances across four subsystems:
  | Forked on | Where | Consequence |
  |---|---|---|
  | Cell indexing | `Room::publish`, `clip_to_visible_mask` | square indices tested against a hex-axial mask |
  | Contract completeness in a SHARED primitive (not a fork — included because it is the same *consequence* from the opposite cause) | `HexGrid::line_traversal` | a thin line, not a supercover — ~55% of segments omitted a crossed hex the gate then never checked; see `scene-rendering`'s "a fixed-count cube lerp is a THIN LINE" gotcha |
  | Input admissibility | `Room::publish` vs `gate_walk` | one bounded coordinate magnitude, the other did not |
  | **Scene identity** | `MoveRequest` vs `Room::publish` | one took the scene from the client, the other derived it from the token ⇒ total movement-gate bypass |
  | **`remove` semantics** | `SceneEcs::apply_op` vs `apply_intent` | ECS ignored `FieldChange.remove` while the DB honoured it ⇒ vision widened where write authz refused |
  | Fail-open defaults | `execute_move` vs `publish` vs `pathfind` | a `unwrap_or(100.0)` cell size dropped from ONE gate and left in its siblings — the shape a fix for the row above produces if it lands at one site. **No such default exists at any of the three gates or their six non-gate siblings** (`SceneEcs::navmesh_for`, `SceneEcs::region_field`, `SceneEcs::player_lit_mask`, `SceneEcs::visible_cells`, `SceneEcs::visible_cells_cached` — an absent `scene_grid_sizes()` entry returns `None`/empty rather than synthesizing a 100-unit grid; `region_field` returns `-> Option<RegionField>`, its three callers (`pathfind`'s two branches, `move_exec::execute_move`) refuse via `let-else` on `None`, and `MoveReject` carries a `SceneUnknown` variant mirroring `Degenerate`; `conn::enrich_vision_explored` continues past a scene absent from either its `grid` or
  `enrich_vision_explored::grid_shapes` map, never synthesizing a fallback `SquareGrid`). `scene_grid_sizes` is the sole intentional defaulting SOURCE. |
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
- **Three-band document shape: envelope `name` + typed `engine` + opaque `system`.** The server
  never decides what a `system` value MEANS and runs no third-party code; its authority over the
  band is structural (size/field-path/`deny_unknown_fields`/declared shape). It DOES evaluate the
  engine's own grammars over `system` data a formula names — `crate::formula` (server twin of
  `@shadowcat/formula`) reads numeric leaves through `SystemLeafResolver` — and by default
  computation runs on the server; the client requests. The typed `engine` body
  (present only for the 23 engine-defined doc types: tokens, actors, scenes, walls, regions,
  lights, drawings, templates, messages, the world/vision/lighting/chat/dice/faction/
  condition/channel/system-defaults config-docs, and the combat family (combat, combatant,
  resource-registry, effect, combat-history) gets REAL server-side ingress validation instead
  (`validate_engine`/`validate_engine_tree`, `deny_unknown_fields` per struct) — this is the band
  engine-owned geometry (movement-collision, vision) lives in, not a `system`-body exception.
  See `shadowcat-codebase-documents-permissions` for the
  `data/engine/` registry, `shadowcat-codebase-combat` for the combat family, and
  `shadowcat-codebase-scene-rendering`/`-chat`/`-actors-tokens` for the per-subsystem re-root.
- **A type built via `Extract<SomeUnion, { type: "x" }>` cannot be documented.** TypeDoc cannot
  project such a projection into a documentable reflection, so a comment on it is unfixable no
  matter how it's placed. The resolution is structural: declare the member as its own named
  exported interface and make it a member of the union directly, rather than extracting it back
  out afterwards. `WireWelcome` follows this shape — a named member of `ServerMsg`, not an
  `Extract<>` projection of it. Follow the same precedent wherever this shape recurs.
- **`WirePermissionSet` exists because one anonymous access-control type spans a file boundary.**
  `WireDocument.permissions` and `StampOpts.permissions` share the same shape across two files; a
  single exported name is structurally required there — the alternative duplicates the
  access-control shape inline in both places, the forked-decision defect this codebase produces
  most (see above). The name exposes nothing new:
  `WireDocument["permissions"]` already exposed the identical shape.
- **File-size limits and test-file placement.** `pnpm lint:file-size` fails any tracked source file
  over 5,000 lines without an owner-signed `.claude/file-size-allowlist.toml` entry and any file
  over 10,000 unconditionally; `pnpm lint:inline-tests` fails any inline `#[cfg(test)] mod x { … }`
  body under `src/`. Rust test bodies live in `<stem>/x.rs` (or `x.rs` beside a `mod.rs`), and the
  large suites are split by subject: `data/sqlite/tests/{mod,rows_and_validation,search_and_worlds,commands_and_intents,invites_and_ownership}.rs`
  and `scene/tests/{mod,ecs_and_footprints,resolution_and_lighting,pathfind_and_vision}.rs`, with
  shared fixtures `pub(super)` in each `tests/mod.rs`. Never add an allowlist entry on your own
  authority — split the file.

## Gotchas

- **No data migrations pre-customers (user directive).** Until a milestone
  explicitly marks live customer databases, there is no upgrade path to preserve: SQL schema
  changes EDIT `src/server/migrations/0001_init.sql` (the single baseline) in place — never add
  an incremental migration file — and document-schema changes keep `data::migrate` step-free
  (`CURRENT_SCHEMA_VERSION` machinery only). The sqlx/`migrate()` machinery itself MUST stay, so
  real migrations can begin at that milestone. A dev DB predating a baseline edit fails the sqlx
  checksum — delete the dev DB file and restart. Any migration files that accumulate anyway are
  deleted on sight (squashed into the baseline).
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
  family specifically, that grep runs automatically:
  `node scripts/check-skill-symbol-refs-cli.mjs` (fatal, CI-wired) resolves every code-symbol
  citation in every TRACKED skill directory against a symbol index built from what the tree
  declares — Rust items, methods, fields, variants, serde wire names, local bindings, parameters
  and literal alternation sets; SQL tables/columns; Cargo and JSON config keys; every TS/Svelte
  declaration, member at any depth, object-literal key, import and literal type, read through the
  TypeScript parser; and module/package/skill directory names. **A token's shape decides only
  whether it is a citation at all, never whether a citation is CHECKED** — a shape exclusion hides
  the citations it skips AND every index gap behind them, so every code span lands in exactly
  one printed bucket — verified, acknowledged non-symbol, broken, EXAMPLE-exempt,
  not citation-shaped, or empty — and each acknowledgement entry is hit-counted, a zero-hit entry
  failing the gate. **That list is `SPAN_BUCKETS`, and this sentence is pinned to it by a test**:
  a claim about the code that is neither derived from it nor tested against it drifts the moment a
  bucket joins the list or its label changes. What makes it true rather than
  asserted is `spanAccountingDelta` — every backtick RUN must be one of a bucketed span's two
  delimiters, or must have left before classification by one of the ways out printed beside the
  buckets: block-blanked, unpaired inside a span, unpaired at top level — of which the last is
  always a prose defect and fails on its own, since a stray delimiter shifts pairing across its
  whole paragraph while conservation still balances. **That list is `RUN_EXCLUSIONS`, pinned by
  the same test.** The identity is enforced per file and in aggregate, or the gate fails and says
  by how much. A span written as `NAME=value` is checked on its NAME: the value is there to save
  the reader a lookup, and letting the whole span fail the citation shape lets a citation of a
  constant the tree does not declare pass with the gate reporting zero broken. A PER-FILE floor
  sits under the global one — a file whose PROSE carries backticks and yields no CHECKED citation
  has silently left the gate; the floor reports what that file's spans DID land in, since the
  shifted-pairing case it exists for turns real citations into
  prose spans that climb the not-citation-shaped bucket. Carve-outs: config/build files (no
  symbols to cite), filenames used as *values*, and dated records under `docs/superpowers/`.
  **RESIDUAL, uncovered by design: a bare citation can still verify
  against an unrelated same-named member** — the citation rule is narrow (location-citations
  only), a bare member name is grep-findable and rename-breaking, so bare member registration
  stays and which member a bare citation MEANT is a review obligation. An untracked skill directory is vendored
  third-party prose and is out of the corpus by that property, never by a name pattern; its count
  prints on every run, from the same `listSkillDirs` both skill gates read, so the two can never
  disagree on the size of the corpus.
  **A function-LOCAL name (a let binding, a for-loop pattern, a parameter, a function-scoped
  object key) is indexed only under the function that declares it (`execute_move::check_mask`),
  never bare, and under its FULL owner chain rather than every suffix** — a bare local carries no
  owner relation, so it would make the index answer "the tree declares that" to any citation
  spelling any local anywhere, and a suffix of a local-headed chain (`WorldSession`'s
  `loadExternalModules`, then one of its bindings) is a path headed by a name invisible outside
  that function. Cite one the same way. **A closed VALUE SET is likewise cited through its
  constant** (`NOTATION_KEYWORDS.kh`, never the member spelled bare), and value-set extraction runs only over
  the product roots: a string literal in a build script is that gate's own configuration, and
  indexing it lets a citation resolve against the tooling that checks it. Full rule:
  `docs/design/doc-sweep-truthfulness-rules.md` RULE 15. [[cite-symbols-not-file-lines]]
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

  **These are one class: each names something outside the code whose identity a process assigns** —
  milestones get renumbered, bug entries move `OPEN_BUGS` → `CLOSED_BUGS`, specs get superseded,
  a past version stops being anyone's reference point. The comment then points at nothing, and
  unlike a stale claim *about code*, **no reader and no tool can tell**, because the referent's
  disappearance is invisible from the code.
  The conversion is always **state the CONSTRAINT, drop the POINTER** — and where the pointer
  carried nothing (`(M13e)` appended to a true sentence), **delete the token and change nothing  <!-- EXAMPLE: RULE 16 specimen -->
  else**; RULE 4 prefers deletion, and inventing a plausible replacement constraint is the single
  worst outcome available. `TODO:` itself stays (a code marker); what goes is the "see `TODO.md`"  <!-- EXAMPLE: RULE 16 specimen -->
  tail. **Direction of dependency: doc → code, never code → doc** — the backlog or bug entry cites
  the SYMBOL (RULE 15) and points inward, so closing it cannot rot a comment.
  Stronger than RULE 15 and wins where they touch: RULE 15 says how to cite, this says what may be
  referred to at all. Ordinary Markdown docs and `.superpowers/` artifacts remain exempt — they may
  cite documents by path + section anchor. **This skill family (`.claude/skills/**/*.md`) is now
  IN SCOPE for a narrower subset** (owner ruling): a skill may still cite a durable document by
  path + section anchor, but may not carry a milestone/task id (`M13-0`, `M10e-4`), a phase/  <!-- EXAMPLE: RULE 16 specimen -->
  workstream/invariant id (`D9`, `D16`), a sweep/round/review marker (`sweep 12`, `fix-round`,  <!-- EXAMPLE: RULE 16 specimen -->
  `buddy-check`), or a date bare or narrative (`2026-07-30`, `(user directive 2026-08-05)`) —  <!-- EXAMPLE: RULE 16 specimen -->
  including a dated plan/spec filename, which is a superseded-by-construction record and not a
  durable citation regardless of its `docs/` path. Repo-document pointers to non-durable trackers,
  unnamed spec references and history narration are ALSO ruled in for skills; process markers are not;
  do not widen the skill subset further without a ruling.
  **The path-plus-anchor carve-out is a GUARD on the check, never the check dropped.** The
  PATHLESS forms — a bare architecture reference, a bare numbered invariant, a bare section anchor —
  are what the carve-out has to make room for, so they are ruled in for skills and reused from the
  code list by reference under `skipLine`, which permits a match exactly when the line ALSO carries
  the full durable design-doc path. Substituting a narrower entry instead is how the carve-out for
  one form silently drops the ban on all of them. The guard's unit is the LINE and it reads the RAW
  line: `lineSubject`'s Markdown branch replaces every design-doc citation with the empty string
  before matching, which would delete the evidence the guard needs. It is not the GROUP either —
  one permitted citation would then exempt every bare anchor sharing its paragraph — so a citation
  wrapped across two lines must carry its path on the line its anchor sits on.
  **Two spellings the reference entries did not reach are now banned in CODE.** A comment naming a
  codebase skill BY NAME (`codebase skill pointer`) is the same class of process-assigned referent:
  skills are created, split, re-scoped and retired, and their names move with them. It is
  deliberately absent from the skill list,
  where a skill naming a sibling skill is the documented structure of this knowledge layer — the
  Subsystem skills list above is written that way. And a churn tracker named WITHOUT its extension
  (`extensionless tracker pointer`) is the same pointer four characters shorter; it requires a
  POINTER CONSTRUCTION (a preposition or verb of reference in front of the name) rather than a bare
  occurrence, because the bare marker form stays permitted and these names also occur as prose.
  **The skill corpus is scoped to the TRACKED skill directories**, read from the same
  `listSkillDirs` the skill-symbol-citation gate reads. An untracked skill directory is vendored
  third-party prose that this repo neither wrote nor may edit, so holding it to a rule about how
  THIS repo writes prose leaves only a vendored-file edit or a carve-out, and both are wrong. The
  excluded count prints on every run.
  **Enforced retroactively with no grandfathering** (user directive) by
  `node scripts/check-comment-refs.mjs` — no baseline, no side-car allowlist, every legacy hit
  fails. The ONE exemption is an `EXAMPLE` marker (that word, then a colon) on a line that
  deliberately exhibits a banned
  form in order to DEFINE it — the use-vs-mention collision a pattern cannot see, and the reason
  this rule's own statement below is marked. It is owner-approved per instance, sits on the line
  it exempts (so no position to rot), and the gate prints its active count, because an uncounted
  exemption is a backdoor. It covers specimens only: a genuine pointer gets converted, never
  marked. The coverage control's own `ACKNOWLEDGED` lists answer to the same rule as the symbol
  gate's: hit-counted on every FULL-corpus run, the reached-entry count printed beside the
  EXAMPLE count, and a zero-hit entry fatal — a `--scope`d run makes no such claim, since a zero
  on a subset says the scope missed the token rather than that the entry is dead. Scoping the
  corpus to the tracked skill directories is what killed six of these entries at once, silently,
  which is what the rule now prevents. But
  **a green detector is not a satisfied rule**: history narration is only partly detectable (`no
  longer` usually describes runtime data, not the code's past), so it is a review obligation.
  A THIRD detectable-but-bounded class sits beside it: **history narration by allusion**, a
  definite reference to an event with no fixed lexical marker — the incident is named as though
  the reader already knows it, unlike a fixed marker word or compound.
  <!-- EXAMPLE: "the reported panic" carries no fixed marker word on the incident itself, unlike
  EXAMPLE: `previously`/`formerly` or a "used to" compound. -->
  Its pattern is a CONSTRUCTION — a determiner, an
  observation/reporting participle, and an incident noun — designed against the collision where
  the same nouns name a CODE CONSTRUCT rather than an event (`the panic path`, `the crash
  handler`, `the failure mode`, `the error type`): the participle is what separates a construct
  name from a reference to something that happened, and a construct-noun suffix immediately after
  the incident noun (the alternation's seven members: `mode, path, handler, type, kind, variant,
  case`) is refused even when a participle precedes it. Cited as one list rather than as seven
  individual spans: each is a literal string in `check-comment-refs.mjs`'s own regex alternation,
  not a name this tree declares, and citing them bare would either fail outright (two of the seven
  match nothing) or pass by coincidence against an unrelated same-spelled field or parameter
  elsewhere in the tree — a citation that "resolves" for the wrong reason is worse than one that is
  honestly not a symbol reference at all. **Bounded on BOTH sides, not complete**: the pattern requires the
  participle to sit directly between the determiner and the noun, so a reordered allusion, an
  allusion with no participle at all, or an incident noun outside its enumerated set is invisible
  to it — a clean run over this shape is not evidence none remains, on the same review-obligation
  footing as `history narration`'s own bound above it. The suffix guard is ALSO a closed word
  list, so it runs the opposite risk: a construct compound using a suffix outside that list (a
  reported error STATE, a known crash recovery MECHANISM) still reads as a false positive. A false
  positive is visible on the next run and a false negative is not, so the pressure this produces
  always points toward narrowing the pattern back — the correct response to a genuine miss here is
  to extend the suffix list, never to drop the participle requirement.
  A second class sits beside it on the same footing: the lowercase hyphenated marker shape
  (`c-1`, `b-2`) is character-for-character ordinary comment arithmetic (`0..n-1`, `w-1`) with no
  separator a pattern can key on, so it is **permanently ungated by design**, not an open gap — a
  reviewer enforces the ban, and a clean `scripts/check-comment-refs.mjs` run is not evidence none
  remains. Rewording to evade a pattern while still speaking of something outside the code
  violates RULE 0.
  **The scan SUBJECT is a comment BLOCK or a Markdown PARAGRAPH, never a LINE** — a line is only
  where the text happened to wrap, so a line-scoped subject reads every multi-word ban as clean the
  moment prose wrapping puts a break at one of the phrase's spaces, and each half is individually
  innocent. The GROUP BOUNDARY is what makes joining safe and is the load-bearing design, not an
  implementation detail: `subjectGroups` ends a group at a blank line, at any line contributing no
  prose, and — in code — at any line that is not purely commentary, so a doc comment never joins
  the declaration beneath it, a string-literal-bearing line stands alone, and a comment TRAILING a
  statement stands alone (it is written against that statement, not as a continuation of the block
  above). Joining across that boundary manufactures phrases nobody wrote out of one line's last
  words and the next line's first — a false negative traded for a false positive.
  **A separator between two WORDS of a marker is a SPELLING, not part of its identity**, so
  `bannedMatchesIn` also matches each pattern under a `separatorFlexible` form derived from that
  pattern's own source: hyphen, underscore and space all reach the same entry, for every entry at
  once including entries not yet written. The rewrite lands on the PATTERN, never the subject. Two
  spellings are widened — a BARE separator between two literal alphabetic characters, and a
  character class whose every member is a separator, written as a literal or a single-character
  escape (`separatorOnlyClass`); a class with any other member is untouched, since widening a range
  corrupts the pattern. RESIDUAL, which is why that coverage claim is bounded rather than
  universal: the neighbour test requires a LITERAL ALPHABETIC character on BOTH sides, so a bare
  separator keeps its single spelling whenever either neighbour is anything else — a group
  boundary, an escape, a class, a quantifier or a punctuation mark. The group boundary is the
  commoner of the two named cases, because an alternation of writers is how a marker with several
  spellings gets written in the first place. **The fix at a site is to respell that separator as a
  ONE-MEMBER CHARACTER CLASS**, which routes it through the class path with no new mechanism: the
  source still declares one spelling, and the class is what marks it as a word separator rather
  than regex punctuation. Loosening the neighbour test instead is the wrong repair — it is correct
  for every separator that is not a word separator at all. Respelling is not unconditionally safe
  either: adding a hyphen or underscore between two words is, but adding a SPACE where the pattern
  had a hyphen fuses two ordinary tokens, which is why `local letter+digit marker` and the
  hyphenated `unnamed spec reference` compound are left at their single spelling on measured
  grounds. **An entry whose own spelling carries NO separator is reached by an added ALTERNATIVE,
  never by a class** — there is nothing to respell, and a one-member class would be widened to the
  space writer, which for `phase / workstream / invariant id` is a capital plus a space plus a
  quantity, i.e. ordinary English. Each alternative's separator sits between a group boundary and
  an escape, so the residual above is what holds the two spellings written at exactly two.
  **Nothing inside a NEGATIVE lookaround is widened at any depth** — widening an exclusion makes
  the pattern match strictly less and the gate report strictly cleaner, the one direction nothing
  in the output distinguishes from a clean corpus.
  Full rule: `docs/design/doc-sweep-truthfulness-rules.md` RULE 16.
- **There are NO justified keeps, exemptions or carve-outs unless the user explicitly signs off**
  (user directive, iron-clad). A well-argued keep is still a decision about *what the work covers*,
  which is the user's, never yours or a subagent's — ratifying one is a silent descope wearing
  technical clothes. Report a candidate as unconverted and awaiting a ruling; never as `kept`,
  never as "the carve-out covers this". **The first move is to remove the NEED for the exemption:**
  a fixture named `"W1"` that forced a comment to name a banned shape became `"token-world"`, and  <!-- EXAMPLE: RULE 16 specimen -->
  the comment then said what it meant with nothing to exempt. Any exemption that does exist must
  print its active count in its own output — an uncounted exemption is a backdoor, and a silent one
  is indistinguishable from a rule that does not apply.
- **No ratchets, only gates** (user directive) — nothing is grandfathered. Every doc/comment check
  is `error` and fails CI: `pnpm lint:docs`, `lint:props`, `lint:comments`, `docs:check-examples`,
  and Rust `-D missing-docs`. A warn tier is an exemption spread across a whole codebase, and a
  reported-but-passing violation is indistinguishable to a later reader from code that was checked.
- **`.claude/CLAUDE.md` is TRACKED and shared** — edits there reach other contributors and the
  open-source repo. `.gitignore`'s `/CLAUDE.md` rule is root-anchored and matches no file (no
  root-level `CLAUDE.md` exists); the genuinely-ignored entries under `.claude/` are
  `settings.json`, `settings.local.json`, `skills/graphify/`, and `kimi.plugin.json`.
  `docs/design/ARCHITECTURE.md` §2 remains the invariant source of truth, but not
  because `CLAUDE.md` is unshared.
  [[claude-md-is-git-ignored]]
- **ts-rs types are generated** — change the Rust enum/struct, regenerate, then mirror in the
  client Zod schema (a drift guard enforces parity).
- **Decide on technical merits, not "how Foundry does it."** [[decide-on-merits-not-foundry]]
- **Tests yield to correct code** — fix code only if objectively wrong; else fix the test.
  [[tests-yield-to-correct-code]]
- **TypeDoc silently drops a `/** */` doc comment written on the same line as its target** inside
  a single-line object literal or a single-line union arm. A multi-line sibling in the same file
  documents correctly. The comment is present in the source and absent from the output, so a
  reader checking the source concludes the symbol is documented while the coverage gate reports
  it undocumented — the two disagree and the source looks right. Fix: move the comment onto its
  own line above the member.
- **A `{@link}` to a `private` member fails the docs BUILD, not just the link.** TypeDoc resolves
  the name, then excludes the reflection from the output, and reports "resolved but is not
  included in the documentation" — a validation warning, which the root config's
  `treatValidationWarningsAsErrors` makes fatal. A tag straddling a line break is worse: the
  comment's leading `*` lands inside the tag and the link fails to resolve at all. Cite a private
  helper in backticks (`axialToPixel`) instead; RULE 15 asks for the symbol name, not a hyperlink,
  and the generator is being asked for something it cannot deliver.
- **TypeDoc's `entryPointStrategy: "packages"` makes most root-level `typedoc.json` settings
  inert.** `Options.copyForPackage` builds a FRESH options object per package, resets every value
  to its default, applies only the root's `packageOptions` map, then reads that package's own
  `typedoc.json` and its `extends` chain — nothing else from the root config reaches a package
  conversion.
  - `skipErrorChecking` and `intentionallyNotDocumented` set at the root are inert; only the
    per-package config (`typedoc.base.json`, which every package extends, or a specific package's
    own file) has any effect.
  - **The split is: per-package config decides WHAT is validated, the ROOT config alone decides
    whether a warning is FATAL.** `treatValidationWarningsAsErrors` only counts at the root.
    Measured: with it removed from the root and left `true` in `typedoc.base.json`, a real
    coverage warning still PRINTS and the run exits 0; restored at the root, the same warning
    exits 4. A per-package copy cannot make any gate real, so never reach for one to harden a
    check — there is exactly one place that does it.
  - A per-package `validation` override that forces `invalidLink` off is a MERGE, not a replace,
    so `notDocumented` inherited from the shared base survives it — that's what keeps the
    per-package coverage check running at all (its escalation to an error still comes from root).
  - An exemption belongs in the config of the ONE package whose reflections need it; putting it
    in the shared base makes every other package flag all of its names as unused.
  Same class as the two separate ESLint config blocks above: a setting that looks authoritative,
  reports success, and does nothing.
- **The ONLY documented-coverage exemption is eight ts-rs synthesized discriminants, enumerated by
  name in `src/types/typedoc.json`'s `intentionallyNotDocumented`.** ts-rs propagates a Rust field's
  doc comment into the generated TS, but drops the doc on the enum VARIANT, and the discriminant key
  itself (`"kind"`, `"type"`, `"op"`) is synthesized by serde's `tag` attribute — there is no
  declaration anywhere to attach a doc comment to, so these cannot be fixed at the source. A new
  discriminated wire union adds a new such reflection: add it BY NAME. Never widen the list to a path
  glob — a glob silently absorbs every future synthesized discriminant, whereas an enumerated list
  fails the gate until someone adds a name deliberately, which is the point. Adding a name needs the
  owner's per-instance sign-off like any other exemption. `scripts/report-doc-exemptions.mjs`
  derives the active set by scanning every `typedoc*.json` in the repo (never one hardcoded
  path — an exemption added to a config the scan doesn't read would otherwise be invisible to
  the count), and `report-doc-exemptions-cli.mjs` prints the total plus a per-source breakdown
  on each `docs:generate` run, because an uncounted exemption is a backdoor.

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

- **Generated API root** — `/api/rust/shadowcat/` (rustdoc, private items included), `/api/ts/`
  (TypeDoc, one entry point per workspace package). Produce with `pnpm build:all`; open
  `dist-docs/index.html` directly over `file://` or serve with `pnpm docs:serve`. Each subsystem
  skill below points to its own package/crate-module pages under this root.

**Build / test / lint commands:**
- Client build (produces `dist/`): `pnpm build` (= `pnpm --filter @shadowcat/shell build`).
- Client tests: `pnpm -r test` (Vitest). Typecheck: `pnpm -r typecheck`. Lint: `pnpm lint` (ESLint).
- `pnpm lint:file-size` (5,000-line soft / 10,000-line hard limit, owner-approved allowlist only)
  and `pnpm lint:inline-tests` (no inline Rust `#[cfg(test)] mod x { … }` bodies) are CI-blocking,
  same no-ratchet posture as the doc gates above.
- Server (from `src/server/`): `cargo test`, `cargo fmt`, `cargo clippy`.
- `pnpm build:all` is the full build entry point: the client build, then `docs:generate`
  (TypeDoc, `cargo doc`, the VitePress portal, assembly with its link check, and the
  documentation-exemption count). `pnpm docs:build` is a delegating alias for `build:all`, and
  `docs:generate` is the single place the chain is spelled out — don't re-enumerate its stages
  anywhere else. The client build must run first: `rust-embed` validates `dist/` at compile
  time, so `cargo doc` fails without it.
- Docs: `pnpm docs:serve` (view; the assembled `dist-docs/index.html` also opens directly over
  `file://` for static content, styling, and link navigation — anything driven by the site's
  runtime JavaScript, including search, the appearance toggle, and the mobile nav panel, needs the
  server instead), `pnpm docs:check-examples` (`@example` `` ```ts `` blocks must typecheck —
  CI-blocking), `pnpm lint:docs` (function doc coverage),
  `pnpm lint:props` (property/type/named-arrow doc coverage), `pnpm lint:comments` (no ephemeral
  references). **All are errors repo-wide with no per-package staging** — see the no-ratchets rule
  above; there is no `rulesAt(severity)` and no advisory tier anywhere in these configs.
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
- CI builds the client **before** cargo (embed ordering) across the three-OS matrix.

**Subsystem skills:** `documents-permissions`, `actors-tokens`, `scene-rendering`,
`realtime-sync`, `client-shell`, `assets`, `dice`, `chat`, `formula`, `module-toolchain`,
`sheets`, `panels`, `server-ops`, `templates`, `combat` (all `shadowcat-codebase-*`).

## Maintaining this skill family

This family is not fixed — **create a new `shadowcat-codebase-<subsystem>` skill whenever work
opens a subsystem none of the existing skills covers** (e.g. a new milestone like effects,
pathfinding, chat, or audio). Don't stretch an unrelated skill to fit.

When adding one:
1. Follow the fixed shape — Purpose / Key files & seams / Hard invariants / Gotchas / Pointers —
   and keep it orientation+index: point INTO graphify, `docs/design/`, and memory; never duplicate
   them. Cite each invariant's memory slug or design-doc section.
2. Add it to the **Subsystem skills** list above, and add its path globs to the activation hook
   (`.claude/hooks/codebase-skill-reminder.py` `SUBSYSTEMS` map). Every hook entry is an
   UNANCHORED substring match, because the Edit/Write payload's `file_path` is always absolute; a
   `^`-anchored pattern is inert while still passing repo-relative test fixtures. Pair each new
   entry with at least one absolute-path assertion in the hook's self-test.
3. This creation step is part of the reviewed skill-update gate (see CLAUDE.md
   `## Codebase Skills & Agents`): a new subsystem with no skill is itself a gate violation.

### Keeping the plugin current

Shadowcat's `.claude/` directory is also a Claude Code plugin source (`.claude-plugin/
marketplace.json` at the Shadowcat repo root points at `./.claude`; `.claude/.claude-plugin/
plugin.json` names and versions the plugin). A consuming repo reaches these skills, agents and
the routing hook through that plugin rather than through a second copy.

**A directory-sourced plugin is COPIED into the consumer's plugin cache rather than read live.**
Structurally verified, not yet empirically confirmed: an install lands under
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` as real copied files, and every
directory-sourced entry observed so far records a `lastUpdated` equal to its `installedAt`. The
consequence still awaiting confirmation is the one that matters — that editing a skill, an agent
body, or the hook in the Shadowcat engine repo reaches nobody else until the plugin is refreshed,
because the consumer keeps serving the snapshot it installed and the two disagree with no error
anywhere. The confirming test: edit one line of a skill here, then diff the copy under that cache
path. Until it runs, work as if the snapshot semantics hold — the cheap assumption is the safe
one, since assuming a live read is what ships stale skills silently.

So the skill-update gate has a third obligation alongside updating the skill and getting the diff
reviewed: **bump the `version` key in `.claude/.claude-plugin/plugin.json`** — that file's
`version`, NOT `marketplace.json`'s `metadata.version`, which versions the marketplace listing and
does not identify a cached plugin copy — **then refresh the plugin in each consuming repo**, from a
shell run inside that repo: `claude plugin marketplace update shadowcat`, then
`claude plugin update shadowcat-codebase@shadowcat --scope project` (a restart applies it). The
version bump is what makes the staleness detectable — an unversioned plugin caches under a single
unchanging placeholder version, where a refreshed copy and a stale one are indistinguishable.

**The update subcommand needs the FULLY-QUALIFIED name and the scope, or it fails.** Bare
`claude plugin update shadowcat-codebase` reports `Plugin "shadowcat-codebase" not found` at both
user and project scope, even while `claude plugin list` displays that plugin as installed and
enabled — the failure names the plugin rather than the resolution, so it reads as "not installed"
when the install is fine. Verified against a consumer that had drifted to a version predating the
skills it was serving; the qualified form updated it in one call. `claude plugin list` is the check
that settles which version a consumer actually holds — the cache directory under
`~/.claude/plugins/cache/` names its versions too, and a directory holding only an old version is
proof the refresh never landed.

Consumers also see these skills under a plugin prefix (`shadowcat-codebase:shadowcat-codebase-core`)
rather than the bare id. Take the exact name from the skill listing.
