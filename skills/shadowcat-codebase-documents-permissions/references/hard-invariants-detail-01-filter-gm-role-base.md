Part of the shadowcat-codebase-documents-permissions skill; read it when changing filter_properties, gm_role or Document.base egress. Part 01 of 02 of "Hard invariants: detailed bullets"; the index is hard-invariants-detail.md.

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
