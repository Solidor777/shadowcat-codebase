# Actors and tokens: key files and seams

Part of the shadowcat-codebase-actors-tokens skill; read it before editing actor or token code (scene-docs, token rendering, conditions, vision, face maps, editors).

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
    `"square" | "circle"` override applied on top of the actor's own shape field — plus the
    `aura`/`sound`/`vfx` emission overrides (`AuraEmission { color, opacity, radius, enabled }`
    (color css `#rrggbb`, radius in grid cells), `SoundEmission { asset, radius, volume, loop,
    enabled }`, `VfxEmission { asset, anchor: VfxAnchor, loop, enabled }` with
    `VfxAnchor = "token"|"above"|"below"`), each replacing the actor's same-named
    `ActorEngine.aura`/`sound`/`vfx` field wholesale when present. All three structs are
    ingress-validated (`ActorEngine::validate`, and `TokenEngine::validate` →
    `TokenOverrides::validate` for the override copies): css-`#rrggbb` color shape, finite
    opacity/volume (their `0..=1` range is a READ-side clamp where consumed, not an ingress
    rejection), finite non-negative radius bounded by the shared cell cap
    `scene::pathfinding::MAX_FOOTPRINT_CELLS`, non-empty sound/vfx asset. The aura renders as a
    filled disc UNDER the token art (`TokenNodeSpec.aura`); the VFX emission PLAYS — the render
    client's `VfxView` renders every enabled `EffectiveActor.vfx` as an `emitter:<token>` node
    in the `vfx` layer, tracking the token's live tweened transform at its `VfxAnchor`
    placement (`below` = footprint base, `token` = center, `above` = top edge) — see
    `shadowcat-codebase-vfx`. Sound is stored, playback-ready data with no consumer yet.
  - **Token visual union:** `RenderVisual = {kind:
    "image", asset} | {kind:"animated", source: AnimatedSource, fps, loop} | {kind:"generated",
    art, crop, border?, background?}` — the only kinds the render layer ever draws. The
    `"generated"` arm frames an existing piece of art: `art: Box<RenderVisual>` restricted to
    image/animated (a nested `generated` — or a smuggled `faces` — inside `art` fails closed at
    `resolveTokenVisual`), `crop: "circle"|"square"`, an optional decorative `border {color,
    width}` ring (authored data, distinct from the faction ring the render layer draws from the
    registry; `width` is a fraction of the token's smaller extent), and an optional `background
    {color}` fill (`GeneratedCrop`/`GeneratedBorder`/`GeneratedBackground` in
    `data::engine::token`). `AnimatedSource = {type:"frames", frames: string[]} | {type:"sheet",
    asset, rows, cols, count?}` (asset ids pre-resolution; resolved to URLs at the render boundary,
    see `resolveTokenVisual` below and `TokenNodeSpec.visual` in `shadowcat-codebase-scene-rendering`).
    `FaceVisual = RenderVisual` — **a face is itself a `RenderVisual`, never nested `faces`** (deliberately
    no `{kind:"faces"}` inside a face; an animated or generated face falls out of the same boundary with no
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
  - **Carried light:** `ActorEngine.light?: LightEmission` and `TokenOverrides.light?:
    LightEmission` — the SAME `LightEmission` payload a standalone `light` document's
    `LightEngine.emission` carries (`{color, intensity, brightRadius, dimRadius, falloff?,
    enabled}`, radii in cells, `FalloffCurve` `linear | quadratic | none`). The override replaces
    the actor's emission wholesale; an override with `enabled: false` is the documented SUPPRESS
    path (the token carries no light although its actor does). `EffectiveActor.light` joins
    `resolveTokenActor`'s projection (`overrides?.light ?? base.light ?? null`), and
    `DEFAULT_LIGHT_EMISSION` (`@shadowcat/core`) is the ONE authoring default every surface
    stamps. **Authoring is GM-only, server-enforced**: an emission edits the shared illumination
    field every viewer's mask reads, so `permission::carried_light_touched` refuses a non-GM's
    create/change/remove of any emission — unlike the owner-writable presentation overrides
    (`shadowcat-codebase-scene-rendering`'s `scene::emitters` bullet owns the server side).
    Surfaces: the actor row's "Carried light" checkbox + `LightEmissionEditor` (whole-payload
    `/engine/light` writes with the raw stored emission as the OCC `old`), the create form's
    `pendingLight`, the actor sheet, and `TokenLightControl` (prop `{ tokenId }`, mounted by
    `ActorsPanel`; inherit / suppress / custom, written as a whole-object `/engine/overrides`
    update with the raw stored overrides as `old`; linked tokens only, GM only).
  - **Elevation + the v2 vision-mode descriptor:** `TokenEngine.elevation?: number` is
    owner-writable TOKEN state (absent = ground; `TokenElevationControl` normalizes 0 to an
    absent value), rendered as an upright `↑n`/`↓n` badge chip beside the condition glyphs
    (`TokenView.toSpec` → `TokenNodeSpec.badges`; `RenderEngine.badgesForTest` is the read-only
    seam the e2e reads). `VisionMode` gains `perceives` (`"terrain" | "creatures"`),
    `requiresLos` and `renderHint`; a creature sense (the seeded `tremorsense`) perceives grounded
    TOKENS through walls and darkness, and the ids reach the client in the masked payload's
    `perceived` set, which `TokenView.toSpec`/`PixiBackend.setToken` raise above the fog — the
    perceived token is re-parented into `PixiBackend`'s `perceivedTokens` container, never
    duplicated. `VisionAssignmentsEditor` (ui-kit; mode + range rows, add/remove) is the ONE vision
    input on actor rows, the create form and the actor sheet (there is no darkvision-only field:
    darkvision is just a mode assignment), and
    `TokenVisionControl` (inherit / custom wholesale `/engine/overrides` write, raw stored
    overrides as `old`) is the per-token override; the game-settings vision-mode editor edits
    every descriptor field with the floor dropdown derived from `resolveGradation`. Server side
    (`scene::senses`, `scene::elevation`) is owned by `shadowcat-codebase-scene-rendering`.
  - **Movement-type tags:** `ActorEngine.movement: string[]` (required, `#[serde(default)]`
    server-side), `TokenOverrides.movement?: string[] | null` (wholesale replacement, same shape
    as `vision`) and `Faction.movement: string[]` — the first faction-RECORD property that flows
    into an `EffectiveActor`. Only `"flying"`/`"incorporeal"` carry engine meaning (the mover
    ignores difficult-terrain COST and nothing else — `shadowcat-codebase-scene-rendering`'s
    movement-tags bullet owns the server resolver `SceneEcs::token_movement_tags` and the pricing
    seam); every other tag is inert system vocabulary, the same posture as conditions.
  - `setNameHidden(doc, hidden)` — sets/clears the `OwnerOrGm` override on `/name` (the envelope
    field).
  - `FactionStance = "friendly"|"neutral"|"hostile"`, `Faction { name, color, stance }`,
    `FactionRegistryEngine`, `buildFactionRegistryDoc(worldId, factions, id?)` (param
    `factions: Record<string, Faction>`) — a
    world-scoped, **parentless config-document** with an id-keyed faction map.
  - `Condition { name, icon, fx? }`, `ConditionRegistryEngine`, `buildConditionRegistryDoc(worldId,
    conditions, id?)` (param `conditions: Record<string, Condition>`) — same parentless
    config-document shape as factions; `icon` is an emoji glyph rendered as a token badge.
    `fx?: ConditionFx { tint?, desaturate?, highlight? }` (css-`#rrggbb` colors, ingress-validated
    by `Condition::validate`; `deny_unknown_fields`) authors built-in token-art effects for tokens
    carrying the condition — presentational only, the server never reads it; the render layer
    folds it into the token's art fx (`shadowcat-codebase-scene-rendering`'s `TokenFx`).
- The `actor` module — `resolveTokenActor(token, store) -> EffectiveActor | null`
  (the one read-through), `EffectiveActor`, `actorDisplayName(a, fallback)` (safe name with a
  redaction-aware fallback), `TokenOverrides` projection. Conditions: `resolveConditions(token,
  store)` (effective condition ids → `{id,name,icon,fx}` via the registry, fail-closed) +
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
  `EffectiveActor.aura`/`sound`/`vfx` are projected identically (`overrides?.X ?? base.X ?? null`
  — a `null` override field INHERITS the base, exactly as a `null` `vision` does).
  `EffectiveActor.movement: string[]` is `overrides?.movement ?? dedup(base.movement ∪
  factionMovement)` — the override REPLACES the whole set (an explicit `[]` strips every inherited
  tag), otherwise the actor's own tags union with the linked faction record's `Faction.movement`,
  read from the `faction-registry` singleton inside `resolveTokenActor` (a dangling faction id or
  an absent registry contributes nothing). This mirrors the server's `SceneEcs::token_movement_tags`
  precedence exactly, and the client value is advisory display only — authoritative pricing runs
  server-side.
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
  `kind` isn't `"image"`/`"animated"`/`"generated"` (defense against a malformed nested `faces`-within-`faces`
  value, which the type system forbids but a hand-edited/legacy doc could still contain); a
  malformed `AnimatedSource` (`isValidAnimated`: non-finite/`<=0` `fps`, an empty `frames` array, or
  a non-positive/non-integer `rows`/`cols` for a `sheet` source); and a malformed `"generated"`
  visual — an unknown `crop`, a non-positive/non-finite `border.width`, a non-string
  `border`/`background` color, or an `art` that isn't itself a valid image/animated visual
  (`isValidGeneratedArt`: nested `generated` refused outright, so the check stays one level deep
  with no recursion guard). A valid `"generated"` face resolves through the same path — the face
  boundary and the top-level boundary share these checks. Optional pre-resolved `resolveTokenVisual.eff` avoids
  a second `resolveTokenActor` call, mirroring `resolveTokenBox`'s convention.
  `selectedFaceNamesFor(token, store) -> string[]` — the effective face-name list for a
  `"faces"`-union visual (`[]` if the effective visual isn't `"faces"`); shares `resolveTokenActor`'s
  projection with `resolveTokenVisual`, so the face-swap palette (`FaceSwapPalette`, below)
  can't diverge from what actually renders.
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
  `VisionAssignment` editor the vision bullet above describes: there is no darkvision-only
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
  whose OCC `old` reads the RAW stored visual (the raw-`old` convention below).
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
