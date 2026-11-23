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
(no mechanical effects): icon badges overlaid on the token, plus optional registry-authored art
fx (`Condition.fx`), toggled by the GM or the token owner.

## Key files & seams

Per-module entries for the scene-docs module, token node specs, conditions and badges, vision, face maps and the actor and token editors, with the seams between them. Read references/key-files-and-seams.md before editing actor or token code or when a task names one of those areas.

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
    `{READ, WRITE_FIELDS}` (`role_floor`); the DELETE of that token belongs to the token's EFFECTIVE
    owner, not to the role, so a stamped `permissions.users` Owner on a token and an Owner of any
    other doc_type gain no delete (`resolve_access` adds it from
    `holds_token_owner_floor`, the ONE test `effective_role` also uses, so the role and the
    delete grant cannot disagree on who owns the token; client mirror: `resolveCaps` adds
    `core:delete` for an effective owner). It excludes `EDIT_PERMISSIONS` and the embedded-document
    management caps, so an effective owner cannot steal or hand off ownership — but the floored role also selects additive `by_role[Owner]` grants, so a
    deployment that puts `EDIT_PERMISSIONS` there lets an owner pin `/owner = self` (defeating
    GM re-assignment) and rewrite `/permissions` to lock the GM out. The capability semantics are
    exactly a *stamped* owner's; what differs is the POPULATION — "Owner" is every player with an
    assigned actor, not a hand-enumerated set.
  - **Egress redaction resolves ownership through this same rule** — `resolve_access`'s
    `is_owner` comes from an explicit effective-owner parameter, so redaction and write authz
    cannot disagree about who owns a token. The per-call-site join sources are egress territory:
    `shadowcat-codebase-documents-permissions`.
- **Rendered token size and hit-test resolve through `resolveTokenBox`** —
  never read `token.engine.w/h` directly for an actor-backed token. Those authored fields are only
  the FALLBACK the read-through applies when the server has stated no extent; reading them
  directly ignores the server's resolved extent whenever one exists (they differ for a multi-cell
  token, and on hex for every token) and ignores the shape override, causing the render size and
  click target to diverge. Deriving a size instead — from `EffectiveActor.size` times
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

- **GM-only token fields** (`/engine/lock_rotation`, `facing_vision` on the token, its overrides and the
  actor, the carried light and the hidden-identity flag) are one list, `gm_only_field_touched`, enforced
  on Create, Update and the `TemplateMerge` path. A control that writes one must be GM-only in the UI
  too (`TokenRotationLockControl`, `TokenFacingVisionControl`, `TokenIdentityHiddenControl`). Detail:
  references/token-fields-bars-identity-and-editing.md.
- **Identity and display fields resolve for non-owners without the actor.** A non-owner gets no actor
  join; `resolveTokenActor` tolerates absent copy identity fields, the generic silhouette stands in
  for a withheld visual, and a token carries no faction (disposition comes from the actor's faction
  stance or the token override). Detail: references/token-fields-bars-identity-and-editing.md.

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
  `ctx.canEdit` — so a non-editable token in the selection cannot make the palette chip's
  active/mixed display, or the click's ADD/REMOVE direction, diverge from what the editable
  tokens alone would show. `isActive` reports `false` (never "active") when zero editable
  targets exist, the same as with no targets at all.
- **Docs-ratchet is live on `data::engine::token`:** it carries
  `#![deny(missing_docs)]` + the private-items twin — a new undocumented field/variant on
  `TokenEngine`/`ActorEngine`/`TokenVisual`/`AnimatedSource` fails the 3-OS CI clippy step, and
  doc comments flow into the ts-rs bindings (regenerate + commit them with the change).

- **Linked vs instanced provenance diverges**: a linked token reflects later actor edits; an
  instanced copy is frozen at placement. Instanced re-sync against the source is deferred
  [[document-inheritance-merge-model]].
- **Tokens are Container sprites behind a `TokenVisual` source abstraction — image, animated,
  multi-face (`"faces"`), and generated (parametric frame: crop + decorative ring + background
  around an image/animated art) visuals all ship today,** as do aura emission discs (a
  `TokenNodeSpec.aura` filled ellipse under the art, resolved by `TokenView.toSpec` from
  `EffectiveActor.aura` with radius × the view's own `setWorldUnitsPerCell` cell-size source — never
  a second grid formula), and built-in per-token art fx + emote overlays
  (`shadowcat-codebase-scene-rendering` covers both). Sound/VFX PLAYBACK
  remains forward-looking [[token-architecture-forward-looking]] — the emission structs are
  stored, playback-ready data with no consumer yet. Don't bind rendering
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
- Forward-looking visual pipeline (sound/VFX playback still open): [[token-architecture-forward-looking]].

## Reference files

| File | Holds | Read it when |
| --- | --- | --- |
| references/key-files-and-seams.md | The Key files & seams section: per-module entries for actors and tokens | Editing actor or token code, scene-docs, conditions, vision or face maps |
| references/token-fields-bars-identity-and-editing.md | Bars, facing vision, rotation lock, disposition, art transform, overlays, quick edit, delete, quick bars | Adding or changing a token or actor field, an override editor or a token control |
