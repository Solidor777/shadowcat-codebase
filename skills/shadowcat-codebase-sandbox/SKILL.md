---
name: shadowcat-codebase-sandbox
description: "Use when touching Shadowcat's sandboxed third-party server-side validators (wasmi): the guest ABI, sandbox/{runtime,registry}, the apply_intent/import_world chokepoints, WorldModuleEntry opt-in, fault counting and the `Room::commit_ops_locked` auto-disable funnel, or examples/validator-rust/. Covers src/server/src/sandbox/ and examples/validator-rust/. Invoke shadowcat-codebase-core first."
---

# Shadowcat — Sandboxed Validators

Orientation for the opt-in, per-world, per-module server-side validators: `wasm32-unknown-unknown`
code running inside `wasmi`, judging one document type's `system` band, able only to refuse a
write. Orientation+index only: points INTO graphify, `docs/design/`, and memory.

## Purpose

A GM installs a module declaring validators AND explicitly opts the world into running them
(`WorldModuleEntry.validators_enabled`). A validator call returns `Accept`, `Refuse` (a
player-presentable reason), or `Fault` (a technical failure of the sandbox itself); five
consecutive faults auto-disable the module for the world. Never the default path.

## Key files & seams

- `src/server/src/sandbox/mod.rs` — `ValidatorVerdict`, `ValidatorFault`, `FaultKind`,
  `ValidatorInput`, `VALIDATOR_FAULT_LIMIT`, `validate_structural` (Phase 1's own pure
  structural chain, re-run here before any validator), `validate_document` (the embedded-tree
  walk AND the fault counter's own increment/reset calls; the walk mirrors
  `validation::validate_system_schema_tree`'s recursion).
- `src/server/src/sandbox/runtime.rs` — the wasmi host: `CompiledValidator` (a compiled
  validator bound to its fuel-metered wasmi engine — `CompiledValidator.engine`,
  `CompiledValidator.module` — plus the declaring module id; one
  `CompiledValidator::compile` constructor), `run_validator`
  (fuel/memory/instance limits, the `env.log` import, the 50ms `TooSlow`/250ms `Hung`
  wall-clock pair via `run_validator_with_budgets`).
- `src/server/src/sandbox/registry.rs` — `ValidatorRegistry`/`ValidatorRegistryCache` (compiled-
  once cache, mtime-invalidated like `crate::modules::ModuleScanCache`; also the home of the
  per-(world, module) consecutive-fault counter (`ValidatorRegistry.faults`), surviving a
  rescan via `ValidatorRegistryCache`'s own persistent copy).
- `src/server/src/modules.rs` — `ValidatorDecl`, `InstalledModule.validators`,
  `WorldModuleEntry` (the per-world `id` + `validators_enabled` enablement record;
  `WorldModuleEntry::parse_legacy_tolerant` also accepts a legacy bare-`string[]` settings
  row, reading every id as `validators_enabled: false`).
- `src/server/src/data/sqlite.rs` — `SqliteRepository::apply_intent`'s pre-transaction
  validator pass (BEFORE the write transaction opens, against a read-only pool pre-image),
  which consults, per op and in this order: the authorization screen (Phase 1's own
  `authorize_create_intent`/`authorize_update_access`/`authorize_update_change` —
  the SAME functions Phase 1's arms call inside the transaction, never a re-spelled copy),
  then `sandbox::validate_document`, then captures `apply_intent::validated_pre_images` for
  the in-transaction re-validation Phase 2's Update arm runs when its pre-image diverges
  from the capture. `merge_update_document` is shared by Phase 2's real merge and the
  validator pre-image build; `reset_validator_fault_streak` delegates to
  `ValidatorRegistryCache::reset_faults`; `SqliteRepository::validator_registry` derives the
  directory from the repository's own `modules_dir` field (one source, never a caller-passed
  copy).
- `src/server/src/data/permission.rs` — `targets_system_band`, the any-depth
  (`/embedded/<coll>/<idx>/system…`) band-membership shape beside `targets_engine_band` —
  the predicate that decides whether an Update touches a validator-judged band at all.
- `src/server/src/data/sqlite/export_import.rs` — `import_world`'s in-loop validator pass
  (inside its own already-exclusive transaction — no throttling concern there, unlike
  `apply_intent`), which persists the bundle's `world_modules_key` settings row with every
  `validators_enabled` forced `false`.
- `src/server/src/ws/room.rs` — `Room::commit_ops_locked`'s error arm, the ONE auto-disable
  funnel every guarded write path shares, and `disable_faulting_validator_locked` (the
  idempotent disable write + GM-only seed-attributed chat notice + counter reset it calls
  once `crate::sandbox::VALIDATOR_FAULT_LIMIT` is reached).
- `src/server/src/ws/protocol.rs` — `ServerMsg::Reject.detail`.
- `examples/validator-rust/` — the reference no-std validator; `src/server/tests/sandbox.rs`
  builds it for real on every `cargo test --all`.

## Hard invariants

- Validators run over `system` ONLY, never `engine` — the engine band is already
  server-validated territory (`docs/design/ARCHITECTURE.md` §2 invariant 6); a validator
  seeing it would blur that boundary. An Update "touches `system`" exactly when
  `permission::targets_system_band` says so — an embedded-child write
  (`/embedded/<coll>/<idx>/system…`) included, and FAIL-CLOSED on every embedded boundary
  shape: a whole-map (`/embedded`), whole-collection (`/embedded/widgets`), or whole-child
  (`/embedded/widgets/0`) rewrite replaces children's `system` bands wholesale without
  stripping to a provable band, so it classifies as a system-band write and the post-image's
  own child walk is judged.
- `apply_command` (the trusted undo/replay substrate) NEVER invokes a validator — only
  `apply_intent` and `import_world`.
- `apply_intent`'s validator pass runs OUTSIDE the write transaction (the single-writer pool
  would otherwise throttle every hosted world on a slow validator); `import_world`'s does not
  need to, since that function already holds the writer exclusively for its whole duration.
- **Authorization always precedes any validator.** The pre-transaction pass screens every op
  through `check_command_scope` followed by Phase 1's OWN authorization functions
  (`authorize_create_intent`, `authorize_update_access`, `authorize_update_change` —
  extracted so the screen and Phase 1 share one statement of the capability floor; a
  re-spelled screen would be the never-fork defect class applied to authz). An op Phase 1
  would refuse gets `Forbidden` before any validator runs: its error text never discloses a
  validator's rules to an unauthorized writer, unauthorized intents never burn fuel or a
  fault streak, and a bare-id Update can never feed another world's document through this
  world's validators as a cross-world oracle.
- `sandbox::validate_document` always re-runs Phase 1's own pure structural validators
  (`validate_system_size`/`validate_property_overrides`/`validate_engine_tree`/
  `validate_containment`/`validate_system_schema_tree`) against the document BEFORE consulting
  any validator, returning that error untouched on failure — a malformed submission never
  reaches, and never faults, a validator, in either `apply_intent` or `import_world`.
- A validator can refuse; it cannot mutate the document, read others, observe time, or reach
  the network — enforced by giving it no imports beyond `env.log`, not by policy alone.
- **`ValidatorInput.prior` is permission-gated** (`validate_document::prior_permitted`):
  the pre-image band is stored content, so it is withheld unless the writer holds
  whole-document READ on the document — a write-without-read configuration would otherwise
  exfiltrate the stored band through the validator's input, or through a crafted refusal
  reason reflected back to the writer. Withheld means every node validates as a Create.
- **The validated post-image is the committed post-image.** The pre-transaction pass validates
  a merge of a read-only pre-image, and Phase 1's OCC covers only each change's own pointer —
  a concurrent write to any OTHER path of the same document would otherwise commit a
  post-image no validator saw. `apply_intent::validated_pre_images` captures the pre-image
  per Update, and Phase 2's Update arm re-runs `sandbox::validate_document` against the
  in-transaction merge when the pre-images diverge — re-validation, NEVER `Conflict` (a
  Conflict on any concurrent write would let two writers livelock a protected document).
- The consecutive-fault counter is COUNTED entirely inside `sandbox::validate_document`
  (per-(world, module), on `ValidatorRegistry`); the auto-disable is ACTED ON at exactly one
  site, `Room::commit_ops_locked`'s error arm — the one funnel intent ingress, HTTP writes,
  chat sends, merge intents, combat transitions and config reseeds all share. `ws::conn`
  carries no inline threshold check (a second check site would fork the policy). Room-less
  callers (`import_world`, `create_world`) record streaks only and NEVER auto-disable — a
  bulk import must not flip a world's settings as a side effect of being read in.
- **An imported world arrives opted out**: `import_world` persists the bundle's
  `world_modules_key` row with every `validators_enabled` forced `false` (opting into third-party
  code is the GM's own act, never something a bundle may carry in) — while the import itself
  is still judged by the bundle's declared validators.
- `ValidatorRegistryCache` invalidates on THREE signals: the modules directory's own mtime,
  each cached module's `module.json` mtime, AND each declared validator's `.wasm` file mtime
  (`CachedEntry.wasm_mtimes`, a `None` sentinel for a declared-but-absent file) — an in-place
  `.wasm` swap (the natural update channel for an already-installed module) and a
  declared-but-missing `.wasm` dropped in later both take effect on the next call, never
  serving a stale compiled form or a stale load error.

## Gotchas

- A wasmi module is BOUND to the wasmi engine that compiled it — a per-call fresh engine can
  never instantiate the cached module. `CompiledValidator` therefore carries its fuel-metered
  engine (`CompiledValidator.engine`) beside the module (`CompiledValidator.module`), and
  `CompiledValidator::compile` is the ONE compile path (scan-time and every test fixture take
  the identical route).
- `FaultKind::TooSlow` reclassifies only a call that COMPLETED (an authored `Accept`/`Refuse`)
  past the 50 ms budget — a call that TRAPPED keeps its precise kind (an infinite loop stays
  `FaultKind::OutOfFuel`, which is strictly more diagnostic; both kinds count toward
  auto-disable identically). Reclassifying a trap would also make the fuel-cap test race the
  clock, since burning the full fuel budget outlasts the budget.
- The slow-call budget is measured on the BLOCKING THREAD (paired with the verdict inside the
  blocking task by `run_validator_with_budgets`), never across the async join — scheduling
  latency is not the validator's fault and must not count against it.
- Validator test fixtures use a NON-engine doc_type (conventionally `"item"`), never
  `"actor"`: an engine doc_type with `engine: None` fails `validate_structural`'s
  `validate_engine_tree` before any validator is consulted, so an `"actor"` fixture with no
  engine body tests the structural gate, not the sandbox. An end-to-end fixture that needs an
  actor must carry a valid typed `engine` body (the intent JSON includes it beside `system`).
- `SqliteRepository::modules_dir` defaults to `None` on every plain `::connect()` call —
  validators silently never run until `.with_modules_dir(..)` is called (production `main.rs`,
  `test_server.rs`, and `test-support::spawn_with` all do; a bespoke test harness that builds
  its own `SqliteRepository` without calling it will never see a validator fire, which usually
  means the test just needs that one call added, not a sandbox bug.
- `WorldModuleEntry::parse_legacy_tolerant` accepts a legacy bare-`string[]` settings row,
  reading every id as `validators_enabled: false`; do not "fix" an old dev DB by hand, the
  fallback already handles it.
- A module's own `Refuse` verdict resets its fault streak exactly like `Accept` — only a
  `Fault` verdict is evidence the sandbox itself is broken; an authored refusal means the
  module ran correctly.
- The auto-disable is idempotent: a module whose `validators_enabled` is already `false` (or
  that dropped out of the enabled set entirely) is a no-op beyond the streak reset, so a
  streak of 6, 7, ... never duplicates the GM notice the 5th fault posted. The notice is
  attributed to the world's first GM via `world_seed::seed_author` — NEVER to the user whose
  intent faulted — and a world with no GM member gets no notice but is still disabled and
  reset. `disable_faulting_validator_locked` performs NO threshold check of its own; the
  funnel at `commit_ops_locked`'s error arm is the only place `VALIDATOR_FAULT_LIMIT` is
  compared, and its notice commit re-enters `commit_ops_locked` through the boxed-future
  wrapper `commit_ops_locked_boxed` because async recursion requires it (bounded: each level
  disables a distinct module).

## Pointers

- Threat model: `docs/design/sandboxed-validators.md`.
- Author-facing guide: `docs/site/guides/creating-a-validator.md`.
- Relationships: `graphify query "sandbox validator wasmi fuel fault world module entry"`.
