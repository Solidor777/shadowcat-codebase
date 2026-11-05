# Hard invariants: detailed bullets

Part of the shadowcat-codebase-documents-permissions skill; read it when changing redaction, gm_role, Document.base egress, band classifiers or per-recipient broadcast transitions.

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
- **`/base`'s egress is decided at ONE site, `own_overrides`, by THREE rules: an unconditional
  `OwnerOrGm` floor on the whole band, a further whole-band `GmOnly` floor when the recorded
  `owner_standing` is `Stranger`, and inside whichever floor stands, the policy the snapshot
  itself records, related to that standing.** Every reader — `filter_properties` (whole-document
  egress), `collect_hidden`/`redact_change` (the change-delta path, at every embedded depth) and
  the merge oracle (`RequesterView`) — reads `own_overrides` through
  `hidden_own_pointers`/`collect_overrides`; there is no second `/base` decision site. The
  `OwnerOrGm` floor is not driven by the document's `property_overrides` (a doc author cannot
  loosen it — there is no override to set; `validate_property_overrides` admits a `/base…` key
  only when it names CONTENT inside the snapshot — `is_base_content_residual` restricts a
  `/base` residual to `name`/`engine`/`system`, at the root or through valid
  `/embedded/<coll>/<idx>` hops, refusing a pointer naming the snapshot's own structural keys
  (`embedded`, the recorded policy map, `sourceId`, `owner_standing`) so an override can never
  corrupt the shape egress relies on — and `recorded_overrides` ignores an admitted `/base…` key
  as a band policy). The SECOND floor is new: the stored value
  is `StoredBase { snapshot, owner_standing }`, where `owner_standing: OwnerStanding`
  (`Stranger`/`Reader`/`Owner`, `permission::owner_standing`) is the instance owner's standing on
  the TEMPLATE at the write that stored the snapshot; a `Stranger` (the owner holds no
  whole-document READ on the template) makes `base_policy` emit the bare `/base` pointer at
  `GmOnly` before reading a single recorded entry — closing a gap where an instance whose owner
  cannot read its own template still leaked the template's content through `/base`. Inside a
  non-`Stranger` standing, `base_policy` emits one `/base{pointer}` (or
  `/base/embedded/<coll>/<k>{pointer}`, recursing into records at their SNAPSHOT positions) entry
  per entry of the stored snapshot's `property_overrides` / a record's `propertyOverrides` — the
  template's mergeable-band policy at sync time, recorded VERBATIM (never re-expressed at record
  time) but RELATED to the standing on read (`OwnerStanding::relate`): a recorded `OwnerOrGm`
  entry — naming the TEMPLATE owner's tier — stands only under `Owner`, else reads as `GmOnly`
  for this purpose; every other tier is unaffected. This is load-bearing: `base` is the FULL
  template snapshot, which carries content the template's own overrides hide from this same
  recipient — an `Owner`-standing instance owner receives it minus exactly what the template hid
  (its `OwnerOrGm` entries included), a `Reader`-standing owner additionally loses the template
  owner's `OwnerOrGm` content, a GM receives it whole, a `Stranger` receives nothing, with no
  template lookup on the egress path and no dependence on the instance's live children (a record
  whose instance child was deleted locally stays covered by its own recorded policy). Fail-closed:
  a recorded tier that does not parse, a recorded pointer naming no mergeable band, or a root
  lacking a parseable `owner_standing` is a `RedactionError`, and the ingest walk admits none of
  these. `own_overrides` reads the stored `/base` value through `merge::bands::StoredBase`'s
  typed deserializer (never raw JSON) before walking it via `base_policy`/`base_policy_child` —
  because `StoredBase`/`MergeBase`/`EmbeddedBaseChild` carry no field defaults, a missing
  structural key (an absent policy map, an absent `embedded` map, a non-object node) fails the
  deserialize and reads as a corrupt `/base` rather than "nothing hidden": the same
  fail-typed-deserializer rule this skill's `base` seam states for `compute_pull`/
  `plan_to_update` applies here too, closing the same class of gap for the read path that
  computes egress redaction rather than the read paths that compute a merge. The client's
  `syncState` depends on the SNAPSHOT half of this cut agreeing with the
  template's own (the recorded `owner_standing` is an access fact the client never compares — see
  `shadowcat-codebase-templates`): it reads the stored base through `normalizeBase`, which reads a
  redaction-stripped content band (`name`/`engine`/`system`) as `null` — matching a nulled hidden
  band on the live template — while treating an absent structural key (`embedded`, the policy map,
  a record's `sourceId`, never themselves redacted) as malformed rather than coalescing it. Since
  the recorded policy is now verbatim, `syncState` compares it key for key like every other part of
  the snapshot rather than excluding it.
- **Redaction operates on content bands, never on the structural envelope — and ingress and egress
  read ONE classifier each, never agree by inspection.** `data::permission::REDACTABLE_BANDS:
  [&str; 4]` (`name`, `engine`, `system`, `base`) is the ONE statement of the EGRESS band set:
  whole-document egress (`filter_properties`) and the change-delta broadcast path
  (`collect_hidden`) both derive from it via `redaction_target`, so the delta path cannot diverge
  from whole-document egress. The WRITE side reads `WRITABLE_BANDS: [&str; 3]` (`name`, `engine`,
  `system`) via `writes_a_content_band` — a strict subset stated separately ON PURPOSE: `base` is
  redactable but never client-writable (server-owned, see the `base` seam in references/key-files-and-seams.md), and the
  asymmetry is a visible decision rather than one constant two sides read for different
  meanings. Adding a band therefore means deciding both lists explicitly; a band added to only
  one is either unredacted-but-writable or redacted-but-unwritable, and which of those is
  intended must be stated. A second symbol is shared the same way:
  `band_has_interior`, the leaf rule stating that `name` is a display string with no interior.
  The residual-segment rule is NOT shared by symbol — `required_cap_for_path` classifies a
  `FieldChange` path, `redaction_target` classifies a `property_overrides` map key, different
  fields on different structures behind different validators, so they are not required to agree
  string-for-string in general — but on one input they now agree in effect: `writes_a_content_band`
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
  `schema_version`, `source`, `owner`, `permissions`, `parent_id`, `embedded`, `created_at`,
  `updated_at`) — AND any pointer descending into a LEAF band, since `band_has_interior` gives
  `name` no interior. So `/name` classifies `Band` while `/name/first` classifies `None` and is
  REJECTED at ingress: an override naming a sub-path of `name` is not authorable at all.
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
