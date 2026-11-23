Part of the shadowcat-codebase-realtime-sync skill; read it when touching self-service account routes, the route prefix, frame admission limits, presence, the modules-changed frame, portal offers, the session pause, module placements or the present-note relay. Part 03 of 03 of "Realtime & Sync: key files and seams"; the index is key-files-and-seams.md.

Continues "Key files & seams" from key-files-and-seams-02-protocol-http-auth-client.md.

- **Self-service accounts** (`http::routes`, routed in `http::router`): `change_own_password`,
  `put_profile`, `put_avatar`/`delete_avatar`, and `get_member_avatar` (world-scoped: the caller
  and the target must both be members of that world). `change_own_password` spends the
  `password_change:u:<user id>` bucket of `http::throttle::AuthThrottle`
  (`PASSWORD_CHANGE_PER_MIN_PER_ACCOUNT`) BEFORE any Argon2 work, runs exactly one verify on every
  path (a missing hash still verifies a throwaway `anti_enumeration_phc` hash), clears the
  account's session rows and calls `RoomRegistry::evict_user`, which broadcasts `ServerMsg::Evicted` so every live
  socket of that account (the caller's own included) closes and must sign in again. `data::repository::WorldMemberRow` carries `colour`, `pronouns` and `has_avatar`; avatar
  bytes never ride a roster listing. A client's roster picks up a profile change only on
  reconnect.
- **Frame admission** (`ws::conn::client_frame::parse_client_msg`): `ClientMsg` is internally
  tagged, and serde buffers every non-tag field before a variant deserializer runs, so a bound
  inside a variant never limits that allocation. The function bounds the frame first:
  `MAX_CLIENT_MSG_DEPTH` nesting, and `MAX_NON_INTENT_FRAME_BYTES` for every message except
  `ClientMsg::Intent` (bounded by the transport's `WS_MAX_MESSAGE_BYTES`). A payload that can
  exceed the non-intent cap must travel as an intent, never as a new typed frame.
- **Route prefix**: `Config.route_prefix` (normalized by `config::normalize_route_prefix`; read
  only through `Config::base_path`). `http::router` nests the whole application under it and
  nothing answers outside it; `http::embed::static_handler` strips it for the embedded-file lookup
  and the served `index.html` publishes it as `window.__SHADOWCAT_BASE__`. Client code reads it
  through `apiPath` and `wsUrl` (`@shadowcat/core` `base-path`); a bare `/api/...` or `/ws` literal
  in client code is a defect.
- **Presence**: `Room.presence` counts live connections per user; `Room::presence_connect` and
  `presence_disconnect` return true only on the 0<->1 transitions, and `ws::conn` then
  `broadcast_aux`es `ServerMsg::Presence` to every connection in the room. Out-of-band: no seq,
  never buffered or resynced, and no snapshot frame, so a client learns of a user already online
  only at that user's next transition. The client surface is `WsClientHandlers.onPresence` and
  `AppContext.presence`.
- **`ServerMsg::ModulesChanged`** (no payload) is broadcast by
  `http::module_routes::set_world_enabled_modules` after a GM saves the enabled set; every client
  re-runs its own module reconcile. A new `ServerMsg` needs its Rust variant, the generated type,
  a Zod arm in `wire.ts` and a `WsClientHandlers` hook; `wire.test` carries a per-tag table that
  fails until the new tag is listed.
- **Session pause** (`ws::session_pause`): one rule for every refusal path. The `ClientMsg::Intent`
  arm of `ws::conn` asks `intent_refusal`; typed requests (`MoveRequest`, a `ChoosePortal` that
  picks a destination, the eight combat intents) ask `msg_refusal`, classified by `blocks_msg`.
  A refusal is a `MoveError`, `PortalChoiceError` or `CombatError` carrying `RejectReason::Paused`,
  which `WsClient` maps to `SessionPausedError`; an intent refusal is a `Reject`. A GM is never
  refused, and server-authored writes (`WriteOrigin::CombatTransition`, region triggers) never
  route through it. A new typed request that moves a token or runs combat must be added to
  `blocks_msg` and `paused_reply`, and a new engine `doc_type` to `DOC_TYPE_CLASSES`.
- **Portal offers** (`ws::room::portal`): `Room.portal_offers` holds one short-lived `PortalOffer`
  per token (a newer offer replaces it; `PORTAL_OFFER_TTL_MS`). Every writer holds
  `publish_guard`, which serializes the table. `ServerMsg::PortalOffer` carries labels and option
  indices only, never coordinates; `ws::conn` delivers it to GM connections and, for a region
  visible to all, the token's effective owner. `handle_choose_portal` validates the answer and
  applies it through the same funnel a fixed `Teleport` uses (`apply_teleport_to`). Every
  `PortalChoiceError` shares one wording for a non-GM caller (`portal_choice_wire_message`), so a
  player cannot learn whether an offer, token or portal exists. The client waits for the reply with
  `WsClient`'s `portalPending` silence-window map, because success sends no frame.
- **Module placements** (`ClientMsg::PlaceEffect`, `ws::conn`'s `handle_place_effect` ->
  `Room::place_effect`): the effect set comes from a module manifest declaration, never from the
  client; success sends NOTHING (the broadcast `Event` of the placed region's Create confirms it)
  and a rejection is a `PlaceEffectError` to the requesting connection only, worded by
  `place_effect_wire_message` per world role. The write runs under `WriteOrigin::ModulePlacement`.
  A server-wide task started in `http::serve_with` (`spawn_placement_expiry_sweep`, period
  `PLACEMENT_EXPIRY_PERIOD`) deletes placed regions whose declared duration has passed, and ends
  with the shutdown request.
- **Present note** (`notes::handle_present_note`): a GM-only, out-of-band relay
  (`ClientMsg::PresentNote` -> `ServerMsg::PresentNote` through `Room::broadcast_aux`). It spends
  the shared `vfx_rate` bucket (`VFX_RATE_PER_MIN`, the one `/fx` and `PlayVfx` spend) after the
  GM gate, requires a `note` of this world whose `permissions.default` is above `DocRole::None`,
  and never widens access; a refusal is a `ChatError`.
- **Shutdown** (`http::serve_with`): both the caller's shutdown future and
  `WsState::trigger_shutdown` (used by the admin restore route) stop the serve loop and run the one
  drain; `conn_serve::serve_router` returns the outcome whose drain deadline bounds
  `WsState::wait_for_drain`.
