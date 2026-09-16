---
name: shadowcat-codebase-audio
description: "Use when touching Shadowcat audio: the playlist/audio-state engine doc types and
the pure `audio::state::apply` transport reducer, `WriteOrigin::AudioTransport`, the
`AudioTransport`/`AudioListenAs` WS frames and `audio::transport::handle_transport`, the
scene-ambience/world-audio-overlay engine fields, the \"audibility\" derived channel and
`scene::audibility`'s falloff/occlusion/listener-selection geometry, the `SoundEmission`
carried-token-emitter resolver, the audio transcode pipeline (canonical never swapped to Opus;
Opus is always a sibling derivative), or
the client `@shadowcat/audio` package (`AudioEngine`, `TrackPlayer`, `EmitterPlayer`,
`OneShotPlayer`, `DuckController`) and the audio/sheet-playlist modules. Covers
src/server/src/data/engine/audio.rs + src/server/src/audio/ + src/server/src/scene/audibility.rs
+ src/server/src/data/asset/process/audio.rs + src/client/audio/ + src/client/core/src/{audio,audibility,playlist-docs}.ts
+ src/modules/audio/ + src/modules/sheet-playlist/. Invoke shadowcat-codebase-core and
shadowcat-codebase-scene-rendering first (audibility composes vision's occlusion primitives)."
---

# Shadowcat — Audio

Orientation for the audio subsystem: server-authoritative playlist playback, the world's audio
mixer overlay, spatial/occlusion audibility, and the framework-neutral client mixer package.

## Purpose

Playback state (`audio-state`, a config-adjacent singleton) is server-authoritative and
server-clocked: every client mixes the SAME `playing` set at the SAME position, computed from
`startedAt`/`pausedAt` against the calibrated server clock, never a client-local play command.
`playlist` documents are ordinary GM-authored content (create/edit/delete like any engine doc).
A carried `SoundEmission` (on `TokenEngine`/`ActorEngine`, inherited/overridden exactly like
`LightEmission`) is a per-token spatial sound source, resolved server-side into the
`"audibility"` derived channel — never client-computed geometry, mirroring the `"vision"`
channel's own posture.

## Key files & seams

- `data::engine::audio` — `PlaylistEngine { tracks: Vec<PlaylistTrack>, mode: PlaylistMode,
  channel: AudioChannel, fade_ms }`, `PlaylistMode { Sequential, Shuffle, LoopAll, Single }`
  (wire `snake_case`), `AudioChannel { Music, Ambience, Sfx }` (wire `lowercase`; `"master"`/
  `"ui"` are CLIENT-ONLY buses that never appear here), `AudioStateEngine { playing:
  Vec<PlayingTrack>, shuffle_seed: u32 }`, `PlayingTrack { id, playlist: Option<Uuid>,
  track_index: u32, asset, channel, gain, loop_, startedAt: f64, pausedAt: Option<f64> }`.
  `PLAYLIST_DOC_TYPE = "playlist"`, `AUDIO_STATE_DOC_TYPE = "audio-state"`.
- `data::engine::scene` — `SceneAmbience { playlist: Uuid, gain: f64 }` (`SceneEngine.ambience`),
  `Occlusion { Walls, None }`, `AudioOverlay { spatial: Option<bool>, occlusion:
  Option<Occlusion>, through_wall_gain: Option<f64> }` (`WorldSettingsEngine.audio`; every leaf
  optional, defaults `true`/`Walls`/`0.25`).
- `ws::protocol` — `AudioOp` (tagged `Play|Pause|Resume|Stop|StopAll|Seek|Next|Prev|SetGain`),
  `ClientMsg::AudioTransport { op }` (GM-only, fire-and-forget, no `request_id`),
  `ClientMsg::AudioListenAs { token: Option<Uuid> }`, `ServerMsg::AudioError { reason }`
  (connection-local refusal toast, never broadcast).
- `audio::state::apply` — the PURE `AudioOp` reducer (no I/O), mirroring `combat::transition`'s
  posture; `audio::transport::handle_transport` is the async GM-gate + asset-row-duration-check
  wrapper that commits the reduced state via `apply_intent` under `WriteOrigin::AudioTransport`
  (Update only — Create/Delete of `audio-state` are `WriteOrigin::ConfigSeed`-only, seeded once
  by `world_seed`; see the guard split in `data::sqlite::apply_intent`).
  `audio::transport::on_active_scene` swaps a scene's ambience playing-entries when
  `world-settings.activeScene` commits (hooked from `ws::room::Room::publish`).
- `scene::emitters`/`scene::audibility` — `token_light_emission`/`token_sound_emission` share
  ONE resolution precedence (linked-token override-or-actor, embedded-actor uncached read, raw
  token = `None`); `scene::audibility::falloff(t) = clamp(1-t²,0,1)`,
  `pan_for(dx, radius_world)`, `segment_occluded` (composes `segments_cross`; the caller,
  `compute_audibility`, narrows the wall set with `elevation::wall_occludes` via
  `elevation::walls_at_elevation`'s band filter BEFORE calling it — never a second occlusion
  primitive), `select_listener` (override →
  lowest-id owned token → `None`), `compute_audibility` → one `SceneAudibility { scene, listener,
  spatial, emitters: [AudibleEmitter { token, asset, gain, pan, loop }] }` per scene. **Gated on
  whole-document `cap::READ` per emitting token** (unlike light: `AudibleEmitter.token` is an
  identity disclosure light's anonymous field is not — mirrors
  `RecipientSight::sensed`/`player_perceived_tokens`, not `token_light_emission`).
  `scene::compute_derived`'s `"audibility"` arm assembles `AudibilityPayload { scenes }` by
  calling `compute_audibility` once per `SceneEcs::token_scene_ids()` entry that passes
  `SceneEcs::scene_visible_to` (the `ctx_can_see_engine` gate `resolved_footprints` shares, so
  the two channels never disagree about which scene ids a recipient may learn of — never a
  single active-scene resolution) and reads a connection-local `listen_as` override threaded from
  `ClientMsg::AudioListenAs` through `ws::conn`'s existing scene-channel re-eval loop — no new
  invalidation hook; it reuses the generic any-`Event` debounced sweep every `scene_subs` entry
  already gets.
- `data::asset::process::audio` — the Opus transcode (symphonia probe+decode → rubato resample
  to 48kHz if needed → Opus VBR encode via `opus`), muxed into whichever container(s)
  `AudioContainers` selects at import time (`Ogg`/`WebM`/`Both`, default `Both`: Ogg for gapless
  loop decode, WebM for the WebKit `canPlayType` gap on Ogg/Opus) — `.opus.ogg` via the `ogg`
  crate, `.opus.webm` via this module's own minimal EBML writer, each a SIBLING derivative,
  dispatched from `process_staged`. **The canonical asset is NEVER swapped to Opus** — the
  original stays canonical and every non-GM player's playback fallback. **Unlike `thumb`/
  `preview`, the Opus siblings are explicitly NOT `Variant`s and bypass `ensure_derivative`
  entirely** — `http::assets::serve`'s `?variant=opus|opus-webm` branch 404s a missing sibling
  rather than regenerating one, since a minutes-long transcode is produced at commit time or not
  at all. Over-cap input or any pipeline failure falls back to pass-through
  (`audio:untranscoded` tag, applied by the caller's `tags::derive`) with no derivative.
  `AssetMeta.duration_ms`/`sample_rate` (both `Option<i64>`) are populated by this pipeline.
- `@shadowcat/audio` (framework-neutral, Web-Audio-injected via `context.ts`'s `*Like`
  interfaces — no jsdom): `AudioEngine` (the per-world mixer graph: `master ← duck ← {music,
  ambience, sfx, ui}`), `TrackPlayer` (server-synced `<audio>`-element playback, drift-corrects
  via `playbackRate` nudge before a hard `currentTime` seek), `EmitterPlayer` (one per carried
  emitter, gain→pan→`sfx`, buffer decode shared with `OneShotPlayer.getBuffer`'s LRU cache),
  `OneShotPlayer` (decode+cache, `ONE_SHOT_CACHE_BUDGET_BYTES` = 32 MiB LRU), `DuckControllerImpl`
  (`approach`'s exponential smoothing, `DEFAULT_DUCKABLE = [music, ambience]`).
- `@shadowcat/core` — `audio.ts` (`AudioApi` — including `serverNow`/`transport`, both thin
  forwarders to `WsClient` — `DuckController`/`DuckSource`, `AudioChannelId`), `audibility.ts`
  (`parseAudibility`/`sceneAudibility`, fail-closed to `EMPTY_AUDIBILITY`/`EMPTY_SCENE_AUDIBILITY`,
  mirrors `footprints.ts`), `playlist-docs.ts` (re-exports + `buildPlaylistDoc`, mirrors
  `table-docs.ts`). `AppContext`'s only audio-flavoured member is `audio: AudioApi` (shell
  wiring).
- `@shadowcat/module-ducking` (`src/modules/ducking/`) — three `DuckController`/`DuckSource`
  consumers: `keySource.ts`'s `KeySource` (held-key push-to-duck), `micVad.ts`'s `MicVadSource`
  (an `AudioWorklet`-hosted energy VAD; the raw audio buffer never leaves the worklet — only a
  boolean per frame crosses the `MessagePort`), and `osMonitor.ts`'s `OsMonitorSource` (the
  browser-side client for `shadowcat audio-monitor`'s localhost WebSocket — see
  `shadowcat-codebase-server-ops`'s `audio_monitor` bullet for the server side). `keySource.ts`'s
  `DuckSink` is the shape `AudioApi.duck.addSource(id)` returns. `controller.ts`'s
  `DuckSourcesController` owns the key/OS-monitor sources for the whole world session
  (constructed once in `register(ctx)`, outliving any one settings-panel mount) and carries a
  `micToggle` field the real wiring sets. **The real wiring lives in `DuckingRuntime.svelte`, a
  headless component contributed into the always-mounted `shadowcat.surface:overlay` surface —
  never `register(ctx)` itself**, because `ModuleContext` (the framework-neutral type a module's
  `register` receives) carries no `audio` member; `AudioApi` is reachable only through the
  Svelte-side `AppContext` (`getAppContext()`), the same path every other `ctx.audio` consumer in
  this codebase uses (`AudioPanel`, `StatusBar`, `PlaylistSheet`). `DuckingSettings.svelte`
  itself only reads `audio.duck.depth`/`setDepth` at mount (a Settings-panel-local concern, safe
  to lose on close) and calls `controller.micToggle` — the sources' actual duck-sink wiring must
  outlive the Settings panel's mount, which is why it is NOT done inside the settings component.
  Any future module needing a background service tied to `AppContext` rather than `ModuleContext`
  should follow this same always-mounted-overlay pattern (mirrors `AssetPickOverlay`'s own
  session-persistent, mostly-invisible `shadowcat.surface:overlay` contribution).

## Hard invariants

- Playback position is NEVER client-authoritative: every readout derives from
  `startedAt`/`pausedAt` against the calibrated server clock (`WsClient.serverNow()`), never
  `Date.now()` or a local timer.
- The audio-state singleton's Create/Delete and Update are guarded by DIFFERENT `WriteOrigin`s
  (`ConfigSeed` vs `AudioTransport`) — a uniform single-origin guard was tried and is a
  documented spec contradiction; do not "simplify" it back to one origin.
- The canonical asset never changes format for audio — Opus is always a sibling, never a
  replacement; an audio asset's `content_type`/bytes at the canonical path are whatever was
  uploaded (or the pass-through note explains why no conversion ran). The Opus sibling(s) are
  NOT `Variant`s (see `data::asset::process::audio` above) — never regenerated lazily on serve.
- `AudibleEmitter.token` is a `cap::READ`-gated identity disclosure — never remove that gate to
  "match" `token_light_emission`'s visibility-blind posture; they are deliberately different.
- `scene::audibility::compute_audibility` (elevation-filtered `wall_occludes` feeding
  `segment_occluded`'s `segments_cross`) and `pan_for`/`falloff` are the ONE occlusion/geometry
  rule; a client never re-derives distance/occlusion — `AudibleEmitter.gain`/`.pan` are final.

## Gotchas

- `SoundEmission`'s (on `TokenEngine`/`ActorEngine`) resolution precedence is copied VERBATIM
  from `token_light_emission` — `scene::audibility` is its only consumer — so a light-emitter
  bug fix likely has a sound-emitter twin worth checking.
- `PlaylistTrack.loop_`/`AudibleEmitter.loop_` are Rust-side names; the wire field is `loop`
  (`#[serde(rename = "loop")]`) — a TS consumer reads `.loop`, not `.loop_`.
- `u32`/`f64` substitutions for `u64`/`i64` throughout this subsystem's wire-facing types
  (`shuffle_seed`, `startedAt`/`pausedAt`) are deliberate ts-rs bigint-drift avoidance, not an
  oversight — see `data::engine::table::RowRange`'s own doc for the class of bug this avoids.
- Web Audio requires a user gesture before `AudioContext.resume()` succeeds; `AudioEngine.unlock()`
  is the one call site that constructs the context, and anything that arrives before it
  (`applyState`/`applyAudibility`) is queued (`#pendingState`/`#pendingAudibility`), not dropped.

## Pointers

- **Generated API** — `/api/rust/shadowcat/data/engine/audio/`, `/api/rust/shadowcat/audio/`,
  `/api/rust/shadowcat/scene/audibility/`, `/api/ts/modules/_shadowcat_audio.html`. Produce with
  `pnpm build:all`.
- Rationale: `docs/design/ARCHITECTURE.md` §3/§4 (audio dependency choices, transcode pipeline).
- Relationships: `graphify query "audio playlist audibility emitter transport transcode"`.
- `shadowcat-codebase-scene-rendering` — `elevation::wall_occludes`/`segments_cross` (the
  occlusion primitives audibility composes rather than re-derives), `scene::emitters`
  (`token_light_emission`, the structural precedent for `token_sound_emission`).
- `shadowcat-codebase-documents-permissions` — `WriteOrigin`, `apply_intent`'s guard sites (the
  `audio-state` split-guard precedent), `cap::READ`/`ctx_access` (the audibility identity gate).
- `shadowcat-codebase-assets` — the transcode pipeline's place in `process_staged`'s dispatch,
  `AssetMeta`'s per-column (not JSON-blob) field convention.
