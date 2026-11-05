# Dice engine: key files and seams

Part of the shadowcat-codebase-dice skill; read it before editing any file under src/server/src/dice/.

## Key files & seams

- `dice::rng` — `noise(seed, n) -> u64` (hand-rolled SplitMix64 finalizer, **no
  `rand` dependency** — a deliberate user preference for determinism-by-construction).
  `RngSource` trait (`next_u32`) + `NoiseRng` (stateful sequential generator). `roll_uniform`
  (unbiased inclusive-range draw via rejection sampling) is the **only** place raw entropy becomes
  a die face — has a hard guard against the exact-2^32-span panic and a documented-conservative
  (not maximally tight) rejection threshold. `NoiseRng::at(seed, index)` is a pure `(seed,index)`
  function with **no correspondence to a sequential `next_u32()` walk once any rejection has
  occurred** — do not use it to "replay the k-th die" of a real roll; currently unused by any
  consumer.
- `dice::spec` — the canonical AST: `DieKind::Numeric{min,max}` |
  `Faces{faces: Vec<Face>}` (custom/symbolic dice). `Face{value: Option<i32>, symbols:
  Vec<Symbol>}` (`Symbol = String`, an opaque system-assigned tag, e.g. Genesys "triumph");
  `value: None` means the face has no numeric meaning, only symbols. `DieKind::validate() ->
  Result<(), DieKindError>` rejects `Faces{faces: []}` (`DieKindError::EmptyFaces`) — called in
  production by `chat::rolls::validate_pre_roll` on every parsed group.
  `recalc::RecalcOp::ReplaceDie` onto a `Faces` die is bounds-checked in `dice::recalc`: an
  out-of-range `natural` (negative or `>= faces.len()`) is silently ignored rather than written,
  matching an unknown `id`'s existing no-op semantics — closes the index-out-of-bounds panic
  surface `face_value_and_symbols` would otherwise hit. `DieKind::is_ordered()`: `Numeric` always
  `true`; `Faces` is
  `true` iff EVERY face has `value: Some` — a single unordered face makes the whole die unrankable
  against a valued sibling. `Comparator`+`test` (`#[derive(Default)] #[default] Gte`), `ExplodeKind`
  (Standard/Compound/Penetrate), `GroupModifier`, `DiceGroup{count, kind, modifiers, label:
  Option<String>}` (**modifiers apply in Vec order — caller-controlled**, e.g. reroll-then-keep vs
  keep-then-reroll are different specs; `label` is a tag propagated onto every `DieRecord`
  this group produces, including exploded/penetrated children — read by
  `RollOutcome::by_label`/`compare_labels`, orthogonal to mode; duplicate labels across groups are
  NOT an error, they pool under `by_label`), `Expr` (Dice(DiceGroup)/Const(ConstTerm)/Bin/Neg/
  Call{name: FnName, args}) — `FnName` (Floor/Ceil/Round/Abs/Min/Max). `FnName::arity()` returns a
  MINIMUM, not always an exact count: `Floor`/`Ceil`/`Round`/`Abs` require exactly `arity()`, but
  `Min`/`Max` are variadic and admit any count `>= arity()` (2) — `FnName::accepts_arg_count(count)`
  is the ONE admissibility check `dice::notation::parser::P::fn_call` applies at parse time
  (`Expr::Call` itself carries no arity guarantee once constructed), so a fixed-arity/variadic
  decision made on `FnName` is never re-decided at the call site.
  `ConstTerm{value: i32, label: Option<String>}` mirrors `DiceGroup`'s label field onto a bare
  constant — the parser's label-consumption (`take_label()`) applies to EITHER atomic factor
  (a `DiceGroup` or a `Const`), not only dice groups; a labeled constant is Total/Sum-mode
  display-only provenance (surfaced via `RollOutcome.labeled_consts`, see below) and never feeds
  `by_label`/`compare_labels` (SuccessCount dice-pool comparison has no pool for a bare constant
  to join). `Direction`
  (`HighWins`/`LowWins`, `#[default] HighWins`) is a global flip on `RollSpec::direction` orienting
  every margin/tier/crit computation. `Tier{margin_offset, label, tier_value}` is one rung of a
  classification ladder, shared by both modes. `CritTrigger`: `AtLeast(i32)` (direction-aware — a
  bare numeric threshold, flipped under `LowWins`)
  | `HasSymbol(Symbol)` (direction-**insensitive** — presence/absence has no "better end" to flip).
  `CritSuccess{trigger: CritTrigger, extra_successes, positive_counter}` /
  `CritFail{trigger: CritTrigger, lost, negative_counter, allow_negative}` are SuccessCount-only
  crit-event configs. `TotalConfig{difficulty: Option<i32>, tiers: Vec<Tier>}` — Sum and Tiered are
  now ONE mode: empty `tiers` = default pass/fail at `margin >= 0`; non-empty = a custom ladder.
  `SuccessRule` (was a struct, now an enum): `Numeric{comp: Comparator, target: i32}`
  (`#[default]` via a HAND-WRITTEN `impl Default` — `derive(Default)`'s `#[default]` attribute only
  targets a fieldless variant, `Numeric` carries fields) | `HasSymbol(Symbol)`.
  `SuccessConfig{success: SuccessRule, required_successes: Option<i32>, tiers: Vec<Tier>,
  crit_success: Option<CritSuccess>, crit_fail: Option<CritFail>, expertise: u32}` — the
  per-roll expertise-point budget (0 = disabled). `Mode` is **data-carrying**:
  `Total(TotalConfig) | SuccessCount(SuccessConfig)` (replaces a unit `Mode::Sum |
  Mode::SuccessCount`). `RollSpec{expr, direction: Direction, mode: Mode}`.
- `dice::outcome` — `RawDie`, `RawRoll` (`dice`, `records`, `next_id`,
  `group_spans`), `DieRecord` (`id`, `group_index`, `natural`, `value`, `kept`, `exploded`,
  `rerolled_from`, `crit_success: bool`, `crit_fail: bool`, `expertise: i32`, `label:
  Option<String>`, `symbols: Vec<Symbol>`, `ordered: bool`). `expertise` is the audit trail of
  points spent adjusting this die's `value` (0 if none/not applicable). `label` is copied
  from the producing `DiceGroup.label`, `None` if unlabeled. `symbols` is the resolved
  symbols for a `Faces` die's drawn face; always empty for `Numeric`. `ordered` is a per-record
  snapshot of the producing group's
  `DieKind::is_ordered()` at construction time, stamped at every `DieRecord` construction site
  (mirrors `label`/`symbols` propagation exactly, including exploded/penetrated children); `#[serde
  (default = "default_ordered")]` defaults deserialized/legacy records to `true`. It exists solely
  so `compare_labels` can detect an unordered (symbolic) label — this can NOT be inferred from
  `value` alone, since a genuine ordered value of `0` is indistinguishable from an unordered die's
  derived-`0` fallback. `RollOutcome`'s final shape: `total: i64`, `records`, `successes:
  Option<i32>`, `pass: Option<bool>`, `margin: Option<i64>`, `tier_label: Option<String>`, `tier_value: Option<i32>`, `crit_successes: i32`,
  `crit_fails: i32`, `positive_counter: i32`, `negative_counter: i32`, `symbol_counts:
  BTreeMap<Symbol, i32>` (per-symbol tallies over KEPT dice, computed UNCONDITIONALLY
  inside `evaluate_success`'s per-die loop regardless of which `SuccessRule` variant is active;
  empty in Total mode), `labeled_consts: Vec<ConstTerm>` (every labeled bare `Const`
  reachable in the expression, Total-mode only; `#[serde(default)]` so messages persisted before
  this field existed still deserialize; `evaluate_success` always sets this to `Vec::new()` since SuccessCount
  ignores all AST arithmetic; display-only — NOT read by `by_label`/`compare_labels`; the
  chat wire mirror (the `chat-docs` module's Zod schema) and `MessageCard` render a labeled const's
  displayed `value` as collected by `eval::sum::collect_labeled_consts`, which threads
  an effective additive sign through the AST: `Neg` flips it, and `Sub`'s RHS flips it (so
  `-3[dex]` and `1d20 - 3[dex]` both display `-3`); `Mul`/`Div` do NOT scale or flip it — a
  labeled const under multiplication/division still displays its literal value, since the sign
  thread is additive-only, not a full evaluator) (all 0/None/empty in Total mode with no
  `difficulty`, or in SuccessCount with no crit config).
  `RollOutcome::by_label(&self, label: &str) -> Vec<&DieRecord>`
  returns all records — kept AND dropped — carrying that label, in roll order.
  `RollOutcome::compare_labels(&self, a, b) -> Option<Ordering>` compares two labels by
  the sum of their KEPT records' `value`s; `None` iff either label has zero matching records at
  all, OR either label's matching records include ANY with `ordered: false` (a mixed
  ordered+unordered pool under one label also has no well-defined sum) — an all-dropped-but-
  ordered label still yields `Some(0)`, since the sum-of-kept is simply empty, not missing.
  `DieRecord.kind: Option<DieKind>` (`#[serde(default)]`, fail-closed `None` for a roll stored
  before the field existed) mirrors the originating `RawDie.kind` — an every-recipient
  face-space fact like `natural`, filled at all three `dice::eval::groups` construction sites
  (`resolve_group`'s main per-die map, the Standard-explode push, `push_extra`), so a roll and
  its `dice::recalc::rederive` re-roll are covered by the same sites. Its client consumer is
  the 3D dice overlay's physical-shape mapping — see `shadowcat-codebase-dice-3d`.
  `RollResult`.
- `dice::eval::groups` — `resolve_group(group, group_index, naturals, rng, raws)
  -> Vec<DieRecord>`: the per-group pipeline (reroll → explode → keep/drop, in modifier-Vec
  order). `face_value_and_symbols(kind, natural) -> (i32, Vec<Symbol>)` derives a die's
  `(value, symbols)`: `Numeric` passes `natural` straight through; `Faces` treats `natural` as a
  face INDEX and looks up `faces[natural]` (`None`-value face contributes `0` numerically). The
  ENTIRE modifier loop is gated by `let ordered = group.kind.is_ordered(); if !ordered { continue;
  }` — an unordered `Faces` group (any face with `value: None`) skips reroll/explode/
  keep/drop entirely for every modifier, fail-closed. A shared `resolve_group::redraw` closure dispatches the RNG
  draw per `DieKind` (a numeric face for `Numeric`, a face INDEX via `roll_uniform(rng, 0,
  faces.len()-1)` for `Faces`). A Compound explosion adds the extra draw by saturating addition. Explode's `Compound`/`Penetrate` arms are guarded by `matches!
  (group.kind, DieKind::Numeric { .. })` — restricted to `Numeric` only; an ordered `Faces` die
  falls through to the shared push-new-die path (Standard-style) instead, since "add"/"−1" have no
  defined meaning over an arbitrary face-list. The Explode chain's retrigger check tests the
  die's DERIVED value (via `face_value_and_symbols`), never the raw redrawn index/face — for
  `Numeric` this is identical to the raw face (a pure pass-through), but for an ordered `Faces` die
  whose index doesn't track value monotonically, checking the raw index would misfire.
  `push_extra` is the single construction site for a Penetrate child
  `DieRecord` (takes an `ordered: bool` param — reached only from the Numeric-guarded Penetrate
  arm, always `true`); the inlined Standard-explode/Faces-fallback arm (reached only inside the
  `!ordered { continue }`-gated modifier loop, so always `true` too) constructs its own `DieRecord`
  directly. `CHAIN_CAP = 100` bounds chained explosions/rerolls per die.
- `dice::eval` — `roll(spec, rng) -> RawRoll` (walks `Expr` left-to-right,
  drawing every die and every explode/reroll tail die from `rng`) and `evaluate(spec, raws) -> RollOutcome` (dispatches
  `Mode::Total(cfg)` → `sum::evaluate_total`, `Mode::SuccessCount(cfg)` →
  `success::evaluate_success`).
- `dice::eval::classify` — the shared classification layer used by BOTH modes.
  `oriented_margin(direction, scalar, reference) -> i64` flips a margin so "better" is always more
  positive (`HighWins: scalar - reference`; `LowWins: reference - scalar`) — used ONLY by Total
  mode; the subtraction saturates at the i64 bounds. `classify(margin: i64, tiers: &[Tier]) -> Classification{pass, tier_label, tier_value}`:
  empty `tiers` => default 2-rung pass/fail at `margin >= 0`; non-empty => the highest rung with
  `margin_offset <= margin`, fail-closed to the lowest rung if below every offset (order-
  independent, no sorted precondition).
- `dice::eval::crit` — `DieCrit{is_success, is_fail, extra_successes, lost,
  positive_counter, negative_counter}` + `score_die(direction, value, symbols: &[Symbol], cfg:
  &SuccessConfig) -> DieCrit`: scores one kept die against `cfg.crit_success`/`cfg.crit_fail`
  independently via the shared `reaches(direction, value, symbols, trigger, is_success_event)`
  helper — one comparator for both crit events, so success and failure cannot drift apart.
  `CritTrigger::AtLeast` is direction-SENSITIVE: it flips its comparison under
  `LowWins`. `CritTrigger::HasSymbol` is direction-
  INSENSITIVE (`reaches`'s `HasSymbol` arm never reads `direction`). Both `is_success` and
  `is_fail` CAN be `true` on the same die under an overlapping-threshold OR overlapping-symbol
  config — intentional, tested (`overlapping_thresholds_fire_both_crit_success_and_crit_fail`,
  `overlapping_symbol_triggers_on_same_symbol_fire_both_crit_success_and_crit_fail`), not a bug.
  `DieScore{base_success: bool, crit: DieCrit}` + `.net() -> i64` (`eval::crit::
  score_die_net`) is the CENTRALIZED per-die net-success formula (`base + extra_successes −
  lost`, summed in i64): `score_die_net(direction, cfg, value, symbols) -> DieScore` computes both `cfg.success`'s
  base-success test AND `score_die`'s crit result together — shared by `eval::success`'s main pooling
  loop, `eval::expertise::allocate` (the `allocate::fixed` term, see below), and `eval::expertise`'s test-only
  `score_pool` helper. `eval::expertise`'s `die_values` deliberately still inlines its own narrower
  version (a different shape — scoring a synthetic single-step candidate mid-DP, symbols always
  empty since expertise only ever adjusts Numeric dice).
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
  `chat::rolls::execute_roll`/`execute_roll_with_seed` (in `chat`, not here) now return the
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
  context a positive substitution reaches. `collect_labeled_consts` recurses through `Expr::Neg`
  with a sign flip and emits a `ConstTerm` for any `Const` carrying a label, so a negative
  substitution surfaces a correctly-signed chip in the breakdown, same as a positive one.
  `eval::sum`'s `additive_negative_labeled_constant_surfaces_a_correctly_signed_chip` test pins
  the parse and the signed chip together for this exact shape.
