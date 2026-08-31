---
name: shadowcat-codebase-combat
description: "Use when touching Shadowcat's combat clock: the combat/combatant/resource-registry/effect/combat-history engine doc types, the `CombatDefaults` engine→system-defaults→world→scene override chain and its resolver, combat containment/singleton-active enforcement, the server-owned transition layer (`combat::{snapshot,transition,effects,history}`, `handle_combat_intent`, `Room::commit_combat`), the per-turn movement-budget gate inside `Room::execute_move`, or the client combat document builders/provenance resolver. Covers src/server/src/data/engine/combat, src/server/src/combat, and the combat-doc portion of src/client/core/src/scene-docs.ts. Invoke shadowcat-codebase-core first; for the READ-transition/redaction machinery combatant hiding relies on, invoke shadowcat-codebase-documents-permissions; for the movement-budget gate's placement inside the move executor and the unified diagonal-cost function it shares with the router, invoke shadowcat-codebase-scene-rendering."
---

# Shadowcat — Combat

Orientation for the combat clock: the document layer, the server-owned transition/intent
pipeline that mutates it, turn history, effect-lifecycle expiry, and the per-turn movement-budget
gate the move executor enforces against it. The document builders and the settings-chain
provenance resolver (`resolveSettingProvenance`) already exist
client-side; what does NOT exist yet is anything that DISPATCHES a combat intent from the UI, or a
tracker/settings-editor UI to host any of it — those are later sub-projects. Everything
server-side about the clock itself (transitions, gates, history, and formula evaluation through
`combat::eval`) is built.

## Purpose

Delivers the five engine doc types the combat clock needs (combat, combatant, resource-registry,
effect, combat-history) and the four-tier `CombatDefaults` override chain (engine fallback →
`system-defaults` → `world-settings` → scene) a running combat snapshots at start. A combat is a
world document bound to one scene; a combatant is a child document of a combat (`parent_id`,
never `embedded`); resource-registry is a singleton config doc the engine ships empty (named
resources like movement are data, not built in); effect carries a typed `engine` band (activation,
transfer, clock-bound duration/lifecycle) so expiry is server-driven rather than system-only;
combat-history is a GM-only child document recording turn-boundary snapshots for rewind/
fast-forward. On top of the document layer, a fixed set of eight combat intents dispatch through
one server-owned pipeline (`combat::handle_combat_intent`) that loads a snapshot, authorizes,
resolves a pure transition into one command's ops, and commits it under a wire-unconstructible
`WriteOrigin`. The move executor (`Room::execute_move`, owned by `shadowcat-codebase-scene-rendering`)
separately enforces a per-turn movement budget against the same documents this skill owns.

## Key files & seams

- `data::engine::combat` — every combat-family type and the chain resolver, all `#[ts(export)]`
  and `#[serde(deny_unknown_fields)]` (except the two internally-tagged enums, see the gotcha
  below): `CombatEngine` (`scene_id`, `active`, `round`, `turn`, `turn_control`, `order`,
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
  evaluation failure, skip that ONE effect and report it — see the hard invariant below.
- `combat::history` (`append_record`, `restore`, `fast_forward`, `live_equals`,
  `resulting_combatants`) — the turn-history record/restore seam `start`/`advance` call through,
  never re-implemented at a call site. `append_record` replays a transition's own accumulated ops
  onto its pre-transition snapshot (`post_transition_snapshot`) to capture the POST-transition
  state as a `TurnRecord`, then creates the `combat-history` document (first record) or replaces
  its whole `/engine` body (later records — see the `set_pointer` gotcha below), truncating any
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
    pre-image at all).
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
  (see the sole-authorization invariant below), resolves the matching `transition` function's ops
  (or, for `CombatRoll`, executes the named rolls first via `chat::resolve_dice_context`/
  `chat::rolls::execute_roll`), and commits them via `Room::commit_combat`. `CombatError`'s
  `Display` collapses every case that could disclose a hidden combatant
  (`NotFound`/`Forbidden`/`NotRunning`/`Data`) to one identical "combat rejected" wording. Every
  variant that DOES carry distinct wording states, on the variant itself, why that distinction
  discloses nothing — `RewindUnreachable` and `Unrewindable` because `CombatRewind` is GM-only per
  `combat::authorize`, `DuplicateRoll` because `authorize` already admitted every named id as the
  caller's own. A new variant needs the same justification or it must reuse the uniform wording.
- `combat::authorize` + `combat::combatant_access` + `combat::owns_combatant` + `CombatantAct` —
  the whole non-GM authorization surface, and the ONLY authorization combat-document writes get
  (see the sole-gate invariant below). `combatant_access(c, ctx, world_defaults)` resolves ONE
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
  client can construct — see the hard invariant below.
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
  world-config seed path — no client seed helper exists.
  `resolveSettingProvenance(store, scene, path)` (`SettingPath` includes `` `combat.${...}` ``
  keys) is the client-side mirror of `resolve_combat_rules`'s four-tier precedence, exposed
  per-field for a settings UI — see `shadowcat-codebase-client-shell` for `SYSTEM_CONTRACT` and
  the server-seeded `system-defaults` half of the same chain.
  None of these client seams wire to a tracker UI yet.

## Hard invariants

- **`Formula::Text` is engine-grammar source the server parses at ingress (`Formula::validate` →
  `crate::formula::parse`) and evaluates through `crate::formula`.** `Formula` is untagged (`30`
  or `"speed"` on the wire). EVERY container that holds one validates it — `Recovery`,
  `ResourceBinding`, `Duration.amount`, `EffectLifecycle`, `EffectLifecycleDefaults` (directly, as
  `CombatEngine`'s own resolved-chain field from `CombatEngine::validate`; and through
  `CombatDefaults::validate`, reached from `SystemDefaultsEngine::validate`,
  `WorldSettingsEngine::validate` and `SceneEngine::validate`), and `CombatHistoryEngine::validate`
  recurses into every captured combatant and effect band so a direct GM `Update` on a
  `combat-history` record cannot store a formula `combat::history::restore` would later fail to
  write back. The transitions EVALUATE through `combat::eval` (`formula_host` — the
  token-embedded actor copy, else the linked actor — plus `eval_formula`, `resolved_resource`,
  `lifecycle_flags`, `duration_amount`): `transition::recover` applies text recoveries clamped
  to the evaluated `max`, `combat::effects::tick`/`expire_by_policy` evaluate the lifecycle
  chain (authored formula → `CombatEngine.effect_lifecycle` → engine fallbacks) per boundary,
  and an untouched countdown (`Duration.remaining: None`) or an ABSENT `Tracked` entry reads as
  FULL and materializes on first change — lazy-full, uniformly for every combatant kind; there
  is no join-time seeding. An evaluation failure skips its ONE write and surfaces as a GM-only
  `MessageKind::System` chat notice (`transition::eval_notice`, deduped per transition, each
  detail prefixed with the combatant's name or id) — the clock never stops on a bad formula.
  Stored resource scalars default to owner-or-GM egress: a combatant `Create` carrying no
  explicit `/engine/resources` property override is stamped `Visibility::OwnerOrGm` at
  `apply_intent` ingress (an explicit entry, `all` included, is respected untouched;
  `buildCombatantDoc` mirrors the stamp for the optimistic view). See
  `shadowcat-codebase-formula` for the evaluator and `SystemLeafResolver`.
- **One combat intent commits as ONE command, under `Room::commit_combat`.** This invariant scopes
  to `combat::handle_combat_intent`'s own pipeline — it does NOT extend to the movement-budget
  gate inside `Room::execute_move` (`shadowcat-codebase-scene-rendering`), which deliberately
  commits the token's position write and the combatant's resource decrement as TWO SEPARATE
  commands under two DIFFERENT `WriteOrigin`s (`Client` for the position, `CombatTransition` for
  the decrement) — bundling them under one origin is a real authz bypass: a
  `CombatTransition`-tagged decrement waives `apply_intent`'s ownership check for every op sharing
  its batch, including the position write, which the split closes. Do not describe the movement-budget gate as
  one-command-per-intent; only `combat::handle_combat_intent`'s own commits carry that property.
- **`combat-history` is GM-only egress.** Its `permissions.default` is `DocRole::None` at
  creation (`combat::history::append_record`) — a turn-boundary log discloses effect/combatant
  state a hidden combatant would otherwise never leak, so it is never readable by anyone but a GM.
- **`WriteOrigin::CombatTransition` is never constructible from the wire, and its effect is the
  OPPOSITE of a requirement — it is an EXEMPTION.** A batch carrying it SKIPS the ordinary per-op
  capability floor (Create/Delete/Update, and descendant re-authorization) that `apply_intent`
  would otherwise enforce against the actor's own access; every other check (scope, size, engine,
  containment, singleton, one-active-per-scene, immutable-envelope-path mapping, OCC) still runs
  regardless of origin. A GM's own ordinary `WriteOrigin::Client` writes to combat documents are
  NOT gated by this origin at all — a GM can already write combat docs freely under `Client`
  because `resolve_access_world`/`access.has` grant it, the same batch shape a non-GM must never be
  able to reach against a token they don't own; `CombatTransition` is not what makes a GM's writes
  work, and no combat-document write is refused merely for lacking it. The only two call sites that
  ever construct it are
  `Room::commit_combat` and the movement-budget gate's decrement commit inside
  `Room::execute_move` — both server-internal, neither reachable from a `ClientMsg` variant.
  `CombatTransition` may `Create` a `message` doc (roll results, event messages) but is still
  blanket-rejected from `Update`-ing one — the same restriction `Client` gets (`apply_intent`'s
  message-doc `Update` arm only re-opens for `WriteOrigin::ServerMessageRevision`).
- **BECAUSE that exemption exists, `combat::authorize` is the SOLE authorization for every write a
  combat intent makes.** Nothing downstream re-checks the caller: `apply_intent`'s per-op ownership
  and capability tests are exactly what the origin waives. So a predicate in `authorize` that
  diverges from the shared `resolve_access_world` authority is not a cosmetic inconsistency — it is
  an authorization HOLE in one direction and a refusal of a legitimate owner in the other, and both
  directions are reachable. Concretely, with `default: none` + `permissions.users[player] = Owner`
  a player genuinely reads and owns the combatant, and with `default: observer` +
  `permissions.users[player] = None` they genuinely do NOT — a `permissions.default` test answers
  both backwards. This is why `owns_combatant` reads `cap::READ` off the shared authority and
  `required_cap_for_path` off the shared path→capability mapping instead of restating either.
  A hand-rolled readability, ownership or capability predicate anywhere on this path is the defect
  class; route it through the shared authority instead.
- **Preview cost equals execution cost, structurally, not by convention.** Both
  `pathfinding::astar_leg` and `scene::move_exec::execute_move` price a diagonal step through the
  SAME `GridShape::neighbors_with_cost` trait method — see the gotcha below for why `step_cost`
  itself is never called directly by either.
- **A combatant's `hidden` state is `permissions.default: none`, not an engine field.** Hiding a
  combatant is genuine document unreadability (the existing whole-document READ gate drops it at
  every egress point), never a display flag on `CombatantEngine` a client could choose to ignore.
- **`transition::is_hidden` is a WORLD-DEFAULT readability test and is NEVER an authorization or
  per-caller READ gate.** It reads `permissions.default == DocRole::None` and nothing else, which
  answers a DIFFERENT question from the per-caller whole-document `cap::READ` that
  `combat::combatant_access` and `SceneEcs::ctx_access` resolve — neither implies the other in
  either direction (a `permissions.users` entry moves the real answer and not this one). It has
  exactly TWO consumer CLASSES, both of which genuinely ask a whole-world question and are correct
  on this predicate:
  - broadcast `Audience` selection for a message a transition posts (`transition::resolve_event`'s
    event message and `transition::roll`'s roll message) — `Audience` names a whole-world tier, so
    the question is whether the entry is public at all, not whether some individual may read it;
  - `settle_turn`'s auto-resolve rule under `TurnControl::OwnerMayEnd` — ONE decision for the whole
    order walk rather than a per-recipient one. Its real-authority form would be "does ANY non-GM
    world member hold `cap::READ` plus ownership", which needs a world-membership enumeration the
    walk does not have; that is a different and more expensive computation, not a mechanical
    extension of the authorization fix, and it is left on the world-default semantics deliberately.
  A caller admitted by a `permissions.users` grant on a `default: none` combatant is therefore
  authorized to act yet still auto-resolves under `OwnerMayEnd` and still gets `Audience::GmOnly`
  on their own roll message — an accepted, documented residual that under-discloses only. Do NOT
  add a third consumer that asks a per-caller question.
- **A combatant a mover cannot READ applies none of the movement-budget gate's three behaviors to
  them: no `MoveReject::NotYourTurn` refusal, no truncation, no `BudgetUnresolvable`.**
  `BudgetGate::enforced` in `Room::execute_move` is exactly `access.has(cap::READ)` off
  `SceneEcs::combatant_for_token`'s resolved `Access`, never a re-derivation from
  `permissions.default`. Either a refusal or a truncation would disclose BOTH the combatant's
  existence and its exact numeric budget through move behaviour alone — reachable without owning
  that combatant's own token, since `combatant_for_token`'s `actor_id` fallback matches ANY token
  instanced from the same actor. The resource decrement still commits (it writes only that
  combatant's own document, and `filter_command` drops the whole op for any recipient lacking
  `cap::READ` on it — uniformly across `Create`/`Update`/`Delete`, never Update-specific). A mover
  lacking `cap::READ` therefore still receives a causally-attributable EMPTY-OPS `Event` frame for
  that write — `filter_command`'s own doc comment: a fully-redacted command keeps its seq with
  empty ops — a residual the genuinely-no-combatant case never produces, since no such write exists
  there to redact in the first place. Full mechanics, including the two reachable
  world-defaults-freshness shapes: `shadowcat-codebase-scene-rendering`.
- **`CombatEngine.order` is the single sequence authority.** Nothing re-derives turn order from
  `CombatantEngine.initiative` at read time; `order` is what a running combat actually iterates,
  mutated only by `combat::transition`'s own functions (`rebuild_order` folds in a combatant a
  restore re-`Create`s or a fresh addition without dropping anyone the record never captured).
- **At most one `active: true` combat per scene, decided ONCE per batch through a single running
  map, not two independently-consulted sets.** `SqliteRepository::apply_intent`'s Phase 1 first
  pre-scans the WHOLE batch (before any per-op validation runs) to compute the local set of every
  scene a same-batch `Update`/`Delete` genuinely frees (a true→false transition, or an active
  combat moving off the scene, via `merged_combat_engine`, the in-memory field-change replay that
  drives this decision ahead of the real `validate_engine_tree` merge). It then walks `ops` once
  more, consulting and mutating ONE `apply_intent::scene_owner` map (`HashMap<scene, combat_id>`, lazily seeded
  per scene by `SqliteRepository::ensure_scene_owner_seeded`/`SqliteRepository::
  active_combat_owner` — a scene already named by that pre-scan's freed set is deliberately left
  unseeded, so an earlier same-batch claim on it validates against the state the batch will
  actually leave, not a stale DB row a later op is about to invalidate): a claim (Create or Update
  making some combat `active: true` on a scene) succeeds when `apply_intent::scene_owner` carries no entry for
  that scene, or already maps it to that combat's own id; a release removes the entry only when it
  still maps to that SAME combat's id. This closes the
  deactivate-then-reactivate-different-combat same-scene batch shape (pinned by
  `a_swap_batch_deactivating_then_activating_on_one_scene_passes_in_either_order`) that an earlier,
  two-independent-set design left fail-closed-but-over-rejecting.

## Gotchas

- **`transition::rewind` validates its PROSPECTIVE post-image before emitting a single op, and
  refuses with `CombatError::RewindUnreachable` when it is invalid.** It builds the `CombatEngine`
  the rewind would write (`round`/`turn` from the target `TurnRecord`, `order` rebuilt only
  alongside a restore) and runs `CombatEngine::validate` on it — delegating wholesale rather than
  restating "turn must be in order" locally, so the two cannot disagree about what a valid clock
  state is. The reachable case is `rewind_restore` OFF with a target boundary whose `turn` names a
  combatant since deleted and dropped from `order` (an exhausted `Event`, which only a restore
  would bring back). Without the pre-check the engine-ingress gate refuses the built ops instead,
  rolling the whole command back behind the uniform "combat rejected" wording — permanently, for
  every future attempt at that boundary. The two rejected alternatives are both worse and both
  tempting: rebuilding `order` without restoring leaves a phantom entry naming a document that does
  not exist, and clamping or skipping the `/engine/turn` write moves the clock somewhere the GM
  never asked for, quietly.
- **The pure-transition unit harness runs REAL ingress gates, and a gate missing from it hides a
  whole defect class.** `combat::tests::validate_persisted` runs `validate_system_size` and
  `validate_engine_tree` (the recursive ingress chokepoint, not `CombatEngine::validate` directly)
  over every document the harness stores, panicking loudly where the real repository would reject
  the batch. It runs `validate_engine_tree` on a CLONE because that function normalizes in place
  and the harness's stored documents must stay exactly what the transition wrote. The other two
  per-document gates (`validate_property_overrides`, `validate_system_schema_tree`) are omitted
  because they are no-ops against these fixtures — no fixture populates `property_overrides` and
  the harness declares no `SchemaDeclaration` — so a fixture that starts carrying either must add
  the matching gate rather than rely on that note. Every unit test in this module passes through
  this harness, which is precisely why an unrun gate makes a real, permanently-bricking bug
  invisible to all of them.
- **`data::command::set_pointer` cannot GROW an array — an out-of-bounds array index fails
  `BadPath`.** This is why `combat::history::append_record`'s later-record path never pushes a new
  `TurnRecord` into `records` by index: it reads the WHOLE history engine into memory, appends/
  truncates the Rust `Vec`, and writes the result back via `whole_engine_replace` (`/engine`,
  pre-imaged against the stored document) — a whole-array replace, not a per-index write. Any
  future combat-family collection that grows over time needs the same shape; do not reach for a
  per-index `Operation::Update` against an array tail.
- **Reach for `GridShape::neighbors_with_cost`, never `step_cost`, when pricing a diagonal step.**
  `scene::grid_shape`'s `step_cost` is a private `fn`, deliberately never made `pub(crate)` —
  `pathfinding::astar_leg` and `move_exec::execute_move` both reach it exclusively through
  `GridShape::neighbors_with_cost`'s trait dispatch, so a router preview and the movement-budget
  gate's own execution cost cannot drift apart by one of the two call sites acquiring a second,
  duplicated pricing path. See `shadowcat-codebase-scene-rendering` for the full parity story
  (`router_preview_cost_equals_executor_cost_per_diagonal_rule`,
  `continuous_smoothed_preview_cost_equals_executor_cost`).
- **A required `world-settings` leaf cannot be "removed" by a reset UI — only a `combat.*`
  override genuinely can.** `WorldSceneDefaults` fields (scene/pathfinding/animation) are
  required on the wire once the `world-settings` document exists, so `resolveSettingProvenance`'s
  `resolvePick` helper collapses a `"world"` pick down to the system-or-engine layer when the
  stored value is merely deep-equal to what's beneath it — presence alone can't distinguish a
  genuine override from a value restating its own fallback. `CombatDefaults` has no such
  constraint: every field is optional end-to-end (server `Option<T>`, client `T | null`), so a
  reset write for a `combat.*` setting can genuinely clear the world-settings leaf back to
  absence — a "reset to system default" action means something different depending on which of
  the two shapes the setting lives in, and a future editor must not assume they're
  interchangeable.
- **`"combat.movementResource"`'s dedicated `resolveSettingProvenance` branch never
  deep-equal-collapses a `world` value against the layer beneath it — unlike every other
  `combat.*` setting, which routes through `resolvePick` and does.** `resolvePick` treats a
  `world` value that is merely `deepEqual` to the resolved system-or-engine baseline as
  non-overriding (collapses its reported `source` down a layer), because that's the only way to
  distinguish a genuine override from a value restating its own fallback for a REQUIRED field. The
  movement-resource branch instead walks its own `resolveSettingProvenance.layerOrder` and returns the first layer whose
  key is present at all (`"movementResource" in layer`), with no deep-equal check against
  anything — a stored world-layer value that happens to equal the system/engine default still
  reports `source: "world"`. This is a known, parked provenance asymmetry: `movementResource` is
  the one `combat.*` field with the doubly-optional `Option<Option<String>>` shape (present-with-
  `null` is a distinct, meaningful state from absent), which is why it can't reuse `resolvePick`
  at all — the asymmetry is a byproduct of that, not a separate defect, but a future
  combat-settings-UI task inherits it and must not assume `movementResource`'s provenance display
  behaves like every other combat setting's.
- **`CombatDefaults.movementResource`'s doubly-optional shape needs a custom deserializer
  server-side.** `Option<Option<String>>`: outer `None` means "inherit", `Some(None)` means
  "explicitly clear an inherited resource" — serde's default `Option<T>` deserialization
  collapses a missing key AND an explicit `null` to the same `None`, so `deserialize_double_option`
  is required to distinguish them. The client mirror (`resolveSettingProvenance`'s
  `"combat.movementResource"` case) needs the equivalent distinction against a plain
  nullish-coalesce, which cannot express "an explicit clear stops the walk here" — see that case's
  own doc comment.
- **`CombatantKind` and `ResourceBinding` are internally tagged (`#[serde(tag = "type"/"kind")]`)
  and therefore CANNOT carry `#[serde(deny_unknown_fields)]`** — serde does not support the
  combination. `normalize_engine`'s re-serialization of the deserialized struct back to `Value`
  drops any unknown key that arrived on the wire, so ingress is still closed to unknown-field
  smuggling; it just isn't enforced by the derive itself on these two types the way it is on every
  other engine struct in this module.
- **A combatant hydrates into the scene ECS exactly like any other parented document — no special
  casing.** `is_scene_entity` admits any document with a `parent_id` set (or `doc_type == "scene"`
  itself); a combatant's `parent_id` points at its combat, not a scene, but that's irrelevant to
  the predicate, which only checks parentedness. Nothing in `SceneEcs::from_documents`/`apply_op`
  branches on `doc_type` to treat a combatant differently from any other child doc.

## Pointers

- Design rationale for the combat clock — the full decision table and the document/intent shapes
  in full — lives under `docs/superpowers/specs/`.
- `shadowcat-codebase-documents-permissions` — owns the READ-transition/redaction machinery a
  hidden combatant's live reveal/hide relies on (`filter_command`, `OpSnapshot`, `delete_stub`),
  the containment/embedding rules this module's placement checks extend, and the singleton
  claim-set pattern `SqliteRepository::ensure_scene_owner_seeded`'s active-scene tracking follows.
- `shadowcat-codebase-scene-rendering` — owns `Room::execute_move`'s movement-budget gate
  (turn-owner enforcement, resource resolution, the two-commit split), the unified diagonal-cost
  function this gate shares with the pathfinder, and every other movement-gate axis.
- `shadowcat-codebase-client-shell` — owns `SYSTEM_CONTRACT` and the server-seeded
  `system-defaults` seam (a system package's `module.json` declaration, written by the server's
  world-config seed path) — the declaration half of the settings chain
  `resolve_combat_rules`/`resolveSettingProvenance` resolve.
