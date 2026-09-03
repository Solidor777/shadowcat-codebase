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

- The server `merge` module (`src/server/src/merge/`, beside `formula`/`dice`) — the ONLY merge
  engine (the client computes no merge); its contracts are stated in its own terms and pinned by
  the conformance corpus below, not by a client twin:
  - `tree.rs` — `structural_diff`, `deep_equal`, pointer escape/`tokenize`/`get_pointer`
    (`pub(crate)`)/`delete_pointer`/`set_pointer` helpers (fallible — `PointerError`, never a
    panic on a malformed or non-container path), `merge3_tree`, `take_template`, `same_result`,
    `HiddenPointers` (`excludes_parent`/`withholds`). Overlap is `data::permission::paths_overlap`
    (one predicate, not a merge-local copy). Sorted-key traversal keeps output order-independent
    (the corpus pins order).
  - `embedded.rs` — `merge3_embedded` (`source.id` correlation, never index), `revert_embedded`,
    `revert_child`, `restamp_subtree`. A template-deleted-but-changed child conflict discloses the
    child's whole `system` (`TEMPLATE_DELETED_PAYLOAD_BAND`), so it is withheld by the tree
    level's one overlap rule (`HiddenPointers::withholds`) against THAT band — a child-hidden
    pointer on or inside `/system` withholds; the synthetic `/base` entry every non-owner
    requester carries, or a hidden `/name`, does not. `child_unchanged_vs_base` compares CONTENT
    only (`content_only`), never the recorded policy.
  - `bands.rs` — `MergeBase`/`EmbeddedBaseChild` (`#[ts(export)]` — the client's types, reached
    through `@shadowcat/types`; both carry `property_overrides` — `propertyOverrides` on a record
    — the snapshotted document's mergeable-band policy, `recorded_overrides` =
    `permission::writes_a_content_band`'s set), `MergeBands` (server-internal, NO ts-rs export:
    it never crosses the wire), `StoredBase` (`#[ts(export)]` — the value actually stored at
    `Document.base`: `MergeBase` flattened, plus `owner_standing: OwnerStanding`), `snapshot_base`
    (the FULL template's snapshot — the tiers it records are the template's OWN, never
    re-expressed), `propagate_overrides(instance, template)` (the template's policy onto an
    instance, VERBATIM and additive: a pointer lands only where the instance holds no entry, an
    instance-held entry — stricter, equal or looser — is never touched; embedded children by
    `source.id`; a recorded `Visibility::All` is skipped — a no-op audience that would otherwise
    cost a capability-gated write for zero visibility effect), `derive_create_base(doc, template,
    owner_standing: OwnerStanding)` (propagates, then snapshots the stamped document's own bands
    and policy under the caller-supplied standing), `OwnerStanding` (`data::document`;
    `Stranger`/`Reader`/`Owner` — the instance owner's standing on the TEMPLATE at the write that
    stored the snapshot, resolved by `permission::owner_standing`; `OwnerStanding::relate` maps a
    recorded `OwnerOrGm` tier to `GmOnly` unless the standing is `Owner`, used only by
    `permission::base_policy` when reading `/base`'s OWN egress — content-band propagation onto a
    live document (`propagate_overrides`) carries `OwnerOrGm` as-is, since on the INSTANCE it
    names the instance's own owner), `content_only`, `bands_tree`/`base_from_child` adapters,
    `placement_exclusions`/`is_placement_excluded` (token `/engine/x|y|rotation`, hardcoded as
    before).
  - `plan.rs` — `merge3` (reduces the stored base's band tree by the TEMPLATE-side hidden set
    through `permission::redact_pointers`, the same procedure `filter_properties` reduced the
    parent with, so base and parent agree on what the requester may see), `compute_pull` (parses
    the child's stored `/base` as a plain `MergeBase` — the recorded `owner_standing` is egress's
    business, not the merge's), `compute_revert` (returns `MergeBands`; the caller emits through
    `plan_to_update`), `plan_to_update(child, template, bands, owner_standing: OwnerStanding)`
    (whole-band emission; absent-vs-empty-collection `null` rule; a
    `/permissions/property_overrides` change carrying the propagated policy; `/base` refresh =
    `StoredBase { snapshot: snapshot_base(template), owner_standing }` — the FULL template's
    CURRENT snapshot, never the requester's view, under the standing THIS write resolved —
    emitted, like every other band, ONLY when it differs from the stored value read through
    `MergeBase`'s own defaults, so an in-sync instance yields an update with no changes and the
    handlers report `Applied` without publishing), `apply_resolutions` (every `Set` first, then
    every `Delete` in descending `pointer_key` order — deepest and highest-indexed first, so no
    splice renumbers a path still waiting; fallible: an unapplicable "theirs" is `Err`, never a
    panic).
  - `visibility.rs` — the `MergeVisibility` oracle (`hidden(side, doc)`, `Side::Template`/
    `Side::Child`): `AllVisible` (tests/corpus) and `RequesterView { template, child }` (production,
    backed by `permission::hidden_own_pointers`). Visibility is resolved by document IDENTITY at
    every embedded depth, never by array index — the live child index and the merged OUTPUT index
    are different spaces (a dropped preceding sibling shifts one and not the other). An
    unanswerable oracle fails the merge closed (`MergeError::VisibilityUnknown`).
  - `mod.rs` — the public surface + `MergeConflict` (`#[ts(export)]`; `path`/`base`/`parent`/
    `child`/`parentKind`, `base`/`parent`/`child` absent — not `null` — when that side has no value),
    `MergeError { CorruptBase, VisibilityUnknown, Pointer(PointerError) }`.
  A JSON conformance corpus (`src/client/core/src/__fixtures__/merge-conformance.json`),
  GENERATED from the TS engine's live output before its deletion, is run forever by the Rust
  suite (`merge::tests::conformance`) — the generation transcript
  (`scripts/merge-corpus-generation.log`) is the equivalence evidence for the port; a divergence
  fails the corpus, not a hand-written expectation. TWO deliberate deltas are recorded in the
  fixture's own `amendments` key (and the transcript): the `/base`-only-when-changed rule above
  (four revert cases amended by hand), and the recorded policy keys every `/base` change's new
  value carries (`property_overrides`/`propertyOverrides`, empty — eleven cases amended by hand).
- The three intents (`ws::protocol::ClientMsg::MergePull`/`MergePush`/`MergeRevert`,
  `ServerMsg::MergeResult`/`MergeError`) — a stateless two-call flow. WITHOUT `resolutions`: the
  server computes the plan from LIVE documents; conflict-free commits immediately (under
  `WriteOrigin::TemplateMerge`, confirmed to the client by the ordinary broadcast `Event` echo, not
  by `MergeResult` alone); conflicted returns the conflict set (per-instance for push) and writes
  nothing. WITH `resolutions` (the caller's "theirs" paths, per instance for push): the server
  RECOMPUTES the plan from live documents and rejects (`MergeErrorKind::StaleResolutions`/
  `UnknownResolution`/`Unresolvable`, each carrying the FRESH outcome) unless every submitted path
  is a CURRENT conflict path whose template side the current merged shape can take — there is no
  server-side session state; interleaving edits are caught by the recompute, never by OCC on a
  stale pre-image. Revert never conflicts.
  - `MergeOutcome::Pull { child_id, status: Applied | Conflicts(Vec<MergeConflict>) }`,
    `MergeOutcome::Push { template_id, instances: Vec<PushInstanceOutcome> }` (per-instance
    `{ instance_id, name, status: Applied | Conflicts(_) | Excluded }` — `name` is the
    pusher-VISIBLE display name for the modal's group label), `MergeOutcome::Revert { child_id,
    status: Applied }`.
  - **Visibility rule (three inputs, one classifier; one canonical `/base`).** Pull, revert AND
    push build the PARENT side of the merge from `merge_intents::visible_template` —
    `filter_properties(template, requester_access)`, the template with every property whose
    override the requester cannot READ removed, the same `property_overrides`/`Access::can_see`
    classifier egress uses — and `merge3` reduces the stored BASE by the same template-side hidden
    set through the same procedure (`permission::redact_pointers`), at every embedded depth; the
    CHILD side stays UNREDACTED. A template-hidden path is additionally EXCLUDED from the parent
    diff (`HiddenPointers::excludes_parent`, overlap semantics: a hidden subtree and every path
    under or above it — needed on its own for an array ancestor carrying a hidden element), so a
    value the requester cannot see never moves into an instance's content in either direction
    (pull cannot copy it in; push cannot copy it into an instance the pusher cannot fully see;
    revert keeps the instance's own value there). A child-hidden path WITHHOLDS its conflict from
    the wire (`HiddenPointers::withholds`) with the child-wins default standing, and an embedded
    template-deletion conflict is withheld by the same rule against its `/system` payload. The
    stored `/base` is NOT requester-relative: `plan_to_update` writes `snapshot_base` of
    the FULL template (`PullDocs::template_full`; push keeps the full template beside the pusher's
    view), so a GM's pull followed by a player's pull on the in-sync instance publishes
    NOTHING and neither seat's badge flips (a requester-relative snapshot rewrote the other seat's
    view on every merge). The recipient direction is closed structurally: every merge write and
    every Create carries the template's policy onto the instance (`propagate_overrides` — a GM's
    push of a `gm_only` value lands hidden on a player-owned instance; the `Event`'s `/system`
    delta, the stored document and `/base` all strip it for the owner), and `/base` egress is cut
    by the policy the snapshot records (`shadowcat-codebase-documents-permissions`'s `/base`
    invariant). The client's `syncState` therefore compares its egress view of the one snapshot
    (read through `normalizeBase`, policy maps excluded) with its egress view of the template and
    is consistent per seat. A GM sees everything, so a GM's merges and conflict sets are unchanged.
    An unreadable template is `NotFound` for pull/revert (existence-hiding, matching push).
  - **Push existence-hiding.** An instance the pusher cannot see AT ALL is OMITTED from
    `instances` entirely — no entry, name, or count (true existence-hiding parity with redaction:
    the pusher's store never contained it). `Excluded` then means exactly one thing: visible but
    not writable.
  - `MergeErrorKind`: `NotFound` (child/template missing OR unreadable), `NotAnInstance` (no
    `source`), `Forbidden` (the owner-or-GM gate), `CorruptBase` (a stored base that does not
    parse — fail-closed), `StaleResolutions(MergeOutcome)`/`UnknownResolution(MergeOutcome)`/
    `Unresolvable(MergeOutcome)` (each carries the fresh outcome so the client re-opens its modal
    without a round trip; `Unresolvable` is the ancestor/descendant conflict shape — the instance
    holds a scalar where the template edited a leaf inside a container, so "theirs" has nowhere
    to land), and `Internal`. **Push commit contract:** instances commit ONE BY ONE (not atomically);
    every resolution is folded before the first commit, so a resolutions rejection precedes any
    write, while a commit failure mid-loop leaves the earlier instances committed with their
    `Event`s broadcast — no ledger rides the error; the fresh outcome is recomputed from live
    documents, in which an already-committed instance reads `Applied`, and a re-sent intent
    commits the remainder.
  - Authorization: pull/revert require GM or the child's EFFECTIVE owner (server's
    `effective_owner` rule) AND every capability the computed `Update`'s change paths require
    (`required_cap_for_path`, the same predicate `apply_intent`'s per-op gate uses — never a
    guessed band list). Push requires GM or effective owner of the TEMPLATE plus `/embedded` write
    on it, then per instance: same-world, VISIBLE to the pusher (`Repository::instances_of`,
    `source_pack IS NULL AND source_id = ?` over the `documents` table's `source_id`/`source_pack`
    columns and `idx_documents_source`, replicating the client store's same-world reach for
    push), writable per the same per-path derivation. Authorized
    writes commit under `WriteOrigin::TemplateMerge` (per-op capability gates waived — the handler
    already derived them; scope/size/engine/containment/schema/OCC all still run), mirroring
    `CombatTransition`/`ConfigSeed`.
- `TemplatesController` (`src/client/ui-kit/src/templatesController.svelte.ts`) — an INTENT
  SENDER, constructed by the shell alongside `SheetsController`. Methods: `stampInstance`,
  `findInstances` (display only — the authoritative instance set for push is server-side),
  `syncState`, `canPull`, `canPush`, `pull`, `push`, `revert`, `cancel`.
  - `pull(childId)`/`push(templateId)`/`revert(childId)` send `MergePull`/`MergePush`/
    `MergeRevert` via the injected `sendMergeIntent: (msg, opts) => Promise<WireMergeOutcome>`
    (wired through `WorldSession.mergeIntent` → `WsClient.merge`, a one-shot correlated
    request/reply — the same shape as `pathfind`/`search`, distinct from `combat`/chat's
    broadcast-echo confirmation, because the reply itself carries the computed outcome). The
    controller sizes `opts.timeoutMs` per request: `MERGE_TIMEOUT_BASE_MS` for pull/revert,
    plus `MERGE_TIMEOUT_PER_INSTANCE_MS` per visible instance for push (the server commits push
    instances one by one before replying). `#inFlight` guards re-entry per child/template id
    while a reply is pending — a second send would race the first's commit and be refused as
    stale; `pull` and `revert` share the one window per child (a revert during a pending pull is
    dropped, and vice versa), `push` holds it per template.
  - A conflicted `MergeResult` opens `pending: PendingSession | null` (a `$state` the
    `TemplateModalHost` renders); the modal's resolve re-sends the SAME intent type with
    `resolutions` built from the user's per-conflict "theirs" choices. `StaleResolutions`/
    `UnknownResolution`/`Unresolvable` reopen the modal with the FRESH conflict set the rejection
    carries — no extra round trip; a rejection whose fresh outcome no longer conflicts is re-sent
    ONCE as a compute-only call (the rejected call wrote nothing, so the re-send applies it),
    bounded to one retry before the failure is reported.
  - `canPull(childId)` gates on `#isOwnerOrGm(child)` (`effectiveOwner`, the SAME
    per-doc-override-else-linked-actor-owner rule the server resolves at egress) AND
    `canEdit(child, "/system")` AND `canEdit(child, "/embedded")` — **`/base` is deliberately NOT
    checked**: the server writes `/base` itself under `WriteOrigin::TemplateMerge` (no client
    capability maps to it at all — see the documents-permissions skill), so gating this
    advisory mirror on `canEdit(child, "/base")` would hide pull/revert from exactly the users the
    server now authorizes.
  - `canPush(templateId)` gates on `#isOwnerOrGm(template)` AND `canEdit(template, "/embedded")`
    AND `findInstances(templateId).length > 0` — covers the TEMPLATE only; per-instance write
    authorization is entirely server-side now (no client-side `#canApplyUpdate` derivation left —
    the server derives it against the actual computed `Update`).
- `MergeConflictModal` (+ `TemplateModalHost`) — unchanged UX; consumes `WireMergeConflict`
  (the hand-written Zod mirror in the `wire` module of the ts-rs-generated `MergeConflict` —
  the `wire.test.ts` parity assertions pin the two shapes equal) instead of an engine-produced
  type. `ConflictGroup.label` comes from the push outcome's `name`.
- `AppContext.templates: TemplatesApi` (`stampInstance`, `pull`, `push`, `revert`, `findInstances`,
  `syncState`, `canPull`, `canPush`) — unchanged shape; still the seam every sheet/module reaches
  templates through.
- `@shadowcat/core`'s retained client-side surface — stamping + display only, no merge
  computation: `structuralDiff`/`deepEqual` (`syncState`'s divergence check),
  `isPlacementExcluded`/`placementExclusions`, `isMergeableBandPointer` (the client twin of
  `writes_a_content_band`, so `snapshotBase` records the same policy the server does),
  `normalizeBase` (reads a stored base with the server's `MergeBase` defaults — a stripped
  snapshot key and a nulled template band compare equal), `restampSubtree`/`snapshotBase`/
  `stampInstance` (stamping's clone-then-Create), `findInstances` (display), `syncState` (its
  diff excludes placement paths and the recorded policy maps — the snapshot's policy is
  re-expressed for the instance, the template's verbatim, and a policy change already shows
  through the views the two policies cut), and the `MergeBase`/`EmbeddedBaseChild` types those
  retained functions still need — ts-rs exports re-exported through `@shadowcat/types`, not
  hand-written.
  **DELETED**: every function that computed a merge or emitted a merge `Update` client-side (the
  TS twins of `merge3`/`merge3_tree`/`take_template`/`compute_pull`/`compute_revert`/
  `plan_to_update`/`apply_resolutions`) and their internal helpers (the client-side pointer
  delete and tokenize functions), plus the hand-written conflict/plan/bands types those functions
  produced — a second live merge implementation is a divergence channel, not a safety net, once
  the server executes every merge.
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
