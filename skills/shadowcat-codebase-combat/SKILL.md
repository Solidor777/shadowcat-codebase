---
name: shadowcat-codebase-combat
description: "Use when touching Shadowcat's combat clock document layer: the combat/combatant/resource-registry/effect engine doc types, the `CombatDefaults` world/scene override chain and its resolver, combat containment/singleton-active enforcement, or the client combat document builders. Covers src/server/src/data/engine/combat and the combat-doc portion of src/client/core/src/scene-docs.ts. Invoke shadowcat-codebase-core first; for the READ-transition/redaction machinery combatant hiding relies on, invoke shadowcat-codebase-documents-permissions."
---

# Shadowcat — Combat

Orientation for the combat clock's document layer: the data model and engine-ingress rules that
later combat intents, turn-advance gates, and tracker UI build on. No intents, gates, or UI exist
yet — this layer only defines and validates the documents.

## Purpose

Delivers the four engine doc types the combat clock needs (combat, combatant, resource-registry,
effect) and the world→scene `CombatDefaults` override chain a running combat snapshots at start.
A combat is a world document bound to one scene; a combatant is a child document of a combat
(`parent_id`, never `embedded` — see the containment invariant below); resource-registry is a
singleton config doc the engine ships empty (named resources like movement are data, not built
in); effect gains a typed `engine` band so effect activation, transfer, and clock-bound expiry are
no longer system-only. Later milestones (combat intents, turn-advance/movement-budget gates, the
tracker module) consume this layer but are not part of it.

## Key files & seams

- `data::engine::combat` — every combat-family type and the chain resolver, all `#[ts(export)]`
  and `#[serde(deny_unknown_fields)]` (except the two internally-tagged enums, see the gotcha
  below): `CombatEngine` (`scene_id`, `active`, `round`, `turn`, `turn_control`, `order`,
  `movement`), `CombatantEngine` (`kind`, `initiative`, `tiebreak`, `resources`), `CombatantKind`
  (`Actor { token_id, actor_id }` | `Event { lifespan, message }`), `ResourceRegistryEngine`
  (`resources: BTreeMap<String, Resource>`), `Resource`/`ResourceBinding` (`Mirror { value }` |
  `Tracked { max, recover }`), `Recovery` (per-clock-boundary `Formula` amounts), `EffectEngine`
  (`active`, `transfer`, `duration`), `Duration`/`ClockStamp`/`DurationUnit`/`ExpiryPoint`,
  `Formula` (untagged `Number(f64) | Text(String)`), `MovementRules`/`Interpretation`/
  `Enforcement`/`TurnControl`, `CombatDefaults` (the override-chain shape), and
  `resolve_combat_rules(world, scene) -> ResolvedCombatRules` — the SOLE resolver of the
  engine-fallback → world → scene precedence; nothing else re-derives it.
- `data::validation::validate_containment` — the combat-family placement rule: a combat is
  never parented and never embedded; a combatant is always parented (its parent must itself be
  a combat, checked where the parent can be loaded) and never embedded. Recurses into every
  embedded descendant, so it covers a combatant nested arbitrarily deep under an unrelated
  embedding structure too.
- `SqliteRepository::active_combat_exists` — the tx-scoped DB check backing the one-active-
  combat-per-scene rule (see the hard invariant below); runs on the caller's own transaction for
  the same single-writer reason `singleton_doc_exists` does.
- `filter_command`'s READ-transition rule (`OpSnapshot::permissions_before_commit`/
  `OpSnapshot::owner_before_commit`) — the mechanism that makes hidden-combatant reveal/hide
  arrive live rather than waiting for a resync. Owned by, and documented in full in,
  `shadowcat-codebase-documents-permissions` — this skill only names it as the seam a hidden
  combatant's visibility change relies on.
- Client builders (`@shadowcat/core`, `src/client/core/src/scene-docs.ts`): `buildCombatDoc`,
  `buildCombatantDoc` (stamps `owner` and, unless `hidden`, an `owner`-role `users` entry so the
  owner may write their own resources — hidden strips both the read grant and the `users` entry),
  `buildResourceRegistryDoc`, `buildEffectDoc`, `seedResourceRegistryIfAbsent` (idempotent GM seed
  under a deterministic id, so racing GMs converge on one registry document rather than creating
  two). None of these wire to any UI yet.

## Hard invariants

- **The server never evaluates a `Formula::Text`.** `Formula` is untagged (`30` or `"speed"` on
  the wire); the server stores text formulas verbatim and only ever reads/writes the NUMBERS a
  client's formula library resolves them to, landing in `CombatantEngine.resources`'s
  `CombatantResource.current`/`CombatantResource.max`. This is the ARCHITECTURE.md invariant-6
  system/engine split applied to combat: formulas are system-owned meaning over engine-owned
  numeric state.
- **A combatant's `hidden` state is `permissions.default: none`, not an engine field.** Hiding a
  combatant is genuine document unreadability (the existing whole-document READ gate drops it at
  every egress point), never a display flag on `CombatantEngine` that a client could choose to
  ignore. Nothing observable betrays a hidden entry to a non-GM recipient: no placeholder row, no
  count, no counter tick.
- **`CombatEngine.order` is the single sequence authority.** Nothing re-derives turn order from
  `CombatantEngine.initiative` at read time; `order` is what a running combat actually iterates,
  set once (server-rolled initiative) and thereafter mutated only by whatever advances the clock.
- **At most one `active: true` combat per scene**, enforced at both `apply_intent` Create and
  Update chokepoints via `apply_intent::claimed_active_scenes`/`apply_intent::
  released_active_scenes` set arithmetic (same-batch claim/release tracking) alongside the
  tx-scoped `SqliteRepository::active_combat_exists` DB check — the same two-mechanism shape
  (in-memory intra-batch set + tx-scoped DB check) `apply_intent`'s singleton-doc_type gate
  already uses, documented in `shadowcat-codebase-documents-permissions`.

## Gotchas

- **`CombatDefaults.movement_resource`'s doubly-optional shape needs a custom deserializer.**
  `Option<Option<String>>`: outer `None` means "inherit", `Some(None)` means "explicitly clear an
  inherited resource" — serde's default `Option<T>` deserialization collapses a missing key AND an
  explicit `null` to the same `None`, so `deserialize_double_option` is required to distinguish
  them (a missing key stays `None`; `null` becomes `Some(None)`).
- **`CombatantKind` and `ResourceBinding` are internally tagged (`#[serde(tag = "type"/"kind")]`)
  and therefore CANNOT carry `#[serde(deny_unknown_fields)]`** — serde does not support the
  combination. `normalize_engine`'s re-serialization of the deserialized struct back to `Value`
  drops any unknown key that arrived on the wire, so ingress is still closed to unknown-field
  smuggling; it just isn't enforced by the derive itself on these two types the way it is on every
  other engine struct in this module.
- **A combatant hydrates into the scene ECS exactly like any other parented document — no special
  casing.** `is_scene_entity` admits any document with a `parent_id` set (or `doc_type == "scene"`
  itself); a combatant's `parent_id` points at its combat, not a scene, but that's irrelevant
  to the predicate, which only checks parentedness. Nothing in `SceneEcs::from_documents`/
  `apply_op` branches on `doc_type` to treat a combatant differently from any other child doc.
- **A known, currently-unreachable, fail-closed gap exists in the one-active-combat-per-scene
  batch enforcement**: a single Intent that deactivates an already-active combat on a scene while
  simultaneously activating a different combat on that SAME scene is incorrectly rejected, in
  either op ordering — the Create-arm check reads the database as it stood before the batch's own
  writes, and neither `apply_intent::claimed_active_scenes` nor `apply_intent::
  released_active_scenes` is populated by the Update-arm handling that would need to see its own
  same-batch deactivation. Fail-closed (over-rejection, never a dual-active-combat authorization
  gap) and currently unreachable from any real client — only a direct `Repository::apply_intent`
  call can construct this batch shape, since no combat client intent exists yet to do so.

## Pointers

- Design rationale for the combat clock — the full decision table, the document shapes in full,
  and the Nightfox effect-engine-band migration coordination note — lives under
  `docs/superpowers/specs/`.
- `shadowcat-codebase-documents-permissions` — owns the READ-transition/redaction machinery a
  hidden combatant's live reveal/hide relies on (`filter_command`, `OpSnapshot`, `delete_stub`),
  the containment/embedding rules this module's placement checks extend, and the singleton/
  active-scene claim-set pattern `active_combat_exists` follows.
