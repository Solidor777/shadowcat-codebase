# Combat: gotchas

Part of the shadowcat-codebase-combat skill; read it before changing rewind, the transition test harness, settings resets and provenance, combat serde shapes, or combatant hydration.

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
- **`combat::transition::start` RE-RESOLVES `movement`/`turn_control`/`effect_cleanup`/
  `rewind_restore`/`forward_restore`/`effect_lifecycle` from `resolve_combat_rules`'s chain
  (scene > world > system) every time a combat starts — these fields are a SNAPSHOT of the
  resolved chain at that moment, never authored state a `Create` op can pre-stamp and expect to
  survive.** A `combat` document's `Create` may set any value on these fields; `combat_start`
  overwrites all of them from the chain unconditionally. To get a non-default value (e.g.
  `movement.enforcement: "warn"`) on a STARTED combat, the override belongs on the scene
  document's `engine.combat: CombatDefaults` (the most-specific layer `resolve_combat_rules`
  reads), not on the combat document itself.
- **A combatant hydrates into the scene ECS exactly like any other parented document — no special
  casing.** `is_scene_entity` admits any document with a `parent_id` set (or `doc_type == "scene"`
  itself); a combatant's `parent_id` points at its combat, not a scene, but that's irrelevant to
  the predicate, which only checks parentedness. Nothing in `SceneEcs::from_documents`/`apply_op`
  branches on `doc_type` to treat a combatant differently from any other child doc.

