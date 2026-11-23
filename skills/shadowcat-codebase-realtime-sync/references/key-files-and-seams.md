Part of the shadowcat-codebase-realtime-sync skill; read it when working in ws, http, auth or the client store and you need the file-by-file map, room/move/rate-limiter/session details.

# Realtime & Sync: key files and seams

The per-file map of ws, http, auth and the client store: Room and move execution, rate limiters, protocol, connection loop, sessions, throttling, accounts and invites, eviction, WsClient and the stores.

| Part | Holds | Read it when |
|---|---|---|
| [key-files-and-seams-01-room-and-rate-limiter.md](key-files-and-seams-01-room-and-rate-limiter.md) | Key files & seams: `ws::room`; the `ws` module root and its flood budget | Editing `Room`, the ring buffer, move execution, the message rate limiter or `WsState` |
| [key-files-and-seams-02-protocol-http-auth-client.md](key-files-and-seams-02-protocol-http-auth-client.md) | Key files & seams: `ws::protocol`; `ws::conn`; `http::routes`; `auth::session`; `http::throttle`; accounts and world seating; `auth::invite`; deletion and eviction; `WsClient`; `Welcome.role_capabilities`; `webSocketConnect`; `DocumentStore` and `OptimisticClient` | Editing frames, the connection loop, HTTP routes, sessions, throttling, accounts, invites, eviction, `WsClient` or the client stores |
| [key-files-and-seams-03-accounts-presence-portals-pause-placement.md](key-files-and-seams-03-accounts-presence-portals-pause-placement.md) | Key files & seams: self-service account routes; frame admission limits; the route prefix; presence; `ModulesChanged`; the session pause; portal offers; module placements; present-note; shutdown | Editing account routes, `parse_client_msg`, the route prefix, presence, portals, the pause, placements or shutdown |
