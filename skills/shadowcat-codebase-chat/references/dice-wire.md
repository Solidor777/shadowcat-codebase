# Dice wire

Part of the shadowcat-codebase-chat skill; read it when changing roll execution, roll segments or roll rendering.
## Dice wire — `chat::rolls` + the ingest roll stage

- `chat::rolls`: caps (`MAX_ROLL_DICE=100` summed over the parsed `Expr` — `walk_groups` recurses
  into `Expr::Call`'s arguments too, so a dice group nested inside a math-function call still
  counts; `MAX_ROLL_RECORDS=1000`
  post-roll; `MAX_EXPERTISE=100`; `MAX_DIE_SIDES=10_000`; `MAX_INLINE_ROLLS=8`),
  `DieKind::validate()` per group, `entropy_seed()` (fresh `Uuid::new_v4` fold per roll —
  nothing persists the seed; a stored outcome's naturals reproduce it), `scan_body_capped` (BALANCED
  `[[…]]` span grammar — single-bracket nesting depth so notation `[label]`s survive;
  `roll:`-prefixed spans are buttons, `|` splits a label), `execute_roll` /
  `validate_formula` (parse+caps without rolling, for buttons), `RollError` + Display.
- **References in roll notation resolve server-side at this boundary.** A roll's formula may be a
  raw TEMPLATE (`1d20 + stats.str`): `execute_roll`/`execute_roll_with_seed` first run it through
  `crate::formula::resolve_notation_template` (the Rust twin of the TS template rewrite), resolving
  each reference against the roll's HOST — for chat, the send's already-ownership-validated
  `actor_owner` via `chat::host::host_for_actor_owner` (a token's embedded actor copy, else its
  linked actor, the combat precedence rule shared through `data::document::embedded_actor_copy`),
  with no binding ⇒ `NoHostResolver` ⇒ an `unknown-ref` refusal via `RollError::Reference`
  (player-presentable `detail`). The substituted labeled constants surface as `labeled_consts`
  chips; the stored `RollEmbed.formula` keeps the author's template text, and recalc re-derives
  from the stored `spec`/`raw`, never re-resolves. Buttons (`[[roll:...]]`) validate structurally
  with a placeholder zero (a reference can never sit in dice-count/sides position) and store the
  raw template, resolving per CLICKER at click time. The template scan also reserves the notation
  `fn_call` vocabulary (`floor(101d6/2)` is notation, never a reference).
- `handle_send_message` roll stage (post-parse, pre-sanitize): kind `Roll` ⇒ the body is the
  formula, content becomes ONE `RollEmbed{formula, outcome, roll_id, spec, raw,
  recalc_history: None}` (sanitize skipped — no text). `chat::rolls::execute_roll`/
  `execute_roll_with_seed` return the parsed `RollSpec` and rolled `RawRoll` alongside
  `formula`/`outcome`, and both are PERSISTED (not discarded) onto the embed — `spec`/`raw` are
  what let a GM later recalculate the roll via `handle_recalc_roll`; `roll_id` (a fresh `Uuid`) is
  the stable identity a recalc targets, never the segment's array index.
  Normal/Emote bodies are `scan_body_capped`-chunked — Text chunks sanitize EACH INDEPENDENTLY
  (markdown spanning an inline roll doesn't survive, documented), Inline chunks execute,
  Button chunks validate-only. Ambient `ParseContext` = `resolve_dice_context(repo, world,
  channel)` (the `dice-settings` config doc: a `channel_overrides` entry for the SENDING channel
  wins outright over the doc's own `mode`/`direction`, full replacement never partial merge; fail-
  closed to Total/HighWins on any query error, absent doc, or malformed body, REGARDLESS of
  channel; GM-authored in module-game-settings' Dice section, including a per-channel editor
  enumerating `channel-registry`'s channels). ANY roll failure ⇒ the message is NOT created; instead
  ONE server-authored `MessageKind::System` notice (audience `Whisper{[sender]}`, same
  channel, sender-owned/deletable, content = the error's Display text) — exactly one message
  per attempted send, so the flood budget stays 1:1. `System` still has NO parse_command
  producer (exhaustive test unchanged).
- **Roll immutability (anti-cheat):** `handle_edit_message` rejects (`RollImmutable`) when the
  stored `kind == Roll`, when the stored content carries ANY `RollEmbed`/`RollButton` segment
  (an executed inline roll's audit record cannot be erased by editing around it), or when the
  new content parses to kind `Roll` (no editing INTO a roll). The stored-kind check is
  deliberately UNCONDITIONAL because `kind: Roll` + `audience: Whisper` IS reachable via the
  frame `audience` field (no `/w` token ⇒ `parse_command` still runs). Edits DO now route through
  `chat::body::compose_message` under `ScanMode::NoExecute` — a `[[doc:]]`/`[[token:]]`/
  `[[asset:]]` span in edited content composes into its typed segment the same as on send, and a
  `[[roll:]]` button span VALIDATES structurally (a malformed formula still fails the edit), but
  `ScanMode::NoExecute` guarantees no inline `[[Ndm]]` roll is ever EXECUTED by an edit — the
  distinction this bullet's title protects is "an edit can never mint a new rolled outcome," not
  "an edit treats `[[…]]` as inert text" (that was the pre-`compose_message` behavior; it changed).
  **Recalculation is the one deliberate
  exception to immutability**, gated entirely differently (see the next bullet) — it does not
  weaken this check, since `handle_edit_message` still refuses to touch `content` at all.
- **Recalculation (`handle_recalc_roll`):** the ONLY path that ever mutates an existing
  `RollEmbed`. GM-only (`ctx.world_role == WorldRole::Gm`) — deliberately NEVER owner-or-GM,
  unlike `handle_edit_message`/`handle_delete_message`: the roll's own author has no
  self-service correction path (`RecalcRollError::Forbidden`). Locates the targeted roll inside
  the message's `content` by `roll_id` (never array index — survives link-preview enrichment
  appending later segments), and refuses (`RecalcRollError::NoStoredState`) when the targeted
  `RollEmbed` carries no `spec`/`raw` (a roll embedded before this feature shipped) rather than
  guessing a spec back from `outcome`. Draws a fresh `entropy_seed()`, applies
  `dice::recalculate(&spec, &raw, &ops, &mut rng)`, overwrites `raw`/`outcome` in place, and
  appends a `RecalcEntry{ops, previous_raw, previous_outcome, recalculated_by,
  recalculated_at}` to `recalc_history` capturing the PRE-recalc state — the roll's original
  result is never silently discarded (`recalc_history` is append-only; `previous_raw`/
  `previous_outcome` on the Nth entry are exactly what the (N-1)th recalc, or the original roll,
  produced). Reuses `WriteOrigin::ServerMessageRevision` as this origin's THIRD producer (after
  `handle_edit_message`/`handle_delete_message`), publishing a single `Operation::Update` that
  writes BOTH `/engine` (the mutated content) AND `/permissions/property_overrides`
  (recomputed via `roll_property_overrides`, since a freshly-appended
  `RecalcEntry.previous_raw` needs its own GM-only override entry) — the exact two-path
  admission `apply_intent`'s `ServerMessageRevision` branch grants (see chokepoint 4 in references/key-files-and-seams.md).
  Rate-limited via the same `PingRateLimiter`/`budget_per_min` shape as
  `handle_send_message`/`handle_edit_message`. `WireRecalcOp` (`RerollDice`/`ReplaceDie`/
  `RemoveDice`, ts-rs exported — the wire frame's op vocabulary) converts via
  `WireRecalcOp::into_recalc_op` to `dice::recalc::RecalcOp` before reaching
  `dice::recalculate`; see `shadowcat-codebase-dice` for the engine-side op semantics.
  `ws::protocol`'s `ClientMsg::RecalcRoll{request_id, message_id, roll_id, ops}` and
  `ws::conn`'s dispatch arm are documented in references/key-files-and-seams.md alongside `SendMessage`/`EditMessage`/
  `DeleteMessage`.
- **Attribution authz (world-pinned):** `handle_send_message`
  fail-closed-validates `actor_owner` BEFORE `build_message_doc` — an `Actor` ref must resolve to
  an existing `doc_type=="actor"` doc, IN THE SENDING ROOM'S WORLD
  (`crate::data::document::world_of(d) == Some(room.world_id)`), owned by the sender (GM: any
  actor in that world). An actor doc from another world is refused (`ActorNotSpeakable`) even for
  its owner — ownership alone does not cross world scope. A `TokenInstance` ref is validated the
  same world-pinned way, except ownership resolves through `Repository::effective_owner_of`
  (the token's own `owner` override, else the linked actor's owner) rather than a stored `owner`
  field read directly — the same chokepoint every other ownership decision in this codebase
  goes through, never reimplemented inline. Edits copy `actor_owner` verbatim
  from the stored doc, so this ingest gate is the only one needed. `world_of` (`data::document`,
  `pub(crate)`) is the SAME helper `ws::scene_broadcast_permitted` uses for its own
  cross-world scene pin — one idiom for "does this doc belong to world X," not two independent
  `Scope` matches.
- Client: the `chat-docs` module mirrors `roll_embed`/`roll_button` (`RollOutcomeSchema`/
  `DieRecordSchema`, records `.passthrough()` for server-only audit fields; the
  unknown-segment fallback REFUSES both new kinds — fail-closed; i64 `total`/`margin` can
  saturate past 2^53, a documented display-precision tradeoff). The `roll_embed` member of
  the `ChatSegment` union is the named exported `RollEmbedSegment` (plus
  `RollEmbedSegmentSchema`/`rollEmbedSegmentSchemaImpl`), never an inline union literal and
  never an `Extract<>` projection — the `TableDrawSegment` precedent: a projection cannot be
  documented, and `AppContext.dice3d.roll` references the type directly (see
  `shadowcat-codebase-dice-3d` for that seam). `DieRecord`/`DieRecordSchema` also mirror
  the server's `DieRecord.kind` face-space field (a nullish `WireDieKindSchema` member). The card
  renders the block
  form ONLY for kind `Roll` + raw single-`RollEmbed` content, inline chips otherwise, buttons
  via `ctx.chat.send({channel: sys.channel, content: "/roll "+formula})` (fresh PUBLIC roll —
  no audience inheritance), System notices muted+badged; everything escaped, the `{@html}`
  single-sink invariant untouched. The composer's "Speak as" picker (own actors; GM: all)
  sends `actorOwner` and self-prunes when the selected actor disappears.

