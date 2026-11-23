Part of the shadowcat-codebase-realtime-sync skill; read it before changing egress, resync, correlated requests, scene-addressed relays (ping/emote/ruler/vfx), audio frames, move streams, or the docs ratchet.

# Realtime & Sync: gotchas

The gotchas of the realtime and sync domain: egress, resync, correlated requests, relays, audio, move streams and the docs ratchet.

| Part | Holds | Read it when |
|---|---|---|
| [gotchas-01-egress-resync-correlated-requests.md](gotchas-01-egress-resync-correlated-requests.md) | Gotchas: `egress_loop` test harnesses; malformed `Intent` frames; `Hello`; the world snapshot route; `WsClient.open()`; the docs ratchet; per-recipient broadcast filtering; live search; correlated request pairs and their typed rejections; client ids; audio frames; per-connection re-eval deadlines | Changing egress, resync, live search, correlated requests, audio frames, re-eval deadlines or the docs ratchet |
| [gotchas-02-scene-relays-and-move-streams.md](gotchas-02-scene-relays-and-move-streams.md) | Gotchas: `ScenePing`; the shared ruler; `Emote`; `ScrollingText`; `MoveRequest` and `MoveStream`; gated moves; the `Egress::Frame` payload | Changing scene-addressed relays, move streams, gated moves or the Egress frame payload |
