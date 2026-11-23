Part of the shadowcat-codebase-core skill; read it when working under the test-fixture delete, module-doc, symbol-citation gate or ephemeral-reference rule a SKILL.md summary names. Part 01 of 02 of "Core gotchas — detail"; the index is gotchas-detail.md.

- **Server-crate Rust tests never call a permanent-delete function on their own fixtures.** A test
  needing a fresh, not-yet-existing directory owns it via `tempfile`'s directory-guard type and
  lets it fall out of scope to recursively remove the directory, rather than calling
  `remove_dir_all` explicitly at the end of the test; a test needing a file to be ABSENT after
  having been present (e.g. to force a regenerate-on-miss path) `rename`s it aside within its own
  temp directory instead of deleting it outright, preserving the same "derivative does not resolve
  to an existing file" precondition. Production delete call sites (e.g. `backup`, `data::asset`,
  `data::sqlite::export_import`, `world_bundle`, `http::assets`, `http::routes`,
  `http::world_bundle`) are untouched by this convention — it governs test fixtures only.
- **A Rust `mod` item never carries an outer doc; the module is documented by the `//!` block
  inside its own file (or inside the braces of an inline `mod x { }`).** Rustdoc merges an outer
  `///` on the declaration with the module's inner docs and resolves the merged text in the PARENT's
  scope, so a relative intra-doc link that is correct inside the module (a bare link naming a child
  module) fails with "no item named … in scope" once the declaration also carries an outer doc, and
  the module ends up documented in two places that can disagree. The first `//!` paragraph is the
  one-sentence summary the parent's module index shows. `pnpm lint:module-docs` (the `scanModuleDocs`
  scan, run by `runGate`) fails any `mod` item with `///`, `/** */` or `#[doc]` attached, file-backed
  or inline, in `src/**/*.rs`; it is in `scripts/gates.toml`'s commit tier and CI-wired. A `cargo
  doc` run does not see `#[cfg(test)]` or other-OS modules, so the scan, not rustdoc, is what covers
  those declarations.
  `node scripts/check-skill-symbol-refs-cli.mjs` (fatal, CI-wired) resolves every code-symbol
  citation in every TRACKED skill directory against a symbol index built from what the tree
  declares — Rust items, methods, fields, variants, serde wire names, local bindings, parameters
  and literal alternation sets; SQL tables/columns; Cargo and JSON config keys; every TS/Svelte
  declaration, member at any depth, object-literal key, import and literal type, read through the
  TypeScript parser; and module/package/skill directory names. **A token's shape decides only
  whether it is a citation at all, never whether a citation is CHECKED** — a shape exclusion hides
  the citations it skips AND every index gap behind them, so every code span lands in exactly
  one printed bucket (the list is in SKILL.md) — and each acknowledgement entry is hit-counted, a
  zero-hit entry failing the gate. **That list is `SPAN_BUCKETS`, and the sentence in SKILL.md is
  pinned to it by a test**:
  a claim about the code that is neither derived from it nor tested against it drifts the moment a
  bucket joins the list or its label changes. What makes it true rather than
  asserted is `spanAccountingDelta` — every backtick RUN must be one of a bucketed span's two
  delimiters, or must have left before classification by one of the ways out printed beside the
  buckets (listed in SKILL.md), of which the last, unpaired at top level, is
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
  cite documents by path + section anchor. **This skill family (the plugin checkout's `skills/**/*.md`) is now
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
  Subsystem skills list in SKILL.md is written that way. And a churn tracker named WITHOUT its extension
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
