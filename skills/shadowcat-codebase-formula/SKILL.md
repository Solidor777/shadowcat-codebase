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

Covers every module of the package (types, lexer, parser, evaluate, graph, template, chars, internal, index), the server twin crate::formula, and the arithmetic semantics that surprise formula authors. Read references/key-files-and-gotchas.md (the Key files half) before changing or consuming any module, or when you need to know which file owns a behaviour.

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
- **DoS caps, exact values:** `MAX_FORMULA_LENGTH` 512 (UTF-16 code units), `MAX_AST_NODES` 256, `MAX_PARSE_DEPTH` 32
  (true structural-nesting boundaries — parens, call arguments, unary minus — NOT
  grammar-production depth, so a flat `a+b+c` chain never trips it), `MAX_GRAPH_VISITS` 2048
  (charged once per newly discovered key in `resolveAll`). No external record fixes any of them, so
  the tests are the source — but FOUR separate cases pin them, one per cap, and no single file
  stands for the rest. `types.test` asserts `MAX_FORMULA_LENGTH`'s value directly. The other three
  are pinned behaviourally, by a boundary case that spells its size as a LITERAL rather than
  deriving it from the constant: `parser.test` for `MAX_AST_NODES` and for `MAX_PARSE_DEPTH` (the
  exact size parses, one more caps — three constructs for the depth cap), and `graph.test` for
  `MAX_GRAPH_VISITS` (a chain of exactly that many distinct keys resolves, one key more caps, which
  also pins the bound as EXCEEDS rather than reaches). The deepest nesting that fits
  `MAX_FORMULA_LENGTH` returns a cap error in both twins (`parser.test` and, on a default-stack
  thread, the Rust `parser` tests), and the Rust twin also parses and evaluates a left-deep chain
  one node under `MAX_AST_NODES` on a default-stack thread. A LOOSE bracket pins nothing however it is
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

Covers the callback-boundary traps: evaluate cannot take the resolveAll getter directly, checkNotationKey answers in isolation (length cap, label extent, preceding digit run), the three-declaration dice-modifier vocabulary, the internal module as the only callback boundary, and consumers reusing function names as data keys. Read references/key-files-and-gotchas.md (the Gotchas half) before writing a consumer callback, a notation-key validator, or a new injected-callback seam, or adding a dependency, changing exports of this package, or editing property tests.

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_formula.html` (TypeDoc). Produce with
  `pnpm build:all`.
- Relationships: `graphify query "formula lexer parser evaluate graph resolver trampoline"`.
- `shadowcat-codebase-sheets` — the sheet registry a formula-driven system registers into.
- `shadowcat-codebase-dice` — the server-side dice engine; `resolveNotationTemplate` produces the
  notation string that engine then executes, and the two owe each other nothing else.

## Reference files

| File | Holds | Read it when |
|---|---|---|
| references/key-files-and-gotchas.md | The full Key files & seams section (module map, server twin, arithmetic semantics) and the full Gotchas section | Changing or consuming any module of the package, writing a consumer callback or notation-key validator |
