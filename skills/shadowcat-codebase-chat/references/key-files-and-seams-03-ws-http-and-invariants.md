Part of the shadowcat-codebase-chat skill; read it when editing the ws and http chat ingress, apply_intent write origins, or the message hard invariants. Part 03 of 03 of "Key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-01-chat-module.md.

- `ws::protocol` — `ClientMsg::SendMessage { request_id, channel, content,
  actor_owner: Option<ActorOwnerRef>, audience: Audience }` (ts-rs exported; `audience` is
  `#[serde(default)]`, so an omitted field parses as `Audience::Public`).
  `ClientMsg::EditMessage { request_id, message_id, content }`,
  `ClientMsg::DeleteMessage { request_id, message_id }`, and
  `ClientMsg::RecalcRoll { request_id, message_id, roll_id, ops: Vec<WireRecalcOp> }` (all three
  ts-rs exported) are the ONLY client-facing ways to mutate an existing stored message. **All
  four carry a REQUIRED `request_id: Uuid`** (mirroring the `Search`/`Pathfind`/`MoveRequest`
  correlation pattern): success is confirmed only by the broadcast `Event` echo, while a
  rejection is surfaced to the sender as a `ServerMsg::ChatError { request_id, message }`.
  `SendMessage`/`EditMessage`/`DeleteMessage` share one `SendMessageError` enum + one `Display`;
  `RecalcRoll` uses its own `RecalcRollError` + `Display` (see `handle_recalc_roll` in references/dice-wire.md) but
  the SAME `ServerMsg::ChatError` frame shape and asymmetric confirm-by-broadcast-echo protocol.
  `message` is `SendMessageError`'s (or `RecalcRollError`'s) `Display`, which is
  `[sec]`-classified: validation-class variants surface a specific reason, but
  authorization/existence/internal-class variants (`ActorNotSpeakable`, `Forbidden`, `NotFound`,
  `Data`; `RecalcRollError::Forbidden`/`NotFound`/`RollNotFound`) collapse to a fixed generic
  string — `NotFound`==`Forbidden` (no existence oracle), `Data` never leaks its inner detail.
  See the `Display` impls on `chat::SendMessageError` and `chat::RecalcRollError`.
- `ws::conn` — four chat dispatch points plus the `Intent` guard:
  - `ClientMsg::Intent { ops, .. }` arm: calls `chat::ops_target_message(&ops)` BEFORE
    `room.publish`; if true, sends `ServerMsg::Reject{reason: Forbidden}` and continues without
    ever reaching `apply_intent`.
  - `ClientMsg::SendMessage { .. }` arm: calls `chat::handle_send_message`.
  - `ClientMsg::EditMessage { .. }` arm: calls `chat::handle_edit_message`.
  - `ClientMsg::DeleteMessage { .. }` arm: calls `chat::handle_delete_message`.
  - `ClientMsg::RecalcRoll { .. }` arm: converts each `WireRecalcOp` via
    `WireRecalcOp::into_recalc_op` and calls `chat::handle_recalc_roll`.
  - All four chat arms confirm success only by the broadcast echo of the authored `Event` (same
    pattern as `Intent`), not a direct reply; a failure is `tracing::debug!`-logged AND emits a
    `ServerMsg::ChatError { request_id, message: e.to_string() }` to the SENDER's connection only
    (`handle_socket::etx`, never broadcast) so the rejection is surfaced instead of vanishing.
- `http::routes::write_ops` — mirrors the WS ingress guard:
  `if chat::ops_target_message(&ops) { return Err(AppError::Forbidden); }` before the room/repo
  write path. Both transports must independently apply this guard. (`EditMessage`/`DeleteMessage`/
  `RecalcRoll` have no HTTP equivalent — they are WS-only frames, same as `SendMessage`.)
- `data::sqlite::apply_intent` — takes a `WriteOrigin` (`Client` |
  `ServerMessageRevision`, from `data::command`) parameter, threaded from
  `Room::publish` through ~60+ call sites (every existing caller passes `WriteOrigin::Client`;
  ONLY `handle_edit_message`/`handle_delete_message`/`handle_recalc_roll`/`handle_revise_audience`/
  `post_publish::run_pending_enrichments` ever construct `WriteOrigin::ServerMessageRevision`, and
  only after either their own owner-or-GM check has already passed (edit/delete/recalc; revise
  is GM only) or, for
  `run_pending_enrichments`, after an OCC re-read against the current stored document (see the
  post-publish section in references/link-previews.md — this producer runs unattended, well after the original sender's
  own authorization already gated the message's existence). FOUR coupled chokepoints:
  1. **Create-gate exemption** (`apply_intent::is_baseline_message = doc.doc_type == MESSAGE_DOC_TYPE &&
     ctx.world_role == WorldRole::Player && doc.owner == Some(ctx.user_id)`) — lets a Player
     create a `message` doc even though `core:create` is otherwise GM-only by world default.
  2. **Ingress guard** (`ops_target_message`, WS `Intent` + HTTP `write_ops`) — rejects any
     client-authored `message` Create/Delete before it ever reaches chokepoint 1.
  3. **Update blanket rejection**, CONDITIONAL: `if cur.doc_type == MESSAGE_DOC_TYPE &&
     origin != WriteOrigin::ServerMessageRevision { return Err(DataError::Forbidden); }` —
     rejects every ordinary client `Update` against a stored `message` doc (an owning Player's
     `DocRole::Owner` would otherwise satisfy WRITE_FIELDS and let them forge fields post-hoc), but
     EXEMPTS the one write shape `handle_edit_message`/`handle_delete_message` produce.
  4. **`WriteOrigin::ServerMessageRevision` access grant**: when `cur.doc_type ==
     MESSAGE_DOC_TYPE && origin == WriteOrigin::ServerMessageRevision`, `apply_intent` does NOT
     call `resolve_access_world` (which would independently re-derive GM write authority from the
     MESSAGE'S OWN `gm_role`/`users` fields — and would incorrectly DENY a non-addressed/
     non-listed GM editing/deleting a `Whisper`/`GmOnly` message, since their capped role there
     has no `WRITE_FIELDS`). Instead it grants a narrowly SCOPED `Access { caps: {READ,
     WRITE_FIELDS}, all: false, ... }`, trusting that the calling handler has ALREADY completed
     its owner-or-GM check. This is proven correct for edit, delete, AND recalc, across all three
     `Audience` variants, for both the owner and a non-addressed GM —
     `handle_recalc_roll_succeeds_for_public_whisper_and_gmonly_audiences` independently
     test-proves the recalc case. `all: false` (not `all:
     true`) is deliberate — the grant itself covers `/engine` (and the delete tombstone's
     `/system` clear), not `/permissions`/`/embedded`, even for this trusted origin. The
     `/permissions` writes are admitted separately, by exact path: `SMR_PERMISSION_PATHS`
     (`/permissions/default`, `/permissions/gm_role`, `/permissions/users`,
     `/permissions/property_overrides`), the first three only for a GM author
     (`SMR_READERSHIP_PATHS`). A write scoped to EXACTLY `/engine`, `/system` or one of
     `SMR_PERMISSION_PATHS` is ALSO exempted from the additive
     `declared_caps_for_path` world/module-requirement check (`authorize_update_change::is_scoped_smr_write`,
     a three-way conjunction: origin + doc_type + exact
     path) — `CapabilityRequirement` carries no `doc_type`, so its ancestor-overlap rule would
     otherwise make ANY world-declared requirement under `/engine` (e.g. an actor's
     `/engine/vision`) block every `ServerMessageRevision` `/engine` write in that world,
     regardless of doc_type, denying a GM's already-vetted moderation edit/delete/recalc. A
     `ServerMessageRevision` write to any OTHER path still goes through the additive check —
     the exemption is scoped by path, not by origin alone, so it cannot silently widen if a
     future caller of this origin ever targets a path outside that list.

- **`SendMessage` is the SOLE message-authoring path.** A stored `message` doc can only be
  produced by `chat::handle_send_message` → `chat::build_message_doc` → `Room::publish`. No other
  code path may construct or persist one.
- **The seam is a FOUR-part coupled surface — weakening any one part alone reopens forgery.**
  (1) create-gate exemption, (2) `ops_target_message` ingress guard (WS `Intent` + HTTP
  `write_ops`), (3) the Update blanket rejection (conditional on `WriteOrigin`), and (4) the
  `WriteOrigin::ServerMessageRevision` scoped-access grant. (1) is sound only because (2) rejects
  a client-authored `message` Create/Delete before it ever reaches (1). (3) still blocks EVERY
  ordinary client Update, so a Player's own `DocRole::Owner` can never satisfy WRITE_FIELDS on
  their own message directly — the ONLY way through (3) is (4), and (4) is reachable ONLY via
  `handle_edit_message`/`handle_delete_message`, which run their own owner-or-GM check BEFORE
  setting `WriteOrigin::ServerMessageRevision`. `WriteOrigin` is not derivable from any wire frame
  — a client cannot request it, forge it, or otherwise reach (4) directly. Do not touch any one of
  the four without re-verifying the others.
- **GM edit/delete authority is audience-independent by design.** A GM may edit or delete ANY
  message (`Public`/`Whisper`/`GmOnly`) via `handle_edit_message`/`handle_delete_message`'s
  `ctx.world_role == WorldRole::Gm` check, REGARDLESS of whether that GM is individually listed in
  a `Whisper`'s `recipients` or would otherwise have read access to a `GmOnly`/`Whisper` message at
  all (moderation authority, not read authority — the two are deliberately decoupled). This is
  exactly why chokepoint (4) above cannot call `resolve_access_world` on the message's own
  `PermissionSet`: a non-addressed GM's capped role there has no `WRITE_FIELDS`, which would
  incorrectly deny a legitimate moderation edit/delete.
- **`/w` has two independent front-doors, and content wins.** A whisper audience can be set either
  via the `SendMessage` wire frame's `audience: Audience::Whisper{...}` field, or via a
  content-level `/w @user...` command. `handle_send_message` reconciles both through the exact
  same cap+membership validation chokepoint; when BOTH are present, the parsed content `/w`
  overrides the frame's `audience` argument. An edit can never open either front-door — a `/w` in
  edited content is rejected outright (`AudienceLocked`), not silently applied.
- **A NON-WHISPER edit re-runs the FULL send pipeline (`parse_command` + `sanitize`) except
  audience, which is frozen.** `kind` MAY change on edit (a plain message can become `/me`), but
  `channel`/`user_owner`/`actor_owner`/`audience`/`deleted_at` are always copied verbatim from the
  STORED document, never re-derived from the edit request. **A WHISPER edit skips
  `parse_command` entirely** — the edit content is the literal body and `kind` is left as stored,
  mirroring `handle_send_message`'s own literal-body treatment of a whisper's content; without
  this, an unmodified resubmit of a whisper's edit-prefill (itself post-`/w`-strip `source`) could
  silently reparse into a different `kind` or spuriously trip `AudienceLocked` one token deeper.
  `AudienceLocked` therefore fires only for a non-whisper edit. A delete is a pure SOFT tombstone — `content`
  is cleared and `deleted_at` is set via `Operation::Update` on `/engine`
  (not `/system`), NOT a hard `Operation::Delete`; the doc stays in the sequenced log at its original
  seq, so resync and per-recipient redaction keep applying to it unmodified. An edit on an
  already-tombstoned message is rejected (`NotFound`) — content can never be resurrected on a
  soft-deleted doc.
- **Content model is opaque and NOT ts-rs-exported** (`MessageKind`, `Segment`, `MessageEngine`)
  — only `ActorOwnerRef` and `Audience` (both on the wire `SendMessage` frame) are. The client
  mirror is the `chat-docs` module — Zod schemas +
  `parseMessageEngine(doc) -> ChatMessageEngine | null` (parses `doc.engine` not `doc.system`;
  fail-closed: wrong doc_type or ANY
  malformed body → null, never partial) + `isKnownSegment` (the source of truth for which
  segment kinds are known — unknown kinds parse as
  opaque forward-compat and render as nothing, but the fallback REFUSES every kind it lists so
  a malformed known-kind segment fails the whole message instead of being misclassified —
  load-bearing, pinned by tests). A Rust-side body-shape change MUST update that file by hand
  (drift notes at both ends), not a regenerated binding. `MAX_MESSAGE_CHARS` is mirrored there
  for composer pre-validation (JS `.length` counts UTF-16 units vs the server's
  `chars().count()` — divergence is fail-safe: client can only over-block). `PermissionSet`
  itself IS a generic, already-mirrored envelope type — its `gm_role` field is covered by
  the existing drift guard, not a message-specific mirror.
- **A whisper hides from the GM by default; only `recipients` membership grants a GM access.**
  There is no automatic GM see-all for `Whisper`/`GmOnly` messages — a GM must be individually
  listed in `recipients` (for `Whisper`) or simply hold `WorldRole::Gm` at read time (for
  `GmOnly`, via `gm_role`); a GM not covered by either sees nothing, not even that the doc exists.
  This is a deliberate product decision, not an oversight.
- **Recipient validation happens BEFORE document construction, fail-closed on the whole send.**
  `handle_send_message` checks every `Whisper` recipient against current world membership; a
  single bad uuid rejects the entire message (no partial send, nothing persisted) — do not move
  this check after `build_message_doc` or make it per-recipient-tolerant.
- **Messages ride the existing Event/redaction/search machinery with zero message-specific
  code in those subsystems** — a message's visibility, per-recipient redaction, sequencing, and
  FTS5 search hit are governed entirely by the generic `Document`/`PermissionSet` rules
  (`shadowcat-codebase-documents-permissions`) and the generic room broadcast/resync path
  (`shadowcat-codebase-realtime-sync`). Any change to those subsystems' redaction or indexing
  logic implicitly changes chat behavior too — there is no separate chat-specific override to
  audit, but also no chat-specific safety net.
- **`spec`/`raw` on a `RollEmbed` (and every `RecalcEntry.previous_raw`) are GM-only via
  `permissions.property_overrides`, populated by `roll_property_overrides` at
  message-Create time and re-populated on every recalc — never a chat-specific redaction
  filter; `outcome`/`recalc_history`/`roll_id` stay visible to every recipient EXCEPT under
  `Audience::Blind`, where `roll_property_overrides` also registers each roll's `formula`,
  `outcome` and every `recalc_history` entry's `previous_outcome` (and a `TableDraw`'s `formula`,
  `outcome` and matched `row`) as GM-only.** `spec`/`raw` are GM-only under every audience. See
  references/audiences-secrets-flavor-and-extensions.md for the blind audience.
  `roll_property_overrides` (its name covers both `RollEmbed` and `TableDraw` segments — see the
  `push_draw_overrides` note below) is recomputed from scratch against the CURRENT `content` on
  every call (never incrementally patched), so a message's override set always matches what it
  actually carries; `build_message_doc` calls it at Create, `handle_recalc_roll` calls it again
  after every recalculation and writes the result to `/permissions/property_overrides` in the
  SAME `Operation::Update` as the mutated `/engine` — the one write shape `apply_intent`'s
  `ServerMessageRevision` branch admits at that exact path (chokepoint 4 above). A
  `Segment::TableDraw(TableDrawSegment)` — produced only by `tables::handle_draw_table`, never by
  chat's own parser — recurses the SAME GM-only treatment through `push_draw_overrides`: its own
  `spec`/`raw` at `/engine/content/{i}/spec|raw`, and recursively through every
  `TableDrawSegment.row.nested` entry at `/engine/content/{i}/row/nested/{j}/...` — a nested draw
  arbitrarily deep still redacts at every level, see `shadowcat-codebase-tables-notes`.

