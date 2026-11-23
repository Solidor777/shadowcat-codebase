---
name: shadowcat-codebase-combat
description: "Use when touching Shadowcat's combat clock: the combat/combatant/resource-registry/effect/combat-history engine doc types, the `CombatDefaults` engine→system-defaults→world→scene override chain and its resolver, combat containment/singleton-active enforcement, the server-owned transition layer (`combat::{snapshot,transition,effects,history}`, `handle_combat_intent`, `Room::commit_combat`), the per-turn movement-budget gate inside `Room::execute_move`, or the client combat document builders/provenance resolver. Covers src/server/src/data/engine/combat, src/server/src/combat, and the combat-doc portion of src/client/core/src/scene-docs.ts. Invoke shadowcat-codebase-core first; for the READ-transition/redaction machinery combatant hiding relies on, invoke shadowcat-codebase-documents-permissions; for the movement-budget gate's placement inside the move executor and the unified diagonal-cost function it shares with the router, invoke shadowcat-codebase-scene-rendering."
---

# Shadowcat — Combat

Orientation for the combat clock: the document layer, the server-owned transition/intent
pipeline that mutates it, turn history, effect-lifecycle expiry, and the per-turn movement-budget
gate the move executor enforces against it. The document builders, the settings-chain
provenance resolver (`resolveSettingProvenance`), and the client dispatch layer
(`CombatController`/`CombatApi`, `@shadowcat/core`) all exist client-side, wired into
`WorldSession`/`AppContext`. A tracker/settings-editor UI hosts all of it:
`@shadowcat/module-combat-tracker` (the default combat tracker panel) and three
`@shadowcat/module-game-settings` editors (`CombatSettings`, `CombatSceneOverrides`,
`ResourceRegistryEditor`) — see the Key files bullet in references/key-files-and-seams-02-validation-intents-client.md; both are owned end-to-end by
`shadowcat-codebase-client-shell`, this skill covers only the document/resolver shapes they read
and write. Everything server-side about the clock itself (transitions, gates, history, and
formula evaluation through `combat::eval`) is built, including the per-recipient `"combat"`
derived scene channel that resolves resource numbers for the client.

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

The per-file map of the combat family: types and chain resolver, snapshot, transitions, effects, history, movement budget, containment validation, ops, intent dispatch, authorization, the commit path, ECS lookup, and the client controller and default tracker module. Read references/key-files-and-seams.md before editing or locating any combat code.

## Hard invariants

- **Formula text is validated at every ingress container.** Covers how a formula field is parsed, which containers must validate it, and the wire stamp rules. Read references/hard-invariants-detail.md (first item) before adding or changing any formula-bearing combat field.
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
  work, and no combat-document write is refused merely for lacking it. The only three call sites that
  ever construct it are
  `Room::commit_combat`, the movement-budget gate's decrement commit inside
  `Room::execute_move`, and `Room::fire_region_triggers`'s region-trigger effect batch (condition
  writes, combat-scoped `resource_delta`s, chat notices — see
  `shadowcat-codebase-scene-rendering`'s region-triggers bullet) — all server-internal, none
  reachable from a `ClientMsg` variant.
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
  SAME `GridShape::neighbors_with_cost` trait method — see the gotcha in references/gotchas.md for why `step_cost`
  itself is never called directly by either — and both read terrain through the SAME
  `pathfinding::terrain_cost` chokepoint, so a mover carrying a terrain-exempt movement tag
  (`MoveTraits::ignore_terrain`, resolved once per request — `shadowcat-codebase-scene-rendering`'s
  movement-tags bullet) is priced unweighted at preview AND execution. This gate consumes
  `MoveOutcome.cost` unchanged: an exempt mover's decrement is simply the smaller number
  (`exempt_mover_decrements_the_exempt_cost_where_the_ground_mover_pays_the_multiplier`).
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
- **The combat order list is the single sequence authority.** Covers how the order list relates to combatant membership, where it can drift, and the drop-only heal rule. Read references/hard-invariants-detail.md (second item) before touching turn order, the combatant list, or the order heal.
- **At most one `active: true` combat per scene, decided ONCE per batch through a single running
  map, not two independently-consulted sets.** `SqliteRepository::apply_intent`'s validation pass first
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
- **An effect-expiry note never names an effect to someone who cannot read it.**
  `transition::expiry_notices` writes at most two chat `Create` ops in the command's own ops list
  (one public, one GM-only). An effect goes in the public one only when `ExpiryNotice::Visible`
  is the resolved mode (`expiry_mode`, through the combat-defaults chain) AND `effect_is_public`
  holds: the effect, its host and the sweeping combatant all grant default access and no hidden
  combatant stands on the host. A per-user grant on an otherwise unreadable document stays GM-only
  (under-discloses, never leaks). `effects::EffectSweep` is what the sweep returns.

## Gotchas

Per-feature traps: rewind validation, the pure-transition test harness, array pointer writes, diagonal costs, world-settings resets and provenance, movementResource deserialization, tagged enums, start re-resolution, and combatant hydration. Read references/gotchas.md before changing any of those.

## Reference files

| File | Holds | Read it when |
|---|---|---|
| references/key-files-and-seams.md | The "Key files & seams" section: per-file map of combat code, server and client | Editing or locating combat code |
| references/hard-invariants-detail.md | Two long Hard invariants in full: Formula text validation and the combat order list | Touching formula fields, turn order or combat membership |
| references/gotchas.md | The "Gotchas" section | Changing rewind, transition tests, settings resets, combat serde or hydration |

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
- `shadowcat-codebase-client-shell` (shadowcat-codebase-client-shell's references/appcontext-i18n-and-session-seams.md) — owns `SYSTEM_CONTRACT` and the server-seeded
  `system-defaults` seam (a system package's `module.json` declaration, written by the server's
  world-config seed path) — the declaration half of the settings chain
  `resolve_combat_rules`/`resolveSettingProvenance` resolve.
