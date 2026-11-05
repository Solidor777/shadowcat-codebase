# Key files and seams

Part of the shadowcat-codebase-documents-permissions skill; read it when touching any file or seam under src/server/src/data or its client wire mirror.

## Key files & seams

- `data::document` — the `Document` envelope: `name: Option<String>` (universal
  display name, `#[serde(default)]`) and `engine: Option<serde_json::Value>` (`#[ts(type =
  "unknown")]`, present iff `doc_type` is engine-defined) alongside the `system`
  body; `enum Visibility { All, GmOnly, OwnerOrGm }` (the per-property visibility tiers);
  `PermissionSet.gm_role: Option<DocRole>` (`#[serde(default)]`, ts-rs exported) — see Hard
  invariants in SKILL.md and references/hard-invariants-detail.md.
  - `base: Option<serde_json::Value>` (`#[serde(default)]`, `#[ts(type = "unknown")]`) —
    the value stored is `merge::bands::StoredBase` (the `MergeBase` snapshot of the TEMPLATE as
    of the instance's last sync, flattened, plus `owner_standing: OwnerStanding` — the instance
    owner's standing on the template at the write that stored it, `permission::owner_standing`):
    ONE canonical, FULL, unredacted snapshot per instance — bands plus the template's
    mergeable-band policy recorded alongside VERBATIM (`MergeBase::property_overrides`,
    `EmbeddedBaseChild::property_overrides` spelled `propertyOverrides` on a record; the
    `writes_a_content_band` set, never re-expressed) — the snapshot itself is never relative to
    the seat that wrote it. SERVER-OWNED: a `Create` derives it from the document's own validated
    bands (`merge::bands::derive_create_base` in `apply_intent`'s Create arm — any client-supplied
    value is discarded, no `source` → `null`, embedded children never carry one), after loading
    the template (a same-batch Create is consulted first; an other-world template reads as
    absent) to land its policy on the new instance VERBATIM
    (`merge::bands::propagate_overrides`, additive: a pointer lands only where the instance holds
    no entry, an instance-authored entry is never removed or widened, and a recorded
    `Visibility::All` is skipped as a no-op audience) and to resolve the owner's standing on the
    template (`permission::owner_standing`, `OwnerStanding::Stranger` when no template loads).
    The ONLY writer afterwards is a server merge under `WriteOrigin::TemplateMerge`, whose
    whole-band `/base` refresh (`StoredBase { snapshot: snapshot_base(template), owner_standing }`
    — the FULL template's CURRENT snapshot, under the standing THIS write resolved) is the single
    server-owned field write `apply_intent`'s capability gate lets through (`/base/...` sub-paths
    stay rejected for every origin); the same write carries the propagated policy as a
    `/permissions/property_overrides` change, which `merge_intents::update_authorized` exempts
    beside `/base` because it can only narrow an audience. `data::permission::required_cap_for_path`
    maps `/base` to NO capability — the same posture as `/source` — because the write side reads
    `WRITABLE_BANDS` (`name`/`engine`/`system`), from which `base` is absent by design (see the
    classifier invariant in references/hard-invariants-detail.md). A client-origin post-image carrying `base` on an embedded child is
    rejected fail-closed before the shape walks (`merge::bands::embedded_carries_base`).
    `/source` (the sibling field naming what a document is an instance OF) stays
    unmapped/immutable — `required_cap_for_path` returns `None` for it, so no write path can
    ever re-target an existing document at a different template. The merge engine itself, and the
    `OwnerStanding` mechanism `/base`'s OWN egress evaluates the recorded policy under: see
    `shadowcat-codebase-templates`.
  - `world_of(doc: &Document) -> Option<Uuid>` (`pub(crate)`) — the single chokepoint for
    "which world does this doc scope to" (`Scope::World { world_id } => Some(world_id)`,
    `Scope::Compendium => None`). Two call shapes: (1) a caller that already knows the world it
    scopes to PINS a doc reference by comparing `world_of(&doc)` against that known `world_id` —
    `ws::scene_broadcast_permitted` (refuses a scene doc from another world even for a
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
- **`data::engine::geometry::validate_hex_color(color)`/`validate_asset_ref(asset)`** are the ONE
  shared shape check for every colour-typed and asset-reference-typed engine field respectively —
  `validate_hex_color` requires exactly `#` + 6 hex digits (the only syntax `<input
  type="color">` ever emits; every client colour-authoring path in the tree uses that input), and
  `validate_asset_ref` requires a well-formed UUID string (`data::asset::Asset.id: Uuid`), FORMAT
  ONLY — it never queries the repository, so a dangling ref is a read-time "no asset" concern, not
  an ingress rejection. Every colour/asset field's own `.validate()` calls the shared
  function: `GeneratedBorder`/`GeneratedBackground`/`Stroke`/`Fill` (the last two via
  `DrawingEngine::validate`), `EnvironmentLight` (via `SceneEngine::validate` and
  `SceneDefaultsOverlay::validate`, shared by `SystemDefaultsEngine`/`WorldSettingsEngine`),
  `Faction.color` (`FactionRegistryEngine::validate`), `TemplateEngine.color`, `LightEmission.color`
  for colour; `TokenVisual::Image.asset`, `RenderVisual::Image.asset`, `AnimatedSource::
  Frames.frames`, `AnimatedSource::Sheet.asset`, `SoundEmission.asset`, `VfxEmission.asset`,
  `SceneEngine.background`, `SceneLevel.background` (per-level, via `validate_levels`),
  `PortalTarget.vfx`, `PlaylistTrack.asset` (`PlaylistEngine::validate`, per track), `PlayingTrack.
  asset` (`AudioStateEngine::validate`, per `playing` entry) for asset refs, wired
  into `TokenEngine::validate`/`TokenOverrides::validate`/`ActorEngine::validate` (the last
  unconditionally, since `visual` is required there) — see `shadowcat-codebase-actors-tokens` for
  the token/actor fields' own shapes and `shadowcat-codebase-audio` for the playlist/audio-state
  fields (fixture convention: a real UUID string, never a placeholder like `"a1"`).
- `data::engine` — the typed `engine`-band structs + the ingress-validation
  registry, one submodule per doc-type family (`data::engine::token`, `data::engine::scene`,
  `data::engine::geometry`, `data::engine::registries`) plus the `data::engine` module itself:
  `is_engine_doc_type(doc_type) -> bool` (membership in `ENGINE_DOC_TYPES`, the one 26-entry
  registry slice — token, scene, wall, region, light, drawing, template, actor, message,
  world-settings, vision-modes, light-gradation, chat-settings, dice-settings, channel-registry,
  faction-registry, condition-registry, asset_folder, table, note, combat, combatant,
  resource-registry, effect, system-defaults, combat-history; `search_text`'s match must stay
  in sync with it — the combat family
  plus `system-defaults`, see `shadowcat-codebase-combat`; `table` (rollable tables) is
  standalone, never embedded/parented, while `note` forms its OWN `parent_id` tree of notes
  (never embedded, but — unlike `table` — MAY carry a parent), see
  `shadowcat-codebase-tables-notes` for both engine bodies and `note`'s
  `data::sqlite::notes::check_note_parent` placement check),
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
  **A server-DERIVED engine path rides the Update as an extra `FieldChange`.** A normalize-time
  derivation (today only `NoteEngine::derive_body` → `/engine/body`) rewrites a key none of the
  op's own `changes` named; `data::engine::derived_engine_paths(doc_type)` is the registry of
  those paths (any `derive_*` call added to `normalize_engine`'s match MUST register there), and
  `data::validation::derive_engine_side_effects` emits one `FieldChange` per registered path that
  no requested path overlaps (`permission::paths_overlap` — equal/ancestor/descendant), comparing
  the TRUE stored pre-image (captured before the op's own `apply_field_change` loop) against the
  normalized post-image with `command::values_semantically_eq`, so normalization noise (an int
  round-tripping to `f64`) never emits. Both Update arms append the result to the normalized
  `changes`, so the returned `Command`, `world_events`, and the broadcast carry it. In
  `apply_intent`, for every origin that does not `skips_capability_gates`, the derived paths are
  capability-gated BEFORE any write:
  the validation pass records one resolved `Access` per Update op, the apply pass consumes them in op order and
  checks `declared_caps_for_path` for each derived path (fail-closed `Forbidden`); the trusted
  `apply_command` arm skips that check exactly as it skips every capability gate.
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
- **A scene with declared floors adds a LEVEL dimension to the `"vision"`/`"footprints"` derived
  channels, alongside (never in place of) the existing ownership/tier conjuncts above — but the
  level SCOPING happens in three different places, not one, and none of them is `apply_intent`
  (which has no elevation awareness at all).** The movement/placement GATES — `Room::execute_move`,
  `Room::publish`'s Create placement gate, and `SceneEcs::pathfind` — are what consult
  `scene::elevation::level_of` (via `SceneEcs::visible_cells`/`visible_cells_cached`, level-scoped
  to the mover's own floor), never `apply_intent`. `"vision"`'s `compute_derived` arm computes and
  returns ALL levels' polygons/lit-cells in one payload, each group individually tagged with its
  own `level` (the same multi-scope pattern `"footprints"` and `"audibility"` use) — the server
  does not filter to one floor server-side; the CLIENT filters to the viewed level at render time
  (`RenderEngine.toVisibility`/`toLighting`, matching `polygons`/`lit` groups on
  `scene === activeScene && level === viewedLevel`). `SceneSubscribe.level` is consumed only by
  `enrich_vision_explored`, which uses it to select which floor's persistent EXPLORED-FOG memory
  gets echoed into the payload's `explored` key — a narrower scope than "what `\"vision\"`
  computes." `"footprints"` is not itself level-scoped by subscription — its per-token entries
  instead carry their own resolved `level`, redacted by ABSENCE exactly like every other
  footprints-entry field (see the `TokenFootprint.level` bullet below for what that absence does
  and does not mean). Full mechanism (the derived-channel egress rule the level dimension composes
  with, and the per-token `token_footprint_visible` gate it must NOT bypass):
  `shadowcat-codebase-scene-rendering`.
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
    ownership" bullet above for why there is no internal `doc.owner` fallback.
  - `effective_role` — the shared floor-resolution helper both `resolve_access` and
    `resolve_access_world` call, taking the SAME `user`/`world_role`/`doc`/`effective_owner`
    parameters; `None` means the unconditional
    GM/admin short-circuit applies (see `gm_role` invariant in references/hard-invariants-detail.md), `Some(role)` means the caller
    must resolve capabilities from that per-document role floor like any other actor.
    **Its ownership floor (`effective_role::owner_floor`) is scoped to `TOKEN_DOC_TYPE` and NO
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
    stated in exactly one place — see the redaction-classifier invariant in references/hard-invariants-detail.md.
    `/base` takes the whole-band treatment as an unconditional `OwnerOrGm` floor, and INSIDE it
    every pointer the snapshot's own recorded policy names is hidden at the recorded tier — see
    the `base` egress invariant in references/hard-invariants-detail.md. The hidden-pointer list itself is
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
  every STRING **and NUMBER** leaf of the `system` body ONLY (the `engine` band is no longer
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
  folded into `validate_system_size` as its first statement, so it runs at all 4 pre-existing
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
  server-generated id in the tree already uses `Uuid::new_v4()`, so this closes an ingress gap
  without touching any production id-generation path — it rejects only a CLIENT-supplied
  v1/nil/other-version id (or, on Update/import, one introduced via an embedded child). Every
  test fixture that becomes a `Document.id` must therefore be v4-shaped: `crate::test_ids::
  test_uuid(n)` (`#[cfg(test)]`-only, `src/server/src/test_ids.rs`) and
  `shadowcat_test_support::test_doc_id(n)` reproduce `Uuid::from_u128(n)`'s low-order bytes while
  forcing the version/variant nibbles to v4/RFC4122 — the now-standard replacement for a bare
  `Uuid::from_u128(n)` anywhere the result becomes a `Document.id` (a `request_id`/`message_id`
  correlation id compared against a hardcoded wire-format string literal is NOT a `Document.id`
  and is deliberately left as plain `Uuid::from_u128`).
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
  system-defaults/chat-settings/dice-settings/channel-registry/light-gradation/vision-modes —
  all ten config singletons, the same set `world_seed`'s `CONFIG_SINGLETON_DOC_TYPES` seeds,
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
    `index_content` composes (see the `data::search` seam above): the envelope `name`,
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

