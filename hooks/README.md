# Codebase-skill activation hook

`codebase-skill-reminder.py` is a `PreToolUse(Edit|Write|MultiEdit)` hook: when a file under a
known subsystem is edited, it injects a one-line reminder to invoke the matching
`shadowcat-codebase-<subsystem>` skill. It dedupes once per `(session, subsystem)` and **fails
open** (never blocks a tool call, emits nothing on a parse error).

The hook is wired via this plugin's own `hooks/hooks.json`, which Claude Code activates
automatically whenever the `shadowcat-codebase` plugin is enabled for a project — no per-machine
`settings.json` edit is needed.

## Test

```bash
bash hooks/test-codebase-skill-reminder.sh   # expects: ALL HOOK TESTS PASS
```

The self-test is a bash script and calls `python3`; on Windows run it under **Git Bash** (the
hook itself needs only `python3`, but the test needs bash).

## Notes & limitations

- **Per-session marker accumulation.** Dedup markers are written to
  `tempfile.gettempdir()/shadowcat-skill-markers/` keyed on `(session_id, subsystem)` and are
  never garbage-collected; they are tiny and harmless, but accumulate across sessions. Prune the
  directory if it ever matters.
- **Multi-subsystem files get one bucket.** A file that spans two subsystems (e.g.
  `src/client/core/src/scene-docs.ts` holds both actor/token/faction builders *and* scene/scene-
  entity builders) is deliberately **not** added to a subsystem glob: first-match-wins routing
  would mis-attribute it to one subsystem. Such files surface via description-match activation for
  the main-thread agent instead; the path hook intentionally stays silent on them.

- **`file_path` is always ABSOLUTE.** The tool payload carries a full path, so every pattern in
  `SUBSYSTEMS` is a substring match and none may be `^`-anchored — an anchored pattern is inert
  yet still satisfies any repo-relative test fixture, so the test suite would certify it green.
  Collisions between a substring pattern and a real file elsewhere are resolved by ORDERING
  (claim the file explicitly in an earlier entry), never by anchoring.

## Maintenance

When a new `shadowcat-codebase-<subsystem>` skill is added, add its path globs to the
`SUBSYSTEMS` map in `codebase-skill-reminder.py` (most-specific subsystems first) and a routing
check to the test. Any new entry needs at least one ABSOLUTE-path assertion (Windows-drive,
POSIX, and backslash forms are all exercised in the suite) — a repo-relative fixture alone cannot
tell a live entry from an inert one. See the `shadowcat-codebase-core` skill's "Maintaining this
skill family".
