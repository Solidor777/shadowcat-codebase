# Combat: long hard invariants

Part of the shadowcat-codebase-combat skill; read it before touching formula-bearing combat fields, turn order, or combat membership. Each item below is a bullet of the "Hard invariants" list in SKILL.md.

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
- **`CombatEngine.order` is the single sequence authority.** Nothing re-derives turn order from
  `CombatantEngine.initiative` at read time; `order` is what a running combat actually iterates,
  mutated only by `combat::transition`'s own functions (`rebuild_order` folds in a combatant a
  restore re-`Create`s or a fresh addition without dropping anyone the record never captured).
  **`order` is a second, independently-stored statement of combat membership, and it can drift
  from the queried `combatant` children it names — an ordinary document `Move` re-parents a
  `combatant` out of (or into) a combat without ever touching `order`.** `Working::from_snapshot`
  (the sole entry point for `start`/`advance`, the two transitions that actually walk `order`) runs
  `heal_order` first, dropping any entry that no longer resolves against the freshly-queried
  `combatants` — through `drop_departed`, the SAME "still a member" test `rebuild_order`'s own
  `reconcile_membership` shares rather than re-derives — so a stale entry can never reach
  `settle_turn`'s combatant lookup and permanently brick the clock behind `CombatError::NotFound`.
  **`heal_order` is deliberately DROP-ONLY: it never appends a `combatants` entry `order` doesn't
  name.** A combatant present in `combatants` but absent from `order` — whether it entered
  `combatants` after `order` was last rebuilt, or was `Create`d without an `order` entry from the
  start — is `order` alone indistinguishable from a
  combatant the GM deliberately staged without rolling it into initiative (a real, permanent,
  end-to-end-tested state: a scenario asserts a `hidden: true` combatant "never enters
  `order`/`turn`" across a whole round). Auto-appending on every `advance` would silently roll a
  staged/hidden combatant into the clock on its own, which is a regression, not a fix. Only an
  EXPLICIT resort (`CombatSort`/`CombatRoll`, both already routing an arrival through
  `rebuild_order`'s full filter-append-then-sort) may decide to admit an arrival — never the
  unconditional per-transition heal.
