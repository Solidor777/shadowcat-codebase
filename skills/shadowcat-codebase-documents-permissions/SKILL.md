---
name: shadowcat-codebase-documents-permissions
description: "Use when touching Shadowcat documents, permissions, redaction, visibility tiers (all / gm_only / owner_or_gm), per-recipient broadcast filtering (document stream AND derived channels, which owe the same two gates), the search index, the `Document.base` merge-snapshot field (its authz/size-cap/egress rules — not the client merge algorithm), or the client wire/Zod types. Covers src/server/src/data and its src/client/core wire mirror. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Documents & Permissions

Orientation for the document data model and the server-side, per-recipient redaction layer.
Server is the source of truth; the client only mirrors the wire shape.

## Purpose

A document is a typed envelope (id, type, owner, permissions, `schema_version`, display `name`)
carrying **three bands**: the envelope `name: Option<String>` itself, a typed `engine`
JSONB body (present only for engine-defined `doc_type`s, strictly ingress-validated), and an
opaque `system` JSONB body the engine never interprets semantically. Permissions are enforced
server-side **per recipient**: hidden fields are stripped before transmission, never
sent-then-hidden. This subsystem also owns the visibility-partitioned full-text index.

## Key files & seams

- `data::document` — the `Document` envelope: `name: Option<String>` (universal
  display name, `#[serde(default)]`) and `engine: Option<serde_json::Value>` (`#[ts(type =
  "unknown")]`, present iff `doc_type` is engine-defined) alongside the `system`
  body; `enum Visibility { All, GmOnly, OwnerOrGm }` (the per-property visibility tiers);
  `PermissionSet.gm_role: Option<DocRole>` (`#[serde(default)]`, ts-rs exported) — see Hard
  Invariants below.
  - `base: Option<serde_json::Value>` (`#[serde(default)]`, `#[ts(type = "unknown")]`) —
    the opaque 3-way-merge snapshot the generic templates system stamps onto an instance at
    stamp/pull/push/revert time (see `shadowcat-codebase-templates` for the client-side
    `MergeBase` shape/algorithm). Purely a client-owned blob: the server never interprets it.
    `data::permission::required_cap_for_path` maps `/base` (and any subtree under it, e.g.
    `/base/system/hp`) to `cap::WRITE_FIELDS` — no dedicated capability, and not a per-band
    decision either: it derives the whole write-fields branch from the shared band set via
    `writes_a_content_band` (see the redaction-classifier invariant below). `/source` (the
    sibling field naming what a document is an instance OF) stays unmapped/immutable —
    `required_cap_for_path` returns `None` for it, so no write path can ever re-target an
    existing document at a different template.
  - `world_of(doc: &Document) -> Option<Uuid>` (`pub(crate)`) — the single chokepoint for
    "which world does this doc scope to" (`Scope::World { world_id } => Some(world_id)`,
    `Scope::Compendium => None`). Two call shapes: (1) a caller that already knows the world it
    scopes to PINS a doc reference by comparing `world_of(&doc)` against that known `world_id` —
    `ws::conn::scene_ping_permitted` (refuses a scene doc from another world even for a
    member of both) and `chat::handle_send_message`'s actor-attribution gate
    (`shadowcat-codebase-chat`). (2) an HTTP by-id route with no caller-known world instead
    DERIVES `world` from the doc itself — `http::routes`'s `get_document`/`patch_document`/
    `delete_document` do `let world = world_of(&doc).ok_or(AppError::NotFound)?`, then use that
    extracted world as the authority for the subsequent `permission_context` lookup; `None`
    (a compendium doc) 404s uniformly with the missing-doc case (existence-hiding). No
    by-id/relay call site duplicates this "derive the world from the doc" decision — the ONE
    place to extend THAT specific pattern is here. A separate, narrower match exists at
    `data::sqlite::check_command_scope`: given a caller-ALREADY-known `world_id` (the
    world a command is being applied to), it asserts `doc.scope` is `Scope::World` for that
    SAME id, rejecting any other scope — a guard inside `apply_intent`/`apply_command`, not a
    `world_of`-style derivation, so it does not duplicate `world_of` itself.
- `data::engine` — the typed `engine`-band structs + the ingress-validation
  registry, one submodule per doc-type family (`data::engine::token`, `data::engine::scene`,
  `data::engine::geometry`, `data::engine::registries`) plus the `data::engine` module itself:
  `is_engine_doc_type(doc_type) -> bool` (the 21-entry registry:
  `is_engine_doc_type::token`/`is_engine_doc_type::scene`/`is_engine_doc_type::wall`/
  `is_engine_doc_type::region`/`is_engine_doc_type::light`/`is_engine_doc_type::drawing`/
  `is_engine_doc_type::template`/`is_engine_doc_type::actor`/`is_engine_doc_type::message`/
  `is_engine_doc_type::world-settings`/`is_engine_doc_type::vision-modes`/
  `is_engine_doc_type::light-gradation`/`is_engine_doc_type::chat-settings`/
  `is_engine_doc_type::dice-settings`/`is_engine_doc_type::channel-registry`/
  `is_engine_doc_type::faction-registry`/`is_engine_doc_type::condition-registry`/
  `is_engine_doc_type::combat`/`is_engine_doc_type::combatant`/
  `is_engine_doc_type::resource-registry`/`is_engine_doc_type::effect` — the combat family,
  see `shadowcat-codebase-combat`),
  `validate_engine(doc_type, engine)
  -> Result<(), DataError>` (deserializes the body against that doc_type's typed struct;
  `deny_unknown_fields` on every struct — engine-defined types WITHOUT an `engine` body error, and
  non-engine types WITH one error too, so a non-engine `doc_type` can never smuggle a typed body
  in). `data::validation::validate_engine_tree` is the recursive ingress
  chokepoint — called on every Create/Update POST-IMAGE (after all `FieldChange`s apply),
  including embedded children, so a wholesale `/engine` replacement, a leaf `/engine/x` write, and
  an embedded child's engine write are all covered by one call site. `normalize_engine` also
  RE-SERIALIZES the typed struct back to `Value` (not pass-through), which both authoritative
  loops (`apply_command` AND `apply_intent`) store — so the stored row, the `world_events` entry,
  and the returned `Command` all carry the IDENTICAL normalized value, never the raw client
  input. A per-doc_type struct can add real semantic validation beyond shape (not just
  `deny_unknown_fields`) — see `TokenEngine::validate` in `shadowcat-codebase-actors-tokens`
  (shares the movement gate's coordinate bound structurally, not by copied literal).
- **Token ownership is EFFECTIVE, and it lives in THIS subsystem's files.** `data::permission::effective_owner`
  and `data::sqlite::load_effective_owner` resolve
  `token's own /owner, else the LINKED actor's owner` at authz time — never stamped. `/owner` is
  Update-writable under `cap::EDIT_PERMISSIONS`; `DocRole::Owner`'s BUILT-IN floor is
  `{READ, WRITE_FIELDS}` and excludes it, but the floored role also selects additive
  `by_role[Owner]` grants. **State the precedence rule exactly ONCE** — duplicating it via a
  short-circuit in the DB join lets an inverted-precedence mutation survive, because either copy
  alone still produces the right answer. Full rule, the fail-closed list, and the instanced-token
  exclusion: `shadowcat-codebase-actors-tokens`.
  **Egress ownership is unified with write ownership.** Every egress site resolves
  `is_owner` through the same `effective_owner`/`effective_owner_via` rule the write path uses —
  the owner is an EXPLICIT parameter of `resolve_access`/`resolve_access_world`
  (`effective_owner: Option<Uuid>`), never read internally from `doc.owner`, and no literal-owner
  wrapper exists, so a new egress call site must state where its owner comes from or it fails to
  compile. Three join sources, one per hot-path shape:
  - **WS hot path** (`ws::conn::send_filtered_event`; `http::routes::write_ops`'s
    HTTP-write receive; and the per-recipient derived-channel egress in `SceneEcs::ctx_access`,
    which resolves the SAME `effective_owner_via` + `resolve_access_world` pair against the same
    in-memory actor table) — `data::permission::filter_command` is a SYNC core taking a
    `CommandSnapshot` (the commit-time half) alongside `load_current_docs`'s per-doc_id
    `CurrentDoc` map (Create/Update/Delete pre-images, awaited ONCE per event before the sync core
    runs — no lock held across that await) and a `filter_command::actor_lookup` closure backed by
    the room's in-memory `SceneEcs` actor table (`|id| ecs.actor(id)`). `send_filtered_event`
    reads `stored.snapshot` straight off the `data::snapshot::StoredCommand` carried by
    `ws::room::RoomEvent::Event` — the REAL commit-time redaction snapshot persisted by
    `apply_intent`, not a mirror of current state — so a HISTORICAL event redacted via
    `ws::conn::replay` (driven by `Room::resync_range`, serving `Egress::Resync` and the
    lag-driven auto-resync path) resolves against the permission set in force at that event's
    actual commit, identically to live delivery: both route through `send_room_event` →
    `send_filtered_event`. `http::routes::write_ops` is the one remaining
    `data::permission::mirror_current_snapshot` caller — an author's read-back of their own
    just-applied write, where commit time and now ARE the same instant by construction, so
    mirroring is exactly correct there and there is no persisted-snapshot gap left to close. No
    pool read on the WS hot path at all — the join is entirely in-memory, preserving the
    no-pool-query-on-the-hot-path property. The scene read guard around `filter_command` itself
    is short (sync core, no await inside it), the same discipline `clip_move_stream` uses.
  - **`http::routes::list_documents`** — one batched `query_documents(world, "actor")` fetch
    up front when listing tokens, folded into a `HashMap<Uuid, Document>` and joined in-memory via
    `effective_owner_via` per doc; every other `doc_type` never triggers the actor query
    (`token_actor_link` returns `None`, so the map goes unused).
  - **Single-doc routes and search** (`get_document`, `search`'s per-hit gate) —
    `Repository::effective_owner_of` (`effective_owner_of` on the trait, `load_effective_owner` in
    `data::sqlite`), one pool-backed join per document, bounded by `MAX_SCAN` on the search path.
  The scope check (rejecting an `actor_id` link that resolves to a document of the wrong type or a
  different `Scope`) lives INSIDE `data::permission::effective_owner` itself, not duplicated
  at any join site — every join source above calls the one function, so the reachable owner set is
  identical regardless of which source resolved it.
- **`command::apply_field_change(v, ch)` is THE store-equal mutation rule — every store of document
  state, authoritative or derived, applies a `FieldChange` through it. Never hand-write a
  `remove`/`set` branch.** One function, one statement of the rule, repo-wide (client mirror: the
  `store` module's `applyOperation`, shared by `DocumentStore` and `OptimisticClient`). Callers
  split only on error handling, and the split is meaningful: the two AUTHORITATIVE loops
  (`data::sqlite`'s `apply_command` and `apply_intent` Phase 2) propagate with `?` so a bad change
  aborts before commit; the DERIVED mirrors in the `scene` module go through `mirror_field_change`
  (logs) / `reapply_changes` (adds the `Document` round-trip), because `apply_op` runs on the
  already-committed broadcast/replay path where the ECS has no authority to reject. **Why this is a
  hard invariant:** an `apply_op` that mirrored with an unconditional `set_pointer`, ignoring
  `ch.remove`, would leave the DB with the key ABSENT (a `remove: true` change) while the ECS holds
  the caller's unconstrained `new` — so with `WRITE_FIELDS` alone, a player removing
  `/engine/actor_id` with a foreign actor id in `new` makes the DB read "unowned" (nobody may write)
  while the ECS resolves ownership to another actor's owner, who then gains the token as a vision
  source. **Vision widens exactly where write authz refuses.** Note the two call-site trust levels
  through one helper: `apply_op` sees
  committed changes, `token_move` sees CLIENT-PROPOSED, not-yet-authorized ones. `MirrorInput::
  {Committed, Proposed}` carries that and decides the LOG LEVEL, not the mutation: `error!` on a
  committed failure (an invariant breach), `debug!` on a proposed one (routine malformed input).
  Backwards in either direction is a real defect — `error!` on the proposed path is an
  attacker-controllable log channel. Both pinned by mutation-checked tests; rationale in full at
  `scene::MirrorInput`.
- `data::validation::validate_field_change` — ingress shape rule: `remove: true`
  must carry a null `new`. Defense-in-depth only; the mirror is correct independently, which
  matters because replay and broadcast can carry shapes ingress never validated.
- `data::command::FieldChange.remove: bool` — a leaf-level object-key-removal
  discriminator on the existing `Operation::Update`/`FieldChange` wire shape, not a new `Command`
  variant: it reuses the same OCC pre-image check (`old`) and capability check
  (`required_cap_for_path`) as an ordinary `set` change. `remove: true` deletes the object key at
  `path` instead of writing `new` (unused, conventionally `Null`), making the key genuinely
  absent (`null` != absent); `#[serde(default)]` on ingest and `skip_serializing_if` on egress
  keep it omitted on the wire when false, and the client Zod mirror makes it optional to match.
  The mutation itself is `remove_pointer(root, pointer)`: **object keys only — a leaf array-index
  removal (e.g. `/tags/1`) is rejected with `DataError::BadPath`, unmutated** (array shrink is
  whole-array replacement only, per the merge-engine invariant; a leaf remove of an index has no
  defined shift semantics), while a missing OR explicit-`null` intermediate ancestor is treated as an
  already-absent no-op rather than an error. Sibling mechanism to `set_pointer` (leaf-SET-only: it
  can create or overwrite a key/index but can never delete a key or resize an array) — the pair
  covers set vs. remove, with array resize handled exclusively by whole-array replacement, not by
  either pointer op. **INVARIANT — all three pointer ops treat a `null` INTERMEDIATE as absent, in
  lockstep on both the server (`data::command`) and the client mirror (the `store` module):** `set_pointer`
  descends by replacing a `null` intermediate with a fresh object (`Option<T>` engine fields with no
  `skip_serializing_if` serialize as `null`, so this is the common case — e.g. a scene's
  `/engine/vision` override on a default-built scene doc); `remove_pointer` no-ops through it; reads
  yield absent (the client's `getPointer` → `undefined`; serde_json's `Value::pointer` server-side →
  `None` — there is no bespoke server `get_pointer`). The LEAF null-vs-absent distinction is preserved (`null !=
  absent` for a leaf value). Forking this null-handling across the two languages is the never-fork
  defect class — parity is pinned by matching tests on each side.
- `data::permission` — the redaction core:
  - `resolve_access` (and `resolve_access_world`) builds the per-connection `Access { caps, all,
    see_gm_only, is_owner }`. Both take `effective_owner: Option<Uuid>` as an explicit parameter
    alongside `user`/`world_role`/`doc` — see the "Egress ownership is unified with write
    ownership" bullet above for why there is no internal `doc.owner` fallback.
  - `effective_role` — the shared floor-resolution helper both `resolve_access` and
    `resolve_access_world` call, taking the SAME `user`/`world_role`/`doc`/`effective_owner`
    parameters; `None` means the unconditional
    GM/admin short-circuit applies (see `gm_role` invariant below), `Some(role)` means the caller
    must resolve capabilities from that per-document role floor like any other actor.
  - `Access::can_see(v: Visibility)` is the single predicate: `GmOnly => see_gm_only`,
    `OwnerOrGm => see_gm_only || is_owner`, `All => true`.
  - `filter_properties(doc, access)` strips hidden **properties** from an outgoing doc — a
    PROPERTY-visibility gate only (see Hard Invariants: it does NOT decide whole-document
    withholding). It decides nothing about what a pointer MEANS: every hidden pointer goes through
    `redaction_target`, whose two outcomes are the two redaction mechanisms. A `Band` result nulls
    the field in place and never strips the key (that variant's own doc states why: dropping the
    key would fail re-deserialization for a required field and, for an `Option` field, be
    indistinguishable from a document that never carried one, breaking the client's stable
    envelope shape); a `Within` result redacts through `strip_pointer`. The band set itself is
    stated in exactly one place — see the redaction-classifier invariant below.
    `/base` takes the whole-band treatment, but its visibility is NOT driven by
    `property_overrides` at all — see the `base` egress invariant below.
  - `redact_change(change, gm_only)` redacts field-level change events on the broadcast path;
    `collect_hidden` (its companion that builds the `gm_only`/hidden-path list for embedded-depth
    redaction) applies the same unconditional `/base` policy at every embedded depth.
- `data::search` — `index_content` (full) vs `index_content_public` (redacted):
  the index is **partitioned by visibility**, not redacted after the fact. `index_content` sweeps
  the `doc_type` unconditionally, the envelope `name` when present, and — through `collect_leaves`,
  which recurses objects and arrays — every STRING **and NUMBER** leaf of both the `engine` band
  and the `system` body; keys, booleans and nulls are excluded. `index_content_public` re-runs
  `filter_properties` first (a nulled band contributes nothing) and matches on its `Result`: an
  unclassifiable override makes it write EMPTY public content rather than fail the index write or
  index unredacted text.
- `data::repository`/`data::validation` — `Repository` trait (storage seam; SQLite today, Postgres-capable later) +
  structural validation (size caps, field-path validity, `deny_unknown_fields`); `data::validation`
  applies the same `MAX_SYSTEM_BYTES` (256 KiB) cap to `engine` as to `system`, checked
  independently per block. `base` gets the SAME independent size cap
  (`validate_system_size`'s cap function, shared across all three blocks) but is explicitly
  `EXEMPT` from `validate_engine_tree` — the tree walker only ever visits `/engine`, never
  `/base`, because `base` is a historical snapshot that may legitimately hold a stale
  `engine`/`system` shape from before the current schema (a template edited after an instance
  stamped from it); running current-schema validation against a deliberately-historical blob
  would be wrong, not defense-in-depth.
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
  enforces from it, see the Hard Invariants entry below).
- `data::sqlite::apply_intent` — the singleton-`doc_type` create-gate:
  `SINGLETON_DOC_TYPES` (world-settings/faction-registry/condition-registry/chat-settings/
  dice-settings — 5 entries; `light-gradation`/`vision-modes` are real engine doc_types but are
  NOT singleton-gated, and `channel-registry` has no gated const at all) + a tx-scoped
  `singleton_doc_exists` DB check reject a second `Create` of a singleton type. That DB check alone
  closes only the CROSS-CALL race (relies on the single-writer `max_connections(1)` pool + a
  tx-scoped executor). A `claimed_singletons: HashSet<String>` seeded before Phase 1's per-op loop
  and checked alongside the DB read closes the separate INTRA-BATCH race: two same-doc_type
  singleton `Create`s inside ONE `apply_intent` call's `ops` both read the DB as empty during
  Phase-1 validation (validated before any Phase-2 insert), so the DB check alone lets both pass; the
  `HashSet` is populated only after both checks pass, so the second op in the same batch is rejected
  regardless of N or ordering. A rejection unwinds the WHOLE `apply_intent` call (no partial insert of
  the batch's other ops) — this is the same whole-batch-rollback semantics every other
  `apply_intent` validation failure already has, not a new rollback path.
- `data::sqlite::apply_intent` — Phase-1 OCC pre-image comparison
  (`values_semantically_eq`) is **numeric-variant-aware, not raw equality**. Same-variant
  integer pairs (both `PosInt`/`NegInt`) compare EXACTLY as `i128`, no magnitude limit — this never
  touches `f64`, so two distinct large integers past 2^53 never alias into a false match. Only a
  genuinely-mixed pair (one integer variant, one `Float`) falls back to an `f64` comparison, gated
  by a `|n| <= 2^53` exactness guard (`MAX_EXACT_F64_INT`) — outside that range a mixed-variant
  pair is unconditionally unequal, never a false-positive OCC pass. Recurses through
  `serde_json::Value::Object`/`serde_json::Value::Array` structure; any non-Number mismatch falls
  back to serde's derived `PartialEq`.
  `apply_intent` is also the tier-2 enforcement chokepoint: `validate_system_schema_tree` runs
  immediately after `validate_engine_tree`, at BOTH call sites — Create (Phase-1, against the
  new document) and Update (Phase-2, against the merged post-image: existing row + applied
  `FieldChange`s, never the pre-image) — recursing through embedded children by their own
  `doc_type` exactly as `validate_engine_tree` does. A violation returns `Err` before the
  transaction commits, so the per-world seq counter is NOT consumed on rejection, and surfaces
  to the client via the rejected-intent path (`DataError::SchemaViolation { pointer,
  reason }`) — no new wire frame.
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
    `index_content` sweeps (see the `data::search` seam above): the `doc_type`, the envelope
    `name`, and every string and number leaf of `engine` and `system`. `doc_type` is
    client-supplied on `Create` and no charset validation constrains it anywhere in
    `data::validation`, so the hostile-input surface includes the envelope, not just the two
    opaque bodies.
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

## Hard invariants

- **Redaction is fail-closed and owner-aware.** `can_see` is the one chokepoint across every
  egress path; a partial-visibility tier (`OwnerOrGm`) uses a distinct flag — never overload the
  GM see-all boolean, or you leak `GmOnly` to owners [[ownerorgm-tier-no-widen]].
- **`filter_properties` is a PROPERTY-visibility gate, NOT a whole-document READ gate.** It only
  strips individual properties whose override is `GmOnly`; it does not withhold, and cannot be
  used to withhold, an entire document. Whole-doc withholding is decided entirely by callers
  checking `access.has(cap::READ)` BEFORE including the op/hit/row at all (see the
  `filter_command`'s `Create`/`Delete`/`Update` branches, `search`'s per-hit filter, and
  `query_documents`/`get_document`) — `filter_properties` runs only after that gate has already
  let the doc through. Any future egress path must follow the same order: check `has(cap::READ)`
  first, then (optionally) `filter_properties` for property redaction. Gating whole-doc delivery
  on `see_gm_only`/GM-ness alone instead of `has(cap::READ)` would leak a `gm_role`-capped
  document (see below) straight past its intended cap.
  - **"Egress path" includes a DERIVED CHANNEL, not just the document stream — and a channel
    inherits NONE of the document stream's filtering.** A derived frame computed from documents
    restates their content on the wire, so it owes the recipient the same two gates in the same
    order, at EVERY document it is computed from — including a linked parent it joins to and an
    embedded child it reads. Both gates must be reached through the same symbols the document
    stream uses (`resolve_access_world` + `effective_owner_via` for READ, `Access::can_see` on the
    `property_overrides` tier for the band), never a same-shaped copy. **The way this defect
    arrives is a helper written as an internal GATE input being promoted to a wire surface:** such
    a helper enumerates without filtering because every prior caller was authoritative, so
    promoting it is a permissions change even when no formula changes and no new query is written.
    Two consequences follow. (1) Redact by ABSENCE of the whole entry — an id paired with an empty
    child list is itself the disclosure, so a nulled field or an emptied list is not a redaction of
    an entry the recipient may not see. (2) An EMBEDDED child is tested on the tier alone, against
    the PARENT's `Access`: `filter_properties` recurses into `embedded` carrying the parent's
    access and no whole-document READ is ever resolved for a child, so demanding one there would
    diverge from the document stream rather than match it. The `"footprints"` channel is the worked
    instance, symbols and levels named in `shadowcat-codebase-scene-rendering`.
- **`PermissionSet.gm_role: Option<DocRole>` makes the GM's usual unconditional access
  conditional, per document.** `resolve_access`'s GM branch normally short-circuits to
  `Access { all: true, see_gm_only: true, is_owner: true, caps: {} }` for every `WorldRole::Gm`
  user, before any document-level permission is consulted — correct and load-bearing for every
  document type (actors, scenes, secret regions: the GM must always see a secret
  region even though it's `default: DocRole::None`).
  - `gm_role: None` (the field's default via `#[serde(default)]`, so a stored document carrying
    no `gm_role` key deserializes to `None`) preserves that unconditional short-circuit exactly —
    every doc_type but the one consumer below is unaffected by the field's existence.
  - `gm_role: Some(role)` caps a GM to the SAME per-document role-floor resolution every other
    actor uses: `effective_role` looks the GM up in `doc.permissions.users` first, falling back to
    `role` (NOT `doc.permissions.default`) only if the GM isn't individually listed. This lets a
    document deny a GM by default (`Some(DocRole::None)`) while still admitting a GM who is
    individually granted a role in `users`, or grant EVERY current GM a role
    (`Some(DocRole::Observer)`) without listing any of them by name — resolved fresh on every call,
    so promotion/demotion to `WorldRole::Gm` takes effect immediately, not a frozen snapshot.
  - `resolve_access_world` deliberately reuses this SAME `effective_role` helper (not
    `doc.permissions.default`) to layer world-level capability grants, so a world-default grant
    for the GM's fallback role applies consistently even when that GM is `gm_role`-capped.
    Recomputing the role independently from `doc.permissions.default` here would silently
    diverge for a capped GM — a real defect class, not a hypothetical, which is why the two call
    sites must share one `effective_role`.
  - First (and so far only) consumer: `shadowcat-codebase-chat`'s `Audience`→`PermissionSet`
    mapping (`Whisper` sets `Some(DocRole::None)`, `GmOnly` sets `Some(DocRole::Observer)`,
    `Public` leaves it `None`).
  - `see_gm_only` stays `true` for any `WorldRole::Gm` actor regardless of `gm_role` capping —
    only `all`/`caps` (whole-document READ) become floor-gated. A `gm_role`-capped GM therefore
    still passes property-tier (`GmOnly`/`OwnerOrGm`) checks on any document they DO have READ on;
    the cap is purely about whole-document access, not GM-ness for property visibility.
- **The search index is visibility-partitioned.** Redacting only the returned doc leaks GM-only
  text via snippet/match/score — index public and full content separately
  [[search-index-must-be-visibility-partitioned]].
- **`engine` ingress validation is strict and fail-closed; `system` stays structural-only.**
  `validate_engine_tree` rejects an engine body with an unknown field, a wrong-typed field, a
  missing body on an engine `doc_type`, or a present body on a non-engine `doc_type` — this is a
  REAL semantic-shape gate, unlike `system`'s size/JSON-validity-only structural check. Do not
  conflate the two bands' authority models when reasoning about what the server does and doesn't
  validate.
- **OCC pre-image comparison at `apply_intent` is numeric-variant-aware, not raw equality.** A
  naive raw-`==` assumption is wrong: `data::sqlite::values_semantically_eq` exists
  because JS clients cannot preserve the whole-number-vs-float distinction through a JSON
  round-trip (e.g. a server-computed `100.0` comes back over the wire and reparses as `PosInt(100)`,
  which raw `==` would treat as unequal to a stored `100`, causing a spurious `Conflict` on an
  otherwise up-to-date write). See the `data::sqlite` seam entry above for the exact comparison rule.
- **`/base`'s egress visibility is hardcoded `OwnerOrGm`, UNCONDITIONAL — never driven by
  `property_overrides`.** `filter_properties` and `collect_hidden`/`redact_change` both
  independently hide `/base` from any recipient who is neither the document's owner nor a GM,
  regardless of what `permissions.property_overrides` says (a doc author cannot loosen or
  tighten `/base`'s visibility by setting an override on it — there is none to set). This is
  load-bearing: `base` is the merge-engine's raw pre-image snapshot of a document's
  `name`/`engine`/`system`/`embedded` bands, which can itself contain content an ordinary
  `GmOnly`/`OwnerOrGm` property override elsewhere on the doc was hiding from this same
  recipient — leaking the snapshot would bypass that override. Be precise about which decision the
  two paths share: the BAND CLASSIFICATION is shared structurally (both read `redaction_target`,
  per the classifier invariant below), but `/base`'s unconditional owner-or-GM policy is NOT —
  `filter_properties` and `collect_hidden` each append `/base` to their own hidden list from their
  own `can_see(Visibility::OwnerOrGm)` test. That one decision is genuinely duplicated, so any
  change to `base`'s visibility must land at both call sites.
- **Tier-2 validates the `system` band's SHAPE only, never values — it EXTENDS the three-band
  document shape, it does not replace it.** `engine`-band validation
  (`validate_engine`/`validate_engine_tree`) remains the separate REAL semantic
  ingress gate for the 21 engine-defined doc types (see the `engine ingress validation` invariant
  above); tier-2 is the `system`-band's analogous but strictly structural enforcement floor. The
  declarable `Schema` type-tree grammar (`type`/`properties`/`required`/`items`/
  `additionalProperties`/`nullable` — no `enum`, no numeric/string bounds, no `pattern`, no
  `anyOf`/`oneOf`/combinators, ever) cannot express a value rule by construction, so it can never
  become a semantic gate no matter what a GM configures; `additionalProperties` is closed by
  default (`None` behaves as `Bool(false)`, matching JSON Schema's spec-divergent-but-documented
  default here). Value legality stays where it always was: tier-1 (client-side Zod, per module)
  plus fail-closed readers. The server still runs no third-party code and never interprets what a
  `system` value MEANS — only whether its declared SHAPE matches.
- **The document writer NEVER supplies the schema that judges it.** The `SchemaDeclaration`
  registry is GM-controlled per-world state, set only through the GM-only
  `/api/worlds/{id}/schemas` endpoint pair (`require_gm`), loaded once before the `apply_intent`
  transaction and enforced read-only against Create/Update post-images — an ordinary writer has no
  path to alter the schema that will judge their own write. The Welcome-broadcast
  `schema_declarations` is informational parity only (lets a client preemptively validate/UX-hint)
  and carries zero enforcement authority; the server-side `apply_intent` load is the only copy
  that matters.
- **Redaction operates on content bands, never on the structural envelope — and ingress and egress
  read ONE classifier, never agree by inspection.** `data::permission::REDACTABLE_BANDS: [&str; 4]`
  (`name`, `engine`, `system`, `base`) is the ONE statement of the band set, and THREE paths derive
  from it rather than re-spelling it: whole-document egress (`filter_properties`), the change-delta
  broadcast path (`collect_hidden`) — both via `redaction_target` — and the write-capability rule
  (`required_cap_for_path`, via `writes_a_content_band`). Adding a fifth band therefore cannot make
  a path redactable without also making it writable under `cap::WRITE_FIELDS`, and cannot let the
  delta path diverge from whole-document egress. A second symbol is shared the same way:
  `band_has_interior`, the leaf rule stating that `name` is a display string with no interior.
  What is deliberately NOT shared is the residual-segment rule, because the two classify different
  input domains — `required_cap_for_path` classifies a `FieldChange` path, `redaction_target`
  classifies a `property_overrides` map key, different fields on different structures behind
  different validators — so `/system/` is a writable path there and unclassifiable here, and they
  are not required to agree string-for-string.
  `redaction_target(pointer) -> Option<RedactionTarget>` returns `Band` (the pointer names a whole
  band — null the field in place, never strip the key), `Within` (the pointer descends into a band,
  landing inside untyped `serde_json::Value` or an `Option`, never a required struct field — which
  is what makes the removal provably non-destructive to deserialization), or `None`
  (unclassifiable). `None` covers two distinct populations, and the second one bites at authoring
  time: everything outside the band set — the structural remainder (`id`, `scope`, `doc_type`,
  `schema_version`, `source`, `owner`, `permissions`, `parent_id`, `embedded`, `created_at`,
  `updated_at`) — AND any pointer descending into a LEAF band, since `band_has_interior` gives
  `name` no interior. So `/name` classifies `Band` while `/name/first` classifies `None` and is
  REJECTED at ingress: an override naming a sub-path of `name` is not authorable at all.
  - **`Within` is NOT uniformly a pointer strip: an ARRAY ELEMENT is nulled in place.**
    `strip_pointer` handles an array container by index at BOTH the descent step and the terminal
    step, because a pointer segment carries no evidence of which container it names
    (`/system/inventory/0` is an object key for one document and an array index for the next) — so
    refusing index segments at ingress is undecidable, and skipping them at egress ships the
    hidden value. The terminal step then differs by container deliberately: an object key is
    REMOVED (true absence, which is what `Within`'s callers rely on), while an array element is
    set to `Null` and never removed, because removal renumbers every later element and the
    recipient's copy would then disagree with the authoritative array about which index holds
    which value. Same rule `remove_pointer` enforces by refusing a leaf index removal: an array
    changes length only by whole-array replacement.
  - **Ingress rejects an unclassifiable `property_overrides` pointer, at all four write paths.**
    `data::validation::validate_property_overrides` calls `redaction_target` and returns
    `DataError::BadPath` on `None`, alongside its well-formedness checks. Called from
    `SqliteRepository::apply_intent`'s Create and Update branches AND
    `SqliteRepository::apply_command`'s Create and Update branches — `apply_command` needs the gate
    too, despite being the trusted, capability/schema/size-skipping undo/replay substrate, because
    this is a structural data-integrity invariant (a redaction pointer must always name something
    redaction can classify), not an authorization check, and trust level doesn't exempt it. A
    pointer naming `/permissions`, `/permissions/default`, `/owner`, `/id`, or `/embedded/items/0`
    is rejected before it is ever stored.
  - **Egress fails closed on an unclassifiable pointer — withhold, never guess.**
    `filter_properties(doc, access) -> Result<Document, RedactionError>`. Two redaction-driven
    failure modes return `Err`, both meaning "this recipient's view cannot be computed": a stored
    `property_overrides` pointer that `redaction_target` cannot classify on whole-document egress
    (`filter_properties`, at the document's own overrides or at any embedded depth it recurses
    through), and the same unclassifiable pointer met on the change-delta path (`collect_hidden`).
    No write that passes the ingress gate can store such a pointer, so an `Err` here means either
    stored data the gate never saw or a band added to `Document` without updating the classifier.
    A THIRD `Err` is defensive rather than redaction-driven and does NOT carry a pointer:
    `filter_properties`' final re-deserialize of the redacted value back into a `Document` yields
    `RedactionError { pointer: "<document>" }`, a sentinel. It is unreachable while the
    classifier's `Within`-lands-in-untyped-or-optional-data guarantee holds, but any caller
    matching on `RedactionError.pointer` will meet it, so that field must not be assumed to be a
    JSON pointer. The one `expect` remaining in the function is the SERIALIZE of an owned
    `Document` into a `Value` — infallible by construction, and not a redaction outcome; it is not
    an assertion about redaction and removing it proves nothing.
    Every caller fails CLOSED on `Err`, never open: `filter_command`'s broadcast path
    drops delivery to that one recipient; `list_documents`/`search` omit the offending item from the
    result rather than erroring the whole call; the single-document read (`get_document`) errors the
    request; the search-index builder (`index_content_public`) writes empty public content for that
    document rather than failing the write. Same posture as fog's fail-closed secrecy gate
    [[fog-is-the-secrecy-gate-fail-closed]]: a gate that meets an input it cannot classify
    withholds, it does not guess.
- **Path-prefix authz covers ancestor (subtree-replacing) writes AND whole-doc Create**, not just
  descendant field updates [[path-prefix-authz-covers-ancestor-and-create]].
- **The singleton create-gate must close BOTH cross-call and intra-batch duplicate-`Create` races,
  via two independent mechanisms.** A tx-scoped DB existence check alone is sufficient for
  cross-call races (serialized by the single-writer pool) but NOT for two same-doc_type Creates
  inside one `apply_intent` batch, since Phase 1 validates every op before Phase 2 inserts any of
  them — both same-batch DB reads see an empty table. The in-memory `apply_intent::claimed_singletons` HashSet
  closes that second gap; do not remove either mechanism assuming the other already covers it.
- **Check-then-act across two queries needs one transaction** — TOCTOU-racy even at
  `max_connections(1)` [[two-query-guard-needs-tx]].
- **`data::sqlite::delete_document_tx` is the SINGLE SOURCE for document-delete
  side-effects** — the row, both FTS tables, and the document's `explored_fog` rows (scene fog
  purge, unconditional by id: only scenes ever appear as `explored_fog.scene_id`, so there is no
  doc_type predicate to drift). BOTH authoritative loops (`apply_intent`, `apply_command`) call
  it; never re-inline a Delete's statements into one loop. World deletion (`delete_world`) relies
  on FK cascades instead — the FTS AFTER DELETE triggers fire under cascade (test-pinned) — plus
  explicit purges for the FK-less `explored_fog` and the five per-world `settings` blobs
  (`world_settings_keys` is the single source for that key list). User deletion (`delete_user`)
  also nulls each owned document's JSON-body `owner` in lockstep with the SET-NULL'd `owner_id`
  column — the column is a denormalized copy, and the two representations must not fork.
- **`Asset.created_by` is `Option<Uuid>`** (`ON DELETE SET NULL`, wire `string | null`): NULL
  means the uploading account was deleted; never assume attribution is present.
- **`INSERT … ON CONFLICT(id)` on a mutated id duplicates rather than moves** the row
  [[upsert-on-conflict-duplicates-not-moves]].
- **Replay redaction is the CONJUNCTION of commit-time and current-time policy, never either
  alone.** `permission::filter_command` takes a `CommandSnapshot` alongside the `Command` it
  redacts; a pointer is hidden iff hidden at commit OR hidden now, and a whole op is dropped
  unless BOTH the commit-time and current-time whole-document `cap::READ` gate admit it. A
  check against current policy alone discloses a pointer's whole historical value once a later
  permission change happens to widen it back to visible; a commit-only check would instead leak a
  value a later TIGHTENING was meant to retroactively hide — the conjunction closes both leaks at
  once, per `filter_command`'s own doc comment.
- **A recipient's whole-document READ transition on an `Update` synthesizes a Create or a stub
  Delete — this closes a pre-existing gap for EVERY doc type, not just combat.** Before this, a
  `/owner` or `/permissions/default` write that flipped one recipient's whole-document
  `cap::READ` (denied→granted, or granted→denied) produced only the ordinary field-delta `Update`
  redaction — a recipient gaining READ got a diff against a document they never had, which the
  client silently no-ops on an unknown `doc_id`; a recipient losing READ kept their stale last-seen
  copy forever. `filter_command`'s `Operation::Update` arm now resolves each op's own
  before→commit transition and, when it grants READ, synthesizes a `Create` of the filtered
  current document (still gated by the ordinary current-time `cap::READ` check, same fail-closed
  posture as every other branch); when it revokes READ, synthesizes a stub `Delete` (`delete_stub`
  — identity/placement fields only, every content band and `permissions` emptied) so nothing
  hidden rides the retraction. The BEFORE half resolves against two new commit-time snapshot
  fields, `OpSnapshot.permissions_before_commit`/`OpSnapshot.owner_before_commit`
  (`#[serde(default)]`, so a legacy stored row without them falls through to the pre-existing
  field-delta path unchanged) — both captured at the same pre-image load point by `apply_command`
  and `apply_intent`'s snapshot-building loops, in lockstep so the two can never desync.
  `owner_before_commit` matters beyond a same-op `/owner` write: `effective_role`'s ownership floor
  grants whole-document READ from ownership alone, so `TOKEN_DOC_TYPE` reassignment is a READ
  transition too, and using the POST-image owner for the BEFORE half (an earlier, unsound version
  of this rule) made that class of transition structurally invisible. Multiple `Update`s to the
  same `doc_id` in one `Command` resolve the identical transition (the snapshot fields are
  captured once per `doc_id`, not per op) but must synthesize exactly once: only the LAST such op
  actually emits; every earlier one is dropped outright, never falling through to the ordinary
  field-delta path (whose assumptions about the recipient's existing access are exactly what a
  genuine transition violates for every op before the one that delivers it). First consumer:
  `shadowcat-codebase-combat` (a hidden combatant's owner needs the reveal/hide to arrive live,
  not on the next resync), but the fix lives entirely in this subsystem and applies identically to
  every doc type.

## Gotchas

- **Docs-ratchet covers the ENTIRE `data` module tree:** every module —
  `data::{document,command,permission,repository,membership,validation,search,asset,sqlite}`
  AND `data::engine::{geometry,registries,scene,token}` — carries `#![deny(missing_docs)]` +
  `#![deny(clippy::missing_docs_in_private_items)]` (the `data` module's inner attrs cascade to all
  children, with no item-scoped exception anywhere in the tree). A new undocumented item
  fails the 3-OS CI clippy step. Doc comments on ts-rs types flow into `src/types/generated` —
  editing them means regenerating (`cargo test`) and committing the bindings, and doc claims about
  authz/redaction must cite the enforcing function — an uncited claim can state a wrong function
  and go undetected by any gate.
- **Wire types are generated** — change the Rust `Visibility`/`Document`, regenerate ts-rs, then
  mirror in the Zod schema (a drift guard enforces parity). Never hand-edit `src/types/generated`.
- **A repo-wide grep for a `property_overrides` pointer's literal field name misses a key built
  through a helper whose call site never spells the field name itself** — `collect_overrides`
  accumulates matched pointers into its `out` parameter, so the values it writes are what actually
  reach the field, not anything the call site itself spells. A survey confirming every constructed
  `property_overrides` key falls inside an allow-listed set must also grep the constructing
  type/helper names, not only the literal field. Same family as scoping a search to the shape you
  imagined rather than the shape that exists.
- **A naive raw-equality assumption about OCC pre-images is wrong.** Any code (or reviewer)
  reasoning about `apply_intent`'s Phase-1 conflict check must account for
  `values_semantically_eq`'s numeric-variant awareness — see the Hard Invariants entry above and
  the `data::sqlite` seam. Treating pre-image comparison as plain `serde_json::Value` `==` will
  misdiagnose both false-conflict and false-pass scenarios.
- **Embedded copies need a deep clone** — `{...doc}` aliases nested `system`/`permissions`/
  `embedded` until the wire round-trip; use `structuredClone` at construction
  [[embedded-copy-needs-deep-clone]].
- **Test harness:** `doc(perms, system)` not `doc(id)`; an `owner_id` is a FK, so a test owner
  must be a real `create_user`, not a synthetic `Uuid` [[server-test-doc-helper-and-owner-fk]].
- **`filter_command`'s commit-time half must never take a live parameter.** Its signature takes
  `cmd`, `snapshot: &CommandSnapshot`, `ctx`, and two live-state parameters (`filter_command::
  world_defaults`, `filter_command::actor_lookup`) that are consulted ONLY for the current-time
  half — no live-lookup argument exists for the commit-time half by construction, which is fully
  derived from `snapshot` alone. A future "just add a quick lookup" change to resolve some
  commit-time value from current state would need to widen this signature, which is a loud diff
  any reviewer will catch; do not add such a parameter without re-justifying the whole conjunction
  invariant above.
- **`documents.created_seq` is set once, at a document's genuine first INSERT.**
  `SqliteRepository::upsert_document`'s `ON CONFLICT(id) DO UPDATE` clause omits `created_seq` from
  its column-update list, so a subsequent update to the same row never touches it — it is the sole signal
  distinguishing a reused document id from its predecessor generation. `OpSnapshot::
  created_seq_at_commit` captures it at commit time; a mismatch against the CURRENT document's
  `created_seq` at redaction time means the id was hard-deleted and recreated since commit, and the
  op is dropped rather than redacted against the wrong generation's permission set.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/` (rustdoc, private items included — the
  `Document`/`permission`/`command`/`engine`/`repository`/`search`/`membership`/`validation`
  submodule tree), `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the `wire` Zod mirror),
  `/api/ts/modules/_shadowcat_types.html` (TypeDoc — the ts-rs generated bindings the Zod mirror
  is checked against). Produce with `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §2 invariant 4 (per-recipient permissions) + invariant 6 (three bands) + §6 (data model),
  plus `docs/design/M2-data-foundation.md` for the data foundation. Design rationale for the
  three-band document shape and the tier-2 structural schema registry lives under
  `docs/superpowers/specs/`.
- Relationships: `graphify query "document permissions redaction filter_properties can_see"`,
  `graphify path "permission.rs" "search.rs"`.
- Deferred merge model: [[document-inheritance-merge-model]].
- `shadowcat-codebase-chat` — the first (and so far only) consumer of `gm_role`, via its
  `Audience` enum's `PermissionSet` mapping (see that skill's Key files & seams). Also owns the
  worked `property_overrides` example this skill's `collect_overrides` gotcha above warns about:
  `chat::roll_embed_property_overrides` computes GM-only `property_overrides` entries for a
  `RollEmbed`'s `spec`/`raw`/`recalc_history[].previous_raw` fields, and the `WriteOrigin::
  ServerMessageRevision` exact-path admission for writing `/permissions/property_overrides`
  (an origin/doc_type/path-scoped extension of the general `apply_intent` access-grant
  mechanism above, with no other consumer) is documented there rather than here, same
  ownership split as `gm_role`.
- `shadowcat-codebase-templates` — the client-side 3-way merge engine + `TemplatesController`
  that produces/consumes `base`; this skill owns only the server-side field/authz/redaction/size
  facts above.
