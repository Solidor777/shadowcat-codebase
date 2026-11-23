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
opaque `system` JSONB body whose meaning the engine never decides (it evaluates engine-grammar
formulas over leaves a formula names — see `shadowcat-codebase-formula`). Permissions are enforced
server-side **per recipient**: hidden fields are stripped before transmission, never
sent-then-hidden. This subsystem also owns the visibility-partitioned full-text index.

## Reference files

| File | What it holds | Read it when |
|---|---|---|
| references/key-files-and-seams.md | The full Key files & seams section: `data::document`, `data::engine`, `data::permission`, `data::search`, `Repository`/validation, `apply_intent` and its `WriteOrigin`s, the client `wire` mirror, snapshots, role caps. | Touching any file or seam in `src/server/src/data` or its client wire mirror, or looking up where something lives. |
| references/hard-invariants-detail.md | The long Hard-invariant bullets: `filter_properties`, `gm_role`, `/base` egress, envelope-vs-content-band redaction, the whole-document READ transition. | Changing redaction, `gm_role`, `Document.base` egress, band classifiers, or replay/broadcast transitions. |
| references/gotchas.md | The full Gotchas section. | Before finishing any change in this subsystem, or when something here behaves unexpectedly. |

## Key files & seams

Covers every file and seam of the document model and redaction layer: the `Document` envelope and `base` field, `data::engine`, `data::permission`, `data::search`, the `Repository` trait, `apply_intent` and its `WriteOrigin` capability-skips, snapshots, and the client `wire` mirror. Read references/key-files-and-seams.md before changing anything under `src/server/src/data` or the `src/client/core` wire types.

## Hard invariants

- **`audio-state`'s Create/Delete and Update are guarded by DIFFERENT `WriteOrigin`s — the one
  per-operation split guard in the codebase, rather than a single uniform origin per doc_type.**
  Create/Delete are `WriteOrigin::ConfigSeed`-only (seeded once by `world_seed`, never
  client-reachable), while Update runs under `WriteOrigin::AudioTransport`
  (`audio::transport::handle_transport`'s GM-gated commit via `apply_intent`). A uniform
  single-origin guard was tried during design and is a documented spec contradiction — do not
  "simplify" it back to one origin. Precedent for a future doc_type with the same "seeded once,
  mutated by a different trusted path thereafter" shape; see `shadowcat-codebase-audio`.
- **Redaction is fail-closed and owner-aware.** `can_see` is the one chokepoint across every
  egress path; a partial-visibility tier (`OwnerOrGm`) uses a distinct flag — never overload the
  GM see-all boolean, or you leak `GmOnly` to owners [[ownerorgm-tier-no-widen]].
- **`filter_properties` is a PROPERTY-visibility gate, NOT a whole-document READ gate.** Read references/hard-invariants-detail-01-filter-gm-role-base.md (the `filter_properties` bullet) before touching it.
- **`PermissionSet.gm_role: Option<DocRole>` makes the GM usual unconditional access conditional, per document.** Read references/hard-invariants-detail-01-filter-gm-role-base.md (the `gm_role` bullet) before touching it.
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
  otherwise up-to-date write). See the `data::sqlite` seam entry in references/key-files-and-seams-03-apply-intent-wire-snapshots-caps.md for the exact comparison rule.
- **The `/base` egress is decided at ONE site, `own_overrides`, by THREE rules.** Read references/hard-invariants-detail-01-filter-gm-role-base.md (the `/base` bullet) before changing `Document.base` egress.
- **Tier-2 validates the `system` band's SHAPE only, never values — it EXTENDS the three-band
  document shape, it does not replace it.** `engine`-band validation
  (`validate_engine`/`validate_engine_tree`) remains the separate REAL semantic
  ingress gate for the 23 engine-defined doc types (see the `engine ingress validation` invariant
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
- **Redaction operates on content bands, never on the structural envelope; ingress and egress each read ONE classifier.** Read references/hard-invariants-detail-02-redaction-and-read-transition.md (the envelope and content-band bullet) before changing redaction, `REDACTABLE_BANDS` or band classifiers.
- **Path-prefix authz covers ancestor (subtree-replacing) writes AND whole-doc Create**, not just
  descendant field updates [[path-prefix-authz-covers-ancestor-and-create]].
- **The singleton create-gate must close BOTH cross-call and intra-batch duplicate-`Create` races,
  via two independent mechanisms.** A tx-scoped DB existence check alone is sufficient for
  cross-call races (serialized by the single-writer pool) but NOT for two same-doc_type Creates
  inside one `apply_intent` batch, since the validation pass validates every op before the apply pass inserts any of
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
- **A recipient whole-document READ transition on an `Update` synthesizes a Create or a stub Delete.** Read references/hard-invariants-detail-02-redaction-and-read-transition.md (the last bullet) before changing per-recipient broadcast filtering.

## Gotchas

Pitfalls of this subsystem: migration, OCC pre-images, raw ownership as a write-capability proxy, docs-ratchet, generated wire types, deep clones, test harness, `filter_command`, `created_seq`. Read references/gotchas.md before finishing any change here.

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
  worked `property_overrides` example this skill's `collect_overrides` gotcha (references/gotchas.md) warns about:
  `chat::roll_property_overrides` computes GM-only `property_overrides` entries for a
  `RollEmbed`'s `spec`/`raw`/`recalc_history[].previous_raw` fields (and, recursively, a
  `TableDrawSegment`'s own `spec`/`raw` at every nesting depth), and the `WriteOrigin::
  ServerMessageRevision` exact-path admission for writing `/permissions/property_overrides`
  (an origin/doc_type/path-scoped extension of the general `apply_intent` access-grant
  mechanism in references/key-files-and-seams-03-apply-intent-wire-snapshots-caps.md, with no other consumer) is documented there rather than here, same
  ownership split as `gm_role`.
- `shadowcat-codebase-templates` — the client-side 3-way merge engine + `TemplatesController`
  that produces/consumes `base`; this skill owns only the server-side field/authz/redaction/size
  facts in references/key-files-and-seams.md and references/hard-invariants-detail.md.
