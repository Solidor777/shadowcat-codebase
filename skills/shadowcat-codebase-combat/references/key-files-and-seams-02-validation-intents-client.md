Part of the shadowcat-codebase-combat skill; read it when editing or locating combat containment validation, ops, intent dispatch, authorization, the commit path, ECS lookup or the client controller and tracker module. Part 02 of 02 of "Combat: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-types-snapshot-transitions.md.

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
  (`ResourceRegistryEngine`/`Resource`/`ResourceBinding` in key-files-and-seams-01-types-snapshot-transitions.md) and the intent semantics
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

