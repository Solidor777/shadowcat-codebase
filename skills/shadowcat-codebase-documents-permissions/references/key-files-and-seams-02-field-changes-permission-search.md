Part of the shadowcat-codebase-documents-permissions skill; read it when touching field-change and Move operations, validation of field changes, data::permission redaction, data::search or the Repository trait. Part 02 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-document-engine-token-ownership.md.

- **`command::apply_field_change(v, ch)` is THE store-equal mutation rule — every store of document
  state, authoritative or derived, applies a `FieldChange` through it. Never hand-write a
  `remove`/`set` branch.** One function, one statement of the rule, repo-wide (client mirror: the
  `store` module's `applyOperation`, shared by `DocumentStore` and `OptimisticClient`). Callers
  split only on error handling, and the split is meaningful: the two AUTHORITATIVE loops
  (`data::sqlite`'s `apply_command` and `apply_intent`'s apply pass) propagate with `?` so a bad change
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
- `data::command::Operation::Move { doc_id, parent_id, old_parent_id }` — the ONE write path for
  the envelope `parent_id` (immutable via field-path Update: `required_cap_for_path` maps no
  capability to envelope fields). GM-only AND uncapped at the `apply_intent` chokepoint
  (`WorldRole::Gm` whose resolved `Access.all` short-circuit holds — a `gm_role`-capped GM
  floor-resolves and is refused; `WriteOrigin::CombatTransition` is exempt like the other
  capability gates); a stored `message` doc refuses it like every ordinary mutation. Validity is
  **Create-validity**: the shared `check_parent_placement` helper (extracted from the Create arm —
  never re-spell it; its third caller is `SqliteRepository::import_world`'s post-loop pass, with
  empty batch maps because every imported row is already in the tx) plus `validate_containment`
  run against the post-image, and
  `check_move_acyclic`'s batch-aware ancestor walk refuses a move beneath itself. `old_parent_id`
  is the OCC pre-image; `invert` swaps the pair; a no-op move (target == current) is carried in
  the log for invertibility but writes nothing and runs no hooks. Both authoritative loops
  (`apply_intent`, `apply_command`) implement the arm — replay keeps the structural checks, drops
  the capability/OCC gates. Egress: `filter_command`'s Move arm delivers the op verbatim iff
  whole-document READ holds at commit AND now (the conjunction), with the recreated-id
  `created_seq` guard; no content band rides a Move and no READ transition can arise from one
  (access resolution never consults `parent_id`). The scene ECS mirror's Move arm rewrites the
  mirrored `parent_id` and re-evaluates `is_scene_entity` (a document re-parented to the top
  level despawns); `actors`/`combats` map entries mirror the parent in lockstep. Client:
  `applyOperation`'s move arm is the store-equal mirror; optimistic predict + rollback ride the
  ordinary correlated-intent machinery.
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
  `None` — `data::command` has no bespoke pointer-read helper of its own; the unrelated
  `merge::tree::get_pointer` is `pub(crate)` for the merge engine's own tree walk and is not
  part of this ingress family). The LEAF null-vs-absent distinction is preserved (`null !=
  absent` for a leaf value). Forking this null-handling across the two languages is the never-fork
  defect class — parity is pinned by matching tests on each side.
- `data::permission` — the redaction core:
  - `resolve_access` (and `resolve_access_world`) builds the per-connection `Access { caps, all,
    see_gm_only, is_owner }`. Both take `effective_owner: Option<Uuid>` as an explicit parameter
    alongside `user`/`world_role`/`doc` — see the "Egress ownership is unified with write
    ownership" bullet in key-files-and-seams-01-document-engine-token-ownership.md for why there is no internal `doc.owner` fallback.
  - `effective_role` — the shared floor-resolution helper both `resolve_access` and
    `resolve_access_world` call, taking the SAME `user`/`world_role`/`doc`/`effective_owner`
    parameters; `None` means the unconditional
    GM/admin short-circuit applies (see `gm_role` invariant in references/hard-invariants-detail-01-filter-gm-role-base.md), `Some(role)` means the caller
    must resolve capabilities from that per-document role floor like any other actor.
    **Its ownership floor (`holds_token_owner_floor`) is scoped to `TOKEN_DOC_TYPE` and NO
    other doc type.** On every other doc type, being the owner grants no role floor whatsoever — an
    owner can sit at `DocRole::Observer` and hold `cap::READ` without `cap::WRITE_FIELDS`. See the
    ownership-is-not-a-capability-proxy gotcha in references/gotchas.md; this scoping is what makes that a live
    defect class rather than a theoretical one.
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
    stated in exactly one place — see the redaction-classifier invariant in references/hard-invariants-detail-02-redaction-and-read-transition.md.
    `/base` takes the whole-band treatment as an unconditional `OwnerOrGm` floor, and INSIDE it
    every pointer the snapshot's own recorded policy names is hidden at the recorded tier — see
    the `base` egress invariant in references/hard-invariants-detail-01-filter-gm-role-base.md. The hidden-pointer list itself is
    `hidden_own_pointers(doc, access)` (`pub(crate)`; `own_overrides` classifies the document's
    own `property_overrides`, appends the hardcoded `/base` floor, and walks the stored snapshot's
    recorded policy through `base_policy` into `/base{pointer}` /
    `/base/embedded/<coll>/<k>{pointer}` entries) — `filter_properties` consumes it,
    `collect_overrides` derives its recursive walk from the same per-level function, and the
    merge engine's `RequesterView` oracle reads it per document so merge visibility and egress
    visibility are ONE classifier, never two that agree by inspection. The removal step is ONE
    procedure too: `redact_pointers(whole, hidden)` (`pub(crate)`) — `filter_properties` applies
    it to a whole document under the recipient's hidden set, and `merge::plan::merge3` applies it
    to a stored base's band tree under the TEMPLATE's hidden set, so the merge's base and parent
    inputs are reduced identically.
  - `redact_change(change, gm_only)` redacts field-level change events on the broadcast path;
    `collect_hidden` (its companion that builds the `gm_only`/hidden-path list for embedded-depth
    redaction) reads the same `own_overrides` at every embedded depth, so a whole-band `/base`
    delta is stripped of the recorded hidden pointers exactly as a `/system` delta is stripped
    of the document's own.
- `data::search` — `index_content` (full) vs `index_content_public` (redacted):
  the index is **partitioned by visibility**, not redacted after the fact. `index_content` no
  longer indexes `doc_type` at all — it composes the envelope `name` when present,
  `data::engine::search_text(doc_type, engine)` (an exhaustive per-doc_type match over the
  `engine` band's OWN display-text fields — e.g. `actor`'s `display_name`,
  `chat::segments_search_text` over a `note`'s rendered `body`/a `message`'s `content`, the
  registries' `name` fields, `light-gradation`'s band names, a `token`'s `overrides.name`, a
  `combat-history`'s captured combatant names; `unreachable!()` on any doc_type missing an arm —
  a runtime fallback the compiler cannot check, so a new `ENGINE_DOC_TYPES` entry with no
  `search_text` arm panics `search_text_is_registered_for_every_engine_doc_type` rather than
  silently indexing nothing), and — through `collect_leaves`, which recurses objects and arrays —
  every STRING **and NUMBER** leaf of the `system` body ONLY (the `engine` band is never
  leaf-swept generically; its indexed text is exactly what `search_text` names). `index_content_public`
  re-runs `filter_properties` first (a nulled band contributes nothing) and matches on its `Result`:
  an unclassifiable override makes it write EMPTY public content rather than fail the index write
  or index unredacted text. `Repository::search` takes `doc_types: &[String]` — an `AND doc_type IN
  (...)` filter over the `doc_type UNINDEXED` FTS column (both `documents_fts_public`/
  `documents_fts_gm`), built via a `sqlx` query builder with a per-value bound parameter, capped at
  `data::search::MAX_SEARCH_DOC_TYPES` (16) — checked ONCE at WS ingress (`ws::conn`'s
  `ClientMsg::Search` arm, which gates both the one-shot query and the `Egress::Subscribe`
  send) ahead of the repository's own check, as defense-in-depth. A caller narrows results to specific doc types; it does not change what is
  indexed.
- `data::repository`/`data::validation` — `Repository` trait (storage seam; SQLite today, Postgres-capable later) +
  structural validation (size caps, field-path validity, `deny_unknown_fields`); `data::validation`
  applies the same `MAX_SYSTEM_BYTES` (256 KiB) cap to `engine` as to `system`, checked
  independently per block. `base` gets the SAME independent size cap
  (`validate_system_size`'s cap function, shared across all three blocks) AND is walked by
  `validate_engine_tree`: the walker shape-checks the `MergeBase`/`EmbeddedBaseChild` structure
  recursively (`validate_base_node`/`check_base_node_shape` — every band key present, the
  recorded policy key present under the node's spelling (`base_policy_key`: an absent map would
  read as "nothing hidden", the fail-open direction for the egress reader) with every entry
  naming a mergeable band (`writes_a_content_band`) and carrying a `Visibility` tier, an
  embedded record carrying a string `sourceId`, no unknown keys) and normalizes each `engine`
  band inside it under the owning doc_type — the root's own for the root record, and for an
  embedded base child the doc_type of the LIVE embedded child its `sourceId` correlates to
  (`snapshot_base`'s keying); a record with no live counterpart is shape-checked only, never
  normalized, because it is historical. Validation is ingest-time, so a legacy stale-schema
  `base` is re-validated only when the document is rewritten.
  `data::validation::validate_document_name(name: &Option<String>)` caps `Document.name`'s UTF-8
  byte length at `data::validation::MAX_DOCUMENT_NAME_BYTES` (512) — the ONE envelope field exempt
  from the three-block (`system`/`engine`/`base`) caps above, since it lives outside all of them;
  folded into `validate_system_size` as its first statement, so it runs at all 4
  `validate_system_size` call sites (Create and Update post-image, top-level and embedded) with no
  new chokepoint. `data::validation::validate_document_id(id)` rejects a `Document.id` that is not
  a v4 (random) or v7 (timestamp+random) UUID (format-only, via the `uuid` crate's own version
  query); `validate_document_id_tree(doc)` recurses it over `doc` and every
  embedded descendant, run at FOUR ingress points, not one. At BOTH authoritative Create paths
  (`data::sqlite::apply_command`'s Create arm and `apply_intent`'s validation pass, in its Create-op
  block) it is wired immediately BEFORE `validate_property_overrides`. **An Update DOES revisit
  ids** — `apply_intent`'s `Operation::Update` arm re-runs it over the MERGED post-image, in
  lockstep just before `validate_engine_tree` (after `validate_system_size`/
  `validate_property_overrides` re-check the merge result): a whole-collection embedded-child
  replacement, or an Update that adds an embedded child wholesale, introduces a child id this
  chokepoint has never checked before, so the Create-only framing does not hold for the recursion
  shape as a whole. `SqliteRepository::import_world` also runs it over every imported row (a
  bundle is untrusted input, same posture as a live Create/Update), alongside its own
  `validate_system_size`/`validate_property_overrides`/`validate_engine_tree` calls. Every
  server-generated id in the tree already uses `Uuid::new_v4()`, so the check
  touches no production id-generation path — it rejects only a CLIENT-supplied
  v1/nil/other-version id (or, on Update/import, one introduced via an embedded child). Every
  test fixture that becomes a `Document.id` must therefore be v4-shaped: `crate::test_ids::
  test_uuid(n)` (`#[cfg(test)]`-only, `src/server/src/test_ids.rs`) and
  `shadowcat_test_support::test_doc_id(n)` reproduce `Uuid::from_u128(n)`'s low-order bytes while
  forcing the version/variant nibbles to v4/RFC4122 — the standard replacement for a bare
  `Uuid::from_u128(n)` anywhere the result becomes a `Document.id` (a `request_id`/`message_id`
  correlation id compared against a hardcoded wire-format string literal is NOT a `Document.id`
  and is deliberately left as plain `Uuid::from_u128`).
