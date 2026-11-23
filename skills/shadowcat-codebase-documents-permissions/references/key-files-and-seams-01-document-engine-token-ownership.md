Part of the shadowcat-codebase-documents-permissions skill; read it when touching data::document, data::engine, token ownership or the derived vision and footprints channels. Part 01 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

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
    classifier invariant in references/hard-invariants-detail-02-redaction-and-read-transition.md). A client-origin post-image carrying `base` on an embedded child is
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
  `is_engine_doc_type(doc_type) -> bool` (membership in `ENGINE_DOC_TYPES`, the one 31-entry
  registry slice — token, scene, wall, region, light, drawing, template, actor, message,
  world-settings, vision-modes, light-gradation, chat-settings, dice-settings, channel-registry,
  faction-registry, condition-registry, combat, combatant, resource-registry, effect,
  system-defaults, combat-history, combatant-group, asset_folder, table_folder, table, note,
  playlist, audio-state, module-settings; `search_text`'s match must stay
  in sync with it — the combat family
  plus `system-defaults`, see `shadowcat-codebase-combat`; `table` (rollable tables) is
  never embedded and may be filed only under a `table_folder` (see
  references/engine-ingress-and-redaction-additions.md), while `note` forms its OWN `parent_id` tree of notes
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
