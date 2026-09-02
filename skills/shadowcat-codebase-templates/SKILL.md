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

- The server `merge` module (`src/server/src/merge/`, beside `formula`/`dice`) — the exact
  behavioural twin of the retired TS engine, unit-by-unit:
  - `tree.rs` — `structural_diff`, `deep_equal`, pointer escape/tokenize/`delete_pointer`/
    `set_pointer` helpers, `merge3_tree`, `take_template`, `same_result`, `paths_overlap`. Sorted-
    key traversal keeps output order-independent (the corpus pins order).
  - `embedded.rs` — `merge3_embedded` (`source.id` correlation, never index), `revert_embedded`,
    `revert_child`, `restamp_subtree`, `EmbeddedBaseChild`.
  - `bands.rs` — `MergeBase`/`MergeBands` (`#[ts(export)]`), `snapshot_base`, `bands_tree`/
    `base_from_child` adapters, `placement_exclusions`/`is_placement_excluded` (token
    `/engine/x|y|rotation`, hardcoded as before).
  - `plan.rs` — `merge3`, `compute_pull`, `compute_revert`, `plan_to_update` (whole-band emission;
    absent-vs-empty-collection `null` rule; `/base` refresh = the template's current snapshot),
    `apply_resolutions`.
  - `mod.rs` — the public surface + `MergeConflict` (`#[ts(export)]`; `path`/`base`/`parent`/
    `child`/`parentKind`, `base`/`parent`/`child` absent — not `null` — when that side has no value).
  A JSON conformance corpus (`src/client/core/src/__fixtures__/merge-conformance.json`),
  GENERATED from the TS engine's live output before its deletion, is run forever by the Rust
  suite (`merge::tests::conformance`) — that generation transcript is the equivalence evidence for
  the port; a divergence in either language fails the corpus, not a hand-written expectation.
- The three intents (`ws::protocol::ClientMsg::MergePull`/`MergePush`/`MergeRevert`,
  `ServerMsg::MergeResult`/`MergeError`) — a stateless two-call flow. WITHOUT `resolutions`: the
  server computes the plan from LIVE documents; conflict-free commits immediately (under
  `WriteOrigin::TemplateMerge`, confirmed to the client by the ordinary broadcast `Event` echo, not
  by `MergeResult` alone); conflicted returns the conflict set (per-instance for push) and writes
  nothing. WITH `resolutions` (the caller's "theirs" paths, per instance for push): the server
  RECOMPUTES the plan from live documents and rejects (`MergeErrorKind::StaleResolutions`/
  `UnknownResolution`, both carrying the FRESH outcome) unless every submitted path is a CURRENT
  conflict path — there is no server-side session state; interleaving edits are caught by the
  recompute, never by OCC on a stale pre-image. Revert never conflicts.
  - `MergeOutcome::Pull { child_id, status: Applied | Conflicts(Vec<MergeConflict>) }`,
    `MergeOutcome::Push { template_id, instances: Vec<PushInstanceOutcome> }` (per-instance
    `{ instance_id, name, status: Applied | Conflicts(_) | Excluded }` — `name` is the
    pusher-VISIBLE display name for the modal's group label), `MergeOutcome::Revert { child_id,
    status: Applied }`.
  - **Hidden-conflict rule (egress).** Every replied conflict set is filtered to the paths the
    REQUESTER can see in BOTH documents — a conflict whose path overlaps a property-override
    subtree hidden from the requester is (a) removed from the replied set and (b) auto-resolved
    child-wins in the applied result (the child value already sits in the merged bands; excluding
    the conflict from the set `apply_resolutions` sees achieves both). The merge COMPUTATION and
    the committed WRITE stay over the UNREDACTED documents — this also fixes the legacy
    hidden-field-dropping behaviour a redacted-view-computed whole-band write used to have. A GM
    sees everything, so a GM's conflict sets are unchanged.
  - **Push existence-hiding.** An instance the pusher cannot see AT ALL is OMITTED from
    `instances` entirely — no entry, name, or count (true existence-hiding parity with redaction:
    the pusher's store never contained it). `Excluded` then means exactly one thing: visible but
    not writable.
  - `MergeErrorKind`: `NotFound` (child/template missing), `NotAnInstance` (no `source`),
    `Forbidden` (the owner-or-GM gate), `StaleResolutions(MergeOutcome)`/`UnknownResolution
    (MergeOutcome)` (both carry the fresh outcome so the client re-opens its modal without a round
    trip), plus shared validation/IO errors.
  - Authorization: pull/revert require GM or the child's EFFECTIVE owner (server's
    `effective_owner` rule) AND every capability the computed `Update`'s change paths require
    (`required_cap_for_path`, the same predicate `apply_intent`'s per-op gate uses — never a
    guessed band list). Push requires GM or effective owner of the TEMPLATE plus `/embedded` write
    on it, then per instance: same-world, VISIBLE to the pusher (`Repository::instances_of`,
    a `json_extract(source, '$.id')`-keyed query over the stored `source` pointer, replicating the
    client store's same-world reach for push), writable per the same per-path derivation. Authorized
    writes commit under `WriteOrigin::TemplateMerge` (per-op capability gates waived — the handler
    already derived them; scope/size/engine/containment/schema/OCC all still run), mirroring
    `CombatTransition`/`ConfigSeed`.
- `TemplatesController` (`src/client/ui-kit/src/templatesController.svelte.ts`) — an INTENT
  SENDER, constructed by the shell alongside `SheetsController`. Methods: `stampInstance`,
  `findInstances` (display only — the authoritative instance set for push is server-side),
  `syncState`, `canPull`, `canPush`, `pull`, `push`, `revert`, `cancel`.
  - `pull(childId)`/`push(templateId)`/`revert(childId)` send `MergePull`/`MergePush`/
    `MergeRevert` via the injected `sendMergeIntent: (msg) => Promise<WireMergeOutcome>` (wired
    through `WorldSession.mergeIntent` → `WsClient.merge`, a one-shot correlated request/reply —
    the same shape as `pathfind`/`search`, distinct from `combat`/chat's broadcast-echo
    confirmation, because the reply itself carries the computed outcome).
  - A conflicted `MergeResult` opens `pending: PendingSession | null` (a `$state` the
    `TemplateModalHost` renders); the modal's resolve re-sends the SAME intent type with
    `resolutions` built from the user's per-conflict "theirs" choices. `StaleResolutions`/
    `UnknownResolution` reopen the modal with the FRESH conflict set the rejection carries — no
    extra round trip.
  - `canPull(childId)` gates on `#isOwnerOrGm(child)` (`effectiveOwner`, the SAME
    per-doc-override-else-linked-actor-owner rule the server resolves at egress) AND
    `canEdit(child, "/system")` AND `canEdit(child, "/embedded")` — **`/base` is deliberately NOT
    checked**: the server writes `/base` unconditionally under `WriteOrigin::TemplateMerge` (no
    client capability maps to it at all — see the documents-permissions skill), so gating this
    advisory mirror on `canEdit(child, "/base")` would hide pull/revert from exactly the users the
    server now authorizes.
  - `canPush(templateId)` gates on `#isOwnerOrGm(template)` AND `canEdit(template, "/embedded")`
    AND `findInstances(templateId).length > 0` — covers the TEMPLATE only; per-instance write
    authorization is entirely server-side now (no client-side `#canApplyUpdate` derivation left —
    the server derives it against the actual computed `Update`).
- `MergeConflictModal` (+ `TemplateModalHost`) — unchanged UX; consumes the GENERATED
  `WireMergeConflict` (ts-rs mirror of `merge::MergeConflict`) instead of a hand-written type.
  `ConflictGroup.label` comes from the push outcome's `name`.
- `AppContext.templates: TemplatesApi` (`stampInstance`, `pull`, `push`, `revert`, `findInstances`,
  `syncState`, `canPull`, `canPush`) — unchanged shape; still the seam every sheet/module reaches
  templates through.
- `@shadowcat/core`'s retained client-side surface — stamping + display only, no merge
  computation: `structuralDiff`/`deepEqual` (`syncState`'s divergence check), `deletePointer`,
  `isPlacementExcluded`/`placementExclusions`, `restampSubtree`/`snapshotBase`/`stampInstance`
  (stamping's clone-then-Create), `findInstances` (display), `syncState`, and the
  `MergeBase`/`MergeBands`/`EmbeddedBaseChild` types those retained functions still need.
  **DELETED**: every function that computed a merge or emitted a merge `Update` client-side (the
  TS twins of `merge3`/`merge3_tree`/`take_template`/`compute_pull`/`compute_revert`/
  `plan_to_update`/`apply_resolutions`) and their internal helpers, plus the hand-written
  conflict/plan types those functions produced — a second live merge implementation is a
  divergence channel, not a safety net, once the server executes every merge.
- `Document.base` — now SERVER-owned and engine-tree-validated. See
  `shadowcat-codebase-documents-permissions` for the field/authz/validation facts; this skill
  covers only the client-side `MergeBase` snapshot SHAPE that `snapshotBase`/`stampInstance` still
  produce and the server still consumes.

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
  spuriously flag as "template_changed" or get clobbered by a merge.
- **Push's instance scope is server-derived same-world SEE + WRITE, per instance, against the
  ACTUAL computed Update** — never a guessed band list, and never the client's own reach. An
  instance invisible to the pusher is omitted entirely (existence-hiding); a visible-but-
  not-writable instance is `Excluded`, never silently stale.
- **`Document.base` is the SERVER-owned merge snapshot** — see
  `shadowcat-codebase-documents-permissions` for its ingest-time `validate_engine_tree` walk, its
  Create-time derivation (discarding any client-supplied value), its capability carve-out (`/base`
  maps to NO client capability), its independent size cap, and its hardcoded `OwnerOrGm`-only
  egress visibility.
- **A merge intent's authorization is derived against the ACTUAL COMPUTED `Update`, per instance
  (push) — never a guessed capability set.** This is what makes `Excluded`/`Forbidden` precise
  rather than approximate, and what lets the same `required_cap_for_path` predicate serve both the
  advisory client mirror (`canPull`/`canPush`) and the real server gate without the two ever being
  asked to agree by inspection.

## Gotchas

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
- **`TemplatesController.push`/`pull` no longer compute anything locally** — a caller reasoning
  about "what happens on pull" must read the SERVER's `merge::plan::compute_pull`/
  `ws::conn::merge_intents` handler, not the client controller, which is now a thin intent sender
  plus modal orchestration.

## Pointers

- **Generated API** — `/api/rust/shadowcat/merge/` (rustdoc, private items included — the server
  merge module) and `/api/rust/shadowcat/ws/conn/merge_intents/` (the intent handlers).
  `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the retained `merge`/`templates` client
  modules: stamping + display only). No dedicated TypeDoc page for the deleted merge computation.
  Produce with `pnpm build:all`.
- Server-side `base` field/authz/redaction: `shadowcat-codebase-documents-permissions`.
- Sheet-panel wrapper mechanics (`SheetHost`, `#register`): `shadowcat-codebase-sheets`.
- Relationships: `graphify query "merge3 compute_pull TemplatesController base snapshot MergePull"`.
