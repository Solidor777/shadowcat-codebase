# Core invariants — detail

Part of shadowcat-codebase-core: the full text of the invariants summarized in SKILL.md; read it before touching the area a summary names.

Case table for the "NEVER FORK A DECISION ACROSS TWO PATHS" invariant in SKILL.md (six instances across four subsystems):

  | Forked on | Where | Consequence |
  |---|---|---|
  | Cell indexing | `Room::publish`, `clip_to_visible_mask` | square indices tested against a hex-axial mask |
  | Contract completeness in a SHARED primitive (not a fork — included because it is the same *consequence* from the opposite cause) | `HexGrid::line_traversal` | a thin line, not a supercover — ~55% of segments omitted a crossed hex the gate then never checked; see `scene-rendering`'s references/gotchas-routing-and-geometry.md, "a fixed-count cube lerp is a THIN LINE" gotcha |
  | Input admissibility | `Room::publish` vs `gate_walk` | one bounded coordinate magnitude, the other did not |
  | **Scene identity** | `MoveRequest` vs `Room::publish` | one took the scene from the client, the other derived it from the token ⇒ total movement-gate bypass |
  | **`remove` semantics** | `SceneEcs::apply_op` vs `apply_intent` | ECS ignored `FieldChange.remove` while the DB honoured it ⇒ vision widened where write authz refused |
  | Fail-open defaults | `execute_move` vs `publish` vs `pathfind` | a `unwrap_or(100.0)` cell size dropped from ONE gate and left in its siblings — the shape a fix for the row above produces if it lands at one site. **No such default exists at any of the three gates or their six non-gate siblings** (`SceneEcs::navmesh_for`, `SceneEcs::region_field`, `SceneEcs::player_lit_mask`, `SceneEcs::visible_cells`, `SceneEcs::visible_cells_cached` — an absent `scene_grid_sizes()` entry returns `None`/empty rather than synthesizing a 100-unit grid; `region_field` returns `-> Option<RegionField>`, its three callers (`pathfind`'s two branches, `move_exec::execute_move`) refuse via `let-else` on `None`, and `MoveReject` carries a `SceneUnknown` variant mirroring `Degenerate`; `conn::enrich_vision_explored` continues past a scene absent from either its `grid` or
  `enrich_vision_explored::grid_shapes` map, never synthesizing a fallback `SquareGrid`). `scene_grid_sizes` is the sole intentional defaulting SOURCE. |
- **Three-band document shape: envelope `name` + typed `engine` + opaque `system`.** The server
  never decides what a `system` value MEANS and runs no third-party code; its authority over the
  band is structural (size/field-path/`deny_unknown_fields`/declared shape). It DOES evaluate the
  engine's own grammars over `system` data a formula names — `crate::formula` (server twin of
  `@shadowcat/formula`) reads numeric leaves through `SystemLeafResolver` — and by default
  computation runs on the server; the client requests. The typed `engine` body
  (present only for the 25 engine-defined doc types: tokens, actors, scenes, walls, regions,
  lights, drawings, templates, messages, asset folders, rollable tables, the
  world/vision/lighting/chat/dice/faction/condition/channel/system-defaults config-docs, and the
  combat family (combat, combatant, resource-registry, effect, combat-history) gets REAL
  server-side ingress validation instead
  (`validate_engine`/`validate_engine_tree`, `deny_unknown_fields` per struct) — this is the band
  engine-owned geometry (movement-collision, vision) lives in, not a `system`-body exception.
  See `shadowcat-codebase-documents-permissions` for the
  `data/engine/` registry, `shadowcat-codebase-combat` for the combat family, and
  `shadowcat-codebase-scene-rendering`/`-chat`/`-actors-tokens` for the per-subsystem re-root.
- **A type built via `Extract<SomeUnion, { type: "x" }>` cannot be documented.** TypeDoc cannot
  project such a projection into a documentable reflection, so a comment on it is unfixable no
  matter how it's placed. The resolution is structural: declare the member as its own named
  exported interface and make it a member of the union directly, rather than extracting it back
  out afterwards. `WireWelcome` follows this shape — a named member of `ServerMsg`, not an
  `Extract<>` projection of it. Follow the same precedent wherever this shape recurs.
- **`WirePermissionSet` exists because one anonymous access-control type spans a file boundary.**
  `WireDocument.permissions` and `StampOpts.permissions` share the same shape across two files; a
  single exported name is structurally required there — the alternative duplicates the
  access-control shape inline in both places, the forked-decision defect this codebase produces
  most (see the NEVER FORK A DECISION ACROSS TWO PATHS invariant in SKILL.md). The name exposes nothing new:
  `WireDocument["permissions"]` already exposed the identical shape.
- **File-size limits and test-file placement.** `pnpm lint:file-size` fails any tracked source file
  over 5,000 lines without an owner-signed `.claude/file-size-allowlist.toml` entry and any file
  over 10,000 unconditionally; `pnpm lint:inline-tests` fails any inline `#[cfg(test)] mod x { … }`
  body under `src/`. Rust test bodies live in `<stem>/x.rs` (or `x.rs` beside a `mod.rs`), and the
  large suites are split by subject: `data/sqlite/tests/{mod,rows_and_validation,search_and_worlds,commands_and_intents,invites_and_ownership}.rs`
  and `scene/tests/{mod,ecs_and_footprints,resolution_and_lighting,pathfind_and_vision}.rs`, with
  shared fixtures `pub(super)` in each `tests/mod.rs`. Never add an allowlist entry on your own
  authority — split the file.
- **Test resource budgets are invariants, and the timeouts depend on them.** Playwright's default
  worker count is half the logical CPUs, which oversubscribes a developer machine because each
  worker drives a Chromium rendering a WebGL stage — far more than one core. Measured on one
  machine against a freshly booted server, `panels-floating.spec.ts`'s popped-out-arrangement test
  takes 3.1s at four workers and 59.4s at twelve, roughly 19x. Oversubscription costs on every
  axis at once: one full-suite run measures 146s at four workers with all 34 passing, against 235s
  at twelve with one failure — the extra workers buy no throughput, make the machine unusable, and
  push ordinary assertions past `expect`'s budget until they fail on the clock. Treat any single
  suite run as one SAMPLE: the spread at a fixed worker count is wide, and runs at the capped count
  have also produced multi-minute hangs in the dual-session specs, so a green run is not evidence
  the suite is stable and the budgets are sized on the worst observed passing test, never the best.
  `workers` is therefore pinned in `playwright.config.ts`, and `timeout`/`expect.timeout` are sized
  against the capped figure. Raising the cap re-inflates per-test latency and those budgets stop
  bounding product behaviour — they start absorbing contention instead, which is how a suite stops
  detecting the regressions it exists to catch. A single browser action costs ~70ms; a spec that
  runs long runs long because it performs hundreds of actions across several contexts, so look at
  action COUNT before suspecting a slow operation.
- **Check WHICH RENDERER the browser picked before optimizing anything about the canvas.**
  Headless Chromium selects a software rasterizer by default, so the stage's WebGL is drawn on the
  CPU at whole cores per canvas; the same browser uses the host's real device when the launch
  selects the platform GL backend, and the graphics layer falls back to software by itself where
  no device exists, so that selection needs no per-environment gating. Reading the renderer string
  from a throwaway context is a two-line check and it reframes the whole problem: the full suite
  measures 235s with failures under software and 21s with 33/33 on the device. Every accommodation
  that looks reasonable while software rendering is assumed — cutting per-pixel work, capping
  workers — is optimizing a cost that need not exist. **When a rendering measurement looks
  extreme, ask what is doing the rasterizing before asking how to make it cheaper.**
  Two things remain true underneath. The renderer redraws the FULL canvas every tick whether or
  not the scene changed (`RenderEngine`'s `pingsActive`/`emotesActive`/`rulersActive` gate only those overlays'
  redraw), so a host genuinely without a GPU still pays continuously and needs the worker and
  per-pixel budgets. And a starved page stops servicing the automation protocol entirely rather
  than merely rendering late — a polling assertion carrying its own budget can outlive the test's
  budget without firing, and the hang surfaces in context teardown rather than in any assertion,
  which reads as a harness fault and is not one.
  **Per-process CPU is the WRONG instrument for judging a fix here** — a software rasterizer
  parallelizes across whatever cores exist, so it reports demand, not the per-frame work that
  changed. Judge by pass rate and per-test duration across REPEATED runs.
- **Drive the stage canvas as an ELEMENT, never at computed page coordinates.** Converting a
  canvas-local point through a separately-read bounding box and clicking absolute coordinates
  performs no actionability check, so nothing waits for the canvas to be visible, to hold a stable
  box, or to be the element that receives the event. Opening or closing a docked panel resizes the
  canvas, and a gesture aimed through a box read before that settles lands on the panel and is
  swallowed with nothing failing to say so. This defect is invisible on any host slow enough to
  finish the relayout first, which is exactly where a software-rendered suite runs — so it appears
  the moment rendering gets FASTER, and reads as the speedup having broken something.
  Playwright's pointer primitives take page coordinates and carry no actionability wait, so a
  drag or a press-and-poll cannot be expressed element-relatively end to end and MUST convert.
  Make the conversion sound rather than avoiding it: hover the canvas element at the gesture's
  start point first, which both settles the layout and leaves the pointer where the press wants
  it, and read the origin only after. `sceneOrigin` is the only way to obtain that origin, so no
  caller can convert from an unsettled box. Every spec reaches the gestures through that one
  shared module — `clickScene`, `dblclickScene`, `dragScene`, `dragScenePath`, `sceneOrigin`,
  `sceneCenter` — because one private copy inside each spec file is the forked-decision defect, and is how
  a fix lands at three of six sites while reporting the class closed.
- **A unit test that never touches the DOM declares the node environment.** Packages select
  `environment: "jsdom"` globally, and vitest constructs that environment per test FILE, so a file
  exercising plain state and pure functions pays the full construction cost and never uses it —
  cumulatively the dominant cost of the unit run, far exceeding the assertions themselves. Such a
  file opens with `// @vitest-environment node`. INVARIANT: a package's `vitest.setup.ts` runs in
  EVERY environment that package selects, so any DOM global it patches must be guarded on that
  global existing (`typeof HTMLCanvasElement !== "undefined"`) — an unguarded patch throws before
  the first test in any node-environment file. Every `vitest.setup.ts` in the tree carries that
  guard, so the pragma is safe to add in any package; adding a new setup file without it re-arms
  the trap for whoever next follows this bullet. Keep jsdom the package default and opt out per
  file: the reverse fails toward a broken test rather than a slow one.
- **Client code runs on a plain-HTTP LAN origin, so a secure-context-only browser member is
  banned outside its seam.** LAN play serves the client over `http://` at a non-loopback address,
  which is NOT a secure context: every SecureContext-annotated web member (crypto.randomUUID,
  navigator.mediaDevices, AudioContext.audioWorklet, caches, navigator.clipboard, …) reads
  `undefined` there, so a call THROWS on every LAN client while vitest (Node) and the loopback e2e
  project (a secure context) never see it. Every client id therefore comes from `randomUuid`
  (`@shadowcat/core`, falls back to `crypto.getRandomValues`), and `pnpm lint:secure-context`
  (`scripts/check-secure-context-apis.mjs`, CI-wired and in `scripts/gates.toml`'s commit tier)
  fails the tree structurally. The gate's own test drives `runGate`, which takes its file list,
  reader and loggers injected. One table, `RULES`, drives two passes. The raw-text pass scans every
  covered file INCLUDING comments and strings, so the bare word randomUUID fails even inside a
  comment. The structural pass reads `.ts`/`.js`/`.mjs` files and the `<script>` blocks and
  template expressions of `.svelte` files through the TypeScript parser (ESLint ignores
  `.svelte`, which is why this is a script gate). Each rule names the banned member, its owner,
  the files allowed to mention it and the seam that replaces it: the randomUUID rule allows
  `SEAM_FILE` (`randomUuid`) plus its own test file `uuid.test.ts`; the mediaDevices and
  audioWorklet rules allow `MIC_SEAM_FILE` (`micVad`'s `MicVadDeps.isAvailable` feature check).
  The caches rule matches the bare identifier only when the file declares no VALUE binding of
  that name (a type-only import or a function-type parameter does not shadow it). Only members
  whose ABSENCE BREAKS the client are ruled; a member merely READ as a property yields `undefined`
  and has no rule. **The BOUND is stated in the script and is real:** an alias (a local alias of
  navigator), a non-literal key, Reflect.get, and the in-operator test are undecidable statically
  (non-literal keys on `navigator`/`crypto` are counted and listed in the output); their cover is
  the `lan-plain-http` e2e project. A file, script block or template fragment the parser cannot
  read FAILS the gate — an unread region is never a silent pass — and `assertGateLive` refuses a
  scan that missed the seam file or every `.svelte` file. Adding a rule needs the owner, the
  members, the replacing seam and a positive control in the script's test. The gate scans the
  files `git ls-files` lists, so a NEW untracked file is unscanned until it is added to the index
  (`git add -N`); run gates with new files added.
- **End-to-end specs latch transient state; they never poll a value that returns to rest by itself.**
  A state held for a bounded time and then left by the app on its own (a tumble/settle machine, a brief
  overlay count, an auto-dismissing toast) can be entered and left between two polls, so a polling
  assertion depends on poll timing rather than on whether the state was ever reached — and is
  green or red by luck. The shared helpers install an in-page observer BEFORE the action:
  `latchAttributeMax` (a numeric attribute's maximum), `latchAttributeValues` (`seen()` = the
  distinct values, `transitions()` = every write in order with repeats, the proof that NO write
  happened over an interval) and `latchTextSeen` (auto-dismissing text). A latch records nothing
  that happened before it was installed. `latchTextSeen` has a stated BOUND: text written into an
  EXISTING text node and overwritten again inside one mutation batch is unrecoverable (a
  character-data record carries only the previous value), so such a change is read only at callback
  time. `login()` in the shared e2e fixtures fails FAST on a failed same-origin `/assets/` fetch,
  naming the request and its network error, because the client is a module graph and one failed
  module fetch means the form can never mount — without it the only symptom is a 120 s timeout
  reading "waiting for Username". It ignores net::ERR_ABORTED and any failure outside `/assets/`. The fixture's own comment records net::ERR_NO_BUFFER_SPACE
  as the measured example (an OS socket-buffer error on the Windows loopback); that mechanism
  is the fixture author's measurement, not something this skill verifies.
- **The `lan-plain-http` Playwright project is the runtime proof of the LAN invariant.**
  `playwright.config.ts` runs two projects over two servers: the loopback project (everything
  except `LAN_SPEC`, against `127.0.0.1:31999`) and `lan-plain-http` (only `LAN_SPEC`, against the
  origin built from `LAN_HOST` and `LAN_PORT`). `LAN_HOST` is a non-loopback hostname that
  Chromium's `--host-resolver-rules` maps to `127.0.0.1`, so the origin is genuinely insecure on
  every CI OS with no network setup, and its server binds `0.0.0.0` because server policy keyed on
  a non-loopback bind (`Config::is_exposed`) applies only there. The project's test file has a "measured" test that asserts the origin is
  insecure, that crypto.getRandomValues is still a function, and that every member in its
  `SECURE_CONTEXT_MEMBERS` table (which includes deviceMemory) is `undefined` there (it also
  attaches other measured members without asserting them), and its two session tests
  (a GM session and a player session) additionally fail on any page error. Both servers are
  `reuseExistingServer` outside CI, so a local run can drive another session's binary on port
  31999 or 32000; only CI's isolated runner attributes a result to the tree under test.
- **A jsdom package whose tests reach the browser's local storage lists the shared
  `test-setup/jsdom-local-storage.ts` first in its `setupFiles`** (the shell, ducking and dice-3d
  configs do; most jsdom packages do not). Node exposes a non-functional global local-storage
  shell that the jsdom environment does not rebind, so a test that reaches real storage would see
  the broken shell; the shared setup rebinds it from the jsdom window and, like every setup file,
  is a no-op where no jsdom window exists. The consumer that needs it here is the shell's
  `WorldSession` test of `WorldSession.shareRuler` (a session constructs its
  `ShareRulerPreference` over the global storage); `ShareRulerPreference`'s own test is a
  node-environment file that injects its storage instead.
