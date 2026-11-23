# Formula: key files, seams and gotchas

Part of the shadowcat-codebase-formula skill; read it when changing or consuming the package modules or its consumer callbacks. The Hard invariants this file refers to live in SKILL.md, not in this file.

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
- The `coerce` module — `coerceFormula(text)`, the ONE decision every formula text input makes
  about what to store: a finite numeric literal becomes a `number`, any other text that PARSES is
  kept as its trimmed source `string`, and everything else (an empty input included) is the
  `FormulaError` `parseFormula` returned. Only the parse is checked; what a reference means stays
  the evaluator's call. The combat settings editors (`BarsEditor`, `ResourceRegistryEditor`,
  `CombatSettings`, `CombatSceneOverrides`) all store through it, so a second spelling of the
  number-or-text rule in an editor is the fork this exists to prevent. Its sibling in the `parser`
  module, `isBareLeafReference(formula)`, answers the dotted path (lowercased, the form a resolver
  is offered) when a stored formula is EXACTLY one bare reference and `null` for a number, any
  other node shape, or a parse failure; it is an AST shape check over `parseFormula`, not a second
  grammar. The token quick-edit bar nudges use it to decide whether a bar's value can be written
  straight to its leaf.
- The `index` module — the only public entry point, re-exporting `types`, `parser`, `evaluate`,
  `graph`, `template` and `coerce`.
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
never `Infinity`/`NaN`; every numeric literal, arithmetic result and resolved reference is gated
through `finite` in both evaluators, so no successful result is non-finite for any `Expr` and an overflow surfaces
as `"non-finite"` instead of leaking downstream. **A leading-dot decimal is not a numeric
literal** — `tokenize` requires a leading digit and emits a bare `.` operator instead, so `.5` is a
parse error; write `0.5`. And `checkArity` runs at PARSE time only, so an `Expr` hand-constructed
against the public API bypasses arity checking entirely and degrades through `finite` rather than
erroring cleanly — build expressions with `parseFormula`, never by hand.

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
  `NOTATION_FUNCTIONS` (floor/ceil/round/abs/min/max, plus `best`, the dice parser's two-branch
  `Expr::BestOf` call), mirrored by the server twin's own
  declaration and parity-checked against the dice parser's `fn_call` match arms the same way; the
  template scan reserves a function name ONLY when immediately followed by `(`, which is what
  keeps `floor(101d6/2)` reading as notation rather than a stat reference, because the server runs
  every roll through the scan. Separately, this package's OWN formula-grammar function set (`FN_NAMES`/`FnName` in `parser`:
  min/max/floor/ceil/round — five names) overlaps with but is not identical to the dice crate's
  six (`FnName` in `dice::spec`: also has `Abs`, which this package has no counterpart for) — the
  overlap is coincidental, not a parity-enforced one.
- **An identifier in a dice COUNT position substitutes as a bare integer, not a labeled value.**
  `resolveNotationTemplate` rewrites `prof d6` to `3 d6`, and `str + d6` still labels `str`: an
  identifier followed (after any spaces or tabs) by the dice operator is the count, so it resolves
  through the integer-only path (`resolveInteger`'s i32-magnitude rule) and must be NON-NEGATIVE.
  Both twins carry the one decision (`diceOperatorFollows` here, `dice_operator_follows` and
  `substitute_bare_count` in `formula::template`), and the scan's single carried flag
  (a flag that the preceding claim was an integer or a bare count, held across blanks) is what stops a second `1` being synthesized ahead of an `d` that already has its count.
  A change to either twin's count handling lands in the corpus first.
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
  invariant in SKILL.md), so a consumer that skips a collision check gets an identifier resolving to a
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

