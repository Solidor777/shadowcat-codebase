---
name: shadowcat-codebase-formula
description: "Use when touching `@shadowcat/formula` (src/client/formula/) or its server twin `crate::formula` (src/server/src/formula/) — the framework-neutral expression language: the `lexer`/`parser`/`evaluate` pipeline, `resolveAll`/`resolve_all`'s cycle-guarded dependency-graph resolution, the shared TS/Rust conformance corpus that pins the two implementations together, the engine's `SystemLeafResolver`, the dice-notation-template rewrite and its key checker (`resolveNotationTemplate`/`NOTATION_KEYWORDS`/`NOTATION_FUNCTIONS`/`checkNotationKey`), the `types` module's error kinds and DoS caps, or the `internal` module's consumer-callback trust boundary. Invoke shadowcat-codebase-core first; for the sheet layer that consumes formulas invoke shadowcat-codebase-sheets; for the combat documents whose `Formula` fields the server parses at ingress invoke shadowcat-codebase-combat."
---

# Shadowcat — `@shadowcat/formula`

Orientation+index for Shadowcat's expression library. Points INTO graphify, `docs/design/`, and
memory rather than restating them.

## Purpose

`@shadowcat/formula` (`src/client/formula/`) is a pure-TS, zero-runtime-dependency expression
library: text → tokens → AST → number, plus generic cycle-guarded dependency-graph resolution and
a dice-notation-template rewrite mode. It carries **no game-system vocabulary** — no stats, no
modifier buckets, no document shape. References are opaque dotted paths resolved entirely by a
consumer-supplied callback, so any game system may use it, extend it, or replace it. **No Svelte
in its dependency closure**, so it is usable from headless contexts, not just the client. It is
one of the shell's `RUNTIME_ENTRIES`, so a consuming module gets the same single instance the
engine holds.

## Key files & seams

- The `types` module — `FormulaError`/`FormulaErrorKind`/`FormulaValue`, `isFormulaError`, and the
  four cap constants. Everything else imports from here.
- The three-stage pipeline, in order: the `lexer` module (`tokenize` → `Tok`/`Op`) → the `parser`
  module (`parseFormula` → the `Expr` AST) → the `evaluate` module (`evaluate`). Each stage imports
  the one before it, so this is a real data flow.
- Two SIBLING entry points over the same value types — NOT later stages of that pipeline: the
  `graph` module (`resolveAll`) and the `template` module (`resolveNotationTemplate`,
  `checkNotationKey`, `NOTATION_KEYWORDS`, `NOTATION_FUNCTIONS`). Neither imports the pipeline — `graph` imports the
  `types` and `internal` modules, `template` those two plus `chars` — and each is driven by a
  consumer callback. Neither can call the pipeline, so wiring a
  graph node's or a template identifier's text through `parseFormula`/`evaluate` is the consumer's
  own callback body, never something this package does on its way through. And `resolveNotationTemplate` is a PREVIEW/AUTHORING aid
  only: the wire carries RAW templates and the server's `formula::template` twin resolves references authoritatively at ingest
  (against the roll's actor binding), so a module SENDS raw templates (`1d20 + str`) and uses this package only to preview to the
  author or validate keys (`checkNotationKey`) — never to pre-substitute before sending.
- The `chars` module — `isDigit`/`isWordStart`/`isWordChar`, the character classes BOTH grammars
  accept, in ONE declaration read by the `lexer` module's tokenizer and the `template` module's
  scanner alike, so neither can widen its identifier set without the other following. Not
  re-exported from the `index` module. The grammars differ ABOVE this layer — what may follow an
  identifier, which words are reserved, how a malformed reference fails — so a difference between
  them never belongs here.
- The `internal` module — the shared trust-boundary helpers `isWellFormedError`,
  `validateResolverOutput`, `finite`, and `callResolver` (the try/catch shared by `evaluate`'s
  `ref` case and `substituteIdentifier`, converting a thrown consumer callback into a synthetic
  `"resolver-error"`; its result still needs `validateResolverOutput`, which it does not apply
  itself). **Deliberately not re-exported from the `index` module**: every injected-callback
  boundary (the `evaluate` module's reference case, `resolveAll`'s call to `resolveAll.evalNode`,
  the `template` module's identifier resolver) validates a consumer callback's return through
  these before trusting it as a `FormulaValue`.
- The `index` module — the only public entry point, re-exporting `types`, `parser`, `evaluate`,
  `graph` and `template`.
- Server twin: `crate::formula` (`src/server/src/formula/`) — `formula::types` (`FormulaError`,
  `FormulaErrorKind`, `FormulaValue`, the four caps), `formula::lexer::tokenize`,
  `formula::parser::parse`/`Expr`/`BinOp`/`FnName`, `formula::evaluate`/`Resolve`,
  `formula::graph::resolve_all`, `formula::resolver::SystemLeafResolver` (the engine's ONE
  reference-semantics decision: a dotted path reads LITERALLY from a document's `system` band —
  a path such as stats.hp.final reads `/system/stats/hp/final`; a number leaf is the value, absent → `unknown-ref`,
  present-but-not-a-number → `type`) plus `resolver::NoHostResolver` (the shared
  every-reference-unknown resolver), and `formula::template::resolve_notation_template`
  — the twin of THIS package's template rewrite (same recognizer chain incl.
  `claimNotationFunction`, the `1d` synthesis, labeled substitution incl. the `-N[path]` form,
  the integer-only and asymmetric i32-magnitude rules, UTF-16 positions). `js_number` renders
  JS-interpolation spellings for details (`Infinity`/`NaN`; `-0` normalizes to `0`).
  Behaviourally identical to this package by construction of
  the shared corpus, never by convention — the corpus's `templates` section pins the rewrite on
  both suites the same way `expressions`/`graphs` pin the evaluator. `data::engine::combat::Formula::validate` runs
  `formula::parse` at ingress, so a stored `Formula::Text` always parses. The combat clock is
  the evaluator's first server-side consumer: `combat::eval` wraps it (`eval_formula`,
  `resolved_resource`, `lifecycle_flags` and `duration_amount`, resolving references through
  `SystemLeafResolver` over `formula_host`'s token-copy-else-linked-actor document), consumed by
  `transition::recover`, `combat::effects::tick`/`expire_by_policy`, and the movement gate's
  `resolve_budget` — see `shadowcat-codebase-combat` and `shadowcat-codebase-scene-rendering`.

**Arithmetic semantics that surprise formula AUTHORS** (the `evaluate` and `lexer` modules): `/` is
float division and `%` is JS TRUNCATED remainder, so `-7 % 2` is `-1`, not the floored `1`; neither
implicitly rounds, so a value requiring an integer needs an explicit `FnName.floor`/`FnName.round`,
and `FnName.round` is JS-native, meaning ties go toward positive infinity rather than away from
zero — a real difference for negative operands. Both `x / 0` and `x % 0` are a `"div-zero"` error,
never `Infinity`/`NaN`; every arithmetic result is gated through `finite`, so an overflow surfaces
as `"non-finite"` instead of leaking downstream. **A leading-dot decimal is not a numeric
literal** — `tokenize` requires a leading digit and emits a bare `.` operator instead, so `.5` is a
parse error; write `0.5`. And `checkArity` runs at PARSE time only, so an `Expr` hand-constructed
against the public API bypasses arity checking entirely and degrades through `finite` rather than
erroring cleanly — build expressions with `parseFormula`, never by hand.

## Hard invariants

This package has no design document of its own, so an invariant here cites the architecture
document or a memory slug where one governs it, and otherwise names the TEST that pins it. A test
is the stronger referent for a library contract anyway: it fails when the invariant stops holding,
which no prose can do.

- **One conformance corpus pins both implementations.**
  `src/client/formula/src/__fixtures__/conformance.json` is read by `conformance.test.ts` here and
  by `formula::tests::conformance` on the server; every case asserts value-or-error INCLUDING the
  `detail` string. A grammar or wording change lands in the corpus first, then in both
  implementations — a change to one side alone fails the other's suite. `round` ties toward +∞ on
  both sides (`formula::evaluate::js_round`, never `f64::round`; the corpus pins
  `round(0.49999999999999994) = 0`, which the naive floor-of-x-plus-one-half model of JavaScript rounding gets wrong);
  source length is counted in UTF-16 code units on both sides. The TS side runs on a real JS
  engine, so when reasoning about what JavaScript rounding "should" return disagrees with the corpus, the
  corpus is right — add the case, never argue from an engine model.

- **Error-value-only, fail-closed.** No function in this package throws on ANY input, and
  arithmetic never leaks `NaN`/`Infinity` — both become a `FormulaError` via `finite`. A consumer
  callback (`evaluate.resolve`, `resolveAll.evalNode`) IS allowed to throw or return a malformed
  value; `validateResolverOutput` converts that into a `"resolver-error"` rather than propagating
  it. `FormulaErrorKind` is mirrored by hand in `FORMULA_ERROR_KINDS` for runtime validation —
  adding a kind means updating BOTH, and the enforcement is ONE-DIRECTIONAL. The array's
  satisfies clause makes an entry outside the union a compile error; the reverse — a kind added
  to the union and omitted from the array — compiles clean and silently narrows what
  `isWellFormedError` accepts, so a consumer returning that kind gets it rewritten to
  `"resolver-error"`. That direction is closed by `types.test`'s exhaustive keyed record over
  `FormulaErrorKind`: adding a union member is a COMPILE error there until it is listed, and the
  assertion beside it then requires `FORMULA_ERROR_KINDS` to carry exactly those members — so
  both directions are machine-checked and neither rests on a habit. The
  callback half is [[injected-callback-boundary-must-validate-every-site]]; the no-throw half is
  pinned by `property.test`'s never-throws and never-NaN properties over random input.
- **DoS caps, exact values:** `MAX_FORMULA_LENGTH` 512, `MAX_AST_NODES` 256, `MAX_PARSE_DEPTH` 32
  (true structural-nesting boundaries — parens, call arguments, unary minus — NOT
  grammar-production depth, so a flat `a+b+c` chain never trips it), `MAX_GRAPH_VISITS` 2048
  (charged once per newly discovered key in `resolveAll`). No external record fixes any of them, so
  the tests are the source — but FOUR separate cases pin them, one per cap, and no single file
  stands for the rest. `types.test` asserts `MAX_FORMULA_LENGTH`'s value directly. The other three
  are pinned behaviourally, by a boundary case that spells its size as a LITERAL rather than
  deriving it from the constant: `parser.test` for `MAX_AST_NODES` and for `MAX_PARSE_DEPTH` (the
  exact size parses, one more caps — three constructs for the depth cap), and `graph.test` for
  `MAX_GRAPH_VISITS` (a chain of exactly that many distinct keys resolves, one key more caps, which
  also pins the bound as EXCEEDS rather than reaches). A LOOSE bracket pins nothing however it is
  spelled: `graph.test`'s cap-trip case and its long-chain smoke case admit every value between
  them. Name those two by what they do rather than by how many chains the file holds — a count goes
  stale the moment a case is added.
- **`resolveAll`'s trampoline is O(1) JS-stack-depth by construction, not an implementation
  detail.** It restarts `resolveAll.evalNode` from scratch on an internal `NeedsDependency` throw
  rather than recursing, so graph depth never grows the call stack. Pinned by MEASUREMENT rather
  than by exhaustion, and it has to be: `MAX_GRAPH_VISITS` caps a chain at 2048 keys, far short of
  the default stack, so no constructible input makes a depth-proportional traversal overflow and
  growing the input can pin nothing. `graph.test`'s constant-frame case reads the observed JS stack
  depth from inside the consumer callback at every chain level, and asserts it is identical across
  the levels of one chain AND across a short and a long chain — which a recursive rewrite fails,
  because its frame count grows per level. Its sibling long-chain case is a smoke case only: it
  runs at the harness default stack and passes under a recursive rewrite too.
  Motivation, not the constraint itself:
  the client must run on mobile browsers (`docs/design/ARCHITECTURE.md` §2 invariant 10), which
  requires that support but states no call-stack bound of its own. **A consumer's
  `resolveAll.evalNode` body must NEVER wrap its own call(s) to the injected getter in
  try/catch**: that swallows the signal driving the trampoline and silently
  memoizes a wrong, partial result. `evaluate`'s `ref` case and `substituteIdentifier` both
  invoke `internal`'s `callResolver`, which wraps a consumer resolver call in its own try/catch
  guarding a DIFFERENT concern (turning a malformed resolver return into a `FormulaError`) and
  must not be reused to catch the trampoline signal — prefetch every reference path unwrapped
  before calling `evaluate` instead.
- **`resolveAll` is a pure function of the key set.** Sorted-root traversal means the same set of
  requested keys always produces the same result regardless of call or iteration order; traversing
  in the caller's key order instead makes the result order-dependent. Cycle-error detail names the
  lexicographically smallest cycle member, so two logically-identical graphs built in different key
  orders report byte-identical detail. Pinned by `graph.test`'s order-independence cases and
  `property.test`'s random-DAG property; no external record states it.
- **Zero game-system vocabulary in this package.** A change that introduces one consumer's concepts
  into `src/client/formula/` is a layering violation: it belongs in that consumer's own package.
  (`docs/design/ARCHITECTURE.md` §2 invariant 7, the framework-neutral public API, and invariant 6,
  which makes the opaque band the game system's own territory rather than the engine's.)
- **The grammar has no exponent notation.** `1e999` lexes as a number followed by a word — a parse
  error, not a cap error. A deliberate grammar boundary, not a lexer defect; do not "fix" the lexer
  to accept exponents without a grammar change. Pinned by `parser.test`'s exponent-notation case;
  the boundary is this package's own decision and no external record states it.
- **The two grammars this package parses differ in reservation, in case handling and in FAILURE
  MODE, and generalizing any of the three across both is a silent miss.** `parseFormula`'s grammar
  reserves no identifier names: a bare word is always a reference, whatever it spells, so
  reserved-word validation there is purely a consumer's concern — and `tokenize` lowercases every
  word token it emits, so that grammar's resolver is always offered a lowercased path.
  `resolveNotationTemplate` does neither, and **which written keys survive its grammar has no
  closed-form description.** Its scan is an ordered chain of recognizers (`RECOGNIZERS`) tried at
  each position by `claimAt`, and a key survives exactly when one `claimIdentifierSpan` claim
  covers all of it — negative space over that ordering, not a property of `NOTATION_KEYWORDS`,
  which the grammar reserves more than. **`checkNotationKey` is the authority, and it answers by
  RUNNING that same chain**, so a consuming system's stat-key authoring validation calls it rather
  than restating it; a restatement is a second statement of one decision and drifts. Do not write a
  rule for the safe set here or anywhere else.
  **Only the membership probe is lowercased.** The emitted text keeps the author's case and
  `substituteIdentifier` splits the raw slice, so this grammar's resolver is offered a RAW-CASE
  path where the other's is offered a lowercased one. A consumer keying its resolver on lowercase —
  which the other grammar teaches it to do — misses on a mixed-case template reference, and the
  miss surfaces as that consumer's own unknown-reference error rather than as anything pointing
  here. **The two also FAIL DIFFERENTLY on one written key**: a key whose dotted segment starts
  with a digit is a loud parse error in `parseFormula` and a silent split in
  `resolveNotationTemplate`, which is why testing a key against one grammar tells a consumer
  nothing about the other. **A template-grammar collision is not reliably loud, and how one scan
  can end is enumerated on `NotationKeyCheck` — read the outcomes there.** The one thing to know
  before reading them is that the discriminator is TWO-LEVEL: branch on `rejects` first, or the
  shape outcomes get read off a value whose `segments` holds only the prefix claimed ahead of the
  rejection. What binds a consumer is the coupling: a consuming system validates a stat key by
  CALLING `checkNotationKey`, never by reasoning over `NOTATION_KEYWORDS`, because a collision it
  misses can change the number a roll produces with no error on any path FOR SOME of
  `NotationKeyCheck`'s outcomes and not others. `NOTATION_KEYWORDS` cannot tell a caller which
  outcome a given key falls into; only `checkNotationKey` can. A spy resolver answering
  every path hides the split outcome, so `template.test` pins it with a resolver that knows only
  the key as written.
  `template.test`'s `checkNotationKey` cases derive their keyword
  shapes from `NOTATION_KEYWORDS` itself, so a keyword added there is covered without a second
  edit, and one case asserts the checker's verdict against what the rewrite observably does to each
  key, so the two cannot drift apart. Beside the hand-written cases sits ONE generated sweep, over
  a keyword-derived alphabet, driven by a `template.test`-local consequence oracle that classifies
  a key from what `checkNotationKey` returns and checks that classification against what
  `resolveNotationTemplate` observably does to it; what the alphabet and length leave unreachable
  is stated at their own declaration rather than here. It exists because an author's list of
  shapes — prose, corpus and predicate set alike — cannot contain the shape nobody thought of, and
  it is what a claim about this taxonomy is answerable against. It is NOT independent of the
  recognizer chain, which both `checkNotationKey` and `resolveNotationTemplate` run through the
  SAME `claimAt` call, so a defect confined to a recognizer moves both answers together and is
  invisible to this oracle AT ANY ALPHABET OR LENGTH — no generated sweep over this oracle, however
  wide or deep, can see such a defect; only a hand-written case with its own independent
  expectation can (the `"a.b.c"` case is what actually covers a multi-join dotted path, for
  exactly this reason: it asserts `intact` against a literal, not against a value this oracle
  reads back off the same scan).

## Gotchas

- **`evaluate` cannot be handed `resolveAll`'s `get` directly.** `evaluate`'s reference case
  wraps the resolver in `callResolver`'s try/catch, which swallows the `NeedsDependency` restart
  signal `resolveAll` throws through `get` — so a graph node whose `resolveAll.evalNode` calls
  `evaluate(ast, (path) => get(...))` resolves every not-yet-memoized dependency to a
  `"resolver-error"` instead of restarting. The consumer pattern is collect the AST's refs, call
  `get` for each OUTSIDE `evaluate`, then evaluate over the fetched map — what
  `conformance.test.ts` and the server's `formula::tests::conformance` both do, and why the two
  harnesses must request the same dependency set per node to stay comparable.

- **`checkNotationKey` answers over the key in ISOLATION, and TWO things can part its answer from
  the rewrite's. Both sit outside the grammar** — within the grammar both run `claimAt`, so an
  intact verdict cannot drift there.
  - **The length cap.** `checkNotationKey` is scoped to the grammar and deliberately does not
    apply `MAX_FORMULA_LENGTH`, which bounds a whole template rather than a key. A key past that
    length is therefore scanned here and refused UNSCANNED by `resolveNotationTemplate`, whose cap
    error returns before any recognizer runs. The behaviour is deliberate and stays; only the
    claim about it needed bounding.
  - **`claimLabelSpan`'s extent**, which is not key-local — it scans forward for a `]` through
    whatever source it is handed. A key holding an unmatched `[` therefore rejects when checked
    alone, while a template supplying a `]` further along returns notation with no error and
    absorbs everything between the two brackets as a label. An authoring UI told "this will not
    run" about a key that runs WRONG is the worse of the two errors. The positions differ for the
    same reason: the checker counts from the start of the key, a template's own error from the
    start of the template. Both behaviours are measured and pinned by `template.test`. Whether a
    bracket inside a written key should be absorbable as a label at all is an open runtime
    question awaiting a ruling — do not change the behaviour to close the gap.
- **An `intact` verdict is not a safe-in-every-position verdict.** `checkNotationKey` scans the key
  from position ZERO, so it says nothing about the text a template puts in FRONT of it: an intact
  key immediately following a digit run has that run emitted ahead of the substituted value, and
  the two concatenate into one number rather than adding — a silently wrong TOTAL, not an error.
  Same class as the bracket-isolation gotcha above: the key checks safe in isolation and runs wrong
  in context, and the caveat is carried on `NotationKeyCheck.intact`. Pinned by `template.test`.
- **The dice-modifier vocabulary is one decision with THREE declarations, and the math-function
  vocabulary is another with three.** `NOTATION_KEYWORDS`
  mirrors the server notation parser's `P::modifiers` match AND the server formula twin's own
  `NOTATION_KEYWORDS` (`formula::template`) — none of the three can read another. `modifierParityDifference`
  reads all three and fails `pnpm test:scripts` on a difference in any direction, so a new modifier lands in all
  declarations or the build breaks. Without that gate the only signal is a wrong roll, seen by whoever wrote the template.
  **Math-function names do NOT belong in
  `NOTATION_KEYWORDS`** — it guards the dice-MECHANIC modifier vocabulary specifically (the same
  category as kh/cs/tr/rs/xs/xf). The notation `fn_call` vocabulary has its OWN list,
  `NOTATION_FUNCTIONS` (floor/ceil/round/abs/min/max), mirrored by the server twin's own
  declaration and parity-checked against the dice parser's `fn_call` match arms the same way; the
  template scan reserves a function name ONLY when immediately followed by `(`, which is what
  keeps `floor(101d6/2)` reading as notation rather than a stat reference now that the server runs
  every roll through the scan. Separately, this package's OWN formula-grammar function set (`FN_NAMES`/`FnName` in `parser`:
  min/max/floor/ceil/round — five names) overlaps with but is not identical to the dice crate's
  six (`FnName` in `dice::spec`: also has `Abs`, which this package has no counterpart for) — the
  overlap is coincidental, not a parity-enforced one.
- The `internal` module's four helpers are the ONLY sanctioned way to cross a consumer-callback
  boundary. A gap at one boundary reopens the class of bug the others already guard against
  [[injected-callback-boundary-must-validate-every-site]] — treat any NEW injected-callback seam as
  needing the same validation, never a bespoke check. `resolveAll`'s own try/catch around
  `resolveAll.evalNode` stays entangled with the `NeedsDependency` trampoline signal and does not
  route through `callResolver` — only `evaluate`'s `ref` case and `substituteIdentifier` share it.
- Arithmetic semantics (`/`, `%`, rounding, `finite` gating, the leading-dot decimal) are stated
  ONCE, under **Key files & seams** above, so two copies cannot drift apart.
- `property.test` uses a hand-rolled seeded PRNG — do not add `fast-check` or any other new
  dependency to this package.
- **A consumer that reuses the library's function names as data keys collides silently.** The
  FORMULA grammar reserves nothing (the notation-template grammar's separate reservation is the
  invariant above), so a consumer that skips a collision check gets an identifier resolving to a
  call instead of a reference. **The two name sets a consumer must reject against are NOT
  equally reachable**, and the asymmetry is the trap: `NOTATION_KEYWORDS` is exported from the
  `template` module, while `FN_NAMES` and its `FnName` mirror are module-private to `parser` and
  the barrel re-exports nothing it does not export. A consumer therefore cannot import the
  builtin-function names and has to mirror them. The RUNTIME value set is what is unimportable —
  the mirror is not unbindable: `Expr` is exported and its call arm declares `fn` as the same
  closed literal union, so a consumer can extract that union from the exported AST type and bind
  its own list to it at compile time in both directions (constrain the list to the union, and
  assert the union minus the list is empty). That is the drift guard a consumer-side duplicate
  needs — not a hand-maintained copy — and it needs no change to this package's public API. Do not
  export `FN_NAMES` to remove the fork without a ruling: that IS a public-API change.

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_formula.html` (TypeDoc). Produce with
  `pnpm build:all`.
- Relationships: `graphify query "formula lexer parser evaluate graph resolver trampoline"`.
- `shadowcat-codebase-sheets` — the sheet registry a formula-driven system registers into.
- `shadowcat-codebase-dice` — the server-side dice engine; `resolveNotationTemplate` produces the
  notation string that engine then executes, and the two owe each other nothing else.
