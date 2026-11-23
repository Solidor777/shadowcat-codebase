Part of the shadowcat-codebase-documents-permissions skill; read it when changing redaction, band classifiers or per-recipient broadcast transitions. Part 02 of 02 of "Hard invariants: detailed bullets"; the index is hard-invariants-detail.md.

- **Redaction operates on content bands, never on the structural envelope — and ingress and egress
  read ONE classifier each, never agree by inspection.** `data::permission::REDACTABLE_BANDS:
  [&str; 4]` (`name`, `engine`, `system`, `base`) is the ONE statement of the EGRESS band set:
  whole-document egress (`filter_properties`) and the change-delta broadcast path
  (`collect_hidden`) both derive from it via `redaction_target`, so the delta path cannot diverge
  from whole-document egress. The WRITE side reads `WRITABLE_BANDS: [&str; 3]` (`name`, `engine`,
  `system`) via `writes_a_content_band` — a strict subset stated separately ON PURPOSE: `base` is
  redactable but never client-writable (server-owned, see the `base` seam in references/key-files-and-seams-01-document-engine-token-ownership.md), and the
  asymmetry is a visible decision rather than one constant two sides read for different
  meanings. Adding a band therefore means deciding both lists explicitly; a band added to only
  one is either unredacted-but-writable or redacted-but-unwritable, and which of those is
  intended must be stated. A second symbol is shared the same way:
  `band_has_interior`, the leaf rule stating that `name` is a display string with no interior.
  The residual-segment rule is NOT shared by symbol — `required_cap_for_path` classifies a
  `FieldChange` path, `redaction_target` classifies a `property_overrides` map key, different
  fields on different structures behind different validators, so they are not required to agree
  string-for-string in general — but on one input they agree in effect: `writes_a_content_band`
  requires a non-empty segment past the band separator, so `/system/` is unclassifiable at both,
  the same way `redaction_target`'s own `!tail.is_empty()` guard already refused it. `/base/system/`
  agrees with the sibling top-level `/system/` for the same reason (`is_base_content_residual` is
  derived from `writes_a_content_band`).
  `redaction_target(pointer) -> Option<RedactionTarget>` returns `Band` (the pointer names a whole
  band — null the field in place, never strip the key), `Within` (the pointer descends into a band,
  landing inside untyped `serde_json::Value` or an `Option`, never a required struct field — which
  is what makes the removal provably non-destructive to deserialization), or `None`
  (unclassifiable). `None` covers two distinct populations, and the second one bites at authoring
  time: everything outside the band set — the structural remainder (`id`, `scope`, `doc_type`,
  `schema_version`, `source`, `owner`, `permissions`, `parent_id`, `created_at`, `updated_at`,
  and `embedded` when the pointer names the whole map, a collection or a whole child) — AND any
  pointer descending into a LEAF band, since `band_has_interior` gives
  `name` no interior. So `/name` classifies `Band` while `/name/first` classifies `None` and is
  REJECTED at ingress: an override naming a sub-path of `name` is not authorable at all. A pointer
  through valid `/embedded/<coll>/<numeric idx>/` hops classifies by what it names inside that
  child (`/embedded/actor/0/name` is `Band`, `/embedded/actor/0/engine/faction` is `Within`);
  see references/engine-ingress-and-redaction-additions.md ("Embedded actor copies").
  - **`/base`'s interior does NOT get the ordinary "any residual is `Within`" treatment.**
    `base`'s content is not an arbitrary untyped tree — it is a `merge::bands::MergeBase`/
    `EmbeddedBaseChild`, a shape with its own required structural keys
    (`validation::check_base_node_shape` enforces them at every depth) — so `redaction_target`
    additionally runs `is_base_content_residual` on any `/base` residual: it strips zero or more
    `/embedded/<coll>/<idx>` hops (each hop needs BOTH segments to keep descending) and requires
    what remains to match `writes_a_content_band`. A pointer landing on `embedded` itself, the
    recorded policy map, a record's `sourceId`, or the root's `owner_standing` fails this test
    and classifies `None` (refused at ingest by `validate_property_overrides`), because stripping
    any of those via `Within`'s ordinary object-key-removal terminal step would corrupt the shape
    a compliant `/base` reader relies on — closing a write-side hole where a GM holding
    `cap::EDIT_PERMISSIONS` could otherwise author an ordinary document override naming a
    structural `/base` key, which would strip that key from a recipient's stored snapshot at
    egress and make a valid copy read as malformed on the client's `normalizeBase`.
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
- **A recipient's whole-document READ transition on an `Update` synthesizes a Create or a stub
  Delete, for EVERY doc type, not just combat.** A
  `/owner` or `/permissions/default` write that flips one recipient's whole-document
  `cap::READ` (denied→granted, or granted→denied) would otherwise produce only the ordinary field-delta `Update`
  redaction — a recipient gaining READ would get a diff against a document they never had, which the
  client silently no-ops on an unknown `doc_id`; a recipient losing READ would keep their stale last-seen
  copy forever. `filter_command`'s `Operation::Update` arm resolves each op's own
  before→commit transition and, when it grants READ, synthesizes a `Create` of the filtered
  current document (still gated by the ordinary current-time `cap::READ` check, same fail-closed
  posture as every other branch); when it revokes READ, synthesizes a stub `Delete` (`delete_stub`
  — identity/placement fields only, every content band and `permissions` emptied) so nothing
  hidden rides the retraction. The BEFORE half resolves against two commit-time snapshot
  fields, `OpSnapshot.permissions_before_commit`/`OpSnapshot.owner_before_commit`
  (`#[serde(default)]`, so a stored row without them falls through to the ordinary
  field-delta path unchanged) — both captured at the same pre-image load point by `apply_command`
  and `apply_intent`'s snapshot-building loops, in lockstep so the two can never desync.
  `owner_before_commit` matters beyond a same-op `/owner` write: `effective_role`'s ownership floor
  grants whole-document READ from ownership alone, so `TOKEN_DOC_TYPE` reassignment is a READ
  transition too, and the BEFORE half must use the PRE-image owner: the POST-image owner would
  make that class of transition structurally invisible. Multiple `Update`s to the
  same `doc_id` in one `Command` resolve the identical transition (the snapshot fields are
  captured once per `doc_id`, not per op) but must synthesize exactly once: only the LAST such op
  actually emits; every earlier one is dropped outright, never falling through to the ordinary
  field-delta path (whose assumptions about the recipient's existing access are exactly what a
  genuine transition violates for every op before the one that delivers it). First consumer:
  `shadowcat-codebase-combat` (a hidden combatant's owner needs the reveal/hide to arrive live,
  not on the next resync), but the mechanism lives entirely in this subsystem and applies identically to
  every doc type.
