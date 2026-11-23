Part of the shadowcat-codebase-realtime-sync skill; read it when changing egress, resync, live search, correlated requests, audio frames, re-eval deadlines or the docs ratchet. Part 01 of 02 of "Realtime & Sync: gotchas"; the index is gotchas.md.

## Gotchas

- **`egress_loop` test harnesses under a paused tokio clock must keep post-pause test traffic off
  the SQLite repository.** A sequenced `RoomEvent::Event` is filtered through a per-recipient
  query that sqlx runs on the SQLite driver's own worker thread, not a tokio blocking-pool thread —
  the only wait shape tokio's auto-advance inhibition recognizes. A `tokio::time::pause()`'d
  runtime treats time waiting on that thread as idle and auto-advances the clock straight to the
  next pending timer (a `tokio::time::timeout` deadline, or `egress_loop::ping_timer`'s own
  tick), firing it instantly with no real time having passed. Keep test code issued AFTER the
  pause on an out-of-band path instead: `Room::broadcast_aux`/`broadcast_aux_shared` reach the
  sink through `send_plain` with no repository query at all, unlike `Room::publish`. `egress_loop`
  ALSO creates `egress_loop::ping_timer` only after sending Welcome, so a harness must wait for a
  loop-served reply before pausing/advancing the clock, or the timer is constructed at the
  already-advanced instant and its first tick lands a full `PING_INTERVAL` late; the heartbeat
  test harness's probe for this is an `Egress::TimePong` round trip, since only
  `egress_loop::erx`'s arm answers it.
- **A malformed field anywhere in a client-authored `Intent` frame produces a generic,
  UNCORRELATED `ServerMsg::Error` (`WsErrorCode::BadMessage`), never a `Reject` — and the client
  silently discards it (`case "error": break;`).** `Reject` requires the frame to parse into
  `ClientMsg` first (it carries the server-VALIDATED `intent_id`); a JSON/type-level failure —
  e.g. a `Document.id: Uuid` field that isn't a valid UUID string — fails at
  `serde_json::from_str::<ClientMsg>` before `intent_id` is ever extracted, so `handle_socket`'s
  `Err(_)` arm (malformed-frame branch) has no `intent_id` to attach and sends the generic
  `Error` instead. The optimistic prediction that intent pushed via `applyIntent` is now
  UNRECOVERABLE: no `Event` will ever confirm it (the write never reached `apply_intent`), and no
  `Reject` will ever roll it back — see the FIFO-misalignment invariant in SKILL.md for the cascading
  consequence. Any id-shaped string builder (e.g. `@shadowcat/core`'s `deterministicId`) needs a
  shape-asserting test (`toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-.../)`), not just a stability/
  uniqueness test — those alone cannot catch a shape defect, since two calls with the same
  (broken) inputs still compare equal to each other while still being invalid.
- **`ClientMsg::Hello { world, last_seq }` is live** — `ws::conn`'s ingress match
  reacts to `Hello { last_seq: None, .. }` by calling `Room::establish_resync_floor`; `world` is
  destructured away (redundant with the connection's already-resolved `world_id`/`room` from the
  WS upgrade route). `WsClient` sends it unconditionally as the first frame on every socket open
  (`#hasEverOpened` distinguishes cold start from reconnect — see `shadowcat-codebase-client-shell`
  or `WsClient.seedWatermark`'s own doc), so the floor is established in production today — see
  `Room::resync_floor_enforced`'s own doc.
- **`GET /api/worlds/{id}/snapshot`** (`http::routes::world_snapshot`) — every document the caller
  can currently see, filtered exactly like `list_documents` (READ-gated, `filter_properties`
  redaction, token→actor owner join) but across every `doc_type` via `Repository::query_all_documents`
  in one call, plus the room's `current_seq` at read time (`WorldSnapshot.seq`). The client's
  cold-start bootstrap source: `WorldSession.enter` fetches it before opening the WS connection and
  pre-seeds the watermark via `WsClient.seedWatermark`, replacing full event replay from seq 1 on a
  genuine cold start; per-document-type grants (`WorldCapDefaults::grants_for`) are cached locally
  in the handler since a snapshot spans many types, unlike `list_documents`'s single shared `q.type`.
- **`WsClient.open()` does not re-check `running_` after its connect await** — a `stop()` call
  during a pending connect can leave an adopted-but-unwatched transport assigned to
  `this.transport`.
- **Docs-ratchet is live on the whole `ws/` tree AND the `http/` + `auth/` trees:**
  every file in all three trees carries `#![deny(missing_docs)]` +
  `#![deny(clippy::missing_docs_in_private_items)]` — a new undocumented item fails the 3-OS CI
  clippy step, and `ws::protocol` doc comments flow into the generated `ServerMsg`/`ClientMsg` TS
  types (regenerate + commit bindings with any change; the docs site's protocol page links these
  types). Route-handler docs in `http::routes` cite their authz gate (`require_gm`/`AuthUser`/
  `AdminUser`/`permission_context`) and the 404-uniform existence-hiding contract — keep those
  citations true when changing a route's gating.

- **Permissions filter every broadcast per recipient** — hidden fields are stripped before
  transmission by default (see `shadowcat-codebase-documents-permissions`); only game state may
  be sent-then-hidden, never personal user information.
- **Live search rides the broadcast** as top-N subscriptions over the same egress
  [[m6c-2-live-search]]. `ClientMsg::Search` and the `Egress::Subscribe`/`Sub` subscription
  record both carry `doc_types: Vec<String>` (`#[serde(default)]` on the frame, so an omitted
  field defaults to empty — no filter, every type). `ws::conn`'s ingress arm cap-checks
  `doc_types.len()` against `data::search::MAX_SEARCH_DOC_TYPES` (16) BEFORE calling the
  repository, on BOTH the one-shot and subscribe arms — sending `ServerMsg::SearchError` on
  violation — as defense-in-depth ahead of `Repository::search`'s own identical check
  (`shadowcat-codebase-documents-permissions`), so a caller that bypassed ingress validation
  entirely still cannot force an unbounded `doc_type IN (...)` clause.
- **One-shot correlated request pairs** (`Search`→`SearchResult`/`SearchError`;
  `Pathfind`→`PathResult`/`PathError`; `MergePull`/`MergePush`/`MergeRevert`→`MergeResult`/
  `MergeError`, the last via `WsClient.mergePending` with a caller-sized `timeoutMs` — see
  `shadowcat-codebase-templates`) route replies to the requesting connection only (never
  broadcast); correlated by `request_id` via the `pending` map in `WsClient`. See
  `WsClient` and `ws::protocol`. **Chat ops
  (`SendMessage`/`EditMessage`/`DeleteMessage`/`RecalcRoll`) also carry `request_id` but are
  ASYMMETRIC**: only
  a REJECTION replies (`ServerMsg::ChatError`, sender-only), while success is confirmed by the
  broadcast `Event` echo. They use a separate `chatPending` map whose timer resolves
  (success-assumed) rather than rejects on timeout — see `shadowcat-codebase-chat`.
  **A THIRD family: the 8 `ClientMsg::Combat*` frames** (`CombatStart`/`CombatPause`/`CombatEnd`/
  `CombatAdvance`/`CombatRewind`/`CombatSort`/`CombatRoll`/`CombatResource`), resolved through
  `WsClient`'s own `combatPending` map by `request_id` on BOTH paths — a dedicated
  `ServerMsg::CombatResult { request_id, seq }` answers an accepted intent (originator-only, never
  broadcast) and `ServerMsg::CombatError { request_id, reason }` answers a rejection; there is no
  echo-matching on success. An entry resolves ONLY once its `combat_result` has arrived
  AND `nextExpected` has advanced past its seq, both keyed by `request_id` — never by matching a
  self-authored broadcast `Event`, which identifies neither the `request_id` nor the specific
  intent an entry is waiting on, and which a client that cannot identify its own authorship never
  sees at all. See `shadowcat-codebase-combat`.
- **Correlated-request rejections are TYPED; a caller chooses by the error's class, never by message
  text.** `WsClient` rejects with `NotConnectedError` (no open socket when the request was issued,
  or the socket closed while it was pending — every reject-all path), `RequestTimeoutError` (the
  reply never arrived; says nothing about whether the request would have succeeded — search,
  subscribe, scene subscribe, pathfind, move, combat and merge all use it), and `PathfindError`
  (the server answered `PathError`; carries the typed `PathfindError.reason`). All three are
  exported from `@shadowcat/core`. **`PathError` carries a typed `reason`
  (`ws::protocol::PathErrorReason`: `Unreachable`/`Invalid`/`Exceeded`) beside its presentable
  text**, and the server derives the text from the reason (`PathErrorReason::message`, via the
  `ws::conn` `path_error` builder) so the two cannot disagree; the one mapping from a pathfinder
  failure is `From<PathFail> for PathErrorReason`. **Every refusal the server deliberately does
  not distinguish (a caller with no token in the scene, a turn or budget refusal) is reported as
  `Unreachable`**, so a client can learn no more than "no route" — a new refusal must reuse
  `Unreachable`, never mint a reason that oracles it. A new wire scalar of this kind needs all four
  edits: the Rust enum, the generated TS (`PathErrorReason`), the Zod schema (`PathErrorReasonSchema`
  / `WirePathErrorReason`) and the `WsClient` mapper that builds the error.
- **Every client-generated id comes from `randomUuid` (`@shadowcat/core`), never
  the browser's crypto.randomUUID.** Plain-HTTP LAN play is a non-loopback insecure origin, where the browser
  withholds secure-context members: crypto.randomUUID is `undefined` there, so a raw call throws
  at world entry, while unit tests (Node) and the loopback e2e project (a secure context) can never
  see it. `randomUuid` falls back to crypto.getRandomValues and still produces a version-4 UUID
  the server's document-id rule accepts. Request ids, document ids, the ruler `origin` token and
  pop-out window keys all route through it; `pnpm lint:secure-context` enforces this structurally
  (`shadowcat-codebase-core`).
- **`ClientMsg::AudioTransport { op }`/`AudioListenAs { token }` and `ServerMsg::AudioError
  { reason }`** — GM-only fire-and-forget playlist/playback transport plus the connection-local
  spatial-audio "listen as" override; `AudioError` is a connection-local refusal toast, never
  broadcast, mirroring `ChatError`'s sender-only shape rather than the request_id-correlated
  Combat/RollRequest pattern above (no `request_id` on either audio frame). The
  `egress_loop::listen_as` override lives entirely in connection-local state and is forwarded
  only to the SENDER's own egress task (`Egress::AudioListenAs`); its arm stores the new value and
  sets that connection's own `egress_loop::reeval_deadline` to now, so the sender's scene
  subscriptions re-derive on the very next loop iteration rather than after the debounce window
  the any-`Event` arm uses. It shares the one deadline timer the scene-channel re-eval loop
  already owns and adds no invalidation hook and no other machinery, and no other connection is
  touched. See `shadowcat-codebase-audio`.
- **Arming a connection's OWN re-eval deadline is the pattern for "server state a per-recipient
  derivation reads has changed underneath it".** `egress_loop::reeval_deadline` is a loop-local in
  `egress_loop`, not a field on any shared state, so what varies between the two users of the
  pattern is WHICH connections arm it. The audio listen-as override (above) is the first user: it
  arms only its own sender's deadline, because the changed state is that connection's own.
  `ServerMsg::ExploredFogReset` is the second: `handle_reset_explored_fog` deletes the rows,
  `broadcast_aux` carries the notice to every connection in the room, and the `egress_loop` arm
  sets EACH connection's own deadline to now, so every recipient re-derives its own
  `vision` payload from the now-empty `explored_fog` rather than serving its previous explored mask
  until something else happens to invalidate it. The derivation itself
  (`ws::conn::enrich_vision_explored`) reads the table fresh on every recompute, so the arm is the
  whole invalidation — there is no cache to evict. Reach for this shape, not a new per-frame
  invalidation hook, whenever a mutation changes what a per-recipient derived channel would compute.
  `handle_reset_explored_fog` refuses before deleting anything: a non-GM sender or a scene outside
  the world gets one identical `Forbidden` error, and a `user`-scoped reset on a `Shared`-pooling
  scene gets a distinct `BadMessage` error (refusal set and rationale:
  `shadowcat-codebase-scene-rendering`'s `scene::explored` bullet); no broadcast is sent for
  either. **Client wire mirror of that frame:** `explored_fog_reset` is a member of the
  hand-written `ServerMsg` union, a member of `serverMsgSchemaImpl`, and a `WsClient.handleFrame`
  case that calls the optional `WsClientHandlers.onExploredFogReset` with an
  `ExploredFogResetNotice` (`scene`, `user`, `level`; no seq). The outbound side is
  `WsClient.resetExploredFog` (`ResetExploredFogOptions`), which sends `reset_explored_fog`
  fire-and-forget with no correlated reply. `WorldSession` registers no `onExploredFogReset`
  handler: the server's re-derived `vision` push is the client's whole update. **Trap for ANY new
  inbound frame:** `parseServerMsg` validates against `ServerMsgSchema` and returns `null` for a
  `type` the schema does not list, and `handleFrame` returns on `null` with no error, so a
  server frame missing its `serverMsgSchemaImpl` member is dropped silently on every client while
  the server side and the type union look complete. A new inbound frame needs all three edits —
  the union member, the schema member and the `handleFrame` case.
