Part of the shadowcat-codebase-core skill; read it when working under the no-ratchets, TypeDoc, no-data-migrations or no-justified-keeps rule a SKILL.md summary names. Part 02 of 02 of "Core gotchas — detail"; the index is gotchas-detail.md.

- **No ratchets, only gates** (user directive) — nothing is grandfathered. Every doc/comment check
  is `error` and fails CI: `pnpm lint:docs`, `lint:props`, `lint:comments`, `docs:check-examples`,
  Rust `-D missing-docs`, and `pnpm docs:check-rust-examples` (nightly rustdoc's
  missing-doc-code-examples lint, denied on every public item of the server crate — a `///` block with
  no fenced Rust example fails the docs job; a ` ```text ` fence does not count). **This gate can be
  green while enforcing nothing**: the lint is unstable, and denied without its feature gate rustdoc
  reports `unknown lint` and exits 0 — `scripts/cargo-doc-strict.mjs`'s examples mode injects
  `-Zcrate-attr=feature(rustdoc_missing_doc_code_examples)` in the same flag string, so a green run
  means the lint ran; a `-D` on an unstable lint with no feature gate is a check that cannot fail. Every example is a real doctest: `cargo test --all` compiles and
  runs each one (roughly 790 in the crate, each its own rustc invocation, several minutes on every
  matrix leg), so an example must use the item visibly and assert an outcome the item's contract
  produces — a ` ```no_run ` fence only where running needs a live socket, server or on-disk tree,
  and never ` ```ignore `. In-memory `SqliteRepository::connect("sqlite::memory:")` under a hidden
  `#[tokio::main]` scaffold is the established shape for persistence and handler examples.
  A warn tier is an exemption spread across a whole codebase, and a
  reported-but-passing violation is indistinguishable to a later reader from code that was checked.
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
  Same class as the two separate ESLint config blocks in references/docs-gates-and-build.md: a setting that looks authoritative,
  reports success, and does nothing.
- **The ONLY documented-coverage exemption is the set of ts-rs synthesized discriminants enumerated
  by name in `src/types/typedoc.json`'s `intentionallyNotDocumented` — its size is whatever
  `report-doc-exemptions-cli.mjs` prints, never a number restated here.** ts-rs propagates a Rust field's
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
- **Two more TypeDoc shapes that fail the strict docs build.** (1) A Rust tuple/newtype enum variant
  has no documentable property in the generated TS: give the variant a struct form (`{ recipients }`
  with `#[serde(untagged)]` keeps the wire form) so the field carries a doc comment. (2) A serde-tagged
  enum's tag key is a synthesized discriminant (the enumerated exemption above), so a new tagged enum adds
  its tag NAME to that list rather than getting a doc. A parameter-name mismatch between an interface
  and its implementation, or two declaration-merged interfaces both documenting the same member, also
  warns: declare shared option shapes as named exported interfaces (`AudioChannelPatch`) and compose
  hook sets by `extends` (`CoreHooks`), never by declaration merging.
- **`git commit -- <paths>` commits only files git already tracks.** A new file is silently left out and
  the commit does not build alone: `git add` each new file first, name it in the commit paths, and check
  `git status --short` for a `??` file the change needs.
- **No bare same-origin URL literal in client code.** Every `/api`, `/modules` and socket URL goes through
  `apiPath` / `wsUrl` so the server's route prefix works; `pnpm lint:route-prefix` fails otherwise. The
  client-side rule is in `shadowcat-codebase-client-shell`.
- **No data migrations pre-customers (user directive).** Until a milestone
  explicitly marks live customer databases, there is no upgrade path to preserve: SQL schema
  changes EDIT `src/server/migrations/0001_init.sql` (the single baseline) in place — never add
  an incremental migration file — and document-schema changes keep `data::migrate` step-free
  (`CURRENT_SCHEMA_VERSION` machinery only). The sqlx/`migrate()` machinery itself MUST stay, so
  real migrations can begin at that milestone. A dev DB predating a baseline edit fails the sqlx
  checksum — delete the dev DB file and restart. Any migration files that accumulate anyway are
  deleted on sight (squashed into the baseline).
- **There are NO justified keeps, exemptions or carve-outs unless the user explicitly signs off**
  (user directive, iron-clad). A well-argued keep is still a decision about *what the work covers*,
  which is the user's, never yours or a subagent's — ratifying one is a silent descope wearing
  technical clothes. Report a candidate as unconverted and awaiting a ruling; never as `kept`,
  never as "the carve-out covers this". **The first move is to remove the NEED for the exemption:**
  a fixture named `"W1"` that forced a comment to name a banned shape became `"token-world"`, and  <!-- EXAMPLE: RULE 16 specimen -->
  the comment then said what it meant with nothing to exempt. Any exemption that does exist must
  print its active count in its own output — an uncounted exemption is a backdoor, and a silent one
  is indistinguishable from a rule that does not apply.
