# Client token plates, bars, art framing, camera, snapping, dash

Client render-layer and scene-tools seams for per-token display, camera moves and shape dashing. Read it before changing `TokenView`, the nameplate/bars host, token art framing, `Camera`, `Grid` snapping or any dashed shape.

## Bars and nameplates

- Server: the `"bars"` derived channel (`scene::bars`: `resolved_bars`, `token_bars`, `nameplate_for`; payload `BarsPayload` / `SceneBars` / `TokenBars` / `ResolvedBar`) is produced by one `compute_derived` arm. Three gates: the scene is visible; the token passes `token_footprint_visible` (the whole entry is dropped otherwise); and a LINKED token whose `actor_id` the recipient does not receive (a secret-identity token) gets no bars and no nameplate (the gate in `token_bars`, the same rule in `nameplate_for`), because the actor's numbers would re-join the token to an actor the recipient can read. Each bar then goes through `delivered_to(OwnerOrGm)` per its mode. Bar formulas evaluate over `filter_properties(host, recipient)`, i.e. over the RECIPIENT'S redacted copy (redact before evaluate, so a GM-only leaf never feeds a number a player sees); the nameplate text comes from the same redacted copy. `BarAttribute`, `BarDisplayMode` (none, hover default, owner, always), at most four bars, `validate_bars`, and `nameplate_mode` ride `ActorEngine` / `TokenOverrides`; a token override replaces the whole object and null inherits. `ResolvedBar.mode` and `TokenBars.nameplate_mode` are sent only when delivered.
- Client: `core` `bars.ts` (`parseBars`, `resolveTokenBarAttribute`, `barRevealed`, `EMPTY_BARS`, `MAX_BARS`) is the reader; `WorldSession` subscribes and `AppContext.bars` exposes it. `RenderEngine` owns `reapplyBars`, hover state and `nameplateFallbackLabel`; `TokenView` mounts a `TokenBarsHost`; `PixiBackend.updateTokenPlate` draws the plate upright and memoises on its plate key. The performance flag `nameplatesAndBars` turns the whole plate off. Hover and pick use the shared `tokenBoxContains` / `ScenePoint` in `@shadowcat/core`, so `scene-tools` `topTokenAt` and the stage hover cannot disagree.
- Editors (`actors` module): `BarModeSelect`, `BarsEditor`, `TokenBarsControl`. Use the shared `coerceFormula` (see `shadowcat-codebase-formula`) for bar formula inputs.

## Token visual layers

- Child order inside a token node, bottom to top: art (`visualContainer`), condition overlay icon (`updateTokenOverlay`, 60 percent of the glyph above the art and below the badges, memoised on its overlay key), badges, nameplate/bars. Effect order: condition fx, perceived tint, selection, ghost.
- A perceived token (seen only through a sense) gets a fixed tint (`PERCEIVED_FX_COLOR`) OUTSIDE the `tokenFx` performance gate, so it never disappears under a low preset.
- `TokenNodeSpec.overlayIcon` is the first overlay condition (`ConditionDisplayEntry.overlay`); `Condition.overlay` is a serde-defaulted bool (ts-rs cannot emit an optional bool, so the generated type is required and literals carry it). The seeded dead and unconscious conditions are overlays.
- Hidden or unauthored visuals: `TokenView` draws `GENERIC_HIDDEN_TOKEN_VISUAL`, a frame-only silhouette; `TokenNodeSpec` art is optional and `updateTokenVisual` has a frame-only branch.
- Art framing: `VisualTransform {anchor, scale, tint, facing}` on image and animated visuals, validated server-side and by client `isValidTransform` (an invalid transform fails closed to the untransformed art). `PixiBackend.frameTokenArt` applies it with the native tint; the sprite angle is the negated `facing`, and the generated frame and border rotate with the token only, never with `facing`. `facing` is validated finite and within a full turn on both sides, and the two validators must agree. `VisualKindEditor` numeric inputs for these use step "any".
- Facing wedge: `TokenNodeSpec.facing`, `TokenView` draws the wedge, `PixiBackend.updateTokenFacing` rotates it on `visualContainer` (0 = +x, clockwise). The `facingWedgeVisible` engine option (GM, or a user who can edit rotation) decides who sees it.
- Reveal: `RenderEngine.isTokenRevealed` / `reveal.ts` is fail closed (an unknown applied mask hides); `onTransformApplied` / `onVisibilityApplied` feed chat bubbles, which are fog-gated by the applied mask. `AppContext.stageView` is written by `Stage`.

## Camera, snapping, tools host

- `Camera.panTo` / `Camera.tick` animate with `animationEasing`; under reduced motion (`perf().reducedMotion`, see `shadowcat-codebase-performance`) the move snaps. `panBy` and `zoomAt` cancel an in-flight pan. `RenderEngine.panToPoint` / `panToToken` are on `SceneToolHost`; every fake host in tests must implement both. `RenderEngine.onCameraApplied` and the stage `data-camera-center` attribute exist so e2e can read the camera.
- `SnapMode` has three values (centre, vertex, edge). `Grid.snapEdge` and `Grid.snapVertex` share the neighbourhood and nearest-of helpers; the ToolRail button cycles the three modes.

## Dashing

One declaration, one cutter, one painter: `ShapeNodeSpec.stroke.dash` is the only dash declaration, `dashPath(points, closed, on, off)` in `dash.ts` is the only cutter and `paintShape` the only painter. A non-positive or non-finite pattern draws nothing. `WallView` (proximity walls) and `regionShapeSpec` (occluding regions) both use it; do not add a second dash path.
