---
name: shadowcat-codebase-templates
description: "Use when touching Shadowcat's generic templates/3-way-merge engine: the server-side `merge` module (structural_diff, merge3_tree/merge3/merge3_embedded, restamp_subtree, take_template, placement exclusions, snapshot_base, compute_pull/compute_revert, plan_to_update, apply_resolutions, `MergeConflict`), the three merge intents (`MergePull`/`MergePush`/`MergeRevert`, `MergeResult`/`MergeError`, `ws::conn::merge_intents`), `Document.base` (the server-owned, engine-tree-validated merge snapshot), `TemplatesController`/`AppContext.templates` (an intent sender), the field-level conflict modal (`MergeConflictModal`/`TemplateModalHost`), the host-rendered `TemplateControls`/`SheetHost` chrome every sheet gets for free, or `@shadowcat/core`'s retained stamp/display surface (`stampInstance`, `snapshotBase`, `findInstances`, `syncState`). Templates are not a doc_type — any document can be a template or an instance via `source`. Invoke shadowcat-codebase-core first; for the server-side `base` field/authz see shadowcat-codebase-documents-permissions, for the sheet-panel wrapper mechanics see shadowcat-codebase-sheets."
---

# Shadowcat — Templates & 3-Way Merge Engine

Orientation for the generic templates system: any document can be stamped as a reusable
template, instanced elsewhere, and later pulled from / pushed to / reverted against its
template via a SERVER-side 3-way merge — no `template` doc_type.

## Purpose

A "template" is just a document another document's `source: { id, ... }` field points at
(`Document.source`). The templates system keeps an instance and its template's mergeable content
(`name`/`engine`/`system`/`embedded`) in sync over time, using a classic 3-way merge (base/mine/
theirs) where "base" is a SERVER-owned snapshot (`Document.base`) derived at Create and refreshed
by every successful merge write. **The server owns the merge**: `MergePull`/`MergePush`/
`MergeRevert` intents ride the `CombatRoll` reply pattern (`ServerMsg::MergeResult`/
`ServerMsg::MergeError`, correlated by `request_id`), the server computes the plan, derives
authorization against the actual computed `Update`, and commits under
`WriteOrigin::TemplateMerge`. The client's `TemplatesController` is an intent sender: it opens the
conflict modal on a conflicted reply and re-sends the intent with the user's resolutions. Stamping
stays a client-composed `Create` — it is a clone, not a merge, and the server's authority over it
is the `base` derivation at Create plus ordinary Create validation.

## Key files & seams

Covers every key file and seam of the server merge engine, its intent handlers and the client templates code. Read references/key-files-and-seams.md before changing any of those files.

## Hard invariants

- **Templates are not a doc_type.** Any document can be a template (something else points a
  `source` at it) or an instance (has a `source`) or both. `stampInstance` is fully generic —
  never gate it on `doc_type`.
- **Embedded correlation is by `source.id`, never index/position** — `merge::embedded::
  merge3_embedded` keys instance/template/base children by `source.id`, so reordering, adding, or
  removing an embedded child between syncs never desyncs correlation.
- **Merge emission is band-level, never per-leaf.** `merge::plan::plan_to_update` always emits
  whole-band `FieldChange`s (`/name`, `/engine`, `/system`, one per changed `/embedded/<coll>` —
  the WHOLE collection array, never a per-index path) — deliberate for merge results, since a
  merge can add/remove/reorder embedded collection members and touch multiple leaves at once. This
  is distinct from `FieldChange.remove` (`data::command::remove_pointer`), a sibling
  leaf-level object-key-deletion mechanism used by `SystemTreeEditor.removeField` for narrow-OCC
  single-leaf deletion — `plan_to_update` not using it for merge results is a design choice, not
  evidence no such mechanism exists.
- **Placement exclusions are per-doc_type and checked everywhere** (`is_placement_excluded`/
  `placement_exclusions`) — pull, revert, push, AND the client's `syncState`'s "changed"
  determination must all exclude the same paths, or a token's own on-scene position would
  spuriously flag as "template_changed" or get clobbered by a merge. The server set and the
  client's `placementExclusions`/`isPlacementExcluded` are therefore a must-agree pair, as are
  `snapshot_base` and the client's `snapshotBase` (the badge compares the `/base` the server
  writes against the client reduction of its redacted view).
- **The merge's three inputs are viewed through one classifier, visibility resolves by document
  identity (never by index), and the stored `/base` is one canonical full value.** A
  template-hidden path never moves into an instance's content in either direction; a
  child-hidden conflict is withheld with the child-wins default standing; the `/base` refresh is
  `snapshot_base` of the FULL template, whoever ran the merge, VERBATIM (the template's own
  recorded policy, never re-expressed), and rides onto the instance with every write
  (`propagate_overrides`). Any new merge entry point takes a `MergeVisibility` and threads it
  through every embedded level, hands `plan_to_update` the FULL template and the resolved
  `OwnerStanding`, and never a requester's view — an
  `AllVisible` in production code, an index-addressed visibility lookup, or a requester-relative
  `/base` is the leak (or the ping-pong) this rule exists to prevent.
- **Push's instance scope is server-derived same-world SEE + WRITE, per instance, against the
  ACTUAL computed Update** — never a guessed band list, and never the client's own reach. An
  instance invisible to the pusher is omitted entirely (existence-hiding); a visible-but-
  not-writable instance is `Excluded`, never silently stale.
- **`Document.base` is the SERVER-owned merge snapshot** — see
  `shadowcat-codebase-documents-permissions` for its ingest-time `validate_engine_tree` walk
  (the recorded policy key is required), its Create-time derivation (discarding any
  client-supplied value, propagating the template's policy), its capability carve-out (`/base`
  maps to NO client capability), its independent size cap, and its egress: an `OwnerOrGm` floor
  cut inside by the policy the snapshot records.
- **A merge intent's authorization is derived against the ACTUAL COMPUTED `Update`, per instance
  (push) — never a guessed capability set.** This is what makes `Excluded`/`Forbidden` precise
  rather than approximate, and what lets the same `required_cap_for_path` predicate serve both the
  advisory client mirror (`canPull`/`canPush`) and the real server gate without the two ever being
  asked to agree by inspection.

## Gotchas

- **The scene `template` document is not a template in this system.** `TemplateEngine` (a measured
  area drawn on a scene: circle, cone, rect or line) is an ordinary engine doc_type that shares only
  the word. It never carries a `source` or a `base` and never enters `merge`. A GM turns one into a
  `region` through `buildRegionFromTemplate` (`@shadowcat/core`, tessellation shared with the render
  layer; one batch: Create the region, Delete the template with its full pre-image), reached from
  scene-tools' `ToolController.convertTemplateToRegion`. The region is plain terrain (cost 1, no
  triggers, no colour); the template stays a drawing and no effect is copied across. Conversion
  mechanics are in `shadowcat-codebase-scene-rendering`.
- **A region a module placed (`Room::place_declared`) is born with `source: None` and `base:
  None`**, so no instance, pull, push or revert ever relates it to a template; it is not a stamp of
  anything. Its write is validated like any other (`shadowcat-codebase-sandbox`).
- Every `$derived.by` in `TemplateControls` that reads `ctx.documents` (directly or via
  `ctx.templates.*`, which reads the same underlying store) must call the component's own
  `subscribe()` first — same freeze-at-first-read hazard as every other sheet
  (`shadowcat-codebase-sheets` Hard Invariants). The calls are present; dropping one is silent.
- `merge::embedded::merge3_embedded` is an internal helper of `merge3`, not part of the module's
  public surface — do not call it directly from a WS handler or another server module; go through
  `merge3`/`compute_pull`/`compute_revert`.
- A template's own document is not special — pulling/pushing reads/writes it through the exact
  same document/intent seam as any instance; there's no separate "template document" type or
  table.
- **`TemplatesController.push`/`pull` compute nothing locally** — a caller reasoning
  about "what happens on pull" must read the SERVER's `merge::plan::compute_pull`/
  `ws::conn::merge_intents` handler, not the client controller, which is a thin intent sender
  plus modal orchestration.

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | Key files and seams of the merge engine and client templates code | changing merge, template stamping or merge-intent code |

## Pointers

- **Generated API** — `/api/rust/shadowcat/merge/` (rustdoc, private items included — the server
  merge module) and `/api/rust/shadowcat/ws/conn/merge_intents/` (the intent handlers).
  `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the retained `merge`/`templates` client
  modules: stamping + display only). No dedicated TypeDoc page for the deleted merge computation.
  Produce with `pnpm build:all`.
- Server-side `base` field/authz/redaction: `shadowcat-codebase-documents-permissions`.
- Sheet-panel wrapper mechanics (`SheetHost`, `#register`): `shadowcat-codebase-sheets`.
- Relationships: `graphify query "merge3 compute_pull TemplatesController base snapshot MergePull"`.
