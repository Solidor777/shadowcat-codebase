---
name: shadowcat-codebase-actors-tokens
description: "Use when touching Shadowcat actors, tokens (linked vs instanced), token visual resolution, the factions/conditions registries, name privacy, the actor browser's live FTS search/open-sheet, or the actors/factions/conditions UI modules. Covers the `actor`/`scene-docs` modules (src/client/core) + src/modules/{actors,factions,conditions}. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Actors & Tokens

Orientation for the actor document model, token placement (linked/instanced), the factions
registry, and name privacy.

## Purpose

An `Actor` is a world-scoped document. A token on a scene either **links** to a shared actor
(reads it live + applies an override whitelist) or **instances** it (embeds an independent copy
with provenance). A single read-through resolves either to an `EffectiveActor` that the render
layer decorates. Factions and conditions are world-scoped config-documents; name privacy hides a
token/actor name from non-owners via the `OwnerOrGm` visibility tier. Conditions are markers-only
(no mechanical effects): icon badges overlaid on the token, toggled by the GM or the token owner.

## Key files & seams

- The `scene-docs` module — builders + types (all re-exported from `@shadowcat/core`):
  Every builder/accessor below is re-rooted onto the envelope `name` + typed `engine` band;
  `ActorEngine`/`TokenEngine`/`FactionRegistryEngine`/`ConditionRegistryEngine` hold token/actor
  position, vision, conditions, and visual on `doc.engine`, not `doc.system` (there is no
  `ActorSystem`/`TokenSystem`/`FactionRegistrySystem`/`ConditionRegistrySystem` back-compat
  alias). `ItemSystem` is UNCHANGED — `ITEM_DOC_TYPE` is a client-only doc_type with no Rust-side
  registration, not one of the 23 engine-defined types, so it stays on the opaque `system` band
  ([[shadowcat-codebase-sheets]]/`shadowcat-codebase-documents-permissions` cover it).
  - `buildActorDoc(worldId, name, engine, id?)` — `name: string | null` is a DEDICATED parameter
    (the envelope `name` band), separate from the `ActorEngine` body.
  - `buildTokenFromActor(worldId, sceneId, actor, "link"|"instance", pos, unit, id?)` — link mode
    sets `token.engine.actor_id` + `overrides`; instance mode embeds an independent (deep-cloned)
    copy with `source` provenance. `unit: FootprintExtent | null` is the parent scene's
    SERVER-RESOLVED unit (1x1) extent, stamped as the new token's `engine.w`/`h`; it is never
    derived from the actor's size and the grid, because deriving it would be a second footprint
    formula. It stands until the server states this token's own extent, and permanently for a
    token no actor sizes. `null` (no `"footprints"` frame yet) stamps `w: 0, h: 0`, which
    `topTokenAt` skips outright — the token is unpickable until the frame lands. In practice
    `WorldSession.enter` opens the subscription before any tool use.
  - `TokenOverrides` whitelist includes `shape` (alongside `name`, `visual`, `size`) — a per-token
    `"square" | "circle"` override applied on top of the actor's own shape field.
  - **Token visual union:** `RenderVisual = {kind:
    "image", asset} | {kind:"animated", source: AnimatedSource, fps, loop}` — the only two kinds the
    render layer ever draws. `AnimatedSource = {type:"frames", frames: string[]} | {type:"sheet",
    asset, rows, cols, count?}` (asset ids pre-resolution; resolved to URLs at the render boundary,
    see `resolveTokenVisual` below and `TokenNodeSpec.visual` in `shadowcat-codebase-scene-rendering`).
    `FaceVisual = RenderVisual` — **a face is itself a `RenderVisual`, never nested** (deliberately
    no `{kind:"faces"}` inside a face; an animated face falls out of the same boundary with no
    separate mechanism). `TokenVisual = RenderVisual | {kind:"faces", faces: Record<string,
    FaceVisual>, default: string, faceMap?: Record<string,string>}` — `default` is REQUIRED (no
    `?`), per the Rust source `TokenVisual::Faces`'s `default` field (`data::engine::token`, ts-rs
    generates the TS union from it); `VisualKindEditor`'s `buildVisual()` always supplies it
    and nulls the whole visual if unset. `ActorEngine.visual` and
    `TokenOverrides.visual` both carry `TokenVisual` (a token can override the actor's whole visual,
    faces-union included). `TokenEngine.face?: string` — the per-token ACTIVE face selection; only
    meaningful when the effective visual resolves to `"faces"`, ignored otherwise; token-local
    always (deliberately NOT part of `overrides` — it selects INTO the actor's faces map rather than
    overriding actor data).
  - `VisionAssignment { mode, range }` (mode = a `vision-modes` registry id, range in grid cells);
    `ActorEngine.vision?` + `TokenOverrides.vision?` carry `VisionAssignment[]`.
    **`range` is OPTIONAL, and `None` inherits the referenced mode's `VisionMode::default_range`** —
    that is what makes the mode default live at all, since nothing else reads it. The resolution
    happens where a caller joins an assignment to its mode (`SceneEcs::token_vision_floors`), never
    as a struct-level default, so a reader holding a bare `VisionAssignment` cannot know the
    effective range without the registry. Both quantities are authored in CELLS and neither is
    itself converted — the measured DISTANCE is converted to cells and both are compared against it
    unconverted, so a resolved default is never scaled relative to an explicit override.
    **An omitted RANGE is not the same as an omitted ASSIGNMENT**, and confusing the two inverts the
    meaning: `ActorsPanel` clears darkvision by writing `null`/`[]` — dropping the whole assignment —
    rather than by writing an assignment with no range, which would now grant the mode's default
    instead of removing vision.
  - `setNameHidden(doc, hidden)` — sets/clears the `OwnerOrGm` override on `/name` (the envelope
    field).
  - `FactionStance = "friendly"|"neutral"|"hostile"`, `Faction { name, color, stance }`,
    `FactionRegistryEngine`, `buildFactionRegistryDoc(worldId, factions, id?)` (param
    `factions: Record<string, Faction>`) — a
    world-scoped, **parentless config-document** with an id-keyed faction map.
  - `Condition { name, icon }`, `ConditionRegistryEngine`, `buildConditionRegistryDoc(worldId,
    conditions, id?)` (param `conditions: Record<string, Condition>`) — same parentless
    config-document shape as factions; `icon` is an emoji glyph rendered as a token badge.
- The `actor` module — `resolveTokenActor(token, store) -> EffectiveActor | null`
  (the one read-through), `EffectiveActor`, `actorDisplayName(a, fallback)` (safe name with a
  redaction-aware fallback), `TokenOverrides` projection. Conditions: `resolveConditions(token,
  store)` (effective condition ids → `{id,name,icon}` via the registry, fail-closed) +
  `conditionTarget(token, store) -> {doc, path, conditions}` (the write site: linked →
  `actor` doc `/engine/conditions`; instanced → token `/embedded/actor/0/engine/conditions`).
  Shapes + footprint: `resolveTokenBox(token, store, footprints, eff?) -> TokenBox
  {x,y,w,h,shape}` — a scene-pixel footprint READ-THROUGH that computes no geometry of its own.
  **There is no client-side footprint formula.** `w`/`h` come from the server's resolved extent
  (`FootprintLookup.token(id)`, off the `"footprints"` derived channel), falling back to the
  token's own authored `token.engine.w/h` when the lookup states none — an unconfirmed optimistic
  token, a token no actor sizes, or an extent the server REFUSED. `shape` is the only field `resolveTokenBox.eff`
  decides (`actor?.shape ?? "square"`); that optional pre-resolved actor avoids a double
  `resolveTokenActor` call, and `null` skips resolution for a known actorless token. Fail-closed,
  never throws. `TokenBox` is exported from `@shadowcat/core`. The definition both the drawn box
  and the movement gate's collision radius are read from is `scene::footprint`
  (`shadowcat-codebase-scene-rendering`) — a size formula re-derived here would be the
  forked-decision defect that seam exists to remove, and the shape/size an extent is computed from
  are additionally gated per recipient, so a client cannot assume one exists for every token it can
  see. `EffectiveActor.visionModes: VisionAssignment[]` — projected by `project()` as
  `overrides?.vision ?? base.vision ?? []` (per-token override **replaces** actor base, not merged).
  **`resolveTokenVisual(token, store, eff?) -> RenderVisual | null`** — the render-boundary
  visual resolver, sibling to `resolveTokenActor`/`resolveTokenBox`/`resolveConditions`. Reads
  `actor?.visual ?? token.engine.visual` (the projected `EffectiveActor.visual` — an
  actor-override-then-base precedence identical to every other overridable field — falling back to
  a raw token's own `engine.visual` when there's no actor at all); when that resolves to
  `{kind:"faces"}`, applies precedence **manual `token.engine.face` (if it names an existing face) >
  first `faceMap` entry matching an id in the token's RAW `EffectiveActor.conditions[]`, in array
  order (NOT `resolveConditions`'s enriched `{id,name,icon}` — the raw id list) > `default` (if it
  names an existing face) > first object key > `null` if `faces` is empty**. Fails closed
  (`null`) on: no visual at all; a `"faces"` visual with zero entries; a resolved face/visual whose
  `kind` isn't `"image"`/`"animated"` (defense against a malformed nested `faces`-within-`faces`
  value, which the type system forbids but a hand-edited/legacy doc could still contain); and a
  malformed `AnimatedSource` (`isValidAnimated`: non-finite/`<=0` `fps`, an empty `frames` array, or
  a non-positive/non-integer `rows`/`cols` for a `sheet` source). Optional pre-resolved `resolveTokenVisual.eff` avoids
  a second `resolveTokenActor` call, mirroring `resolveTokenBox`'s convention.
  `selectedFaceNamesFor(token, store) -> string[]` — the effective face-name list for a
  `"faces"`-union visual (`[]` if the effective visual isn't `"faces"`); shares `resolveTokenActor`'s
  projection with `resolveTokenVisual`, so the face-swap palette (`FaceSwapPalette`, below)
  can't diverge from what actually renders.
- The `actors` module (`ActorsPanel`, `VisualKindEditor`, `FaceSwapPalette`)
  — `ActorsPanel`: create/list/pick actors; hide-name control; faction assignment; shape editing —
  the authored field is `ActorEngine.shape`, a bare string on the server, so its two values are
  enumerated only by the read-through projection's literal union
  (`EffectiveActor.square`/`EffectiveActor.circle`), which is what the citation names — plus size
  (fractional grid-cells) editing, both in the create form and in the per-row
  GM inline editor; darkvision range authoring (create + per-row), writing `engine.vision: [{
  mode: "darkvision", range }]` (omitted when range 0).
  **Visual authoring (`VisualKindEditor`):** a visual-kind editor (image / faces / animated) in the
  actor-creation form, mounted by `ActorsPanel` and driven by an `onBuild` callback prop.
  Every asset pick goes through `AppContext.pickAsset` (the asset-browser pick modal): the
  editor's shared asset-pick snippet renders a pick BUTTON (face / sheet / top-level image,
  single pick) and the frames flow is one ordered multi-pick that REPLACES `anim.frames`
  wholesale — there is no in-editor `listAssets` grid any more, and a cancelled pick (`null`)
  leaves state untouched
  (`ActorsPanel` still owns `conditionOptions` and the aggregate create-form reset, calling the
  child's exposed `reset()`). `buildVisual()` (in `VisualKindEditor`) validates per-kind
  completeness for EVERY face row (an image row needs `asset`; an animated row needs non-empty
  `frames` or a chosen `sheetAsset` — a failing row nulls the WHOLE `faces` visual, disabling
  submit) via the shared `animSourceComplete(anim)` helper (also backs the top-level animated-kind
  completeness check — a single "frames-nonempty AND sheet-asset-present" rule, not two divergent
  copies), face-row name uniqueness (a duplicate name nulls the visual), and that `defaultFace`
  names an existing row (else nulls the visual); a stale `faceMapRows` entry referencing an
  absent face (row name changed or row deleted) is silently DROPPED rather than failing the
  whole visual.
  **Per-TOKEN face-swap palette (`FaceSwapPalette`, prop `{ tokenId: string
  | null }`, mounted by `ActorsPanel` as `<FaceSwapPalette tokenId={selectedTokenId} />`):**
  distinct from the per-actor creation-form editor; shows only when the selected token's effective
  visual is `"faces"`, resolved via `selectedFaceNamesFor(token, store)` — a thin
  wrapper over `resolveTokenActor` that reads the SAME override-projected `EffectiveActor` that
  `resolveTokenVisual` independently resolves through `resolveTokenActor` too, so a token's
  `overrides.visual` faces-union can never diverge between what renders and what the palette
  offers to swap to (pinned by an `actor.test` case combining an `overrides.visual` faces-union
  with an active `token.engine.face`). Clicking a face name dispatches a `/engine/face` update on
  the TOKEN doc.
  **Load-bearing convention: the dispatched update's `old` reads the RAW stored `token.engine.face`**
  (never a resolved/defaulted value) — the same raw-`old` convention already established for other
  config-doc field-toggle editors in this codebase (e.g. the `snapToGrid` toggle) — a
  resolved/defaulted `old` would mismatch the server's field-level optimistic-concurrency check
  after the first successful write.
  **Actor browser:** a search input drives live FTS via `ctx.searchDocuments` (the
  subscription seam, wired through `AppContext`/`WorldSession`) — an EMPTY
  query renders the existing reactive full `ctx.documents.query("actor")` list; a NON-EMPTY query
  opens a `subscribeSearch` handle keyed on the query string, torn down/recreated on every query
  change and on unmount. Deliberately NOT reconnect-resilient (unlike `subscribeScene`) — a
  dropped connection just means the next keystroke re-subscribes; no `#sceneSubs`-style
  bookkeeping. The `onUpdate` callback MUST check its own `cancelled` flag as its first statement,
  not only at the `.then()`/cleanup level — `WsClient.subscribeSearch`'s initial page resolves
  SYNCHRONOUSLY inside the pending-resolve handler, strictly BEFORE the caller's `.then()` runs,
  so an abandoned query's late first page can otherwise overwrite a newer query's results
  (verified by tracing the real `WsClient` dispatch order). Each row also
  gets an "Open sheet" button (`ctx.openDocument({docId: a.id})`, [[shadowcat-codebase-sheets]]).
- The `factions` module (`FactionsPanel`) — GM editor + idempotent seed of
  the faction registry (extracted into `seedFactionRegistryIfAbsent(store, worldId,
  dispatchIntent)` for testability); faction-colored token border + select-by-faction.
  **Deterministic singleton-seed id (reference implementation for other config-doc seeders):**
  the seed doc's id is `deterministicId(worldId, "faction-registry")`
  (re-exported from `@shadowcat/core`) — a synchronous UUID-v5-SHAPED hash (four
  seeded FNV-1a 32-bit mixes, not true SHA-1 UUIDv5, because every doc builder in the `scene-docs`
  module is synchronous and Web Crypto's SHA-1 is async) rather than `crypto.randomUUID()`. Two GMs
  racing to seed a brand-new world compute the SAME id — the load-bearing property is SAME ID,
  NOT byte-identical content: `envelope()`'s `created_at`/`updated_at` stamp via `Date.now()` per
  call, so the two racers' Creates genuinely differ there. The server's singleton create-gate
  (doc_type-scoped, not id-scoped — see
  `shadowcat-codebase-documents-permissions`) rejects the losing Create, the existing
  `WsClient.onReject` → `OptimisticClient.reject` rollback path discards the loser's local
  prediction automatically, and because both racers used the same id the winner's confirmed doc
  lands under that same store key — no explicit conflict-catching code is needed (or possible:
  `AppContext.dispatchIntent` is fire-and-forget with no per-call reject signal exposed to
  modules). `seedFactionRegistryIfAbsent` short-circuits via `store.get(id)` before dispatching.
- The `conditions` module (`ConditionsPanel`) — GM editor + idempotent emoji seed
  of the condition registry (extracted into `seedConditionRegistryIfAbsent(store, worldId,
  dispatchIntent)`, mirroring `seedFactionRegistryIfAbsent`'s shape exactly, including the
  deterministic `deterministicId(worldId, "condition-registry")` seed id) + a
  token-selection-driven toggle palette; render via
  `TokenNodeSpec.badges` (upright glyph chips). Toggle gated by `AppContext.canEdit(doc, path)`
  (GM or token owner).

## Hard invariants

- **Token ownership is EFFECTIVE, resolved server-side at authz time — never stamped at create.**
  `effective_owner(token) = the token's own `/owner`, else the LINKED
  actor's owner` (`data::permission::effective_owner`; server join in
  `SqliteRepository::load_effective_owner`, ECS
  side in `SceneEcs::token_effective_owner`, client mirror `effectiveOwner`). A GM sets
  the per-token override; actor ownership is assigned on the actor, so re-assigning an actor moves
  authority over **every** linked token with no re-stamp — which is the whole point of resolving
  rather than copying. **State the precedence rule exactly ONCE**: a DB join that
  short-circuits on the token's own owner expresses the same precedence a second time, and two
  copies of one rule cover for each other — an inverted-precedence mutation then survives, because
  either copy alone still produces the right answer.
  - **Fail-closed** on a missing link, a dangling link, an `actor.id` that does not match the link, a
    non-`actor` `doc_type`, or an unowned actor — no owner means no write, never a fallback to
    "world member". (Cycles are unrepresentable: only tokens carry the link.) The actor join is **scope-checked**: an actor whose
    `scope` differs from the token's is discarded, so the DB join's reachable set matches the ECS's
    (room hydration loads actors `WHERE world_id = ?`).
  - **Instanced tokens are deliberately NOT links.** `embedded.actor[0]` is a frozen copy;
    inheriting from it would be the stamped semantics this design rejects.
  - **The floor is token-scoped**, so `owner` keeps its provenance-only meaning on every other
    doc_type — an actor's owner cannot edit their own sheet. Deliberate.
  - **`/owner` is Update-writable under `cap::EDIT_PERMISSIONS`** (an immutable `/owner` would make
    GM ownership re-assignment unbuildable). `DocRole::Owner`'s BUILT-IN floor is
    `{READ, WRITE_FIELDS}` and excludes `EDIT_PERMISSIONS`, so an effective owner cannot steal or
    hand off ownership — but the floored role also selects additive `by_role[Owner]` grants, so a
    deployment that puts `EDIT_PERMISSIONS` there lets an owner pin `/owner = self` (defeating
    GM re-assignment) and rewrite `/permissions` to lock the GM out. The capability semantics are
    exactly a *stamped* owner's; what differs is the POPULATION — "Owner" is every player with an
    assigned actor, not a hand-enumerated set.
  - **Egress redaction resolves ownership through this same rule** — `resolve_access`'s
    `is_owner` comes from an explicit effective-owner parameter, so redaction and write authz
    cannot disagree about who owns a token. The per-call-site join sources are egress territory:
    `shadowcat-codebase-documents-permissions`.
- **Rendered token size, hit-test, and the selection ring all resolve through `resolveTokenBox`** —
  never read `token.engine.w/h` directly for an actor-backed token. Those authored fields are only
  the FALLBACK the read-through applies when the server has stated no extent; reading them
  directly ignores the server's resolved extent whenever one exists (they differ for a multi-cell
  token, and on hex for every token) and ignores the shape override, causing the render size, click
  target and selection ring to diverge. Deriving a size instead — from `EffectiveActor.size` times
  the grid cell — is worse still: that is a second footprint formula, and the drawn geometry would
  then disagree with the geometry the server's movement gate collides with.
- **Instanced token's embedded actor copy needs `structuredClone`, not `{...}`** — a shallow copy
  aliases nested `system`/`permissions`/`embedded` with the source until the wire round-trip
  [[embedded-copy-needs-deep-clone]].
- **Registries are config-documents** (world-scoped, parentless, runtime-editable), not hardcoded.
  Keyed by id as a **map**, so adding an entry is a single-key Update (factions, conditions).
- **Engine owns the mechanism, a replaceable first-party module owns the content** — `module-factions`
  / `module-conditions` seed default content (idempotent GM seed); a game-system module replaces
  them wholesale. The registry/resolution/render seams stay engine-side.
- **Condition toggling is capability-gated client-side via `AppContext.canEdit(doc, path)`** — an
  advisory mirror of the server's Update-path check (GM bypasses; a non-GM needs the doc-role
  write cap). The server stays authoritative; the gate only shows/hides the control.
- **Name privacy rides the existing redaction layer** — `setNameHidden` flips `/name` (the
  envelope field) to `OwnerOrGm`; the owner still sees it,
  others get the `actorDisplayName` fallback. Enforcement is server-side and fail-closed (see
  `shadowcat-codebase-documents-permissions`).
- **`TokenEngine::validate` shares ONE coordinate bound with the
  movement gate, structurally.** Every numeric field must be finite, and `x`/`y` must fall
  within `scene::move_exec::MAX_GATE_WALK_COORD` — the same symbol the server-authoritative
  move gate reads (`shadowcat-codebase-scene-rendering`'s `Room::publish`/`gate_walk`), not a
  copied literal. Runs on every GM-write/Create ingress of a `token` doc via
  `data::engine::normalize_engine`'s `"token"` arm, so a token can never be CREATED
  outside the range the move gate would later refuse to walk it into. An anti-drift test
  (`ingress_bound_equals_gate_walks_exactly`) pins parity with the gate's own bound test.

## Gotchas

- **A `$state`-declared value re-wraps ANY object/array assigned into it as a deep reactive
  Proxy — including one already built as a fresh, plain object literal.** `ActorsPanel`'s
  `pendingVisual = $state<TokenVisual | null>(null)` is fed by `VisualKindEditor`'s `onBuild`
  callback; even though `buildVisual()`/`animSourceToSource()` construct fresh literals per the
  "no stale sibling field" invariant above, the `pendingVisual = v` ASSIGNMENT itself re-proxies
  the whole tree, because that is how `$state` works for any object it is handed — copying at the
  BUILD site cannot prevent this. A reactive Proxy array/object surviving into a document
  `ctx.dispatchIntent` persists then breaks `structuredClone` wherever that document is later
  deep-cloned (e.g. `buildTokenFromActor`'s instanced-token branch,
  `structuredClone(actor)`) — Chromium's algorithm reports a generic
  `DataCloneError: ... could not be cloned` with NO indication which nested field is the
  culprit, even though every value walked plain-JS-side looks ordinary (a JS array-type check
  reports true, and its prototype compares equal to the built-in array prototype) — only cloning
  the SAME array in isolation vs.
  a fresh spread-copy of it (`[...arr]`) distinguishes a reactive Proxy from a plain array. **The
  fix is `$state.snapshot(pendingVisual)` at the READ site** (`ActorsPanel.create()`), not a copy
  at the build site — `VisualKindEditor` cannot prevent the re-wrap its caller's own `$state`
  imposes after the callback returns. Any future host component reading a `$state` field to embed
  into a `ctx.dispatchIntent` document must snapshot it the same way.
- **`ConditionsPanel`'s `isActive`/`toggle` share ONE canEdit-gated target set.** Both read
  `editableTargets()` — every selected token resolving a `conditionTarget` AND passing
  `ctx.canEdit` — so a non-editable token in the selection can no longer make the palette chip's
  active/mixed display, or the click's ADD/REMOVE direction, diverge from what the editable
  tokens alone would show. `isActive` reports `false` (never "active") when zero editable
  targets exist, mirroring its prior no-targets convention.
- **Docs-ratchet is live on `data::engine::token`:** it carries
  `#![deny(missing_docs)]` + the private-items twin — a new undocumented field/variant on
  `TokenEngine`/`ActorEngine`/`TokenVisual`/`AnimatedSource` fails the 3-OS CI clippy step, and
  doc comments flow into the ts-rs bindings (regenerate + commit them with the change).

- **Linked vs instanced provenance diverges**: a linked token reflects later actor edits; an
  instanced copy is frozen at placement. Instanced re-sync against the source is deferred
  [[document-inheritance-merge-model]].
- **Tokens are Container sprites behind a `TokenVisual` source abstraction — image, animated, and
  multi-face (`"faces"`) visuals all ship today.** `generated` (procedural) and fx/emote
  remain forward-looking [[token-architecture-forward-looking]]. Don't bind rendering
  to raw image URLs or assume a token has exactly one static image — always resolve through
  `resolveTokenVisual`, never read `actor.visual`/`token.system.visual` directly.
- **Token on-scene placement is excluded from template merge:** `/engine/x`, `/engine/y`,
  `/engine/rotation` are always instance-owned — never pulled, pushed, reverted, or flagged
  `SyncState.template_changed` by the merge engine (`placementExclusions("token")`). See
  `shadowcat-codebase-templates`.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/engine/token/` (rustdoc, private items included —
  `TokenEngine`/`ActorEngine`/`TokenVisual`/`AnimatedSource`),
  `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the `scene-docs`/`actor` modules),
  `/api/ts/modules/_shadowcat_module-actors.html`, `_shadowcat_module-factions.html`,
  `_shadowcat_module-conditions.html`. Produce with `pnpm build:all`.
- Design rationale: `docs/superpowers/specs/` (token design docs, incl. faces + animated visuals);
  data-model context in `docs/design/M2-data-foundation.md`.
- Relationships:
  `graphify query "actor token linked instanced resolveTokenActor EffectiveActor faction visual face"`.
- Forward-looking visual pipeline (generated/fx/emotes still open): [[token-architecture-forward-looking]].
