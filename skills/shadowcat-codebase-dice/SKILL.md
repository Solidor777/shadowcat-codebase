---
name: shadowcat-codebase-dice
description: "Use when touching Shadowcat's dice engine: RollSpec/Expr AST, the seeded-noise RNG, roll/evaluate/recalculate, the per-group reroll/explode/keep-drop pipeline, group_index-based Total folding, SuccessCount aggregation, group_spans-based recalculation, the shared classify/crit layers, the dice notation lexer/parser, or the chat wire boundary that executes untrusted notation (caps/entropy/validate in chat::rolls — co-owned with shadowcat-codebase-chat). Covers src/server/src/dice/. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Dice Engine

Orientation for the server-authoritative dice engine: a pure Rust library (still no ws/data/http
imports) whose ONLY untrusted entry is the notation parser, wired to chat. The core evaluator
(RNG, per-group pipeline, Sum/SuccessCount modes, notation, recalculate) is layered under the
`direction` global flip, a data-carrying `Mode`, the shared classification layer, crit events,
unified `t<N>` notation, the expertise-point DP allocator (differential-oracle-verified) with
`e<N>` notation, labeled dice, custom-face (symbolic) dice, the `is_ordered` pipeline gate,
`SuccessRule`/`CritTrigger` as enums, `symbol_counts`, and Numeric-only expertise. The transport
boundary — `chat::rolls` (OUTSIDE this crate — see `shadowcat-codebase-chat`) — executes
untrusted notation at chat ingest behind caps
(`MAX_ROLL_DICE=100`, `MAX_ROLL_RECORDS=1000`, `MAX_EXPERTISE=100` — true DP worst case is
records-bounded, ~1000·100² ≈ 1e7 ops — `MAX_DIE_SIDES=10_000`, `MAX_INLINE_ROLLS=8`),
per-roll OS-entropy seeds (`Uuid::new_v4` fold), and is the sole production `DieKind::validate()`
caller; this crate carries matching hardening — `#[serde(default)]` on every optional
`RollSpec`-reachable field, `RawRoll::push` `checked_add` id guard, saturating arithmetic in
`eval::sum::fold` (per-group sum AND every `Expr::Bin` Add/Sub/Mul arm — unbounded `Const`
terms/`*` chains are otherwise deterministically overflowable with zero dice),
and player-presentable `Display` for `ParseError`/`Token` (surfaced via chat System notices).
The recursive-descent parser has NO depth counter — callers rely on their input-length cap
(documented on `struct P`; chat's `MAX_MESSAGE_CHARS=4096` ≈ 2k nesting levels, safe on all
three target OSes' default stacks). Ambient `ParseContext` for chat rolls comes from the
world's `dice-settings` config doc (`chat::settings::resolve_dice_context`, channel-scoped: a
`DiceSettingsEngine.channel_overrides` entry for the sending channel wins over the doc's own
`mode`/`direction`; fail-closed to Total/HighWins on any query error, absent doc, or malformed
body, regardless of channel; GM-authored in `module-game-settings`'s Dice section). `ChannelDiceOverride`
(`data::engine::registries`) is a sibling type of `DiceSettingsEngine` in the world-settings-doc
family — identical `{mode, direction}` shape, so a channel's override and the document's own
world default share ONE resolution semantics, never a second merge rule. A table draw's
row-selecting roll uses a FIXED, channel-independent `ParseContext` instead —
`chat::rolls::TABLE_PARSE_CONTEXT` (`ModeKind::Total`, `Direction::HighWins`) — never the ambient
`dice-settings` resolution, since a table's outcome must not depend on which channel it happened
to be drawn into. `chat::rolls::validate_table_formula(notation) -> Result<(), RollError>`
ingress-validates a `DrawRule::Formula` row's notation at `TableEngine::validate` time: resolves
references through `NoHostResolver` (a table's row-range notation may carry no host-bound
reference), parses under `TABLE_PARSE_CONTEXT`, runs `validate_pre_roll`, and refuses a resolved
`Mode::SuccessCount` (`RollError::TableNeedsTotal` — a row's inclusive `lo..=hi` range only makes
sense against a single total, never a success count).

## Purpose

A roll is a canonical `RollSpec` (an `Expr` AST of dice groups + arithmetic, a `direction`, and a
`Mode` carrying its own config). `roll(spec, rng) -> RawRoll` is the **only** randomness step;
`evaluate(spec, raws) -> RollOutcome` is deterministic; `recalculate` applies targeted die ops then
re-derives. Randomness is a stateless noise function keyed by `(seed, index)`, so results are
reproducible by construction without persisting the seed — only the resulting `RawRoll` (natural
faces) needs to be stored. String notation (`4d6kh3+2`, `5d10cs>=7`, `1d20t15`) is one parser
front-end producing a `RollSpec`; the canonical struct form is what every other function operates
on.

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
  Call{name: FnName, args}) — `FnName` (Floor/Ceil/Round/Abs/Min/Max, `arity()` fixed per variant,
  checked at parse time only).
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
  faces.len()-1)` for `Faces`). Explode's `Compound`/`Penetrate` arms are guarded by `matches!
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
  the ONLY randomness entry point) and `evaluate(spec, raws) -> RollOutcome` (dispatches
  `Mode::Total(cfg)` → `sum::evaluate_total`, `Mode::SuccessCount(cfg)` →
  `success::evaluate_success`).
- `dice::eval::classify` — the shared classification layer used by BOTH modes.
  `oriented_margin(direction, scalar, reference) -> i64` flips a margin so "better" is always more
  positive (`HighWins: scalar - reference`; `LowWins: reference - scalar`) — used ONLY by Total
  mode. `classify(margin: i64, tiers: &[Tier]) -> Classification{pass, tier_label, tier_value}`:
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
  `DieScore{base_success: bool, crit: DieCrit}` + `.net() -> i32` (`eval::crit::
  score_die_net`) is the CENTRALIZED per-die net-success formula (`base + extra_successes −
  lost`): `score_die_net(direction, cfg, value, symbols) -> DieScore` computes both `cfg.success`'s
  base-success test AND `score_die`'s crit result together — shared by `eval::success`'s main pooling
  loop, `eval::expertise::allocate` (the `allocate::fixed` term, see below), and `eval::expertise`'s test-only
  `score_pool` helper. `eval::expertise`'s `die_values` deliberately still inlines its own narrower
  version (a different shape — scoring a synthetic single-step candidate mid-DP, symbols always
  empty since expertise only ever adjusts Numeric dice).
- `dice::eval::expertise` — the value-mutating pre-pass `allocate(direction,
  cfg: &SuccessConfig, raws: &RawRoll, records: &mut [DieRecord])`, called by
  `eval::success::evaluate_success` only when `cfg.expertise > 0`, BEFORE base-success counting
  (b-1's counting logic itself is unmodified/sealed). `adjust(direction, value, min, max, k)`
  moves a face up to `k` steps toward "better," stopping at the die's better-end bound
  (`max`/`min`) — provably preserves `adjust(_, v, _, _, 0) == v` for every `v`, INCLUDING values
  outside `[min,max]` (a Compound die's `value > max`, a Penetrate child's `value < min`), so an
  out-of-range face is never dragged back across a bound even at zero spend. `die_values(...) ->
  Vec<(i32,i32)>` builds the per-die `v_i(k)` table for `k in 0..=e`: each entry is
  `(net_i, counter_i)` from moving the face `k` steps then re-scoring via `crit::score_die` +
  `cfg.success`. `run_dp(dies, e, better) -> (Vec<u32>, (i32,i32))` is a bounded-knapsack DP,
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
  own (unchangeable) success/crit contribution is folded in as a constant `fixed: i32` term (via
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
  never folded into `successes`). The same per-die loop also tallies `symbol_counts`
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
  change was needed for the six function names themselves; `FnName::arity` is checked at parse
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

## Hard invariants

- **`roll` is the ONLY randomness step; `evaluate` is pure/deterministic.** Given the same
  `(spec, raws)`, `evaluate` MUST return an identical `RollOutcome`. This is what makes a stored
  `RawRoll` (natural faces only, no seed) fully reproducible.
- **`oriented_margin` applies to Total mode ONLY; SuccessCount's margin is a plain subtraction,
  NEVER direction-flipped.** SuccessCount's per-die direction sensitivity is already baked in by
  `crit::score_die`/the success-rule comparator resolved at parse time; flipping the pooled margin
  again would double-apply direction. Any future change touching `dice::eval::success`'s margin
  computation must preserve this asymmetry.
- **A `RollOutcome` reports EITHER `pass` (default 2-rung classification) OR a tier
  (`tier_label`/`tier_value`, custom ladder), never both** — `classify::classify` enforces this at
  the source; both modes rely on it unmodified.
- **`resolve_group`'s outer Explode loop must never re-scan a die it (or a sibling die's own
  chain) already pushed** — snapshot the pool length (`resolve_group::initial_len`) before the pass; the inner
  chain loop is the sole mechanism that extends any one die's own chain. Violating this grows the
  pool without bound (41GB observed) and silently falsifies `CHAIN_CAP`'s bound.
- **An Explode/Reroll retrigger check must test the RAW rolled face, never a post-modifier value**
  (Penetrate's `-1` must apply only to the stored `value`, not to what gates whether the chain
  continues) — checking the decremented value silently truncates Penetrate chains to length 1.
- **An Explode retrigger check on an ordered `Faces` die must test the die's DERIVED value
  (`face_value_and_symbols`), never the raw drawn face INDEX** — a face-list where index
  doesn't track value monotonically (e.g. index 0 -> value 6, index 1 -> value 1) would otherwise
  test the comparator against the wrong number and silently truncate the chain. For `Numeric` the
  distinction is a no-op, since `face_value_and_symbols` is a pure pass-through there.
- **Reroll and Explode must skip `!kept` dice.** Since modifiers apply in Vec order, a
  Drop-then-Reroll sequence is legal and must not mutate an already-dropped die.
- **`resolve_group`'s ENTIRE modifier loop must be gated by `DieKind::is_ordered()`** — an
  unordered `Faces` group (any face with `value: None`) has no rankable value, so every
  value-reading modifier (reroll/explode-by-comparator, keep/drop) must be a no-op for that group,
  not a ranking-by-`0`-default accident. `Numeric` is always ordered; a `Faces` group is ordered
  iff EVERY face has `value: Some`.
- **Expertise's `allocate` must restrict its contributing-dice set to `Numeric` dice only, folding
  any excluded kept `Faces` die's contribution in as a constant `allocate::fixed` term on the pass-choice
  threshold** — `adjust`'s face-move has no defined meaning over a `Faces` die's arbitrary
  face-list, but a kept-but-excluded `Faces` die's own (unchangeable) success/crit score still
  counts toward the TRUE pool-wide net that decides whether the two-pass clamp fork triggers.
  Checking only the DP's own Numeric-only partial `net` (omitting `allocate::fixed`) answers a different
  question than `evaluate_success` will actually score.
  `allocate::fixed` never needs to enter the DP's own per-allocation comparisons (a constant
  shift never changes an argmax), only the pass-choice threshold.
- **`resolve_group`/`push_extra` must stamp every produced `DieRecord` (including exploded/
  penetrated children) with the CALLER-SUPPLIED `group_index`** — `eval::sum::fold`'s per-group
  folding depends on every record in a group carrying that group's own index, never a stale/wrong
  one.
- **`compare_labels` must treat ANY unordered record under a label as making that label's sum
  undefined** (`DieRecord.ordered: bool`) — checking only `recs.is_empty()` (the absent
  case) is insufficient; an unordered symbolic label's records derive `value` via
  `face_value_and_symbols`'s `unwrap_or(0)`, so omitting the ordered check silently returns
  `Some(0)`/`Some(sum)` instead of `None` for the Daggerheart Hope/Fear headline case. A label
  spanning multiple `DiceGroup`s where even one group is unordered
  must also yield `None` for that label (a partial pool with any unordered member has no
  well-defined sum).
- **`recalculate` targets ONLY base naturals (via `group_spans`), never explosion/penetrate
  children** — a `RecalcOp` naming a non-base id silently no-ops (documented on `RecalcOp`, not an
  error). **`recalculate` is NOT a no-op-diff snapshot for a group with an Explode/Reroll
  modifier**: `rederive` re-triggers the full modifier pipeline fresh against (possibly-unchanged)
  base naturals, so an UNTARGETED sibling die in the same group can get a brand-new explosion/
  reroll tail across a recalc call even though its own `natural` never changed. This is
  intentional, not a bug — see `dice::recalc`'s doc comment and the pinning tests in
  `dice::recalc`'s test module (`explosion_tail_for_untouched_sibling_changes_across_recalc` et al.)
  for the exact proven behavior. Base-die `natural` values ARE stable across recalc; derived
  records for exploding/rerolling dice are NOT.
- **Every `DieKind::Numeric` construction from untrusted/parsed input must validate `sides >= 1`
  before construction** — `rng::roll_uniform` only `debug_assert!`s this (unsafe in release). The
  notation parser enforces it (`ParseError::InvalidDieSides`); any FUTURE wire-facing `RollSpec`
  construction path bypassing the parser needs the identical guard independently.
- **Pure library — `dice` must never depend on `ws`/`data`/`http`/`scene`.** Still NO wire
  frames and NO `#[derive(TS)]`/ts-rs bindings: roll outcomes ride the
  opaque chat `engine` body (`Segment::RollEmbed{formula, outcome, roll_id, spec, raw,
  recalc_history}`) and the client mirrors them by hand in the `chat-docs` module's Zod
  (`RollOutcomeSchema`/`DieRecordSchema`) — a shape change to `RollOutcome`/`DieRecord` MUST
  update that mirror, not regenerate a binding. `dice::recalc::RecalcOp` now derives
  `#[derive(Serialize, Deserialize)]` (so it can be stored inside `chat::RecalcEntry.ops`) but
  still carries no `#[derive(TS)]` — this crate's wire boundary stays serde-only by design; the
  wire-facing mirror (`chat::WireRecalcOp`, ts-rs exported) and its `into_recalc_op` conversion
  live in `chat`, not here, preserving the crate boundary the same way `RollOutcome`'s Zod
  mirror does. All transport policy (caps, entropy, settings, error surfacing) lives in
  `chat::rolls`, never here.
- **The notation-modifier vocabulary is ONE decision with THREE declarations, and the math-function
  vocabulary is another with three.** The keyword set
  `P::modifiers` matches is mirrored by `@shadowcat/formula`'s `NOTATION_KEYWORDS` AND by the
  server formula twin's own `NOTATION_KEYWORDS` (`formula::template`) — none of the three can
  read another's declaration. Adding, renaming or removing a modifier
  here therefore requires the matching edits IN THE SAME COMMIT: `modifierParityDifference`
  reads all three declarations and fails `pnpm test:scripts` on a difference in any direction. That
  gate is the only signal — without the edits, a template the client rewrites is notation
  this parser then rejects or reads differently, and the first report is a wrong roll seen by
  whoever authored the template. **The six math-function names
  (floor/ceil/round/abs/min/max) are not modifier vocabulary** — they
  never enter `P::modifiers`'s match at all (`fn_call` is a separate `factor`-level grammar
  production) — but they now have their OWN parity set of the same shape: the template grammar's
  `NOTATION_FUNCTIONS` (both template sides) against this parser's `fn_call` match arms, because the
  server resolves every roll's references through the template scan at the chat boundary
  (`chat::rolls`), so a function name the scan didn't reserve would read as a stat reference and
  break every function-calling roll. The scan reserves a name ONLY when immediately followed by `(`,
  mirroring `fn_call`'s own rule. `@shadowcat/formula`'s formula-grammar parser also reserves an
  OVERLAPPING but not identical function set independently (`FN_NAMES`/`FnName`:
  min/max/floor/ceil/round — five names, no abs) — the overlap is coincidental, not a
  parity-enforced one, and this crate's `FnName::Abs` has no `@shadowcat/formula` counterpart.
- **Expertise optimizes the CLAMPED (visible) net successes, with a counter-max fallback in the
  all-failed region.** `eval::expertise::allocate` maximizes raw lexicographic `(net, counter)`
  first; only when that raw net is `< 1` AND `allow_negative` is unset (every allocation clamps to
  net 0, so successes tie) does it re-run the DP with counters as the sole objective. A future
  change must preserve this two-pass fork, not just always maximize raw net.
- **`adjust` preserves `v_i(0) = value` for out-of-range (Compound/Penetrate) faces.** A naive
  `clamp(value ± k, min, max)` would drag an already-out-of-range die (a Compound's `value > max`,
  a Penetrate child's `value < min`) back across the bound even at `k = 0`; `adjust` instead moves
  by `k.min((bound - value).max(0))`, which is a no-op whenever the die is already past its
  better-end bound.
- **The expertise DP allocation is deterministic and oracle-verified.** `run_dp`'s tie-break
  (smallest `k` wins per die, backtrack from the last die) is pinned against a brute-force
  reference (`oracle` in `dice::eval::expertise`'s test module) over a 4000-case deterministic pseudo-random
  corpus varying direction/target/crit config/`allow_negative`/e/n — both the objective value AND
  the exact per-die allocation must match. Any future change to the tie-break or the DP recurrence
  must re-run this oracle test, not just check the objective value.

## Gotchas

- **Docs-ratchet is live on the whole `dice/` tree:** all 16 files carry
  `#![deny(missing_docs)]` + `#![deny(clippy::missing_docs_in_private_items)]` — a new
  undocumented item fails the 3-OS CI clippy step. Notation-token and grammar docs are quoted
  from the lexer/parser's enforcing lines — never document a marker or grammar rule from memory.
- **A written design snippet and the real code can drift** — this module's signatures carry more
  detail than any prose summary of them. Always read the actual current file before assuming a
  documented snippet's exact signature.
- **The crate's OWN types stay uncapped by design — the caps live at the transport boundary**:
  `DiceGroup.count` is still an unbounded `u32` inside the pure library; anything
  reaching `roll()`/`evaluate()` from untrusted input MUST come through
  `chat::rolls::execute_roll`/`validate_formula` (the cap walk + `DieKind::validate()`
  caller). A future second transport must reuse or replicate that boundary, never call
  `notation::parse` + `roll` bare. Overflow is defense-in-depth-guarded crate-side
  (`RawRoll::push` checked id increment; saturating folds in `dice::eval::sum` incl. every
  `Expr::Bin` arm).
- **`ParseError`/`Token` implement player-presentable `Display`** — chat System
  notices surface them directly; a new variant MUST get a clean `Display` arm (pinned by the
  no-debug-artifacts test iterating every variant), never a `{:?}` payload.
- **The notation-level `cs>N`/`cf<N` tokens and
  `SuccessConfig.crit_success`/`crit_fail` are two unrelated mechanisms that happen to share
  initials.** `cs>N`/`cf<N` in a dice-notation string set
  the ordinary per-die `SuccessRule` (or its inverted-comparator `cf<N`
  approximation); they do NOT construct a `CritSuccess`/`CritFail` struct. Those come from the
  SEPARATE `xs<N>[:<extra>[:<counter>]]`/`xf<N>[:<lost>[:<counter>]][!]` modifiers, which set
  `SuccessConfig.crit_success`/`crit_fail` directly — `CritTrigger::AtLeast` only (v1 notation has
  no syntax for `CritTrigger::HasSymbol`, a deliberate scope boundary: it names an opaque,
  system-defined `Symbol`, and this crate carries zero game-system vocabulary). `xs<N>`/`xf<N>`
  are roll-level parser scratch state (`P.crit_success`/`P.crit_fail`) consumed into
  `SuccessConfig` only when the resolved mode is `SuccessCount` — silently dropped under `Total`,
  mirroring `e<N>`'s existing mode-gating precedent (see the `e<N>`/`rs<N>` gotcha above) rather
  than FORCING `SuccessCount` the way `cs>N`/`cf<N` do.
- **Expertise DP is the highest-risk piece of the whole engine** — it is verified via
  differential-oracle testing against a brute-force reference (see the Hard invariants entry
  above). Treat any future change to `dice::eval::expertise` as needing independent two-reviewer
  review by default, same tier as `dice::eval::groups`/`dice::eval::sum`/`dice::eval::success`
  below.
- **`e<N>` is roll-level and silently discarded under Total mode.** Mirrors the existing `t<N>`-
  vs-mode gotcha: `e<N>` sets the parser's internal `struct P.expertise` scratch field, but that
  value is only ever read into `SuccessConfig.expertise` when the resolved `Mode` is
  `SuccessCount`. A notation string like
  `4d6t10e3` parses successfully under Total-ambient context: its target resolves to
  `TotalConfig.difficulty` rather than a success target, so the expertise value it carries is
  simply dropped — no `ParseError`, no warning.
- **This module's pipeline logic is dense and easy to get subtly wrong.** Treat any future
  change to `dice::eval::groups`, `dice::eval::sum`, `dice::eval::success`, `dice::eval::classify`,
  `dice::eval::crit`, `dice::eval::expertise`, or `dice::recalc` as needing independent
  two-reviewer review by default — each of these modules carries dense per-group state that a
  single reviewer can plausibly miss (see the `allocate::fixed`-term and derived-value-retrigger Hard
  invariants above for two such cases).
- **`DieKind::validate()` is enforced at the wire boundary, not inside `roll()`**:
  `chat::rolls::validate_pre_roll` calls it per parsed group before any rolling, so an
  empty-`faces` die cannot arrive via chat (notation cannot construct `Faces`
  anyway). The crate itself remains unvalidated by design — any future non-chat caller that
  hand-builds a `RollSpec` must run the same validation. `ReplaceDie`-onto-`Faces` is separately
  bounds-checked inside `dice::recalc` itself (see the `dice::spec` entry above), so it
  needed no wire-boundary gate.
- **`validate_tiers` (`chat::rolls`) guards `SuccessConfig`/`TotalConfig.tiers`
  uniqueness at the wire boundary** —
  `classify::classify`'s `max_by_key`/`min_by_key` tie on a duplicate `margin_offset` is
  caller-order-dependent (documented on `dice::eval::classify`), so a malformed ladder with a
  repeated offset would otherwise resolve nondeterministically. `validate_pre_roll` calls it on
  every parsed spec's tiers; `RollError::DuplicateTierOffset(i32)` is the player-presentable
  rejection. Reachable from untrusted notation via the repeatable `tr<offset>[:<value>][<label>]`
  modifier (`dice::notation::parser`'s `"tr"` arm appends one `Tier` rung per occurrence, with no
  parse-time duplicate check of its own — `validate_tiers` is the sole enforcement point, exactly
  the `DieKind::validate()` precedent above).
- **`compare_labels` returns `Some(0)`, not `None`, for an all-dropped-but-ordered label.** `None`
  means the label has ZERO matching records at all, OR at least one matching record is unordered
  (see the Hard invariants entry above); a label whose records all exist, are all ordered, but are
  all `kept: false` still sums to `0` over an empty kept-subset, which is `Some(0)` — distinct from
  "label doesn't exist" or "label is unordered."

## Pointers

- **Generated API** — `/api/rust/shadowcat/dice/` (rustdoc, private items included — the
  `eval`/`notation`/`outcome`/`recalc`/`rng`/`spec` submodule tree). The transport boundary
  (`chat::rolls`) is documented under `shadowcat-codebase-chat`'s generated-API pointer instead.
  Produce with `pnpm build:all`.
- Related work in the project's auto-memory: `m11-dice-chat-resume`.
