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
The recursive-descent parser counts `factor` recursion and refuses nesting past
`MAX_NESTING_DEPTH` (parentheses, unary `-`, function-call arguments) with
`ParseError::TooDeeplyNested`, so its stack use is bounded independently of the input length.
Ambient `ParseContext` for chat rolls comes from the
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
`Mode` carrying its own config). `roll(spec, rng) -> RawRoll` draws every die and every explode/reroll tail die; `evaluate(spec, raws) -> RollOutcome` draws
nothing and is deterministic; `recalculate` applies targeted die ops then re-derives, drawing
from its `rng` for `RecalcOp::RerollDice` and for any explode/reroll modifier tail. Randomness is a stateless noise function keyed by `(seed, index)`, so results are
reproducible by construction without persisting the seed — only the resulting `RawRoll` (natural
faces) needs to be stored. String notation (`4d6kh3+2`, `5d10cs>=7`, `1d20t15`) is one parser
front-end producing a `RollSpec`; the canonical struct form is what every other function operates
on.

## Key files & seams

Per-module entries for dice::rng, spec, outcome, eval (groups, classify, crit, expertise, sum, success), recalc and notation, with the seams between them. Read references/key-files-and-seams.md before editing any file under src/server/src/dice/.

## Hard invariants

- **`evaluate` draws nothing and is pure/deterministic; randomness enters only through an
  `RngSource` handed to `roll`, `recalculate` or the `resolve_group` they share.** Given the same `(spec, raws)`, `evaluate` MUST
  return an identical `RollOutcome`. This is what makes a stored `RawRoll` (natural faces only, no
  seed) reproducible by `evaluate`.
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
  update that mirror, not regenerate a binding. `dice::recalc::RecalcOp` derives
  serde's Serialize and Deserialize (so it can be stored inside `chat::RecalcEntry.ops`) but
  carries no `#[derive(TS)]` — this crate's wire boundary stays serde-only by design; the
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
  whoever authored the template. **The seven function names
  (floor/ceil/round/abs/min/max/best) are not modifier vocabulary** — they
  never enter `P::modifiers`'s match at all (`fn_call` is a separate `factor`-level grammar
  production) — but they have their OWN parity set of the same shape: the template grammar's
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

- **`GroupModifier::Clamp` is one per group** (a second min or max token is `ParseError::DuplicateClamp`; the clamp sits where its first token appeared), applies to kept dice only, and applies the ceiling after the floor so a hand-built floor above the ceiling cannot panic. `SuccessRule::Parity` tests with Euclidean remainder, so a negative odd value still counts. Every `SuccessRule` match (crit, expertise) must handle each variant.

- **`best(a, b, ...)` is `Expr::BestOf`, not an `Expr::Call`, and every branch is rolled.** `dice::eval::roll` rolls all branches unconditionally; the winner is chosen only at `evaluate_total`'s `fold`, so `evaluate` stays pure over the stored `RawRoll`. The winner is the branch whose total is best under `RollSpec::direction` (`HighWins` greater, `LowWins` lower), a tie going to the leftmost. Losing branches' dice are marked on a CLONE of the records as `kept: false` with `DieRecord::best_of_branch = Some(branch index)` (never on `raws`), and only the winning branch contributes `labeled_consts` chips. The parser needs at least two arguments (`ParseError::BestOfRequiresTwoArgs`), and `best` is Total-mode only: `chat::rolls`' `walk_groups` flags a best-of node over every branch and `RollError::BestOfRequiresTotal` refuses it in any other mode. `best` is in `NOTATION_FUNCTIONS` on both template sides, so the parity gate reads it like the math functions. The client mirrors `best_of_branch` in the `chat-docs` die schema and `RollTooltip` shows a distinct reason for a die dropped by `best` versus one dropped by keep/drop.

Docs-ratchet, the notation-level token precedents, the expertise and e<N> mode gotchas, the wire-boundary validation split, and the compare_labels edge cases. Read references/gotchas.md before changing any of those areas or when a dice change behaves unexpectedly.

## Pointers

- **Generated API** — `/api/rust/shadowcat/dice/` (rustdoc, private items included — the
  `eval`/`notation`/`outcome`/`recalc`/`rng`/`spec` submodule tree). The transport boundary
  (`chat::rolls`) is documented under `shadowcat-codebase-chat`'s generated-API pointer instead.
  Produce with `pnpm build:all`.
- Related work in the project's auto-memory: `m11-dice-chat-resume`.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | Per-module Key files & seams entries for src/server/src/dice/ | Editing any dice module |
| references/gotchas.md | The Gotchas section | Changing docs-ratchet, notation tokens, expertise or validation, or debugging odd dice behavior |
