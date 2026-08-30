---
name: shadowcat-codebase-sheets
description: "Use when touching the Shadowcat sheet registry: the `shadowcat.sheet:<doc_type>` contract family, `pickSheet`/`resolveDocRef`/`SheetRef`/`SheetTarget` in @shadowcat/core, `ctx.openDocument`, `SheetsController` (dynamic sheet:<docId> panel registration, wraps every sheet in `SheetHost`), `setField`/`SystemTreeEditor` (the OCC edit path), or the generic actor/item/fallback sheet modules. Covers src/client/core/src/sheets.ts + src/client/ui-kit/src/{sheetsController.svelte.ts,sheetEdit.ts,SystemTreeEditor.svelte,SheetHost.svelte} + src/modules/sheet-{fallback,actor,item}/**. For the panel-manager internals sheets mount into (layout tree, floating placement) invoke shadowcat-codebase-panels; for the template chrome `SheetHost` renders and the merge engine behind it invoke shadowcat-codebase-templates. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Sheet Registry (document panels)

Orientation for the sheet system: every document (actor, item, and any doc_type a mod
introduces) is openable as a floating panel, edited through field-path Updates with real OCC
pre-images.

## Purpose

Sheets are **document panels** — runtime `Contribution`s under the existing `shadowcat.panel`
contract with id `sheet:<docId>`, registered on demand by `SheetsController` and mounted by the
already-shipped `PanelHost` ([[shadowcat-codebase-panels]]). A separate `shadowcat.sheet:<doc_type>`
contract family (plus an always-registered `shadowcat.sheet:*` fallback) resolves which sheet
COMPONENT to show for a document; `ctx.openDocument(ref)` resolves the doc + its write site, picks
the sheet, and opens/focuses the panel. This is the seam mods use to add their own sheets — see
`shadowcat-codebase-documents-permissions` for the client-only `ITEM_DOC_TYPE` document type.

## Key files & seams

- The client `sheets` module — pure, no Svelte/panel-manager import:
  - `SHEET_CONTRACT_PREFIX`/`SHEET_FALLBACK_CONTRACT`/`sheetContract(docType)`.
  - `SheetRef = { docId: string; embeddedPath?: string } | { tokenId: string }` — `embeddedPath`
    is a ONE-level `/embedded/<coll>/<idx>` extension beyond the base docId/tokenId union, added to
    honor the generic actor sheet's "open an inventory item" requirement.
  - `resolveDocRef(ref, store) -> SheetTarget | null` — write-site resolution (the security-adjacent
    surface). `SheetTarget = { panelId, doc, writeDocId, writePrefix }`.
    - top-level `docId` → itself, `/system`.
    - linked token (`tokenId` with `actor_id` set) → the SHARED actor doc, `/system` (mirrors
      `resolveTokenActor`/`conditionTarget`; intentional dedup — a linked token and its actor
      resolve to the identical `SheetTarget`, including `panelId`).
    - instanced token (embedded actor copy) → the TOKEN doc's `/embedded/actor/0/system`, with
      panelId `sheet:<tokenId>/embedded/actor/0` — self-describing, NOT the bare `sheet:<tokenId>`
      (see Hard Invariants: the panelId-collision rule).
    - embedded child (`docId` + `embeddedPath`) → `/embedded/<coll>/<idx>/system`.
    - fail-closed: every dangling/raw/malformed ref returns `null`, never throws.
  - `pickSheet(registry, doc) -> component | null` — doc_type providers + the `*` fallback,
    match-filtered, priority DESC (relational comparison, not subtraction — `-Infinity` ties would
    produce `NaN` otherwise), tie-broken by lexicographically LOWEST registering module id,
    deduped by `Contribution` object identity (not id string — ids aren't namespace-unique across
    contracts).
  - `isDiceNotation(s)` — client-only heuristic (`NdM[+-K]`) gating the roll-to-chat affordance;
    the server owns real parsing.
- The client `contributions` module — `Contribution.sheet?: SheetMeta { priority; match? }`;
  `ContributionRegistry.entriesFor(contract)` (module-tagged, `pickSheet`'s data source);
  `DefaultPlacement` includes `{ kind: "floating" }` alongside `docked`/`minimized`.
- The ui-kit `sheetsController` module — `SheetsController` (shell-constructed like
  `PanelsBridge`; imports no module): `openDocument(ref)` (resolve → dedup via internal panelId
  map → `pickSheet` → register `Contribution` → `panels.open`, or `panels.focus` if already
  registered), `closeDocument(panelId)` (disposes the contribution AND closes the panel —
  symmetric), `restoreFromPersisted(blob)` (boot restore: deep-walks the persisted layout blob
  for any `sheet:*` string, reverse-parses `docId`+`embeddedPath` from the id shape, re-registers
  only resolvable ones — NEVER calls `open()`, relying entirely on the panel manager's own
  late-registration/`placeFromPersistedLocation` path to restore float/dock/minimize state;
  idempotent).
  - **`#register` registers `SheetHost`, not the picked sheet directly.** The picked
    `component` (from `pickSheet`) is never the contribution's own `component`;
    `#register` ALWAYS registers `SheetHost` (`@shadowcat/ui-kit`) as the panel's
    `component`, forwarding the picked component as `props.inner` alongside `props.docId`/
    `props.systemPrefix`/`props.close`. `SheetHost` renders `TemplateControls` (the source
    badge + pull/revert/push chrome, see `shadowcat-codebase-templates`) above `props.inner`, so
    EVERY sheet — first-party or mod-provided — gets template chrome for free without opting in.
    Any future sheet-registration change must preserve this wrapper; do not re-register the
    picked component directly, or every doc_type silently loses its template controls.
- The ui-kit `appContext` module — `AppContext.openDocument(ref: SheetRef): void`, wired in
  `Table` via a shell-constructed `SheetsController`, called reactively inside a
  `createSubscriber`-backed `$effect` on boot (panels mount before resync fills the store —
  [[contribution-seed-reactive-before-resync]]-class hazard).
- The ui-kit `sheetEdit` module — `setField(ctx, docId, path, old, value)`: the ONE
  field-path Update dispatch every sheet uses. `old ?? null` collapses ONLY a genuinely-absent
  (`undefined`) pre-image — `0`/`false`/`""` pass through verbatim (see Hard Invariants).
- **`SystemTreeEditor`** — recursive type-aware editor over the opaque
  `system` body (string/number/boolean/null/object/array; add/remove fields; array-item add seeds
  a value MATCHING the array's existing element kind, not a hardcoded `""`). Self-recurses via
  `import Self from "./SystemTreeEditor.svelte"`; every level computes its OWN `old` at its own
  `basePath` via a fresh `getPointer(doc, path)` read.
- `@shadowcat/module-sheet-fallback`/`-actor`/`-item` — the three generic sheets, each `sheetContract`
  registered (fallback at `-Infinity`, actor/item at `0`). `sheet-item` introduces the client-only
  `ITEM_DOC_TYPE` doc_type ([[shadowcat-codebase-documents-permissions]]) and the roll-to-chat affordance
  (`ctx.chat.send({channel:"general", content:"/roll <formula>"})`, gated by `isDiceNotation`).
  Seam-only: none of the three imports any other `@shadowcat/module-*`.
  **`basePrefix` derivation pattern (`ActorSheet`/`ItemSheet`):** the three-band document
  restructure (envelope `name` / typed `engine` / opaque `system`) put `name`/`engine` at the SAME
  tree node as `system` — `systemPrefix` (the `SheetTarget.writePrefix` from `resolveDocRef`) is
  ALWAYS `/system` or `/embedded/<coll>/<idx>/system`, so both sheets derive the sibling roots by
  stripping the trailing `/system` suffix: `const basePrefix = $derived(systemPrefix.replace(/\/system$/, ""))`,
  then `enginePrefix = ${basePrefix}/engine` and `namePrefix = ${basePrefix}/name`. **This is the
  load-bearing pattern for any FUTURE sheet that needs to read/write the envelope `name` or a
  typed `engine` field** — do not hand-derive these paths any other way. `systemPrefix`/
  `writePrefix` ITSELF still genuinely means `/system` — game-system
  data is untouched by the three-band restructure; only the DERIVED `enginePrefix`/`namePrefix`
  are new. `setField`'s `old` for an engine-field edit reads the RAW current value via
  `getPointer(doc, enginePrefix + "/" + field)`, mirroring the raw-`old` invariant
  above — no special-casing needed since `setField` is already path-generic. **Reading the
  envelope `/name` path DIRECTLY, rather than via `namePrefix`, corrupts an embedded item:** for
  an item opened from an actor's inventory, `/name` targets the PARENT ACTOR's name, not the
  item's own, so a read shows the wrong name and an edit renames the wrong document. Both sheets
  therefore derive `namePrefix` from `basePrefix`. Any future sheet touching an embedded child must
  derive `namePrefix`/`enginePrefix` from ITS OWN `systemPrefix`, never read `/name`/`/engine` as
  a hardcoded top-level path — treat any new envelope-band access in a sheet as needing
  independent review by default.
- **`MessageCard`** (`@shadowcat/module-chat-card`) — actor names on chat cards become
  `ctx.openDocument` links, permission-gated by PRESENCE in the recipient's per-recipient
  optimistic store (a doc absent from `ctx.documents` means the recipient lacks READ — server-side
  redaction is the sole gate; no client-side permission check duplicates it).

## Hard invariants

- **`old` in every `setField`/`SystemTreeEditor` dispatch is the RAW current stored value** — never
  `null` when the field is present, never a resolved/defaulted value. The server's `apply_intent`
  enforces field-level OCC (`actual != change.old` → `Conflict`); a wrong `old` either permanently
  rejects the sheet's own edits or (worse) can overwrite a concurrent edit. The rule is the same
  one `GameSettingsPanel`'s own field toggles obey, generalized to every sheet.
- **Every sheet component's `doc`/`system`-derived `$derived` MUST bridge `ctx.documents` reactivity
  via `createSubscriber`/`subscribe()`** (mirrors `GameSettingsPanel`). `ctx.documents`
  (`OptimisticClient`) is a plain-callback store, not a Svelte rune — a `$derived.by(() =>
  ctx.documents.get(docId))` with no `subscribe()` call freezes at the component's FIRST read and
  never re-derives, including in response to the sheet's OWN prior edits in the same session. This
  silently corrupts the OCC `old` on any second edit, and for a compound field (e.g. `size:{w,h}`),
  silently reverts the untouched sibling sub-field. It reproduces against a real
  `OptimisticClient`, and is the highest-consequence mistake available in this subsystem —
  it produces no error, only wrong data. `subscribe()` is called as the FIRST
  statement inside every `$derived.by` that reads `ctx.documents` DIRECTLY (`doc`, and any sibling
  derived independently calling `ctx.documents.query(...)`, e.g. `factions`); a derived that reads
  another already-reactive derived (`system`/`readOnly` off `doc`) needs no separate call.
- **Sheets read the OPTIMISTIC view (`ctx.documents`), never `ctx.store`**
  [[render-from-optimistic-view]] — this is also load-bearing for the OCC-pre-image invariant
  above: a sheet wired to `ctx.store` would read a pre-optimistic-update snapshot and dispatch a
  stale `old`, the same failure mode as a missing subscription.
- **The instanced-token `panelId` is self-describing** (`sheet:<tokenId>/embedded/actor/0`, not the
  bare `sheet:<tokenId>`) — the bare form is string-identical to a plain top-level docId panelId,
  which would make `restoreFromPersisted`'s reverse-parse silently rebind an instanced token's
  persisted sheet to the TOKEN's own `/system` on reload instead of its embedded actor. Any new
  `SheetRef` variant must keep its `panelId` distinguishable from every other variant's shape by
  this same reverse-parse.
- **`pickSheet`'s priority tie-break uses relational comparison, not subtraction** —
  `-Infinity - -Infinity` is `NaN`, which the standard array sort treats as "equal" (skipping the
  module-id tie-break) rather than throwing; two providers sharing a non-finite priority (e.g. two
  modules both registering a generic fallback) would silently fall back to registration order.
- **Sheet modules import ONLY `@shadowcat/core`/`@shadowcat/ui-kit`/`@shadowcat/types`** — no
  cross-module import; `openDocument`/the registry resolver are
  generic host glue (core/ui-kit), never a module.

## Gotchas

- `ctx.contributions.contribute(c)` is a **1-arg** call — the real `ModuleContext.contributions`
  wrapper (the `modules` module's `activate()`) auto-injects the module id; passing a second `{module}` arg
  is a `svelte-check` error. (Every first-party module already does this; a stale 2-arg snippet
  will not compile.)
- A sheet's root element must be `<div role="dialog">`, not `<section role="dialog">` — Svelte's
  a11y linter flags a non-interactive element (`<section>`, implicit role `region`) carrying an
  interactive role.
- `resolveDocRef`/`pickSheet` are pure and fail-closed by returning `null` — never throw on a
  malformed/non-object `ref` (guard `!ref || typeof ref !== "object"` before any property access).
- An `aria-label` always overrides an element's visible text as its accessible name — a STATIC
  `aria-label` on a per-item control inside an `{#each}` (e.g. a roll-to-chat button per
  dice-notation field) makes every instance announce identically; either omit it and let the
  per-item visible text serve as the accessible name, or template it per-item.
- `SheetsController.restoreFromPersisted` deep-walks the persisted blob for `sheet:*` strings —
  it is intentionally agnostic to the blob's exact schema (robust to the panel persistence shape
  evolving) but DOES assume the `sheet:` id prefix and the reverse-parseable `docId`/`embeddedPath`
  shape hold for every panelId a `SheetTarget` ever produces (see the panelId-collision invariant).

## Pointers

- **Generated API** — `/api/ts/modules/_shadowcat_core.html` (TypeDoc — the `sheets` module),
  `_shadowcat_ui-kit.html` (`SheetsController`/`SheetHost`/`SystemTreeEditor`),
  `_shadowcat_module-sheet-actor.html`, `_shadowcat_module-sheet-fallback.html`,
  `_shadowcat_module-sheet-item.html`. Produce with `pnpm build:all`.
- Relationships: `graphify query "sheets registry openDocument SheetsController resolveDocRef pickSheet setField"`.
- Panel-manager internals sheets mount into: [[shadowcat-codebase-panels]].
- Document/permission model + the client-only `ITEM_DOC_TYPE` doc_type: [[shadowcat-codebase-documents-permissions]].
- `SheetHost`'s `TemplateControls` chrome + the 3-way merge engine it drives:
  [[shadowcat-codebase-templates]].
