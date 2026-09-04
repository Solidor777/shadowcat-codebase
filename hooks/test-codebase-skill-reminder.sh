#!/usr/bin/env bash
# Self-test for the codebase-skill reminder hook. Exits non-zero on any failure.
set -u
H="python3 hooks/codebase-skill-reminder.py"
SID="testsession-$$"
mk() { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$SID" "$1"; }

# 1) First edit under data/ => emits documents-permissions reminder
out1=$(mk "src/server/src/data/permission.rs" | $H)
echo "$out1" | grep -q "shadowcat-codebase-documents-permissions" || { echo "FAIL: no reminder on first data edit"; exit 1; }

# 2) Second edit same subsystem same session => silent (deduped)
out2=$(mk "src/server/src/data/document.rs" | $H)
[ -z "$out2" ] || { echo "FAIL: not deduped on second data edit: $out2"; exit 1; }

# 3) Unmapped path => silent
out3=$(mk "README.md" | $H)
[ -z "$out3" ] || { echo "FAIL: emitted for unmapped path"; exit 1; }

# 4) Fresh session under data/ => emits again (dedup is per session, not global)
out4=$(printf '{"session_id":"%sb","tool_name":"Edit","tool_input":{"file_path":"src/server/src/data/permission.rs"}}' "$SID" | $H)
echo "$out4" | grep -q "shadowcat-codebase-documents-permissions" || { echo "FAIL: dedup leaked across sessions"; exit 1; }

# 5) Malformed input => silent, exit 0 (fail open)
out5=$(echo 'not json' | $H) ; rc=$?
{ [ -z "$out5" ] && [ $rc -eq 0 ]; } || { echo "FAIL: not fail-open on garbage"; exit 1; }

# 6) A representative path per subsystem maps to the right skill (fresh session each)
check() { # <session-suffix> <path> <expected-skill>
  o=$(printf '{"session_id":"%s%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$SID" "$1" "$2" | $H)
  echo "$o" | grep -q "$3" || { echo "FAIL: $2 did not map to $3 (got: $o)"; exit 1; }
}
check m1 "src/modules/asset-browser/src/AssetBrowser.svelte" "shadowcat-codebase-assets"
check m2 "src/modules/actors/src/ActorsPanel.svelte"     "shadowcat-codebase-actors-tokens"
check m3 "src/server/src/scene/vision.rs"                 "shadowcat-codebase-scene-rendering"
check m4 "src/server/src/ws/room.rs"                      "shadowcat-codebase-realtime-sync"
check m5 "src/modules/topbar/src/index.ts"               "shadowcat-codebase-client-shell"
# Routing-order disambiguation: asset files under shared dirs must beat the broader globs.
check m6 "src/server/src/data/asset.rs"                   "shadowcat-codebase-assets"
check m7 "src/server/src/http/assets.rs"                  "shadowcat-codebase-assets"
check m8 "src/server/src/data/permission.rs"             "shadowcat-codebase-documents-permissions"
check m9 "src/modules/conditions/src/index.ts"           "shadowcat-codebase-actors-tokens"
check m10 "src/modules/game-settings/src/index.ts"       "shadowcat-codebase-client-shell"
check m11 "examples/system-minimal/src/index.ts"         "shadowcat-codebase-module-toolchain"
check m12 "src/client/core/src/index.ts"                 "shadowcat-codebase-client-shell"
# Absolute paths: the Edit/Write payload always carries one, so a repo-relative
# assertion alone cannot prove an entry fires in production.
check m13 "C:/Dev/Shadowcat/src/client/core/src/footprints.ts" "shadowcat-codebase-scene-rendering"
check m14 "/home/dev/Shadowcat/src/client/core/src/scene-docs.ts" "shadowcat-codebase-scene-rendering"

# `@shadowcat/formula` is the engine's own expression library and carries its own skill.
check f1 "src/client/formula/src/graph.ts"                "shadowcat-codebase-formula"
check f2 "src/client/formula/src/template.test.ts"        "shadowcat-codebase-formula"

# THE REAL PAYLOAD SHAPE. Edit/Write always deliver an ABSOLUTE `file_path`; a repo-relative
# fixture alone cannot distinguish a live entry from an inert one, because a `^src/` anchor
# satisfies every relative fixture and matches nothing in production. The prefixes below are
# deliberately arbitrary: routing must not depend on what the checkout directory is called.
check f3 "C:/checkouts/anything/src/client/formula/src/evaluate.ts" "shadowcat-codebase-formula"
check f4 "/srv/checkouts/anything/src/client/formula/src/lexer.ts"  "shadowcat-codebase-formula"
# Backslash payload: the hook normalizes `\` to `/` before matching. The backslashes MUST be
# doubled so the JSON stays valid — an unescaped `\c` is a JSON syntax error, the hook fails open
# and emits nothing, which an assertion on absence would silently read as a pass.
check f5 'C:\\checkouts\\anything\\src\\client\\formula\\src\\parser.ts' "shadowcat-codebase-formula"
check a7 "/srv/checkouts/shadowcat/src/server/src/data/permission.rs" "shadowcat-codebase-documents-permissions"

# `client-shell` claims `src/client/core/src/(contributions|index)` explicitly, so the barrel and
# its neighbour reach the shell skill rather than any broader glob.
check n7 "src/client/core/src/contributions.ts"           "shadowcat-codebase-client-shell"
check n12 "C:/checkouts/shadowcat/src/client/core/src/contributions.test.ts" "shadowcat-codebase-client-shell"

# `combat` precedes `documents-permissions` (shared src/server/src/data/) — absolute paths
# per the real Edit/Write payload shape. No scene-docs.ts assertion here: that file is
# already claimed by `scene-rendering`'s existing, unchanged glob (see m14 above), so `combat`
# deliberately carries no glob of its own for it — first-match-wins would otherwise mis-
# attribute the whole file to one subsystem.
check c1 "C:/Dev/Shadowcat/src/server/src/data/engine/combat.rs"      "shadowcat-codebase-combat"
check c2 "/srv/checkouts/shadowcat/src/server/src/data/engine/combat/tests.rs" "shadowcat-codebase-combat"

# `src/server/src/combat/` (the transition/intent pipeline, distinct from
# `src/server/src/data/engine/combat`, the document types) routes to the same skill.
check c3 "C:/Dev/Shadowcat/src/server/src/combat/transition.rs"       "shadowcat-codebase-combat"
check c4 "/srv/checkouts/shadowcat/src/server/src/combat/mod.rs"      "shadowcat-codebase-combat"

# `src/modules/combat-tracker/` (the default combat tracker panel UI) also routes to `combat`,
# ahead of `client-shell`'s own module list.
check c5 "C:/Dev/Shadowcat/src/modules/combat-tracker/src/CombatTrackerPanel.svelte" "shadowcat-codebase-combat"
check c6 "/srv/checkouts/shadowcat/src/modules/combat-tracker/src/model.ts" "shadowcat-codebase-combat"

# `tables-notes` precedes `documents-permissions` (shared src/server/src/data/) — absolute
# paths per the real Edit/Write payload shape.
check t1 "C:/Dev/Shadowcat/src/server/src/data/engine/table.rs"       "shadowcat-codebase-tables-notes"
check t2 "/srv/checkouts/shadowcat/src/server/src/data/engine/table/tests.rs" "shadowcat-codebase-tables-notes"
check t3 "C:/Dev/Shadowcat/src/server/src/tables/draw.rs"             "shadowcat-codebase-tables-notes"
check t4 "/srv/checkouts/shadowcat/src/client/core/src/table-docs.ts" "shadowcat-codebase-tables-notes"

# The `note` half of `tables-notes` -- added in M19 fold-in review after the note engine/tree/
# client module globs were skipped in the original plan (routed to documents-permissions or
# matched nothing at all until this fix).
check t5 "C:/Dev/Shadowcat/src/server/src/data/engine/note.rs"        "shadowcat-codebase-tables-notes"
check t6 "/srv/checkouts/shadowcat/src/server/src/data/engine/note/tests.rs" "shadowcat-codebase-tables-notes"
check t7 "C:/Dev/Shadowcat/src/server/src/data/sqlite/notes.rs"       "shadowcat-codebase-tables-notes"
check t8 "/srv/checkouts/shadowcat/src/client/core/src/note-docs.ts"  "shadowcat-codebase-tables-notes"

echo "ALL HOOK TESTS PASS"
