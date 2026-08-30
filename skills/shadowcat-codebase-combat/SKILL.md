---
name: shadowcat-codebase-combat
description: "Use when touching Shadowcat's combat clock: the combat/combatant/resource-registry/effect/combat-history engine doc types, the `CombatDefaults` engine→system-defaults→world→scene override chain and its resolver, combat containment/singleton-active enforcement, the server-owned transition layer (`combat::{snapshot,transition,effects,history}`, `handle_combat_intent`, `Room::commit_combat`), the per-turn movement-budget gate inside `Room::execute_move`, or the client combat document builders/provenance resolver. Covers src/server/src/data/engine/combat, src/server/src/combat, and the combat-doc portion of src/client/core/src/scene-docs.ts. Invoke shadowcat-codebase-core first; for the READ-transition/redaction machinery combatant hiding relies on, invoke shadowcat-codebase-documents-permissions; for the movement-budget gate's placement inside the move executor and the unified diagonal-cost function it shares with the router, invoke shadowcat-codebase-scene-rendering."
---

# Shadowcat — Combat

Orientation for the combat clock: the document layer, the server-owned transition/intent
pipeline that mutates it, turn history, effect-lifecycle expiry, and the per-turn movement-budget
gate the move executor enforces against it. The document builders and the settings-chain
provenance resolver (`resolveSettingProvenance`, `systemDefaultsUpsertOps`) already exist
client-side; what does NOT exist yet is anything that DISPATCHES a combat intent from the UI, a
client-side resolveResources formula evaluator, or a tracker/settings-editor UI to host any of
it — those are a later milestone. Everything server-side (transitions, gates, history) is built.

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
  `ExpiryPoint`/`ResolvedLifecycle`, `Formula` (untagged `Number(f64) | Text(String)`),
  `MovementRules`/`Interpretation`/`Enforcement`/`TurnControl`, `TurnRecord`/`EffectSnapshot`/
  `MAX_TURN_HISTORY`, `CombatDefaults` (the override-chain shape, every field optional), and
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
  hidden combatant is observable from outside its own (permission-gated) document. `settle_turn`
  bounds its auto-resolve walk with a LINEAR step budget: `settle_turn::budget` seeds at
  `w.engine.order.len()`, each step increments `settle_turn::steps`, and the walk stops
  (`w.set_turn(entry_id)` then returns) once `steps >= budget` rather than spinning forever on a
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
  `transfer` set), anchored by `Duration.anchor`. `tick` decrements `remaining` at a matching
  clock boundary and deactivates at zero; `expire_by_policy` deactivates by lifecycle flag
  (`on_combat_end`/`on_turn_end`) independent of `Duration` entirely. Both skip any effect whose
  `lifecycle.resolved` or `Duration.remaining` is still unresolved (`None`) — see the hard
  invariant below.
- `combat::history` (`append_record`, `restore`, `fast_forward`, `live_equals`,
  `resulting_combatants`) — the turn-history record/restore seam `start`/`advance` call through,
  never re-implemented at a call site. `append_record` replays a transition's own accumulated ops
  onto its pre-transition snapshot (`post_transition_snapshot`) to capture the POST-transition
  state as a `TurnRecord`, then creates the `combat-history` document (first record) or replaces
  its whole `/engine` body (later records — see the `set_pointer` gotcha below), truncating any
  redo tail past the current cursor and evicting the oldest record past `MAX_TURN_HISTORY`.
  `fast_forward` short-circuits `advance`'s ordinary transition walk only when `forward_restore`
  is set, the combat is active, a record exists at both the current cursor and the next, and
  `live_equals` proves nothing has diverged since the current record was captured.
- `data::validation::validate_containment` — the combat-family placement rule, extended by this
  milestone to cover `combat-history` alongside `COMBATANT_DOC_TYPE`: a `combat` document is never
  parented and never embedded; a `COMBATANT_DOC_TYPE` OR `combat-history` document is always
  parented (never embedded) and its parent must resolve to a `combat` document. The
  parent-is-a-combat check itself runs at the persistence chokepoint (`apply_intent`'s Create arm
  in `data::sqlite`), not inside `validate_containment` (which only checks parentedness/embedding,
  no DB access) — it checks `apply_intent::batch_combats` (the set of combat ids this SAME batch
  is Creating) OR a DB load, so a Create batch that creates a combat and its combatants together in
  one `Intent` is admitted without a spurious "parent must be a combat" rejection.
  `validate_containment` recurses into every embedded descendant, so it also catches a
  combatant/combat-history nested arbitrarily deep under an unrelated embedding structure.
- `combat::ops` (`set_engine`, `update`, `whole_engine_replace`) — shared `FieldChange`/
  `Operation` construction: every OCC pre-image is read from the target document's OWN current
  value at the pointer, never guessed or carried forward from an earlier belief.
- `combat::handle_combat_intent` — dispatches one of the eight `ClientMsg::Combat*` variants
  (`CombatStart`/`CombatPause`/`CombatEnd`/`CombatAdvance`/`CombatRewind`/`CombatSort`/
  `CombatRoll`/`CombatResource`): checks a per-user flood budget (`COMBAT_RATE_PER_MIN`) against
  the SAME shared limiter INSTANCE `SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll` check
  (`WsState::message_rate`, one `Arc<PingRateLimiter>` cloned into every handler, not a
  per-handler copy) — `COMBAT_RATE_PER_MIN` also happens to equal that figure numerically, but what
  is actually shared across all five call sites is the one limiter instance's tracked state, not
  merely a repeated constant. Loads the snapshot, authorizes (GM
  unconditional; a non-GM only for `CombatAdvance` as the current non-hidden turn owner under
  `TurnControl::OwnerMayEnd`, or for `CombatRoll`/`CombatResource` as the owner of every named
  non-hidden combatant — an empty `CombatRoll.rolls` list is rejected outright rather than
  vacuously authorizing), resolves the matching `transition` function's ops (or, for `CombatRoll`,
  executes the named rolls first via `chat::resolve_dice_context`/`chat::rolls::execute_roll`),
  and commits them via `Room::commit_combat`. `CombatError`'s `Display` collapses every case that
  could disclose a hidden combatant (`NotFound`/`Forbidden`/`NotRunning`/`Data`) to one identical
  "combat rejected" wording.
- `Room::commit_combat` — the ONE commit path for a combat intent: `commit_ops_locked(...,
  WriteOrigin::CombatTransition)`. `WriteOrigin::CombatTransition` has no wire representation a
  client can construct — see the hard invariant below.
- `SceneEcs::active_combat_for_scene(scene) -> Option<(Uuid, CombatEngine)>` /
  `SceneEcs::combatant_for_token(combat, token) -> Option<(Uuid, CombatantEngine, hidden, owner)>`
  — the ECS-cached lookups `Room::execute_move`'s movement-budget gate resolves under the same
  read guard as every other gate input (restriction/cell/visible_cells/start); a miss on either
  means no gate applies, never a refusal. `SceneEcs::system_defaults_doc() -> Option<&Document>`
  is the cached `system-defaults` singleton every `resolve_combat_rules` caller in `scene` reads
  its `system` argument from.
- Client (`@shadowcat/core`, `src/client/core/src/scene-docs.ts`): `buildCombatDoc`,
  `buildCombatantDoc` (stamps `owner` and, unless `hidden`, an `owner`-role `users` entry so the
  owner may write their own resources — hidden strips both), `buildResourceRegistryDoc`,
  `buildEffectDoc`, `seedResourceRegistryIfAbsent` (idempotent GM seed under a deterministic id).
  `resolveSettingProvenance(store, scene, path)` (`SettingPath` includes `` `combat.${...}` ``
  keys) is the client-side mirror of `resolve_combat_rules`'s four-tier precedence, exposed
  per-field for a settings UI — see `shadowcat-codebase-client-shell` for `SYSTEM_CONTRACT`/
  `systemDefaultsUpsertOps`, the module-declaration and on-join-upsert half of the same chain.
  None of these client seams wire to a tracker UI yet.

## Hard invariants

- **The server never evaluates a `Formula::Text`, and skips any effect whose resolved state is
  unresolved.** `Formula` is untagged (`30` or `"speed"` on the wire); the server stores text
  formulas verbatim and only ever reads/writes the NUMBERS a client's formula library resolves
  them to (`CombatantEngine.resources`' `current`/`max`, `Duration.remaining`,
  `EffectEngine.lifecycle.resolved`). `combat::effects::tick`/`expire_by_policy` both skip an
  effect outright when the lifecycle/remaining value they need is still `None` — never a guessed
  starting value, never a default. This is the engine's system/engine split applied to combat.
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
- **Preview cost equals execution cost, structurally, not by convention.** Both
  `pathfinding::astar_leg` and `scene::move_exec::execute_move` price a diagonal step through the
  SAME `GridShape::neighbors_with_cost` trait method — see the gotcha below for why `step_cost`
  itself is never called directly by either.
- **A combatant's `hidden` state is `permissions.default: none`, not an engine field.** Hiding a
  combatant is genuine document unreadability (the existing whole-document READ gate drops it at
  every egress point), never a display flag on `CombatantEngine` a client could choose to ignore.
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
- `shadowcat-codebase-client-shell` — owns `SYSTEM_CONTRACT`, `Module.systemDefaults`, and
  `systemDefaultsUpsertOps` — the module-declaration and on-join-upsert half of the settings chain
  `resolve_combat_rules`/`resolveSettingProvenance` resolve.
