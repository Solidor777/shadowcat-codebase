---
name: shadowcat-codebase-templates
description: "Use when touching Shadowcat's generic templates/3-way-merge engine: stamp/pull/push/revert of a document instance against its template, `Document.base` (the opaque merge snapshot), `@shadowcat/core`'s `merge`/`templates` modules (structuralDiff, merge3Tree/merge3/merge3Embedded, restampSubtree, takeTemplate, placement exclusions, snapshotBase, stampInstance, computePull/computeRevert, planToUpdate, applyResolutions, findInstances, syncState), `TemplatesController`/`AppContext.templates`, the field-level conflict modal (`MergeConflictModal`/`TemplateModalHost`), or the host-rendered `TemplateControls`/`SheetHost` chrome every sheet gets for free. Templates are not a doc_type — any document can be a template or an instance via `source`. Invoke shadowcat-codebase-core first; for the server-side `base` field/authz see shadowcat-codebase-documents-permissions, for the sheet-panel wrapper mechanics see shadowcat-codebase-sheets."
---

# Shadowcat — Templates & 3-Way Merge Engine

Orientation for the generic templates system: any document can be stamped as a reusable
template, instanced elsewhere, and later pulled from / pushed to / reverted against its
template via a client-side 3-way merge — no server-side merge logic, no `template` doc_type.

## Purpose

A "template" is just a document another document's `source: { id, ... }` field points at
(`Document.source`). The templates system adds the machinery to keep an instance and its
template's mergeable content (`name`/`engine`/`system`/`embedded`) in sync over time, using a
classic 3-way merge (base/mine/theirs) where "base" is a client-owned snapshot
(`Document.base`) taken at stamp time or the last successful sync. This is entirely client-core
algorithm + client-ui-kit orchestration; the server only stores/redacts/size-caps the opaque
`base` blob (`Document.base` — see `shadowcat-codebase-documents-permissions`) and never
interprets or merges anything itself.

## Key files & seams

- The `merge` module — the pure 3-way diff/merge algorithm, no store/Svelte
  dependency:
  - `structuralDiff(base, now, prefix)` → `Diff[]` (leaf-level added/changed/removed vs base).
  - `merge3Tree(base, parentNow, childNow, exclusions)` → `{ merged, conflicts }` at the tree
    level: **arrays merge wholesale** (either side's whole-array change wins outright, or
    conflicts if both changed — arrays have no stable per-element identity to diff), **objects
    merge key-level** (each key independently: parent-only / child-only / both-same /
    both-different-conflict). `merge3Tree.exclusions` drops matching paths from the parent side entirely
    (never merge, never conflict) — the placement-exclusion mechanism (below).
  - `merge3Embedded(baseChildren, theirsChildren, mineChildren)` — **internal helper, not
    exported from `@shadowcat/core`** (used only inside `merge3`); correlates embedded children
    across base/mine/theirs **by `source.id`, never by array index or embedded-array position**
    — an instance's embedded children were themselves stamped from the template's embedded
    children, so `source.id` is the only stable cross-side key. Handles instance-added
    (mine-only, kept) and base-missing (fail-safe: kept, not silently dropped) cases; a
    correlated triple with a real conflict is kept pending, not merged.
  - `merge3(base: MergeBase, parentNow: WireDocument, childNow: WireDocument, exclusions:
    string[])` → `MergePlan { mergedBands, conflicts: Conflict[] }` — the top-level entry point:
    merges `name`/`engine`/`system` bands (via `merge3Tree`, forwarding `merge3.exclusions`) plus
    `embedded` (via `merge3Embedded`) in one pass.
  - `restampSubtree(doc)` — deep-clones a document tree for use as a fresh `base`/instance
    (guards against the aliasing hazard in `[[embedded-copy-needs-deep-clone]]`).
  - `takeTemplate(root, conflict)` — applies "theirs" for one conflicted leaf, used by conflict
    resolution.
  - `isPlacementExcluded(path, exclusions)` / `placementExclusions(docType)` — per-doc_type
    paths that are always instance-owned and never merged/pulled/pushed (e.g. a token's on-scene
    `x`/`y`) — checked by every pull/revert/push computation in the `templates` module, not re-derived
    per call site.
  - Types: `Diff`, `Conflict` (`{ path, base, parent, child, parentKind: "set" | "delete" }` —
    `parent`/`child` are `undefined` when that side deleted the key; `parentKind` records how
    "take template" resolves it. Conceptually `parent`≈"theirs" (the template) and `child`≈"mine"
    (the instance), but the field names on the type are `parent`/`child`, not "mine"/"theirs"),
    `MergeBase` (the `base` snapshot shape: `{ name, engine, system, embedded }`), `MergeBands`
    (the merged-band result shape), `EmbeddedBaseChild`, `MergePlan`.
- The `templates` module — the stamp/sync operations built on the `merge` module:
  - `snapshotBase(doc) -> MergeBase` — takes the `base` snapshot from a document's current
    mergeable bands (called at stamp time and after every successful pull/push/revert).
  - `stampInstance(source, opts: StampOpts) -> WireDocument` — clones `source` into a new
    instance: sets `source: { id: source.id, ... }`, deep-clones embedded children via
    `restampSubtree`, then assigns `stamped.base = snapshotBase(stamped)` — a snapshot of the
    ASSEMBLED new instance (post-clone, with its fresh `id`/`scope`/`owner`/`source`), not a
    direct call against `source`. The mergeable content (`name`/`engine`/`system`/`embedded`) is
    equivalent either way since it's cloned verbatim from `source`, but the call target is the
    stamped document, not the template.
  - `computePull(child, template) -> MergePlan` / `computeRevert(child, template) ->
    WireOperation` — pull = 3-way merge (child's local edits + template's edits, base = child's
    stored `base`); revert = discard local edits, reset to template's current state.
  - `planToUpdate(child, template, mergedBands) -> WireOperation` — turns a resolved
    `MergeBands` into ONE `Update` op, refreshing `/base` to `snapshotBase(template)` — the
    TEMPLATE's current snapshot, not a snapshot of the merged result. This is deliberate: it
    makes `syncState`, run immediately after this op lands, compare the child's new stored
    `base` against the template's CURRENT state and correctly read `SyncState.up_to_date` rather
    than falsely `SyncState.template_changed` (a merged-result snapshot would already differ from the
    template's live state the instant the template changes again, or in edge cases immediately).
    **Emits whole-band `FieldChange`s (`/name`, `/engine`, `/system`, `/embedded/<coll>`),
    never per-leaf changes** — deliberately, not because no leaf-removal mechanism exists: a
    merge result can add/remove/reorder embedded collection members and touch multiple leaves
    across `name`/`engine`/`system`/`embedded` at once, and whole-band replacement is the
    simpler, correct operation for reconciling that across a 3-way merge, distinct from
    `FieldChange.remove`'s narrow single-leaf-deletion use case (see the
    `data::command::remove_pointer` entry in `shadowcat-codebase-documents-permissions`, and
    `SystemTreeEditor.removeField` for its consumer). `set_pointer` itself still cannot delete a
    key or resize an array via a leaf-path Update — that part of the wire boundary is unchanged
    — but `planToUpdate` choosing band-level emission over per-leaf `FieldChange.remove`s is a
    design choice for merge results, not a limitation being worked around.
  - `applyResolutions(mergedBands, conflicts, theirs: Set<string>) -> MergeBands` — folds a
    user's per-conflict "mine"/"theirs" picks (from the modal) back into the merged result.
  - `findInstances(templateId, all: Iterable<WireDocument>) -> WireDocument[]` — same-world scan
    over a document snapshot (typically `store.snapshot()`) for every doc whose `source.id`
    matches; says nothing about per-instance write authorization (a caller doing push must
    additionally filter by its own `canEdit`, see `TemplatesController.push` below).
  - `syncState(child, template) -> SyncState` (`"none" | "up_to_date" | "template_changed"`) —
    derived comparison of the child's stored `base` against the template's current state.
  - Types: `StampOpts`, `SyncState`.
- `TemplatesController` — thin glue
  (constructed by the shell alongside `SheetsController`/`PanelsBridge`, imports no module) that
  calls the pure `templates` module's functions, opens a conflict-resolution session
  (`pending: PendingSession | null`, a `$state` the `TemplateModalHost` renders) when a plan has
  conflicts, and dispatches the resolved `WireOperation` via the injected `dispatchIntent`.
  Methods: `stampInstance`, `findInstances`, `syncState`, `canPull`, `canPush`, `pull`, `push`,
  `revert`, `cancel`. `canPull(childId)` gates on the private `#isOwnerOrGm(child)` (`role ===
  "gm" || effectiveOwner(child, documents) === selfId` — from
  `@shadowcat/core`'s `effectiveOwner`, the SAME per-doc-override-else-linked-actor-owner rule the
  server resolves at egress; a literal `doc.owner` read here would fork it) AND the
  injected `canEdit(child, "/base")` AND `canEdit(child, "/system")` AND `canEdit(child,
  "/embedded")` (an advisory client-side mirror of the server's real authority — WRITE_FIELDS ∪
  MANAGE_EMBEDDED). **`canPush(templateId)` DOES call `canEdit`**, but only one leg of that union:
  `#isOwnerOrGm(template)` AND `canEdit(template, "/embedded")` AND
  `findInstances(templateId).length > 0`. The two predicates are NOT the same check and neither
  is a superset by accident — `canPull` gates the bands a pull writes onto the INSTANCE, while
  `canPush` gates the TEMPLATE only. Per-instance write authorization is DERIVED, not enumerated:
  `TemplatesController.#canApplyUpdate(inst, op)` checks every `op.changes[].path` of an actual
  computed `Update` (from `planToUpdate`) against `canEdit(inst, path)`, so the check always
  matches whatever bands that instance's merge happens to touch — including `/embedded/<coll>` —
  with nothing to keep in sync by hand. `push` calls it twice per instance: once against the
  provisional Update built from `computePull`'s pre-resolution `mergedBands` (gates entry into the
  dispatch-now/conflict-modal split — an instance failing here never reaches the modal at all),
  and — for an instance that entered the conflict modal — again inside `#openSession`'s `resolve`,
  against the FINAL Update built after `applyResolutions`, since resolving a conflict toward
  "theirs" can newly touch a path the provisional Update never touched (e.g. taking the template's
  side of an embedded-deletion conflict). Either exclusion is logged via the injected `logger.warn`,
  listing every excluded instance in one call, rather than silently leaving that instance stale.
  `#openSession`'s `resolve` runs the same derivation for BOTH its callers (`push`'s multi-group
  sessions and `pull`'s single-group session) — without it, `resolve` would dispatch every entry's
  Update with no capability filter at all, including for `pull`'s conflict path.
- `MergeConflictModal` (+ `TemplateModalHost`) — the
  field-level conflict resolution UI: renders one `ConflictGroup` per pending child
  (`{ key, label, conflicts: Conflict[] }`; the type lives in
  the `mergeConflict` module — a plain TS module, because a named type export
  from a `.svelte` file is invisible to plain tsc consumers like TypeDoc), lets the user pick
  mine/theirs per leaf path, and
  calls the session's `resolve(theirsByGroup: Map<string, Set<string>>)`. `TemplateModalHost`
  just renders `MergeConflictModal` when `controller.pending` is non-null — mount once per
  `Table` alongside the root `<Surface>`.
- `TemplateControls` — the host-rendered chrome: a source
  badge (template name + `syncState`) and pull/revert (if `canPull`) / push (if `canPush`)
  buttons, reactive via `createSubscriber`/`subscribe()` on `ctx.documents` (same pattern as
  every sheet — see `shadowcat-codebase-sheets` Hard Invariants). Rendered by `SheetHost`
  above every sheet body, so ALL doc_types get template chrome for free without opting in — see
  `shadowcat-codebase-sheets`'s `#register` entry for the wrapper mechanics.
- `AppContext.templates: TemplatesApi` (`stampInstance`,
  `pull`, `push`, `revert`, `findInstances`, `syncState`, `canPull`, `canPush`) — the seam every
  sheet/module reaches the merge engine through; never call `TemplatesController` directly from a
  module.
- `Table` — constructs the real `TemplatesController` (deps:
  `session.store`/`session.documents`/`dispatchIntent`/`role`/`selfId`/`canEdit`+a logger),
  provides it into `setAppContext({ templates: {...} })`, and mounts
  `<TemplateModalHost controller={templates} />` once alongside `<Surface
  contract="shadowcat.surface:root" />`.

## Hard invariants

- **Templates are not a doc_type.** Any document can be a template (something else points a
  `source` at it) or an instance (has a `source`) or both. `stampInstance` is fully generic —
  never gate it on `doc_type`.
- **Embedded correlation is by `source.id`, never index/position** — see `merge3Embedded` above;
  it is what keeps embedded children correlated when either side reorders, adds or removes one
  between syncs.
- **Merge emission is band-level, never per-leaf.** `planToUpdate` always emits whole-band
  `FieldChange`s (`/name`, `/engine`, `/system`, one per changed `/embedded/<coll>` — the WHOLE
  collection array, never a per-index path) — deliberate for merge results, since a merge can
  add/remove/reorder embedded collection members and touch multiple leaves at once, making
  whole-band replacement simpler and correct there. This is distinct from `FieldChange.remove`
  (`data::command::remove_pointer`), a sibling leaf-level object-key-deletion mechanism on the
  same `Operation::Update`/`FieldChange` wire shape, used by `SystemTreeEditor.removeField` for
  narrow-OCC single-leaf deletion — `planToUpdate` not using it for merge results is a design
  choice, not evidence no such mechanism exists. `set_pointer` itself remains leaf-set-only
  (still cannot delete a key or resize an array via a leaf-path Update); any future change to
  `planToUpdate` that tries to emit finer-grained changes must confirm it's actually the better
  fit for the merge-result case, not just that a leaf-removal path exists.
- **Placement exclusions are per-doc_type and checked everywhere** (`isPlacementExcluded`/
  `placementExclusions`) — pull, revert, AND `syncState`'s "changed" determination must all
  exclude the same paths, or a token's own on-scene position would spuriously flag as
  "template_changed" or get clobbered by a pull.
- **`push`'s instance scope is same-world SEE **and** WRITE**, not just `findInstances`' same-
  world SEE — `TemplatesController.push` derives write authorization per instance via
  `#canApplyUpdate` (against the actual computed Update, never a guessed band list) before
  deciding dispatch-now vs. conflict groups, and `#openSession`'s `resolve` re-derives it against
  the FINAL resolved Update before dispatch; skipping either derivation would attempt to silently
  write instances the pusher cannot edit.
- **`Document.base` is the client-owned merge snapshot; the server treats it as fully opaque** —
  see `shadowcat-codebase-documents-permissions` for its `#[ts(type="unknown")]` typing, its
  exemption from `validate_engine_tree`, its independent size cap, and its hardcoded
  `OwnerOrGm`-only egress visibility (a real security-relevant fact, not merge-engine trivia).

## Gotchas

- Every `$derived.by` in `TemplateControls` that reads `ctx.documents` (directly or via
  `ctx.templates.*`, which reads the same underlying store) must call the component's own
  `subscribe()` first — same freeze-at-first-read hazard as every other sheet
  (`shadowcat-codebase-sheets` Hard Invariants). The calls are present; dropping one is silent.
- `merge3Embedded` is intentionally NOT exported from `@shadowcat/core`'s public surface —
  it's an implementation detail of `merge3`. Do not import it directly from a
  module or ui-kit component; go through `merge3`/`computePull`/`computeRevert`.
- A template's own document is not special — pulling/pushing reads/writes it through the exact
  same `ctx.documents`/`dispatchIntent` seam as any instance; there's no separate "template
  document" type or table.

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the `merge`/`templates`
  modules). No dedicated rustdoc page: the server only stores/redacts/size-caps the opaque `base`
  blob (see `shadowcat-codebase-documents-permissions`'s generated-API pointer for that). Produce
  with `pnpm build:all`.
- Server-side `base` field/authz/redaction: `shadowcat-codebase-documents-permissions`.
- Sheet-panel wrapper mechanics (`SheetHost`, `#register`): `shadowcat-codebase-sheets`.
- Relationships: `graphify query "merge3 stampInstance TemplatesController base snapshot"`.
