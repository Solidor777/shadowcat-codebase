# Dice engine: gotchas

Part of the shadowcat-codebase-dice skill; read it before changing docs-ratchet, notation tokens, expertise or wire-boundary validation.

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
  mirroring `e<N>`'s existing mode-gating precedent (see the `e<N>`/`rs<N>` gotcha in references/key-files-and-seams.md) rather
  than FORCING `SuccessCount` the way `cs>N`/`cf<N` do.
- **Expertise DP is the highest-risk piece of the whole engine** — it is verified via
  differential-oracle testing against a brute-force reference (see the Hard invariants entry
  in SKILL.md). Treat any future change to `dice::eval::expertise` as needing independent two-reviewer
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
  invariants in SKILL.md for two such cases).
- **`DieKind::validate()` is enforced at the wire boundary, not inside `roll()`**:
  `chat::rolls::validate_pre_roll` calls it per parsed group before any rolling, so an
  empty-`faces` die cannot arrive via chat (notation cannot construct `Faces`
  anyway). The crate itself remains unvalidated by design — any future non-chat caller that
  hand-builds a `RollSpec` must run the same validation. `ReplaceDie`-onto-`Faces` is separately
  bounds-checked inside `dice::recalc` itself (see the `dice::spec` entry in references/key-files-and-seams.md), so it
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
  (see the Hard invariants entry in SKILL.md); a label whose records all exist, are all ordered, but are
  all `kept: false` still sums to `0` over an empty kept-subset, which is `Some(0)` — distinct from
  "label doesn't exist" or "label is unordered."
