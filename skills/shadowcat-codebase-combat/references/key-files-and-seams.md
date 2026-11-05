# Combat: key files and seams

Part of the shadowcat-codebase-combat skill; read it before editing or locating combat code on the server, client core or the default tracker module.

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
- `data::validation::validate_containment` — the combat-family placement rule, covering
  `combat-history` alongside `COMBATANT_DOC_TYPE`: a `combat` document is never
  parented and never embedded; a `COMBATANT_DOC_TYPE` OR `combat-history` document is always
  parented (never embedded) and its parent must resolve to a `combat` document. The
  parent-is-a-combat check itself runs at the persistence chokepoint (`apply_intent`'s Create arm
  in `data::sqlite`), not inside `validate_containment` (which only checks parentedness/embedding,
  no DB access) — it checks `apply_intent::batch_combats` (the set of combat ids this SAME batch
  is Creating) OR a DB load, so a Create batch that creates a combat and its combatants together in
  one `Intent` is admitted without a spurious "parent must be a combat" rejection.
  `validate_containment` recurses into every embedded descendant, so it also catches a
  combatant/combat-history nested arbitrarily deep under an unrelated embedding structure.
- `combat::ops` (`set_engine`, `whole_engine_replace` — exactly two, no general-purpose `Update`
  builder) — shared `FieldChange`/`Operation` construction: every OCC pre-image is read from the
  target document's OWN current value at the pointer, never guessed or carried forward from an
  earlier belief. `whole_engine_replace`'s callers are `history::append_record`,
  `history::fast_forward` and `transition::rewind`; `history::restore` does NOT use it (it goes
  through `set_engine`).
- `combat::handle_combat_intent` — dispatches one of the eight `ClientMsg::Combat*` variants
  (`CombatStart`/`CombatPause`/`CombatEnd`/`CombatAdvance`/`CombatRewind`/`CombatSort`/
  `CombatRoll`/`CombatResource`): checks a per-user flood budget against BOTH the shared limiter
  INSTANCE and the single shared BUDGET `SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll`
  check — `WsState::message_rate` (one `Arc<PingRateLimiter>` cloned into every handler, not a
  per-handler copy) spent against `ws::MESSAGE_RATE_PER_MIN`, which is declared exactly ONCE, beside
  the limiter it governs. There is no combat-specific rate constant, and adding one would
  be a forked decision on a security control: all five call sites share one per-user hit list, so a
  second constant naming the same budget lets raising one copy silently change the other's
  effective behaviour against the very same counter. It then delegates to `combat::run_intent`,
  the load → authorize → resolve → commit pipeline for one combat intent: loads the snapshot, reads
  `Repository::world_cap_defaults` ONCE (after the snapshot, so an unknown or foreign `combat_id`
  still costs only the snapshot's own existence-hiding refusal; propagated with `?`, never
  defaulted, so an unresolvable authority input fails closed), authorizes via `combat::authorize`
  (see the sole-authorization invariant in SKILL.md), resolves the matching `transition` function's ops
  (or, for `CombatRoll`, executes the named rolls first via `chat::resolve_dice_context`/
  `chat::rolls::execute_roll` — after validating `channel` against the channel registry, and
  resolving EACH entry's notation as a raw template against that combatant's
  `combat::eval::formula_host`, so a `1d20 + init` reads the combatant's own actor), and commits them via `Room::commit_combat`. `CombatError`'s
  `Display` collapses every case that could disclose a hidden combatant
  (`NotFound`/`Forbidden`/`NotRunning`/`Data`) to one identical "combat rejected" wording. Every
  variant that DOES carry distinct wording states, on the variant itself, why that distinction
  discloses nothing — `RewindUnreachable` and `Unrewindable` because `CombatRewind` is GM-only per
  `combat::authorize`, `DuplicateRoll` because `authorize` already admitted every named id as the
  caller's own. A new variant needs the same justification or it must reuse the uniform wording.
- `combat::authorize` + `combat::combatant_access` + `combat::owns_combatant` + `CombatantAct` —
  the whole non-GM authorization surface, and the ONLY authorization combat-document writes get
  (see the sole-gate invariant in SKILL.md). `combatant_access(c, ctx, world_defaults)` resolves ONE
  `Access` per combatant through `effective_owner` + `resolve_access_world` — argument for
  argument the pair `filter_command` uses at egress and `SceneEcs::ctx_access` uses for the
  movement-budget gate — and returns the whole `Access` because `owns_combatant` asks THREE
  questions of it that must not be answered from different rules. The no-join `effective_owner(doc,
  None)` form is EXACT here, not an approximation: `token_actor_link` resolves only for
  `TOKEN_DOC_TYPE`, and `CombatSnapshot.combatants` only ever holds `COMBATANT_DOC_TYPE` documents.
  `owns_combatant(c, ctx, world_defaults, act)` then demands `Access::is_owner` AND whole-document
  `cap::READ` AND, under `CombatantAct::WritesEngine`, the capability `required_cap_for_path` maps
  `COMBATANT_WRITE_BAND` to — read FROM that function rather than restated as a literal, because it
  is the very check `WriteOrigin::CombatTransition` waives inside `apply_intent`, and an
  unmappable path refuses exactly as `apply_intent` refuses one. The two `CombatantAct` arms:
  - `WritesEngine` (`CombatRoll` via `transition::roll`, `CombatResource` via
    `transition::resource`) writes the NAMED combatant's own `engine` band, so it needs the write
    capability. Ownership is NOT a proxy for it: `effective_role`'s ownership floor is scoped to
    `TOKEN_DOC_TYPE`, so a combatant's owner is floored at nothing and can hold `DocRole::Observer`
    — `cap::READ` without `cap::WRITE_FIELDS`.
  - `EndsTurn` (`CombatAdvance` under `TurnControl::OwnerMayEnd`) demands ownership + `cap::READ`
    and NO write capability. The combatant writes `transition::advance` produces — `run_boundary`'s
    recovery amounts, effect ticks, an `Event`'s `lifespan` decrement — are server-COMPUTED
    consequences of the clock moving that land on whichever combatants the boundary sweep touches,
    including ones the caller has no relationship with at all, so no per-document write capability
    OF THE CALLER'S could gate them coherently. Turn ownership is the whole rule for this arm.
  Ownership stays a hard requirement alongside the capability, never an alternative: a non-owner
  holding `cap::WRITE_FIELDS` may write that document through an ordinary `Intent` but may not
  drive the clock with it. Every other intent
  (`CombatStart`/`CombatPause`/`CombatEnd`/`CombatRewind`/`CombatSort`) is GM-only and consults no
  combatant at all; an empty `CombatRoll.rolls` list is rejected outright rather than vacuously
  authorizing through an empty loop.
- `Room::commit_combat` — the ONE commit path for a combat intent: `commit_ops_locked(...,
  WriteOrigin::CombatTransition)`. `WriteOrigin::CombatTransition` has no wire representation a
  client can construct — see the hard invariant in SKILL.md.
- `SceneEcs::active_combat_for_scene(scene) -> Option<(Uuid, CombatEngine)>` /
  `SceneEcs::combatant_for_token(combat, token, ctx, world_defaults) -> Option<(Uuid,
  CombatantEngine, Access)>` — the ECS-cached lookups `Room::execute_move`'s movement-budget gate
  resolves under the same read guard as every other gate input (restriction/cell/visible_cells/
  start); a miss on either means no gate applies, never a refusal. `combatant_for_token` returns
  the resolved `Access`, NOT a bare hidden flag: it takes the caller's `PermissionContext` and the
  world's `WorldCapDefaults` and resolves them through `SceneEcs::ctx_access` — the same
  `effective_owner_via` + `resolve_access_world` pair document egress uses — so the gate's
  readability decision and what the caller actually receives on the wire are ONE decision, not two.
  `SceneEcs::system_defaults_doc() -> Option<&Document>`
  is the cached `system-defaults` singleton every `resolve_combat_rules` caller in `scene` reads
  its `system` argument from.
- Client (`@shadowcat/core`, `src/client/core/src/scene-docs.ts`): `buildCombatDoc`,
  `buildCombatantDoc` (stamps `owner` and, unless `hidden`, an `owner`-role `users` entry so the
  owner may write their own resources — hidden strips both), `buildResourceRegistryDoc`,
  `buildEffectDoc`. The `resource-registry` singleton itself is SERVER-seeded (empty) by the
  world-config seed path — no client seed helper exists; a client must fetch the existing
  singleton (via the world snapshot) and `Update` it, never `Create` a second one — the same
  singleton-uniqueness gate `data::world_seed::CONFIG_SINGLETON_DOC_TYPES` seeds for all ten
  config doc types rejects a duplicate `Create` as `RejectReason::Conflict`.
  `resolveSettingProvenance(store, scene, path)` (`SettingPath` includes `` `combat.${...}` ``
  keys) is the client-side mirror of `resolve_combat_rules`'s four-tier precedence, exposed
  per-field for a settings UI — see `shadowcat-codebase-client-shell` (shadowcat-codebase-client-shell's references/appcontext-i18n-and-session-seams.md) for `SYSTEM_CONTRACT` and
  the server-seeded `system-defaults` half of the same chain.
  `ENGINE_COMBAT_DEFAULTS`/`newCombatEngine` (also `scene-docs.ts`) are pinned against
  `src/client/core/src/__fixtures__/engine-combat-defaults.json`, the single fixture both this
  module's Rust tests and the TS test read — the cross-language promotion gap a private-scope
  default leaves open otherwise.
- `CombatController`/`CombatApi` (`src/client/core/src/combat.ts`) — the framework-neutral client
  dispatch layer (also `shadowcat.service:combat`, `COMBAT_SERVICE`), owned end-to-end by
  `shadowcat-codebase-client-shell` (`WorldSession` construction, `AppContext.combat`, the
  `combat:*` `CoreHooks` derivation and `CombatHookEmitter`) and `shadowcat-codebase-realtime-sync`
  (`WsClient.combat()`'s `combat_result`/`combat_error` correlation and the `"combat"` channel
  parsing). This skill owns only the resolved-resource SHAPE the channel carries
  (`ResourceRegistryEngine`/`Resource`/`ResourceBinding` above) and the intent semantics
  `CombatController`'s eight dispatch methods target — not the client wiring itself.
- `@shadowcat/module-combat-tracker` (`src/modules/combat-tracker`) — the default combat tracker
  panel (order 2, launcher-closed): `CombatTrackerPanel` composed from `CombatHeader` (clock
  controls gated by `ctx.combat.canAct`, the two-click End confirm, "Roll all" — `model.ts`'s
  `rollTargets` excludes `Event` combatants and, for a non-GM, everything but the caller's own
  rows), `CombatantRow` (name/conditions/initiative/per-resource cells, GM-only hide/remove/drag),
  and `AddCombatants` (adds the current token selection, authors one-off `Event` combatants;
  its "Add selected" button label is a `PluralEntry` (`combatTracker.addSelected`) rendered via
  `ctx.plural("combatTracker.addSelected", selectableTokenIds.length, { n: selectableTokenIds.length })`
  — see `shadowcat-codebase-client-shell`'s `I18n.plural` entry (shadowcat-codebase-client-shell's references/appcontext-i18n-and-session-seams.md) for the category-selection
  contract — never `ctx.t`).
  `TurnBadge` lights the launcher item on the viewer's own turn only. `@shadowcat/module-
  game-settings` gained three editors reading/writing the shapes this skill owns:
  `CombatSettings` (world-tier `CombatDefaults` chain editor, one control per leaf plus an
  effective-rules summary table over `EFFECTIVE_PATHS` — all ten `SettingPath` leaves including
  the three `effectLifecycle` ones), `CombatSceneOverrides` (the same controls scoped to the
  selected scene, Inherit falling through to world), and `ResourceRegistryEditor` (add/remove
  `Resource` entries, per-kind formula fields via `parseFormula`). Every combat-leaf write
  replaces the whole `/engine/combat` object (`set_pointer` cannot create a missing parent from a
  leaf sub-path). Pure UI over already-built seams — owned end-to-end by
  `shadowcat-codebase-client-shell` alongside `CombatController`/`CombatApi` above; this skill
  covers only the document/resolver shapes these components read and write.

