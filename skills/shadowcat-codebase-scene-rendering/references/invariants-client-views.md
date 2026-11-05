# Hard invariants: shape views, templates and RegionView

Part of the shadowcat-codebase-scene-rendering skill; read it before changing the client shape views, TemplateShape, template authoring controls or RegionView.

- **The four shape views are a NEAR-IDENTICAL SIBLING SET, and that is where they diverge silently.**
  `drawing-view`, `template-view`, `region-view`, and `wall-view` share one shape: a
  `reconcile()` diffing scene-scoped docs against tracked ids, and a module-private `toSpec()`
  returning `ShapeNodeSpec | null` where `null` means "don't render". Because they are written by
  copy-and-adapt, a change made to one is easy to omit from the other three, and nothing structural
  catches it. Two divergences the four must not reacquire:
  - **Non-numeric coordinate guards** must be identical in all four, and their placement is
    load-bearing:
    the guard runs on the RAW authored fields BEFORE tessellation, because JS coerces `null` to 0 in
    arithmetic — `circlePoints(null, 5, 10)` yields finite, plausible geometry that a
    post-tessellation check cannot distinguish from an authored shape.
  - **`"rect"` means different geometry per file**: a ROTATED rectangle via `squarePoints`
    (centred on the anchor; its third and fifth arguments are HALF-extents, so the full sides are
    twice each) in `template-view`, versus an axis-aligned bbox between two authored corners via
    `rectPoints` in `drawing-view`/`region-view`. Same string, different shape. `squarePoints`
    keeps its name because its fifth argument defaults to its third: a caller passing four
    arguments still gets a square.
  **When you change one of these four, diff it against the other three.** [[docs-sweep8-render]]
- **`TemplateShape` carries THREE geometry dimensions, and two of them are optional with
  behaviour-preserving defaults.** `size` plus `angle: Option<f64>` (cone aperture, degrees) plus
  `width: Option<f64>`, all `#[serde(default)]`, validated by `TemplateEngine::validate` (`angle`
  finite and in `(0.0, 180.0)` EXCLUSIVE, `width` finite and `>= 0.0`). `width` serves ONE
  meaning — the shape's second/perpendicular dimension — across two kinds: `"line"` thickness
  (`linePoints`, absent ⇒ a bare two-point zero-width segment) and `"rect"`'s second axis
  (`squarePoints`, absent ⇒ `size`, i.e. a square). A cone's absent `angle` resolves to
  `DEFAULT_CONE_ANGLE_DEGREES`, the named export that holds the default aperture — read it rather
  than writing the number, and note it is a FULL aperture, halved inside `conePoints`.
  **`conePoints` returns a three-point wedge (apex + two base corners), so an aperture is only
  representable below a half-turn:** at exactly 180° the triangle is collinear and draws nothing,
  and above 180° the base corners cross behind the apex so the wedge opens OPPOSITE its facing
  direction. That is why the bound is `(0.0, 180.0)` rather than a full turn; widening it requires
  tessellating the base as an arc first, which would change the default cone's output and break its
  regression pin. `templateShapeSpec` refuses an out-of-range angle exactly as it refuses a
  non-finite one, because the optimistic store legitimately holds server-unvalidated engine data.
- **Template authoring controls are conditional by kind** in `ToolRail`: `ToolController`'s
  `templateAngle` shows for `"cone"`, `templateWidth` for `"line"` and `"rect"`, both `null` when
  the field is left empty, which the authored doc carries as an EXPLICIT `null` (not an absent
  key); `Option<f64>` reads either as `None`, so the client must treat `undefined` and `null`
  alike — `template-view`'s guards use a loose `!= null` for exactly that reason. `topTemplateAt` hit-tests through
  the same `templateShapeSpec` the renderer uses, so there is no second copy of this geometry to
  keep in step. **`templateAngle`/`templateWidth` are stored UNSCOPED on `ToolController` and
  survive a `templateMode` change, so `makeTemplateTool`'s `onPointerUp` scopes them AT THE READ
  SITE** — each field resolves to `null` for a kind that ignores it, and only then is the payload
  gated by `isValidTemplateAngle`/`isValidTemplateWidth` (deliberate mirrors of
  `TemplateEngine::validate`). A gate keyed on the mode instead of on the payload is bypassable by
  switching modes; a further mode-scoped numeric field follows this same read-site pattern.
- **`RegionView` mirrors `WallView` exactly** — a dumb per-frame reconciler with
  NO client-side secrecy logic. The `"regions"` render layer sits between `"tiles"` and
  `"drawings"` in the `layers` module's `CORE_LAYERS`. Only regions the viewer is permitted to see ever
  reach `store` in the first place: `setRegionVisibility(doc, true)` sets `permissions.default =
  "none"` (NOT just a `/engine` override — not `/system`), so `filter_command` drops a secret region's whole
  `Create` op for non-owner/non-GM recipients — the doc never arrives, not even redacted — while
  `region_field`'s per-requester view independently keeps a secret region out of a non-GM's
  pathfinder/budget field. There is no client-side hide check to get wrong, by design.

