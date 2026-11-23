Part of the shadowcat-codebase-dice skill; read it when editing dice::eval::expertise, sum, success, recalc or notation. Part 02 of 02 of "Dice engine: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-rng-spec-outcome-eval.md.

- `dice::eval::expertise` — the value-mutating pre-pass `allocate(direction,
  cfg: &SuccessConfig, raws: &RawRoll, records: &mut [DieRecord])`, called by
  `eval::success::evaluate_success` only when `cfg.expertise > 0`, BEFORE base-success counting
  (b-1's counting logic itself is unmodified/sealed). `adjust(direction, value, min, max, k)`
  moves a face up to `k` steps toward "better" (arithmetic in i64, result back in i32), stopping at the die's better-end bound
  (`max`/`min`) — provably preserves `adjust(_, v, _, _, 0) == v` for every `v`, INCLUDING values
  outside `[min,max]` (a Compound die's `value > max`, a Penetrate child's `value < min`), so an
  out-of-range face is never dragged back across a bound even at zero spend. `die_values(...) ->
  Vec<(i64,i64)>` builds the per-die `v_i(k)` table for `k in 0..=e`: each entry is
  `(net_i, counter_i)` in i64 from moving the face `k` steps then re-scoring via `crit::score_die` +
  `cfg.success`. `run_dp(dies, e, better) -> (Vec<u32>, (i64,i64))` is a bounded-knapsack DP,
  `O(N·E²)`, over an injected `run_dp::better` ordering; ties break toward the SMALLEST `k` at each die,
  and backtracking runs from the LAST die outward so points concentrate on the earliest dice
  whenever spending is actually needed. `allocate` runs `run_dp` up to
  TWICE: pass 1 maximizes raw lexicographic `(net, counter)`; if
  `allow_negative` is unset and the achieved net is `< 1`, every allocation clamps to net 0 so a
  second counter-only pass replaces it (the all-failed-region fallback). Both passes mutate only
  the chosen dice's `value` (adjusted face) and `expertise` (points spent). **`allocate` restricts
  its contributing-dice set to `Numeric` dice only** — the bounds map (`DieId ->
  (min,max)`) is built via `filter_map` over `raws.dice`, mapping only `DieKind::Numeric` entries;
  a kept `Faces` die (ordered or not) is excluded, since `adjust`'s "+1 toward better within
  [min,max]" has no defined meaning over an arbitrary face-list. A kept-but-excluded `Faces` die's
  own (unchangeable) success/crit contribution is folded in as a constant `fixed: i64` term (via
  `crit::score_die_net`) — the two-pass
  clamp-decision branch checks `allow_neg || net + fixed >= 1`, not just the DP's own Numeric-only
  `net`, because the pool's TRUE clamped net includes any fixed contribution from an excluded
  Faces die that independently satisfies success/crit rules; using only the partial `net` answers
  a different question than `evaluate_success` will actually score. `allocate::fixed` is a constant additive
  shift across every candidate allocation, so it never changes either DP pass's own argmax — only
  the pass-choice threshold needs it.
- `dice::eval::sum` — `evaluate_total(spec, cfg: &TotalConfig, raws) ->
  RollOutcome`: folds the AST to a total by matching `DieRecord.group_index` against an AST-order
  cursor (`fold`); **the group-boundary reconstruction is the correctness core** — a wrong
  boundary silently mis-sums a multi-group roll. If `cfg.difficulty` is set, classifies via
  `oriented_margin` + `classify::classify`; otherwise reports a bare total (`pass`/`margin`/
  `tier_*` all `None`).
- `dice::eval::success` — `evaluate_success(spec, cfg: &SuccessConfig, raws) ->
  RollOutcome`: if `cfg.expertise > 0`, first runs `eval::expertise::allocate` over a cloned
  `records` to mutate chosen dice's `value`/`expertise`, THEN pools **all kept records across
  every group** (ignores `group_index`/AST
  arithmetic entirely — the defining difference from Total mode), counts base successes against
  `cfg.success` (via the shared `crit::score_die_net`), then folds each kept die's crit
  result into net successes and the positive/negative counters (counters are a SEPARATE output,
  never folded into `successes`). The net and both counters accumulate in i64 and clamp to
  i32 once, via `clamp_i32`, so the result does not depend on summation order. The same per-die loop also tallies `symbol_counts`
  UNCONDITIONALLY over every kept die's `symbols` — independent of which `SuccessRule` variant is
  active, so a Numeric-rule roll on symbolic dice still populates `symbol_counts`. Net
  = `base + extra_successes - lost`, clamped at 0 unless `cfg.crit_fail.allow_negative` opts out.
  If `cfg.required_successes` is set, classifies `net - required` via the SAME shared
  `eval::classify::classify` Total uses — but **NEVER runs it through `oriented_margin`**: more
  successes is always better, and `direction` was already applied per-die inside `crit::score_die`.
  This asymmetry (Total margins are direction-flipped; SuccessCount margins are a plain
  subtraction) is load-bearing — a future change that "fixes" SuccessCount to also call
  `oriented_margin` would double-apply direction and silently invert every LowWins SuccessCount
  roll's pass/tier result.
- `dice::recalc` — `recalculate(spec, raws, ops, rng) -> (RawRoll, RollOutcome)`
  + `RecalcOp{RerollDice, ReplaceDie, RemoveDice}`. Reconstructs each group's **base naturals only**
  from `RawRoll.group_spans` (excludes explosion/penetrate children by design), applies ops, then
  `rederive`s by re-running `resolve_group` over the mutated naturals in AST order. `RecalcOp::
  RerollDice`'s redraw formula is `DieKind`-dispatched: a fresh numeric face for
  `Numeric`, a fresh face INDEX via `roll_uniform(rng, 0, faces.len()-1)` for `Faces` — mirrors the
  same formula used at `eval::groups`'s two other draw sites. `ReplaceDie`/`RemoveDice` needed no
  `Faces` change (both are `DieKind`-agnostic, operating only on `natural`/id).
  `chat::rolls::execute_roll`/`execute_roll_with_seed` (in `chat`, not here) return the
  parsed `RollSpec` and rolled `RawRoll` alongside `formula`/`outcome`, so they can be persisted
  onto a `Segment::RollEmbed`; `chat::handle_recalc_roll` (also in `chat`) is `recalculate`'s
  FIRST production caller — it re-derives from the message's stored `spec`/`raw` under a fresh
  `entropy_seed()`-keyed `NoiseRng`, same as any other roll, and never bypasses this function's
  own base-naturals-only reconstruction.
- `dice::notation` (its `lexer` and `parser` submodules) — `lex`/`Token`/`ParseError` +
  `parse(input: &str, ctx: ParseContext) -> Result<RollSpec, ParseError>` (recursive descent:
  `expr := term (('+'|'-') term)*`; `term := factor (('*'|'/') factor)*`; `factor := '(' expr ')'
  | '-' factor | fn_call | dice | int`, `fn_call := ident '(' expr (',' expr)* ')'`). `fn_call`
  recognizes an `Ident` as a math function only when immediately followed by `(` at the `factor`
  position — the same lexer `Ident` token the modifier grammar already consumes, so no lexer
  change was needed for the six function names themselves; `FnName::accepts_arg_count` (Min/Max
  variadic >= 2, every other variant exact) is checked at parse
  time, producing `Expr::Call{name: FnName, args}`. `Token::Comma`/`Token::Colon` are two new
  single-char tokens: `Comma` separates `fn_call` arguments, `Colon` separates a modifier's
  threshold from its optional value fields (`tr<offset>:<value>`, `xs<N>:<extra>:<counter>`,
  `xf<N>:<lost>:<counter>`). `ParseContext{mode: ModeKind, direction: Direction}` is caller-
  supplied ambient state the notation string does not itself encode: `mode` (`ModeKind::Total |
  SuccessCount`) resolves a bare `t<N>` target's `Mode` when the notation has no explicit
  `cs>N`/`cf<N`; `direction` resolves `t<N>`'s comparator under
  SuccessCount-ambient context (`HighWins` -> `Gte`, `LowWins` -> `Lte` — the composer never
  specifies the comparator via `t<N>`) and seeds
  `RollSpec::direction`. Under Total-ambient context, `t<N>` resolves to `TotalConfig.difficulty`
  instead. The parser's internal state (`struct P`, not `ParseContext`) also carries an
  `expertise: Option<u32>` roll-level scratch field set by an `e<N>` token (no dedicated lexer
  token — the alphabetic-run arm emits `Ident("e")`, the parser's `modifiers` arm reads the
  following int, the same function that handles
  `P::modifiers::kh`/`P::modifiers::cs`/`P::modifiers::t`); a duplicate `e<N>` is
  `ParseError::DuplicateExpertise`. `expertise` is only consumed when the FINAL resolved mode is
  `SuccessCount(SuccessConfig{expertise, ..})` — if the notation instead resolves to `Total`
  (e.g. `t<N>` under Total-ambient context with no
  `cs>N`/`cf<N`), any parsed `e<N>` value is silently
  dropped, never an error. The parser carries an analogous `required_successes: Option<i32>`
  scratch field set by an `rs<N>` token, mirroring `e<N>`'s exact pattern: a duplicate `rs<N>` is
  `ParseError::DuplicateRequiredSuccesses`, and the value is consumed only into
  `SuccessConfig.required_successes` when the resolved mode is `SuccessCount` — silently dropped
  under `Total` (`TotalConfig` has no equivalent field; `t<N>` already fills that role via
  `TotalConfig.difficulty`). `required_successes` gates `eval::success::evaluate_success`'s entire
  pass/margin/tier classification (`match cfg.required_successes { None => ..., Some(req) => ... }`)
  — without an `rs<N>`, a `tr<offset>`-built tier ladder parses fine but never actually classifies
  anything on any roll. Explicit `cs>N`/`cf<N` in the notation
  always forces `SuccessCount` regardless of the
  ambient `mode`. A `t<N>` + explicit `cs>N`/`cf<N` together is a
  collision —
  `ParseError::DuplicateSuccessRule` (shared parser state: `success`/`t_target` are one `RollSpec`,
  not per-`DiceGroup`). SuccessCount with NEITHER a
  `cs>N`/`cf<N` rule nor a `t<N>` target is a hard
  parse error. The lexer is **case-insensitive on the `Token::D` dice operator** and
  enforces
  **ASCII-only input** as an explicit precondition (not an accident of the byte-as-char cast it
  uses internally). The parser also rejects `sides < 1` (`ParseError::InvalidDieSides`) before ever
  constructing a `DieKind::Numeric`. **`[label]` notation**: the lexer's `[` arm scans to
  the closing `]`, rejecting any byte that is neither `is_ascii_graphic()` (33-126) nor space
  (`ParseError::InvalidLabelChar`, catches control bytes and DEL/0x7F), an unterminated bracket
  (`ParseError::UnterminatedLabel`), or an all-whitespace/empty body after `.trim()`
  (`ParseError::EmptyLabel`); the trimmed, case-PRESERVING string becomes `Token::Label`. The
  parser's `factor` arm reads an optional trailing `Token::Label` onto the just-built `DiceGroup`
  (after its modifiers) — a per-group, not per-spec, field. Duplicate labels across different
  groups in the same notation string are NOT a parse error (they pool under `by_label`
  intentionally); only a duplicate
  `e<N>`/`t<N>`/`cs>N`/`cf<N` (shared roll-level state) errors.
  Label-consumption is a shared `take_label()` helper applied after EITHER atomic
  factor — a `DiceGroup` or a bare `Const` — not the `Dice` branch alone; a label immediately
  after a parenthesized/compound sub-expression is still correctly rejected as trailing input
  (the generalization is scoped to atomic factors only, not the whole grammar). This
  generalization is required: `@shadowcat/formula`'s `resolveNotationTemplate` substitutes a
  resolved identifier as a labeled constant (`value[name]`) even with no dice roll present, so
  the parser must accept such a label on a bare `Const`, not only immediately adjacent to a
  dice group.
  **A NEGATIVE substitution is labeled the same way a positive one is.** `substituteIdentifier`
  emits `-N[name]` (a unary minus directly before the labeled integer literal), which parses as
  `Expr::Neg` wrapping a labeled `Const` — `factor`'s `Token::Minus` arm applies wherever a factor
  is expected, including immediately after a binary operator, so this parses in every additive
  context a positive substitution reaches. `eval::sum`'s `fold` recurses through `Expr::Neg`
  with a sign flip and emits a `ConstTerm` for any `Const` carrying a label, so a negative
  substitution surfaces a correctly-signed chip in the breakdown, same as a positive one.
  `eval::sum`'s `additive_negative_labeled_constant_surfaces_a_correctly_signed_chip` test pins
  the parse and the signed chip together for this exact shape.
