# shadowcat-codebase

Claude Code plugin: codebase orientation skills, a coder/reviewer agent set, and a skill-routing
hook for [Shadowcat](https://github.com/Solidor777/Shadowcat), an open-source, fully-moddable
virtual tabletop engine. Intended for engine development and for anyone building an external
Shadowcat module or system in its own repository.

The `shadowcat-codebase-*` skills are orientation+index briefs (Purpose / Key files / Hard
invariants / Gotchas / Pointers) for each engine subsystem — `shadowcat-codebase-core` is the
always-relevant base; one `shadowcat-codebase-<subsystem>` skill exists per subsystem alongside
it.

## Install

This plugin lives at `~/.claude/skills/shadowcat-codebase/` (Claude Code's `skills-dir`
convention) as a live clone of this repository, so an edit here takes effect immediately — no
version bump or marketplace refresh needed:

```bash
git clone https://github.com/Solidor777/shadowcat-codebase.git ~/.claude/skills/shadowcat-codebase
```

It loads automatically next session, addressed as `shadowcat-codebase@skills-dir`, and is
**disabled by default** everywhere. Enable it per project you want it active in:

```bash
claude plugin enable shadowcat-codebase@skills-dir --scope local
```

`--scope local` writes to that project's gitignored `.claude/settings.local.json`, so nothing is
committed to the consuming repo.

## Updating

Since the plugin reads live from the cloned directory, `git pull` inside
`~/.claude/skills/shadowcat-codebase/` is the entire update step.
