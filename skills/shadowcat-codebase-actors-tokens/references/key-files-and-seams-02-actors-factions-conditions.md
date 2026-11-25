Part of the shadowcat-codebase-actors-tokens skill; read it when editing the actors panel, factions or conditions modules. Part 02 of 02 of "Actors and tokens: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-scene-docs-and-actor.md.

- The `actors` module (`ActorsPanel`, `VisualKindEditor`, `FaceSwapPalette`,
  `TokenEmissionControl`, `TokenVisualControl`, `TokenMovementControl`)
  — `ActorsPanel`: create/list/pick actors; hide-name control; faction assignment; shape editing —
  the create `<form>` is gated by `ctx.canCreate(ACTOR_DOC_TYPE)` (hiding exactly what the
  server's `core:create` gate would refuse; carried-light/hide-name/ownership stay `role === "gm"`-gated, since those are
  Update-path GM affordances, not the Create gate — see `shadowcat-codebase-client-shell`'s
  `canCreate`/`canDelete` bullet, in its references/session-state-theming-and-chat-seams.md) —
  the authored field is `ActorEngine.shape`, a bare string on the server, so its two values are
  enumerated only by the read-through projection's literal union
  (`EffectiveActor.square`/`EffectiveActor.circle`), which is what the citation names — plus size
  (fractional grid-cells) editing, both in the create form and in the per-row
  GM inline editor; vision-mode assignment authoring (create + per-row) — the same
  `VisionAssignment` editor the vision bullet in key-files-and-seams-01-scene-docs-and-actor.md describes: there is no darkvision-only
  field, darkvision is one mode assignment among the registry's, and clearing it writes
  `null`/`[]`, never an assignment with no range.
  **Visual authoring (`VisualKindEditor`):** a visual-kind editor (image / faces / animated /
  generated — the `generated` kind authors a `TokenVisual::Generated` frame: one image/animated
  art pick plus crop/border/background state) in the
  actor-creation form, mounted by `ActorsPanel` and driven by an `onBuild` callback prop. Its
  optional `initial?: TokenVisual` prop seeds every editor state from an existing visual ONCE at
  mount (fail-closed on a shape the editor can't represent, e.g. a nested-`generated` `art`),
  which backs post-create editing: an actor row's edit-visual button mounts the same editor with
  `initial` set to that actor's current visual, and apply dispatches a `/engine/visual` Update
  whose OCC `old` reads the RAW stored visual (the raw-`old` convention below). The editor's
  folder list is store-subscribed (`createSubscriber` over `ctx.documents.subscribe`), so a folder
  created elsewhere appears without a remount; `ActorsPanel`'s `locatedTokenIds` resolves located
  tokens with one token query per recompute; `BarsEditor` re-keys its inline errors when a bar is
  removed so each stays on its own row.
  Every asset pick goes through `AppContext.pickAsset` (the asset-browser pick modal): the
  editor's shared asset-pick snippet renders a pick BUTTON (face / sheet / top-level image,
  single pick) and the
  frames flow is one ordered multi-pick that REPLACES `anim.frames` wholesale — there is no
  in-editor `listAssets` grid any more, and a cancelled pick (`null`) leaves state untouched
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
  **Emission authoring (`EmissionEditor` + `TokenEmissionControl`):** `EmissionEditor` lives in
  `@shadowcat/ui-kit` (beside `LightEmissionEditor` — a sheet module cannot import
  `module-actors`, the seam rule this skill and `shadowcat-codebase-sheets` both enforce; this
  module and `sheet-actor` both import it from ui-kit, never from each other), one
  controlled component for all three emission kinds (aura / sound / VFX) — props carry the current
  `AuraEmission | null` / `SoundEmission | null` / `VfxEmission | null`, `onAura`/`onSound`/`onVfx`
  callbacks report replacements (`null` = section toggled off), plus a `disabled?: boolean` prop
  (added for `ActorSheet`'s read-only rendering — `sheet-actor` wraps it in
  `<fieldset disabled={readOnly}>` AND threads the prop, since a `<fieldset disabled>` alone does
  not reach every nested control the shared markup renders); asset fields are `<select>`s over
  `listAssets(ctx.world)` filtered to `audio/*` (sound) and `image/*`+`video/*` (VFX), refetched on
  `ctx.onAssetChanged`. `ActorsPanel`'s create form mounts it with panel-owned `pendingAura`/
  `pendingSound`/`pendingVfx` `$state` (read through `$state.snapshot` at create, same convention as
  `pendingVisual`); `ActorSheet` mounts ONE instance bound to `engine.aura`/`sound`/`vfx`,
  committed through the sheet's existing `setEngine(field, next)` (whole-object write, `null`
  clears — the same wholesale-override shape `TokenOverrides` uses), with NO GM gate — emissions
  follow standard write rules; `light` alone keeps its GM gate (a vision input, unlike an
  emitter). `TokenEmissionControl` (prop `{ tokenId: string | null }`, mounted by
  `ActorsPanel` beside `FaceSwapPalette`) is the per-token override editor: it renders only for a
  LINKED selected token (an instanced token's `overrides` never project) and only when
  `ctx.canEdit(tok, "/engine/overrides")` passes, writing `/engine/overrides/aura` (…`/sound`,
  …`/vfx`) Updates with the raw stored override value as the OCC `old` (the same raw-`old`
  convention as `FaceSwapPalette`).
  **Per-TOKEN visual override (`TokenVisualControl`, prop `{ tokenId: string | null }`, mounted
  by `ActorsPanel` beside `TokenEmissionControl`):** hosts `VisualKindEditor` with `initial` set
  to the selected token's EFFECTIVE visual (`resolveTokenActor`'s projection — the same read
  `resolveTokenVisual` resolves from — so the editor opens on what the token actually renders),
  under the same linked-token-only + `ctx.canEdit(tok, "/engine/overrides")` gating as
  `TokenEmissionControl`. Apply writes the built visual to `/engine/overrides/visual`; a clear
  button (rendered only while a stored override exists) writes `null`, restoring actor
  inheritance — both with the raw stored override value as the OCC `old`, and the editor
  remounted per selected token (`{#key linkedToken.id}`) because `initial` is read once at
  mount.
  **Movement-tag authoring (`MovementTagsEditor`, in `@shadowcat/ui-kit`):** one value-only chip
  editor — a toggle chip per engine-reserved tag plus a removable chip per free-form tag and an
  add row (Enter adds without submitting a hosting form; empty/duplicate drafts are no-ops; the
  stored list is deduplicated for display and a toggle-off removes every occurrence). The OWNING
  surface normalizes its stored value and dispatches: `ActorsPanel`'s per-row editor writes
  `/engine/movement` whole-payload with the RAW stored list (`null` when the key is absent) as
  the OCC `old`, and its create form carries a `pendingMovement` `$state` read through
  `$state.snapshot`; `ActorSheet` routes through `setEngine("movement", next)` (an emptied list
  commits as `[]`, never `null` — the field is a required array, unlike `vision`);
  `FactionsPanel` edits `Faction.movement` per row through its `update(id, patch)` (and `add()`'s
  literal carries `movement: []`). `TokenMovementControl` (prop `{ tokenId: string | null }`,
  mounted by `ActorsPanel` beside `TokenVisionControl`) is the per-token inherit/custom override:
  linked tokens only, gated by `ctx.canEdit(tok, "/engine/overrides")`, writing the WHOLE
  `/engine/overrides` object with the raw stored overrides as `old` (the same shape as
  `TokenVisionControl`/`TokenLightControl`); "custom" seeds from the stored override, else the
  resolved inherited set, and a stored empty list reads as custom ("no tags"), never as inherit.
  **Actor browser:** a search input drives live FTS via `ctx.searchDocuments` (the
  subscription seam, wired through `AppContext`/`WorldSession`), called with
  `{ docTypes: ["actor"] }` — the server filters to `doc_type == "actor"` itself
  (`shadowcat-codebase-realtime-sync`'s `doc_types` cap; `shadowcat-codebase-documents-permissions`'s
  `Repository::search` filter), so `ActorsPanel` does NOT client-side re-filter the returned hits
  by doc_type — an EMPTY
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
- The `factions` module (`FactionsPanel`) — GM editor over the faction registry;
  faction-colored token border + select-by-faction. The registry itself is SERVER-seeded
  (the engine's `FactionRegistryEngine::seed` three-faction default, written by the
  world-config seed path at world creation/join — see
  `shadowcat-codebase-documents-permissions`'s `ConfigSeed` bullet); the panel never creates
  it, only edits entries with real-OCC stored pre-images. `deterministicId(worldId, name)`
  (re-exported from `@shadowcat/core`) remains available for fixture ids — a synchronous
  UUID-v5-SHAPED hash (four seeded FNV-1a 32-bit mixes, not true SHA-1 UUIDv5, because every
  doc builder in the `scene-docs` module is synchronous and Web Crypto's SHA-1 is async)
  rather than a random id (`randomUuid`) — but no production path derives a config-singleton id
  from it anymore (server seeds use fresh UUIDs; absence is keyed by doc_type).
- The `conditions` module (`ConditionsPanel`) — GM editor over the condition registry
  (SERVER-seeded with the engine's `ConditionRegistryEngine::seed` emoji default, same seed
  path as the faction registry) + a token-selection-driven toggle palette; render via
  `TokenNodeSpec.badges` (upright glyph chips). A per-condition fx editor writes
  `/engine/conditions/<id>/fx` (writing `null` once the last fx key is cleared) with the raw
  stored value as the OCC `old`. Toggle gated by `AppContext.canEdit(doc, path)`
  (GM or token owner).
