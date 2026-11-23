# Gotchas

Part of the shadowcat-codebase-documents-permissions skill; read it before finishing a change in this subsystem.

## Gotchas

- **`data::migrate::migrate` has no production caller.** Schema versioning is `CURRENT_SCHEMA_VERSION`
  alone (read by `combat::history`); the repository schema migrates through `sqlx::migrate!` in
  `SqliteRepository::connect`.
- **OCC pre-images in one `apply_intent` batch are checked against the PRE-BATCH stored value,
  never against a sibling op's `new`.** The validation pass loads each op's current document with its own
  `load_document` read of the not-yet-written tx and applies no intra-batch simulation of an
  earlier op's changes (the only intra-batch state it tracks is the one-active-combat-per-scene
  and singleton bookkeeping), so a second `Operation::Update` to the same document whose `old` names the
  first op's `new` is a `Conflict`. Batches are atomic snapshots; the client coalesces
  same-document edits into ONE Update via `buildUpdate`'s `FieldEdit[]`, never two chained ops.
- **RAW OWNERSHIP IS AN UNSAFE PROXY FOR WRITE CAPABILITY ON EVERY DOC TYPE BUT `TOKEN_DOC_TYPE`,
  and a hand-rolled `permissions.default` test is an unsafe proxy for READ on ALL of them.**
  `doc.owner == Some(user)` (or `Access::is_owner`) answers "who owns this", never "may they write
  it": `holds_token_owner_floor` is scoped to `TOKEN_DOC_TYPE`, so on any other doc type the
  owner gets no role floor and can hold `cap::READ` without `cap::WRITE_FIELDS`. Symmetrically,
  `permissions.default` answers a WORLD-DEFAULT question, and a `permissions.users` entry moves the
  real per-caller answer in BOTH directions — `default: none` + `users[player] = Owner` is readable
  by that player, `default: observer` + `users[player] = None` is not. Every substitution of one of
  these proxies for the real authority produces the same paired defect: an authorization/
  enforcement HOLE in one direction and a refusal or disclosure in the other, with the code
  reading perfectly sensible at the site. **The real checks are `resolve_access_world`
  (whole-document `cap::READ`, ownership, capabilities — all off ONE resolution) and
  `required_cap_for_path` (the single statement of the write-path→capability mapping, which
  `apply_intent` itself consults).** Read them; never restate either as a literal or a predicate.
  This is the same never-fork class the core skill names, specialized to authz, and it is the
  reason `SceneEcs::ctx_access`, `combat::combatant_access` and `filter_command` all resolve
  through the identical pair rather than each answering locally.
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
  reasoning about `apply_intent`'s validation-pass conflict check must account for
  `values_semantically_eq`'s numeric-variant awareness — see the Hard invariants entry in SKILL.md and
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
  invariant in SKILL.md.
- **`documents.created_seq` is set once, at a document's genuine first INSERT.**
  `SqliteRepository::upsert_document`'s `ON CONFLICT(id) DO UPDATE` clause omits `created_seq` from
  its column-update list, so a subsequent update to the same row never touches it — it is the sole signal
  distinguishing a reused document id from its predecessor generation. `OpSnapshot::
  created_seq_at_commit` captures it at commit time; a mismatch against the CURRENT document's
  `created_seq` at redaction time means the id was hard-deleted and recreated since commit, and the
  op is dropped rather than redacted against the wrong generation's permission set.

