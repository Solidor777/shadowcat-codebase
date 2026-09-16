---
name: shadowcat-codebase-dice-3d
description: "Use when touching Shadowcat's 3D dice overlay: the `STAGE_OVERLAY_CONTRACT` surface `Stage.svelte` renders, the `DiceOverlay`/`DiceEngine` tumble (lazy-imported three + @dimforge/rapier3d-compat, fixed-substep physics, settle-then-freeze), the `remapFaces` label remap that makes the up face always show the server's `DieRecord.value`, the `shapeGeometry` per-shape convex construction, `shapeFor`/`realFaceCountOf` shape resolution, the `mulberry32`/`seedFromRollId` deterministic throw, the document-store trigger (`seedFromSnapshot`/`scanForPlays`/`enqueueRoll`/`dequeueRoll`, `MAX_CONCURRENT_ROLLS`/`MAX_DICE_PER_ROLL`), the `Dice3DBridge` late-binding seam (`AppContext.dice3d`), or the server-side `DieRecord.kind` face-space field it consumes. Covers src/modules/dice-3d/ and src/client/ui-kit/src/dice3dInteraction.ts. Invoke shadowcat-codebase-core first; for the dice engine itself invoke shadowcat-codebase-dice, for the roll wire shapes shadowcat-codebase-chat."
---

# Shadowcat — 3D Dice Overlay

Orientation for the client-side 3D tumble: a roll lands across the stage in 3D and settles
showing exactly the result the server rolled, on every recipient's screen — presentation
only, costing nothing on a device that turns it off.

## Purpose

The server authors every roll outcome; this subsystem renders it. A transparent WebGL
canvas contributed into `STAGE_OVERLAY_CONTRACT` (`shadowcat.stage-overlay`, multi — the
contract this subsystem owns, rendered by `Stage.svelte` as absolutely-positioned children
over the render canvas) tumbles physics dice whose face labels are remapped after settle so
the up face always carries the server's authoritative value. The `three` renderer and the
`@dimforge/rapier3d-compat` physics world are lazy-imported on the first roll, so a device
with 3D dice off never downloads or initializes either.

## Key files & seams

- `src/modules/dice-3d/` — the `@shadowcat/module-dice-3d` package (one contribution:
  `DiceOverlay` into `STAGE_OVERLAY_CONTRACT`).
- `DiceOverlay` (`DiceOverlay.svelte`) — the overlay host: subscribes to the document store
  directly (no dependency on the chat card), manages the tumble queue, owns the engine's
  lazy construct / 60-second-idle dispose lifecycle, resolves theme tokens to css colors
  for the label textures, and exposes the live state as the `data-dice3d-state` /
  `data-dice3d-values` host attributes (the browser-suite observability seam).
- `DiceEngine` (`DiceEngine.ts`) — the ONLY three/rapier-touching class: `init` lazy-imports
  both libraries, `throwDice` spawns one convex-hull rigid body per die with velocities
  seeded from the roll id, steps the world at a fixed substep, detects settle
  (velocity-epsilon hold plus a hard timeout), freezes the bodies, swaps each physical
  face's label texture to the `remapFaces` result, and resolves. `dispose` releases the
  WebGL context and the physics world.
- `geometry.ts` — `shapeGeometry`: ONE analytic construction per standard shape (d4/d6/d8/
  d10/d12/d20) producing the vertex cloud AND its oriented physical faces; the visual
  mesh's triangle soup (one geometry group per face), the collider's convex-hull point
  cloud, and the up-face normal table all derive from it and can never drift apart. The
  Platonic solids group their vertex clouds onto their dual solids' vertex directions; the
  d10 (a pentagonal trapezohedron, not Platonic) lists its ten kite faces explicitly.
- `shapes.ts` — `shapeFor`/`realFaceCountOf`: every `DieKind` resolves to a standard shape
  (the smallest whose face count covers the kind's, unused faces blank; an over-large kind
  renders as a d20 whose every face carries the final value — `ResolvedShape.sameLabel`).
- `remapFaces.ts` — the pure cyclic label shift: `remapFaces(upFaceIndex, faceCount,
  targetIndex)` is a bijection placing `targetIndex` on the settled up face.
- `rng.ts` — `seedFromRollId`/`mulberry32`: the throw is deterministic per roll id, so
  every recipient sees the same tumble (the server's authority is over the VALUE, not the
  animation).
- `trigger.ts` — the store-subscription trigger: `seedFromSnapshot` seeds the seen-set from
  the cold-start snapshot, `scanForPlays` returns new/recalculated rolls exactly once,
  `createRollQueue`/`enqueueRoll`/`dequeueRoll` cap concurrent tumbles at
  `MAX_CONCURRENT_ROLLS` and per-roll dice at `MAX_DICE_PER_ROLL` (the remainder is a "+N"
  badge on the chat card path — the card is the source of truth, the overlay a courtesy).
- `settings.ts` / `performanceSeam.ts` / `audioSeam.ts` — the per-device appearance override
  (`readDice3DSettings`/`writeDice3DSettings`, localStorage) and two seam stubs
  (`dice3dEnabled`/`reducedMotionPreferred`/`antialiasPreferred`, `playThrowSound`) bound to
  device-local defaults until the performance and audio seams land; only the function
  bodies rewire then, never the call sites.
- `Dice3DBridge` (`src/client/ui-kit/src/dice3dInteraction.ts`) — the late-binding
  `SceneInteractionBridge`-pattern seam exposed as `AppContext.dice3d`
  (`Dice3DInteraction` = `Dice3DHost` + `attach`): a system module that rolls outside chat
  calls `roll(outcome, rollId)`/`clear()` unconditionally; every call no-ops before the
  overlay attaches.
- `DieRecord.kind` (server: `dice::outcome::DieRecord`; client mirror: `chat-docs.ts`) —
  the every-recipient face-space fact this subsystem reads to pick each die's physical
  shape; absent on a roll stored before the field existed, which renders no 3D dice
  (fail closed). See `shadowcat-codebase-dice`.

## Hard invariants

- **The server's `DieRecord.value` always wins.** The remap is cosmetic — a bijective
  relabeling of the physical faces after the physics settles — never a reroll and never a
  second source of randomness. The remap target derives from the record's FINAL
  `DieRecord.value`, never `DieRecord.natural` (a reroll/explode leaves `natural` at the
  pre-reroll draw). Only the texture swaps after settle; no motion after the last frame
  moves (the settled body is frozen).
- **The cold-start snapshot IS history.** `seedFromSnapshot` runs once, before the first
  `scanForPlays`; a roll already in the store at mount never plays. A roll plays exactly
  once, and a recalculated `roll_embed` re-plays only under a HIGHER `recalc_history`
  length — the seen-set keys on (roll id, recalc count), and `scanForPlays` marks a play
  seen even when the overlay is disabled at the call site, so re-enabling never replays
  history.
- **`MAX_CONCURRENT_ROLLS` / `MAX_DICE_PER_ROLL` are hard caps** — at most three rolls
  tumble at once (the rest queue), and a roll past thirty dice renders thirty plus a "+N"
  badge.
- **Every `DieKind` renders.** `shapeFor` has no failure mode: small kinds pad a larger
  standard shape with blank faces; an over-large kind becomes the d20 value chip
  (`ResolvedShape.sameLabel`), so no face can ever show a wrong label.
- **One geometry construction per shape.** The visual mesh, the physics collider, and the
  up-face normal table all read `shapeGeometry`'s output; nothing re-derives a shape's
  vertices or face normals from a second source.

## Gotchas

- **`three`/`@dimforge/rapier3d-compat` must stay lazy-imported** — the only references are
  `DiceEngine`'s dynamic `import()` calls (plus type-only imports, which erase at build).
  A static import anywhere in the module's graph drags both chunks into the eagerly-loaded
  bundle for every device, including ones with 3D dice off.
- **The d10's constants are load-bearing geometry, not proportions to taste.** Its kite
  faces are planar only when apex/ring-height equals `(2+φ)/(2−φ)` (φ the golden ratio),
  and each kite is {apex, two adjacent near-ring vertices, one far-ring vertex} — the
  alternative decomposition cannot be planar for equal-radius rings. `geometry.test.ts`
  pins planarity, containment, face counts, and outward unit normals for every shape in a
  node environment; do not "round" the constants.
- **Unit tests mock both native-touching libraries** — `vi.mock("three")` and
  `vi.mock("@dimforge/rapier3d-compat")` in `DiceEngine.test.ts`, `vi.mock("./DiceEngine")`
  in `DiceOverlay.test.ts`; the package's `vitest.setup.ts` stubs the canvas 2D context to
  `null` (the stage module's precedent), which `DiceEngine`'s label-texture builder guards
  on. Real pixel/physics behavior is browser-suite territory, never jsdom.
- **The overlay never blocks the stage.** The host and canvas are `pointer-events: none`;
  the single dismiss layer opts into pointer capture only while dice are visible (the
  `STAGE_OVERLAY_CONTRACT` contract doc's own rule: a contributing component opts into
  pointer capture on its OWN root element, never by default).
- **A `table_draw` tumbles too** — its `TableDrawSegment.outcome` carries the same
  `DieRecord` shape as a `roll_embed`, and nested draws recurse; a table draw is not
  recalculable, so it keys at recalc count 0.

## Pointers

- User-facing module page: `docs/site/modules/dice-3d.md`.
- Dependency/licensing rationale: `docs/design/ARCHITECTURE.md` §3 (the three/rapier rows).
- Generated API: `/api/ts/modules/_shadowcat_module-dice-3d.html`. Produce with
  `pnpm build:all`.
- Relationships: `graphify query "3D dice stage overlay tumble settle remap"`.
