Part of the shadowcat-codebase-documents-permissions skill; read it when touching apply_intent and its WriteOrigins, the sandboxed validator, the client wire and scene-docs mirrors, snapshots or role caps. Part 03 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-document-engine-token-ownership.md.

- `data::validation::validate_system_schema_tree` (tier-2) — a read-only recursive
  `system`-band structural gate, run beside (not instead of) `validate_engine_tree`.
  `validate_value_against_schema(value, schema) -> Result<(), SchemaMismatch>` is the pure
  accept/reject matcher over the type-tree grammar. Types: `Schema`/`SchemaType`/
  `AdditionalProperties`/`SchemaDeclaration` (`data::document`). Set-time authority:
  `http::routes::validate_schema_declarations` (strict `/system/…`-descendant
  `subtree_pointer`, per-`doc_type` overlap/dup rejection, `schema_format` version gate via
  `SCHEMA_FORMAT_V1`, and resource bounds `MAX_SCHEMA_DECLARATIONS`/`MAX_SCHEMA_NODES`/
  `MAX_SCHEMA_DEPTH`), reached only through the GM-only `GET`/`PUT /api/worlds/{id}/schemas`
  pair (`routes::get_world_schema_declarations`/
  `set_world_schema_declarations`). Registry storage: `Repository::world_schema_declarations`/
  `set_world_schema_declarations` (`data::sqlite`), a per-world settings row keyed by
  `world_schemas_key(world)` — same storage shape as other world-settings singletons, not a new
  table. Broadcast: `ServerMsg::Welcome.schema_declarations` (parity only; the client never
  enforces from it, see the Hard invariants entry in SKILL.md).
- `data::sqlite::apply_intent` — the singleton-`doc_type` create-gate:
  `SINGLETON_DOC_TYPES` (world-settings/faction-registry/condition-registry/resource-registry/
  system-defaults/chat-settings/dice-settings/channel-registry/light-gradation/vision-modes/
  audio-state/module-settings — all twelve config singletons, the same set `world_seed`'s `CONFIG_SINGLETON_DOC_TYPES` seeds,
  which is what makes the gate the seed path's race backstop) + a tx-scoped
  `singleton_doc_exists` DB check reject a second `Create` of a singleton type. That DB check alone
  closes only the CROSS-CALL race (relies on the single-writer `max_connections(1)` pool + a
  tx-scoped executor). A `claimed_singletons: HashSet<String>` seeded before the validation pass's per-op loop
  and checked alongside the DB read closes the separate INTRA-BATCH race: two same-doc_type
  singleton `Create`s inside ONE `apply_intent` call's `ops` both read the DB as empty during
  the validation pass (validated before any apply-pass insert), so the DB check alone lets both pass; the
  `HashSet` is populated only after both checks pass, so the second op in the same batch is rejected
  regardless of N or ordering. A rejection unwinds the WHOLE `apply_intent` call (no partial insert of
  the batch's other ops) — this is the same whole-batch-rollback semantics every other
  `apply_intent` validation failure already has, not a new rollback path.
- **`WriteOrigin::CombatTransition` is a capability-skip on THIS chokepoint, not a new gate.** A
  batch tagged with it skips `apply_intent`'s ordinary per-op capability floor (Create/Delete/
  Update, and descendant re-authorization) — every other check here (scope, size, engine,
  containment, singleton, one-active-per-scene, OCC) still runs regardless of origin, and an
  ordinary GM's `WriteOrigin::Client` writes to combat documents are unaffected by this origin at
  all (a GM already writes combat docs freely under `Client`). **CONSEQUENCE for anyone adding a
  caller: because this chokepoint stands down, `combat::authorize` is the ONLY authorization those
  writes ever get** — there is no second check downstream to catch a permissive predicate. Full
  mechanism, the exact call sites that construct it, and the authz-bypass this exemption exists to
  prevent: `shadowcat-codebase-combat`.
- **`WriteOrigin::TemplateMerge` is the template-merge origin — the same capability-skip shape
  as `CombatTransition`, set ONLY by `ws::conn::merge_intents`.** The handler derives
  authorization against the ACTUAL computed `Update` (owner-or-GM plus `required_cap_for_path`
  over every change path — `update_authorized`) before publishing, so this chokepoint's
  actor-holds-the-required-capability test is the only thing waived; `required_cap_for_path`'s MAPPING still
  applies (an immutable envelope path is rejected for every origin) with exactly one exception,
  the whole-band `/base` refresh this origin alone may write. Scope, size, engine, containment,
  schema and OCC all still run. Because the chokepoint stands down, `update_authorized` is the
  ONLY authorization a merge write gets — the same consequence `combat::authorize` carries.
- **`WriteOrigin::ConfigSeed` is the world-config seed/refresh origin — the same capability-skip
  shape as `CombatTransition` (`WriteOrigin::skips_capability_gates` is the ONE predicate every
  capability-gate site in `apply_intent` reads; `ServerMessageRevision` deliberately does NOT
  skip), plus one gate of its own: it is the ONLY origin permitted to Create, Update or Delete a
  `system-defaults` doc.** Update/Delete are rejected against the STORED doc_type — the same
  authoritative-stored-type shape as the `MESSAGE_DOC_TYPE` guard beside them — so no
  client-reachable origin (including a GM's `Client` writes, and `CombatTransition`) can author
  the singleton. Constructed only by the `create_world` seed, the WS join's
  `ws::conn::reseed_world_config`, and the enabled-modules refresh; the ops always come from ONE
  builder, `data::world_seed::missing_config_ops` (a Create per absent config singleton with the
  Rust seed body, plus an OCC'd `/engine` Update when a stored `system-defaults` body drifts
  from the enabled system package's manifest declaration). `world_seed::seed_author` attributes
  a seed commit to the world's first GM by sorted user id; a world with no GM member is not
  seeded (`Command.author` stays a required, real user).
- **`WriteOrigin::Trigger` is a region-trigger-effect origin — the same capability-skip shape as
  `CombatTransition`/`ConfigSeed` (`is_server_authored`/`skips_capability_gates` both `true`).**
  Constructed only by `ws::room::Room::fire_region_triggers`'s own `commit_ops_locked` call, after
  a `RegionTrigger`'s effect (`ConditionAdd`/`ConditionRemove`/`ResourceDelta`/`ChatNotice`/
  `Teleport`) has already been resolved against the SCENE's own authority (the entering token's
  mover must legitimately be able to move there; the trigger itself carries no separate per-write
  authorization) — the chokepoint standing down means `fire_region_triggers`'s own resolution is
  the ONLY authorization these writes get, the same consequence every other capability-skip origin
  carries. A `Teleport` effect (`TriggerEffect::Teleport { target: PortalTarget }`) repositions the
  entering token (same-scene when `target.scene: None`, cross-scene otherwise), gated to ONE hop
  per move (`allow_teleport: false` on the recursive re-fire that processes the destination cells'
  own `Enter` triggers — a chained portal is refused with a GM-only notice rather than looping).
  A `PortalChoice` effect shares that one-hop slot but writes nothing itself: it registers a
  per-token offer, and the owner's accepted choice re-enters the same funnel as a synthetic
  `Teleport` through `Room::apply_teleport_to`, so a portal and a teleport share one write routine.
- **The remaining server-authored origins, each a capability-skip like the ones above
  (`is_server_authored` and `skips_capability_gates` list them in one place).**
  `WriteOrigin::AudioTransport` is the ONLY origin allowed to `Update` the `audio-state`
  singleton (Create/Delete stay `ConfigSeed`). `WriteOrigin::DoorToggle` is set only by
  `Room::toggle_door`, which has already enforced reach and visibility or GM standing.
  `WriteOrigin::ModulePlacement` is set only by `Room::place_effect` (creating one `region` per
  placement from a module manifest declaration whose `who` vetted the sender) and by
  `Room::expire_due_placements` (deleting a placed region past its declared duration); scope,
  size, engine, containment, singleton, schema and OCC still run. As with every capability-skip
  origin, the handler's own check is the only authorization the write gets.
  `WriteOrigin::ServerMessageRevision` is the one server origin that does NOT skip: it is
  admitted by exact path instead. `SMR_PERMISSION_PATHS` (default, gm_role, users,
  property_overrides under `/permissions`) lists them; the readership trio
  `SMR_READERSHIP_PATHS` additionally needs a GM-world-role author, and the declared-capability
  skip and the missing-capability admission both read the one list.
- **GM-only engine fields share ONE predicate pair.** `permission::gm_only_field_touched`
  (Update: a write at, below or above the field's pointer that changes its effective value) and
  `permission::gm_only_field_in_body` (Create) name the list: a carried-light emission, a token's
  `identity_hidden` flag, `lock_rotation`, and the facing-limited-vision fields. Both
  `apply_intent` (via `authorize_update_change`) and the template-merge authorization read them,
  so a new GM-only field is added to those two functions once. A state-restating write (the
  stored value sent back, or `null`/absent versus `false`) is not a touch: the shared
  `pointer_value_changed` compares with `values_semantically_eq` and a per-field normalizer.
  The `WriteOrigin::TemplateMerge` handler skips `apply_intent`'s gates, so its own authorization
  must call `gm_only_field_touched` too.
- **The token owner floor is READ + WRITE_FIELDS plus DELETE of that token.**
  `permission::holds_token_owner_floor` is the one test behind both the `DocRole::Owner` floor
  in `effective_role` and the `cap::DELETE` grant in `resolve_access`; no other `doc_type` and no
  stamped `permissions.users` Owner reaches it. MANAGE_EMBEDDED and EDIT_PERMISSIONS are not in
  the floor. The client `resolveCaps` mirror must agree with it.
- `data::repository::WorldMemberRow` is the roster row (user, username, role, `colour`,
  `pronouns`, `has_avatar`). Avatar bytes are never in a roster listing; the avatar route serves
  them world-scoped, and a client's roster picks up a changed profile only on reconnect.
- Sense-occlusion engine fields are validated at ingress like any other engine field:
  `WallEngine.proximity` (an optional `WallProximity` tier read only by the sight, light and
  sound collectors) and `RegionEngine.occludes` (an optional `RegionOcclusion`, same readers).
  Movement never reads either.
- **Every engine `doc_type` is classified for the session pause.** `ws::session_pause::
  DOC_TYPE_CLASSES` lists each `ENGINE_DOC_TYPES` entry as `Free`, `PositionWrites` (token) or
  `Combat`; a test fails until a new engine type is added there.
- `data::sqlite::apply_intent` — validation-pass OCC pre-image comparison
  (`values_semantically_eq`) is **numeric-variant-aware, not raw equality**. Same-variant
  integer pairs (both `PosInt`/`NegInt`) compare EXACTLY as `i128`, no magnitude limit — this never
  touches `f64`, so two distinct large integers past 2^53 never alias into a false match. Only a
  genuinely-mixed pair (one integer variant, one `Float`) falls back to an `f64` comparison, gated
  by a `|n| <= 2^53` exactness guard (`MAX_EXACT_F64_INT`) — outside that range a mixed-variant
  pair is unconditionally unequal, never a false-positive OCC pass. Recurses through
  `serde_json::Value::Object`/`serde_json::Value::Array` structure; any non-Number mismatch falls
  back to serde's derived `PartialEq`.
  `apply_intent` is also the tier-2 enforcement chokepoint: `validate_system_schema_tree` runs
  immediately after `validate_engine_tree`, at BOTH call sites — Create (validation pass, against the
  new document) and Update (apply pass, against the merged post-image: existing row + applied
  `FieldChange`s, never the pre-image) — recursing through embedded children by their own
  `doc_type` exactly as `validate_engine_tree` does. A violation returns `Err` before the
  transaction commits, so the per-world seq counter is NOT consumed on rejection, and surfaces
  to the client via the rejected-intent path (`DataError::SchemaViolation { pointer,
  reason }`) — no new wire frame.
- `apply_intent` is ALSO the sandboxed-validator chokepoint: opted-in third-party WASM
  validators run over the `system` band of every Create and every Update touching that band
  at ANY depth (`permission::targets_system_band` decides — an embedded-child
  `/embedded/<coll>/<idx>/system…` write included, and fail-closed on every embedded
  boundary shape: whole-map, whole-collection, or whole-child rewrites classify as
  system-band writes because they replace children's `system` bands wholesale), BEFORE the
  write transaction opens.
  Per op, the pass runs `check_command_scope` followed by the validation pass's OWN authorization functions
  (`authorize_create_intent`/`authorize_update_access`/`authorize_update_change` — the same
  symbols the validation pass calls inside the transaction, so the screen and that pass cannot
  diverge on who is `Forbidden`, and a bare-id Update can never feed another world's
  document through this world's validators), then `sandbox::validate_document`, whose
  `validate_document::prior_permitted` parameter withholds the pre-image band unless the
  writer holds whole-document READ. Phase
  1's OCC covers only each change's own pointer, so a concurrent write to another path of the
  same document re-validates inside the transaction against the in-transaction merge
  (`apply_intent::validated_pre_images` is the capture it diverges from) — re-validation,
  never `Conflict`. `import_world` is the only other call site (inside its own
  already-exclusive transaction; it persists the bundle's enablement record with
  `validators_enabled` forced `false`); `apply_command` never runs one. Both chokepoints call
  the same `sandbox::validate_document`, which first re-runs the validation pass's own pure structural
  chain on the document — a structurally-invalid write surfaces the validation pass's own error before
  any validator is consulted or faulted. A refusal maps to
  `DataError::OpFailed("validator <module>: <reason>")`, a technical fault to
  `DataError::Validator(ValidatorFault)`. The whole mechanism (guest ABI, runtime, registry,
  fault counting and the single auto-disable funnel at `Room::commit_ops_locked`'s error
  arm) is owned by `shadowcat-codebase-sandbox`; this bullet owns only its placement
  relative to the document write path.
- The client `wire` module — Zod mirror: `VisibilitySchema = z.enum(["all","gm_only",
  "owner_or_gm"])`, `property_overrides`. ts-rs generates the TS types from the Rust source.
  Three boundary rules the mirror carries that a plain shape copy would not:
  - **`WireFieldChange.old`/`new` are DECLARED optional but REQUIRED at runtime, and that
    mismatch is structural — do not "correct" it in either direction.** `fieldChangeSchemaImpl`
    `.refine()`s the WHOLE object to reject a frame omitting either key (a per-key schema cannot
    distinguish "absent" from "present and `undefined`"), because the Rust `FieldChange` carries
    no `skip_serializing_if` on either value, so a frame lacking one is malformed. The declared
    type nevertheless stays optional because **Zod v3 infers an object field's declared
    optionality STRUCTURALLY**: any field whose output type admits `undefined` — which an
    unknown-valued `zod` field's always does — is inferred optional regardless of what a whole-object
    `.refine()` enforces, so the declared type cannot be tightened to "required key, unknown
    value" while the impl still satisfies `z.ZodType<WireFieldChange>`. Tightening the type
    breaks that annotation; dropping the refine restores the hole. An explicit `null` is valid on
    both keys — a real pre-image for a new key, and the conventional `new` of a removal.
  - **`WireCapabilityGrants.by_role` is a ROLE-KEYED PARTIAL map; `by_user` stays open by
    design.** `capabilityGrantsSchemaImpl` keys `by_role` by `DocRoleSchema`, so a frame naming an
    unknown role is rejected and adding a `DocRole` variant requires adding it to that schema
    before any grant can name it; the map is partial because the Rust source may omit any role.
    `by_user` keys are user ids — genuinely unconstrained — so it remains a string-keyed record,
    and narrowing it would be wrong.
  - **`WireSearchHit.snippet`, and the `document` beside it, carry indexed text that a consumer
    must render as INERT TEXT, never as innerHTML.** The exposed set is everything
    `index_content` composes (see the `data::search` seam in key-files-and-seams-02-field-changes-permission-search.md): the envelope `name`,
    `data::engine::search_text`'s per-doc_type display text, and every string and number leaf of
    `system`. `doc_type` itself is NOT indexed — narrowing by type is the `doc_types` filter's
    job, not a text-match side effect — but a hit's `document.doc_type` is still client-supplied on
    `Create` with no charset validation anywhere in `data::validation`, so the hostile-input
    surface includes the envelope, not just the two opaque bodies.
- The client `scene-docs` module — `ITEM_DOC_TYPE = "item"`, `ItemSystem`, `buildItemDoc`:
  a **client-only doc_type** — the server has NO Rust-side knowledge of `ITEM_DOC_TYPE` and
  requires none, since `doc_type` is an unconstrained wire string and `system` is opaque JSONB the
  server never interprets. An item document lives standalone (top-level, `parent_id: null`) or
  embedded in an actor's inventory (`actor.embedded.item[]`); write-site resolution for an embedded
  item is `/embedded/item/<idx>/system`, the same one-level `embeddedPath` scheme
  `resolveDocRef` uses for any embedded child ([[shadowcat-codebase-sheets]]).
- `data::snapshot` — the commit-time redaction snapshot: `StoredCommand` (a `Command` paired with
  its `CommandSnapshot`, the server-internal transport persisted into `world_events.command_json`
  and carried through the room broadcast/ring/resync path in place of a bare `Command`),
  `CommandSnapshot` (index-aligned `per_op: Vec<Option<OpSnapshot>>` plus `world_gm_at_commit`),
  and `OpSnapshot` (`owner_at_commit`, `doc_type`, `overrides_at_commit`,
  `retraction_hidden_at_commit`, `created_seq_at_commit`, `permissions_at_commit` — the
  commit-time redaction inputs for one op, built once per command from its own post-image).
  `StoredCommand::from_stored_json` tolerates a legacy bare-`Command` `world_events` row (no
  `command`/`snapshot` keys), wrapping it with an all-`None` `per_op` so `filter_command` drops
  every op in it on replay rather than falling back to a live-lookup redaction.
- **`data::permission::project_role_caps_for(caps: &RoleCaps, role: WorldRole) -> RoleCapabilities`**
  — the per-connection Welcome projection of `WorldCapDefaults.role_caps` for the
  CONNECTING user's OWN role: `RoleCapabilities { all, by_type }` carries only that role's entries
  from `caps.all`/`caps.by_type[*]`; nothing about another role crosses, the same isolation rule
  `project_grants_for` already states for its own actor-grants projection. `ws::conn` computes it
  beside that projection on every Welcome and sends it as `ServerMsg::Welcome.role_capabilities`; the
  client mirror (`@shadowcat/core`'s `canCreateDoc`, `WorldSession.canCreate`/`AppContext.canCreate`
  — `shadowcat-codebase-client-shell`) is ADVISORY ONLY — `apply_intent`'s Create arm's own
  `role_has` check over `WorldCapDefaults.role_caps` remains the sole authority; this projection
  only lets the client hide a create affordance the server would refuse, never grants anything.
- **`grantAuthor` (client-side, `@shadowcat/core`'s `scene-docs.ts`) is the one place "what an
  author may do to their own document" is stated** — the `Owner` `DocRole` floor is
  READ+`WRITE_FIELDS` ONLY by design (an owner must not silently gain the power to reassign
  ownership or reshare a document), so a note/table author needs an EXPLICIT per-document grant of
  `core:delete`/`core:edit_permissions` onto `permissions.capabilities.by_role.owner` — the exact
  mechanism the `/owner` and `/permissions/*` path gates already name ("only a GM, or an explicit
  `EDIT_PERMISSIONS` grant"). `buildNoteDoc`/`buildTableDoc` call it when `opts.owner` is given;
  `doc.owner` (the ownership OVERRIDE field, `shadowcat-codebase-actors-tokens`'s effective-owner
  mechanism) is deliberately left untouched — granting capabilities is not the same act as
  assigning ownership. This is a CLIENT-side convention, not a server gate: nothing on the server
  requires a Create's `permissions` to look this way, so a hand-built document that skips
  `grantAuthor` is still valid, just unmanageable by its own creator (see the RAW-OWNERSHIP
  gotcha in references/gotchas.md — `canDelete`/`canEdit(doc, "/permissions/default")` resolve through the SAME
  `resolveCaps` this grant feeds, never through `doc.owner`).

