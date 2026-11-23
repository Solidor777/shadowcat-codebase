Part of the shadowcat-codebase-combat skill; read it when editing or locating the combat types, snapshot, transitions, effects, history or movement budget. Part 01 of 02 of "Combat: key files and seams"; the index is key-files-and-seams.md.

## Key files & seams

- `data::engine::combat` — every combat-family type and the chain resolver, all `#[ts(export)]`
  and `#[serde(deny_unknown_fields)]` (except the two internally-tagged enums, see the gotcha
  in references/gotchas.md): `CombatEngine` (`scene_id`, `active`, `round`, `turn`, `turn_control`, `order`,
  `movement`, `effect_cleanup`, `effect_lifecycle`, `rewind_restore`, `forward_restore`),
  `CombatantEngine` (`kind`, `initiative`, `tiebreak`, `resources`), `CombatantKind`
  (`Actor { token_id, actor_id }` | `Event { lifespan, message }`), `ResourceRegistryEngine`
  (`resources: BTreeMap<String, Resource>`), `Resource`/`ResourceBinding` (`Mirror { value }` |
  `Tracked { max, recover }`), `Recovery` (per-clock-boundary `Formula` amounts), `EffectEngine`
  (`active`, `transfer`, `duration`, `lifecycle`), `Duration`/`DurationUnit`/
  `ExpiryPoint`, `Formula` (untagged `Number(f64) | Text(String)`),
  `MovementRules`/`Interpretation`/`Enforcement`/`TurnControl`, `TurnRecord`/`CapturedCombatant`/
  `EffectSnapshot`/`CombatHistoryEngine`/`MAX_TURN_HISTORY`, `CombatDefaults` (the override-chain
  shape, every field optional), and
  `resolve_combat_rules(system, world, scene) -> ResolvedCombatRules` — the SOLE server-side
  resolver of the engine-fallback → system-defaults → world → scene precedence; nothing else
  re-derives it. `data::engine::{SYSTEM_DEFAULTS_DOC_TYPE, SystemDefaultsEngine}` carry the
  `system-defaults` singleton `combat: Option<CombatDefaults>` slot this resolver's second
  argument reads.
- `combat::snapshot` (`load_snapshot`, `CombatSnapshot`, `Combatant`) — gathers everything a pure
  transition needs in one read: the combat document + engine, every combatant child, every named
  actor/token host, the `combat-history` child (if any), the world's resource-registry, sibling
  active combats on the same scene, and the resolved `(system, world, scene)` `CombatDefaults`
  chain. `NotFound` collapses "absent", "not a combat", and "wrong world" into one variant so a
  caller can never use the distinction to probe existence across worlds.
- `combat::transition` (`start`, `pause`, `end`, `advance`, `rewind`, `roll`, `resource`,
  `transition::sort`,
  `rebuild_order`, `is_hidden`, `ResourceOp`, `RollPost`) — one pure function per intent, each
  taking a `&CombatSnapshot` and returning the `Operation`s for ONE command; nothing here touches
  a `Repository` or chooses a `WriteOrigin`. `start`/`advance` share `settle_turn`: entering a
  combatant runs its `turn_start` boundary, and an `Event` combatant (removed when exhausted,
  granting one extra budget unit) or a hidden combatant under `TurnControl::OwnerMayEnd`
  auto-resolves and the walk continues — nothing this does for a
  hidden combatant is observable from outside its own (permission-gated) document. An `Event` that
  its `resolve_event` does NOT remove runs `run_turn_end` too, the same compressed
  `turn_start`+`turn_end` pair a hidden actor's auto-resolve runs; only a removed `Event` skips it,
  having no document left to write a boundary against. Entering a turn goes through
  `transition::enter_turn`, which runs the boundary, sets `turn`, AND captures the history record —
  so EVERY boundary the walk crosses is recorded, not only the one it finally settles on (see
  `combat::history` below). `settle_turn`
  bounds its auto-resolve walk with a LINEAR step budget: `settle_turn::budget` seeds at
  `w.engine.order.len()`, each step increments `settle_turn::steps`, and the walk stops (returning
  immediately — `turn` is already parked on the entry by that step's own `enter_turn` call) once
  `steps >= budget` rather than spinning forever on a
  pathological all-auto-resolving order — a removal grants exactly one extra unit of budget rather
  than resetting to a fresh full-length guard, closing the quadratic blowup a naive reset would
  reintroduce. Every
  `Operation::Update` a transition accumulates is coalesced by document id into one `Update` with
  a correct cumulative OCC pre-image before it reaches the caller — the `Working::coalesce_updates`
  pass, which folds same-document duplicate `Operation::Update`s into one via `merge_field_changes`
  (same-path duplicates further folded into a single `FieldChange`), called exactly once at the
  end of each transition function, never per-step.
- `combat::effects` (`collect_effects`, `collect_all_effects`, `tick`, `expire_by_policy`,
  `set_effect_field`, `EffectRef`) — walks the embedded effect collections reachable from a
  combatant's host(s) (actor and/or token-embedded actor, plus item-embedded effects with
  `transfer` set), anchored by `Duration.anchor`. **HOST and ANCHOR are two INDEPENDENT axes, and
  `collect_effects` walks both** — the host owns where an effect physically lives, `Duration.anchor`
  owns whose clock moves it, and `AnchorScope` is what keeps them independent: a first pass over the
  combatant's OWN hosts under `AnchorScope::OwnHost` (admitting an unanchored effect, which belongs
  to whoever hosts it, as well as one explicitly anchored to this combatant), then a second pass
  over every OTHER host in `CombatSnapshot.hosts` under `AnchorScope::AnchoredOnly` (admitting
  nothing but an explicit `anchor == Some(combatant.doc.id)`). So an effect living on A's actor but
  anchored to B ticks, expires and is captured on B's clock. Collapsing this to the own-host pass
  alone makes a cross-host anchor SILENTLY INERT — `anchor` is an unvalidated client-written
  `Option<Uuid>`, so such an effect would never tick, never expire and never reach history, with no
  error anywhere. The two passes are deduplicated by `(host, path)` and the cross pass walks hosts
  in sorted id order, because `CombatSnapshot.hosts` is a hash map whose iteration order varies run
  to run and the collection order decides which combatant's boundary sweep claims a shared key
  first. `tick` decrements `remaining` at a matching
  clock boundary and deactivates at zero — an untouched countdown (`Duration.remaining: None`)
  is materialized on its first matching boundary from the evaluated `Duration.amount`;
  `expire_by_policy` deactivates by evaluated lifecycle flag (`on_combat_end`/`on_turn_end`)
  independent of `Duration` entirely. Both evaluate per boundary through the chain and, on an
  evaluation failure, skip that ONE effect and report it — see the hard invariant in references/hard-invariants-detail.md.
- `combat::history` (`append_record`, `restore`, `fast_forward`, `live_equals`,
  `resulting_combatants`) — the turn-history record/restore seam `start`/`advance` call through,
  never re-implemented at a call site. `append_record` replays a transition's own accumulated ops
  onto its pre-transition snapshot (`post_transition_snapshot`) to capture the POST-transition
  state as a `TurnRecord`, then creates the `combat-history` document (first record) or replaces
  its whole `/engine` body (later records — see the `set_pointer` gotcha in references/gotchas.md), truncating any
  redo tail past the current cursor before the first push of a transition.
  `fast_forward` short-circuits `advance`'s ordinary transition walk only when `forward_restore`
  is set, the combat is active, a record exists at both the current cursor and the next, and
  `live_equals` proves nothing has diverged since the current record was captured.
  Three properties of this seam are load-bearing and each one prevents a distinct failure:
  - **A record captures a NARROWED `CapturedCombatant` per combatant, never a whole `Document`.**
    `history::capture_combatant` keeps `id`/`name`/`permissions`/`owner`/`engine`/`system` and
    nothing else; `scope`, `doc_type` and `parent_id` are DERIVED in `history::rebuild_document`
    from the combat the record hangs off (a combatant is always a `COMBATANT_DOC_TYPE` child of its
    own combat), because a second stored copy of a derivable value is a forked decision with
    nothing keeping the two in agreement — and it is paid for once per captured combatant per
    retained record, in the very band the byte bound below exists to keep small.
  - **Retention has TWO INDEPENDENT bounds, and only the byte bound is load-bearing for
    correctness.** `history::bounded_push` applies the `MAX_TURN_HISTORY` COUNT cap and then
    `history::evict_to_fit`'s SERIALIZED-BYTE cap (`HISTORY_BYTE_BUDGET`, 90% of
    `MAX_SYSTEM_BYTES`, plus `HISTORY_ENVELOPE_BYTES` for the surrounding object; sizes each record
    once and subtracts as it walks rather than re-serializing per eviction). Neither bound implies
    the other, and a count cap alone does NOT bound serialized size — which is the only thing
    `validate_system_size` refuses on. Without the byte bound, an ordinary-length combat's history
    breaches `MAX_SYSTEM_BYTES` well before the count cap, and because the refusal rolls the WHOLE
    transition back, the clock then rejects every `CombatStart`/`CombatAdvance`/`CombatRewind`
    PERMANENTLY behind the same generic "combat rejected" wording. Never describe retention as
    count-bounded. RESIDUAL, documented on `evict_to_fit`: one record larger than the budget on its
    own cannot be evicted away (it would take thousands of combatants at a single boundary).
  - **`append_record` runs once per turn BOUNDARY, and all of them fold into ONE write.**
    `transition::enter_turn` calls it for every boundary a `settle_turn` walk crosses, auto-resolved
    intermediate entries included, so a rewind can land on an `Event`'s or a hidden combatant's turn
    rather than only on the turn the walk finally stopped at — and capturing BEFORE the resolution
    that may follow is what keeps an exhausted `Event`'s record self-consistent. Every call after
    the first in the same transition folds into the op the first one staged
    (`history::staged_history`) instead of emitting a second write to the same document, which
    `SqliteRepository::apply_intent` would reject outright (at most one `Operation::Update` per
    document per batch, and a second `Create` of a document the batch already created has no valid
    pre-image at all). These records are also the client's turn-hook evidence:
    `deriveCombatHookEvents` (`combat-hooks.ts`, owned by `shadowcat-codebase-client-shell`) walks
    the records a command's history write placed after the pre-command current record
    (`crossedRecords`, located by `(round, turn)` identity so eviction and fast-forward both
    resolve) and emits `combat:turn-start`/`turn-end` per crossed boundary — a GM's hooks name
    every auto-resolved entry, a `lifespan: null` `Event` or a hidden combatant included, with no
    client-side re-derivation of this walk; a player, who never receives the GM-only history
    document, gets the combat document's own `turn`/`round` endpoints (`turnWalk`). Nothing infers
    a turn from a `lifespan` decrement or a combatant delete.
- `combat::budget` (`BudgetInputs`, `MovementBudget`, `resolve_movement_budget`,
  `resource_cells`) — the ONE resolution of "this combatant's movement budget, in cells": the
  `ResourceBinding::Tracked` gate (a `Mirror` binding is no budget), the
  `combat::eval::resolved_resource` evaluation over the formula host, and the `Interpretation`
  conversion (`per_cell` under `PerCell`, `1.0` under `Spaces`) live here and nowhere else.
  `ws::room::resolve_budget` (the movement-budget gate, and through it `handle_pathfind`'s
  route-preview clamp and `PathResult.budget_cells`) and `SceneEcs::resolved_combats` (the
  `"combat"` channel's `movement_cells`) both call it, so a `Mirror`-bound `movement.resource` is
  `movement_cells: None` on the channel exactly as the gate refuses it — pinned by
  `a_mirror_bound_movement_resource_yields_no_movement_cells_and_an_unresolvable_gate` beside
  the turn-owner parity test in `scene::tests::combat_index`.
