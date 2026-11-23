Part of the shadowcat-codebase-combat skill; read it before editing or locating combat code on the server, client core or the default tracker module.

# Combat: key files and seams

The per-file map of the combat family: types and chain resolver, snapshot, transitions, effects, history, movement budget, containment validation, ops, intent dispatch, authorization, the commit path, ECS lookup, and the client controller and default tracker module.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-types-snapshot-transitions.md](key-files-and-seams-01-types-snapshot-transitions.md) | Key files & seams: `data::engine::combat`; `combat::snapshot`; `combat::transition`; `combat::effects`; `combat::history`; `combat::budget` | Editing combat types, the chain resolver, snapshot, transitions, effects, history or the movement budget |
| [key-files-and-seams-02-validation-intents-client.md](key-files-and-seams-02-validation-intents-client.md) | Key files & seams: `validate_containment`; `combat::ops`; `handle_combat_intent`; `combat::authorize`; `Room::commit_combat`; `SceneEcs::active_combat_for_scene`; the client `buildCombatDoc`, `CombatController` and combat-tracker module | Editing containment validation, ops, intent dispatch, authorization, the commit path or the client combat code |
