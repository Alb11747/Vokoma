# Vokoma — architecture proposal

Status: **accepted** (2026-11-14). The user left the design decisions in this document
to the project lead; they can still overrule any of them. Implementation starts with M0.
[PLAN.md](PLAN.md) is the requirements brief and stays the source of truth for what the
app must do; this document says how. Where the two disagree, PLAN.md wins until the user
changes it.

## 1. Summary of what I recommend

| Area | Recommendation |
|---|---|
| Playback engine | **libmpv** on Windows, Android, and later iOS/macOS. A separate `<video>`-based engine on web. |
| Client | **One Flutter app** for Windows, Android and web (iOS/macOS later), using `media_kit` as the libmpv binding. |
| Server | **One TypeScript (Node) codebase**, SQLite, run as three containers on the home server: `api`, `recorder`, `worker`. nginx serves the file bytes. |
| Sync | Local SQLite on each device plus an outbox of small, order-independent changes. WebSocket for live updates. |
| Sessions | Two automatic lanes (streams, anime) instead of named tabs. Opening the app follows the last thing paused anywhere. |
| Updates | Every green push to `main` becomes a `nightly` build; tags become `stable`. Velopack on Windows, self-installing APK on Android, image pull for server and web. |
| CI | GitHub-hosted runners (free for a public repo). The self-hosted runner is not used at first. |
| TwitchLiveDownloader v2 | Becomes the server's `recorder` container: streamlink does the download, Vokoma records the metadata v1 throws away. |
| TranscodeX | Replaced by a small archive job in the `worker` container (one ffmpeg pass, verify, swap). |
| Jellyfin / Plex | Not reused. Left running and untouched. |

## 2. What I checked against the real environment

- **Media disk:** 7.3 TB, 100% used, 9.3 GB free. System drive: 38 GB free.
- **Streams:** one channel folder, 253 `.ts`, 13 `.mkv`, 2 `.mp4`, 5.1 TB.
  Another 16 `.ts` recordings sit in TwitchLiveDownloader's fallback folder on the system
  drive. The library must index both.
- **The 0-byte parts** were caused by the full disk: each start failed the downloader's
  10 GB reserve check and was retried every 30 s. They have since been cleaned up, and
  **someone changed the deployed downloader today** (new `recordinglog.py`, container
  restarted 06:52 EST). I left it alone.
- **Timed ID3 track in the `.ts` files:** Twitch's own metadata. Each packet carries
  `ingest_r` (wall-clock time in ms) and `stream_offset` (seconds since the broadcast
  started). This is the reliable way to group split parts into one broadcast and to map
  a file position to a wall-clock time for chat, including across ad gaps. v1 ignores it.
- **Anime metadata:** the `.nfo` files are empty Jellyfin output (the folder name as the
  title, no IDs). They are no use for matching, so Vokoma needs its own parser.
- **Rustlog:** 37 channels, the recorded channel logged since 2023-10-01
  with gaps. Range queries work and are fast (10 minutes: 349 messages, 0.18 s). A whole
  day is 19 MB of JSON, so Vokoma should use range queries. An empty range returns 404.
- **PotPlayerChat:** Electron + Svelte. It aligns chat by the filename timestamp plus a
  manual offset and has no handling for split parts or gaps. Worth keeping: message
  search with jump, the user popup, "align chat to this message", link previews.
- **TranscodeX:** about 15k lines of backend plus 8k of web UI. It has finished 8 files
  since September; 267 are queued (5.5 TB). It encodes at about 0.23× real time and is
  currently blocked because it needs 61 GB of scratch space. Output is about 30% of the
  input size. The server has no AV1 hardware encoder (Intel UHD 750 only).
- **t3code:** pnpm monorepo, `AGENTS.md` with `CLAUDE.md` pointing at it, skills under
  `.agents/skills`, Conventional Commits, every push to `main` becomes a prerelease, and
  unsigned Windows builds. The self-hosted runner is hard-wired to one other
  repo and limited by memory, so Vokoma cannot use it without changes on the server.

## 3. Playback engine experiment

**Method.** One mpv Lua script ([tools/engine-bench/bench.lua](../tools/engine-bench/bench.lua))
ran inside mpv on each platform against the same real files, served from the home server over
HTTP with range requests. It measures how long each operation takes and checks that
every step lands exactly one frame away.

Files: HEVC 10-bit MKV with ASS subtitles and embedded fonts (keyframe gaps up to
10 s), H.264 High 10 MKV, AV1 anime MKV, a TranscodeX AV1 stream archive (1080p60,
10-bit), a short TwitchLiveDownloader `.ts` and a 16 GB one.

**Two ways to step backward.**
1. *Seek-based* (`frame-back-step`): mpv seeks to the previous keyframe and decodes
   forward to the target. Always exact; cost grows with the distance from the keyframe.
2. *Reverse mode* (`play-direction=backward`, then step): mpv decodes a whole
   keyframe-to-keyframe group once and keeps the frames. Entering costs one group's
   decode; every step after that is nearly instant.

**Results** (median / 90th percentile, in ms).

Windows (the desktop PC: Ryzen 5 5600, Radeon RX 6700 XT, mpv 0.42, GPU decoding unless
noted, local disk; it is on the same LAN as the server):

| File | Seek-based back step | Reverse-mode step | Forward step | Far exact seek | ±5 s exact seek |
|---|---|---|---|---|---|
| HEVC 10-bit MKV | 74 / 177 | 42 / 50 (after ~1 s to enter) | 42 / 47 | 118 / 692 | ~325 / ~530 |
| HEVC 10-bit MKV, CPU decoding | 283 / 659 | 42 / 51 | 42 / 49 | 374 / 727 | ~690 / ~1500 |
| H.264 High 10 (always CPU) | 515 / 755 | 41 / 50 (after ~2 s) | 44 / 50 | 431 / 1276 | ~540 / ~900 |
| AV1 anime | 87 / 109 | 42 / 48 | 42 / 50 | 201 / 291 | ~130 / ~260 |
| AV1 stream archive | 329 / 359 | 34 / 49, **not exact** | 16 / 31 | 258 / 338 | 160 / 161 |
| `.ts` (short) | 21 / 48 | 17 / 35 (after ~1.8 s) | 16 / 33 | 27 / 37 | 18 / 23 |
| `.ts` (16 GB, over HTTP) | 67 / 124 | 17 / 35 (after ~2.7 s) | 16 / 22 | 106 / 145 | ~125 / ~150 |

Over HTTP from the server the HEVC file's back step was unchanged (75 / 177) and far exact
seeks rose to 175 / 596. Showing ASS subtitles made no measurable difference. A separate
check stepped back ten times through mpv's control pipe: each step moved exactly one
frame and consecutive screenshots differed.

Android emulator (x86_64, Android 15, 4 cores, software rendering and CPU decoding —
slower than a real phone, and it has no HEVC 10-bit or AV1 hardware decoder):

| File | Seek-based back step | Reverse-mode step | Forward step | Far exact seek |
|---|---|---|---|---|
| HEVC 10-bit MKV | 375 / 544 | 45 / 80 (after 1–8 s to enter) | 47 / 84 | 801 / 1399 |
| AV1 anime | 350 / 474 | 47 / 82 (after ~1 s) | 51 / 77 | 987 / 1223 |
| AV1 stream archive | 623 / 1033 | 7 / 63 (after ~3 s) | 19 / 98 | 1277 / 1445 |
| `.ts` (short) | 654 / 2652 | 14 / 50 (after ~5 s) | 8 / 68 | 1481 / 2108 |

**What the numbers say.**
- **Seek-based back step was exact in every run on every platform** and is fast with
  GPU decoding: 20–90 ms for most files, about 330 ms for the 60 fps AV1 archives (their
  keyframes are 5 s apart), and about 500 ms for H.264 High 10, which no GPU decodes.
- **Reverse mode is fast but not dependable.** Three separate failures:
  - With default settings it skipped frames across long keyframe gaps (HEVC) and broke
    badly on 60 fps AV1 with GPU frames (320 of 360 steps wrong). It was exact only with
    frames copied to system memory and a 2 GB buffer, at about 2 GB of RAM.
  - It never starts when the active audio track is FLAC (over HTTP on Windows, always on
    Android). It works with another track or with audio off.
  - Entering it costs 0.5–8 s.
- **Exact seeks in `.ts` files land on the next keyframe**, up to 2 s late (a seek to
  30.123 s lands at 32.016 s). Frame stepping in `.ts` is unaffected. mpv has a setting
  for this container limitation (`hr-seek-demuxer-offset`); M0 confirms it fixes it.
- **Hardware-decoded `.ts` froze during long seeks on the Android emulator.** This may
  be the emulator's decoder and not Android's. It must be retested on the real phone.
- **The emulator cannot say how the real phone performs.** AV1 at 1080p60 10-bit
  without a hardware decoder is the main worry; see "portable renditions" in section 8.

**Decision.** libmpv. It is the only engine that plays every file in the library
unmodified (HEVC 10-bit, H.264 High 10, AV1, ASS with embedded fonts, PGS, MKV/TS/MP4),
steps backward exactly, and offers high-quality speed change, loudness filters and
optional upscaling shaders. Platform players (ExoPlayer, Media Foundation) fail on ASS
and backward stepping; VLC cannot step backward.

**Back-step behaviour in the app.** `,` always uses the seek-based step. Holding the
key repeats it, which gives roughly 3 to 40 frames per second backward depending on the
file. Reverse mode is left out of the first version; it can be added later for holding
`,`, limited to the configuration that tested exact and with audio switched off.

## 4. Client stack

**One Flutter app** with `media_kit` (a maintained Dart binding that embeds libmpv and
gives the app the raw mpv handle for commands and properties).

Why Flutter and not a web UI wrapped around mpv (Tauri or Electron on desktop, a WebView
on Android):
- The video is one more layer in the app's own renderer. A web UI needs a transparent
  browser layer stacked on a native video window, which is a different hack on every
  platform.
- One language for all client logic on five platforms. The web-UI route needs
  TypeScript plus Rust plus Kotlin (plus Swift later) with a message bridge between the
  UI and the engine.
- Touch feel on a mid-range phone is better than a WebView's.
- The same app category already ships this way (Fladder, Kazumi, PiliPlus: anime and
  Jellyfin players on Windows, Android and iOS with libmpv).

What it costs:
- PotPlayerChat's Svelte code cannot be reused; chat is rewritten in Dart, keeping its
  design.
- Flutter web is heavier than a hand-written web app. The login page is plain HTML so
  password managers work.
- `media_kit`'s bundled libmpv is old on Windows (March 2025). Vokoma pins its own
  libmpv builds.

**Fallback if M0 fails:** a web UI (TypeScript) over libmpv, with Tauri on Windows and a
Kotlin shell on Android. The server, protocol and data model do not change.

**Engine boundary.** All playback goes through one `PlayerEngine` interface (open,
seek, step, speed, tracks, filters, events). Two implementations: `MpvEngine` (native)
and `WebEngine` (browser).

**Web engine, first version.** `<video>` fed by the server: the video stream is copied
when the browser can decode it (H.264, AV1, HEVC where the browser supports it) and
transcoded with Intel QuickSync when it cannot (H.264 High 10 always). Audio becomes AAC
when needed. ASS subtitles render with JASSUB (libass compiled for browsers) using the
file's own fonts. Frame stepping is approximate. Full parity stays the TODO in PLAN.md;
the likely route is a WebCodecs engine behind the same interface.

**Native pieces per platform** (small, kept beside the Flutter runner):
- Windows: global hotkeys, PiP window mode, updater hooks.
- Android: system PiP, background downloads, SD-card storage, APK self-update.

## 5. Repo layout

```
apps/client/            Flutter app
  lib/engine/           PlayerEngine, MpvEngine, WebEngine
  lib/features/         library, player, chat, bookmarks, downloads, settings
  lib/sync/             local database, outbox, WebSocket
  windows/ android/ web/  runners and native code
server/                 TypeScript server (api, recorder, worker entry points)
  src/library/          scanning, filename parsing, AniList matching
  src/media/            probing, thumbnails, loudness, renditions
  src/streams/          broadcasts, parts, chapters, chat, heatmap
  src/recorder/         TwitchLiveDownloader v2
  src/archive/          AV1 archiving (TranscodeX replacement)
  src/lifecycle/        recycle bin, TTL, qBittorrent
  src/sync/             sessions, watch ranges, bookmarks, settings
contracts/              OpenAPI document generated from the server; Dart client generated from it
tools/                  engine-bench, PotPlayer bookmark importer
deploy/                 compose file and nginx config for the home server
docs/                   PLAN.md, ARCHITECTURE.md, decisions/
.agents/skills/         agent skills (CLAUDE.md points at AGENTS.md)
.github/workflows/
```

## 6. Server

**Stack.** Node with TypeScript, Fastify, SQLite in WAL mode, zod schemas that also
generate the OpenAPI contract. ffmpeg (a QuickSync-capable build) and streamlink are in
the image.

**Why TypeScript.** The server is glue: HTTP, SQLite, ffmpeg and streamlink
subprocesses, and four external APIs. TypeScript is where the implementing agents are
most reliable, matches the t3code tooling, and keeps build caches small (a Rust server
would cost several GB of cache on a drive with 38 GB free).

**Three containers from one image**, so an update never interrupts long work:
- `api` — HTTP, WebSocket, scanning, short jobs. Restarts for updates only when nothing
  is playing.
- `recorder` — live recording. Updates only when no channel is live.
- `worker` — archive encodes and other long jobs. Updates only between files.

**File serving.** The API authorizes a request and hands the transfer to nginx
(`X-Accel-Redirect`), so file bytes never pass through Node. Range requests work as they
do today.

**Access.**
- One account, password stored as an argon2id hash, login rate-limited.
- Each device gets its own revocable token, kept in the OS keystore. Credentials are
  sent in headers and never placed in URLs or playlists.
- Public address behind the existing nginx and certificate. After login the client
  learns the LAN address, checks that the same server answers there, and uses it for
  file bytes when reachable.

**Storage.** Database, thumbnails, chat cache and renditions live on the system drive
under one data folder with a size cap per kind. Nothing but media is written to the
media disk.

### Data model (main tables)

| Table | Holds |
|---|---|
| `library_root` | A folder and its kind: anime, stream, movie, TV |
| `media_file` | Path, size, fingerprint, probe result (tracks, chapters, keyframes, loudness), state: present / in recycle bin / deleted |
| `series`, `season` | Parsed and matched anime, movies and TV, with AniList and MAL IDs |
| `channel` | Twitch login and ID |
| `item` | One playable thing: an episode, a movie, or a whole broadcast. Kept after its files are deleted, which is the watched log PLAN.md asks for |
| `item_part` | The files that make up an item, in order, with each part's offset and wall-clock start. A `.ts` and its AV1 archive are the same part |
| `chapter` | Embedded chapters for anime; Twitch title and category changes for broadcasts |
| `watch_range` | Merged watched intervals per item, each marked played or skimmed |
| `item_state` | Resume position, watched flag and how it was set (automatic or manual) |
| `series_pref` | Remembered audio language, and the subtitle choice for each audio language |
| `bookmark`, `bookmark_folder` | Timestamp, name and folder |
| `lane`, `device` | Session lanes and registered devices |
| `download` | What each device holds offline, so deletions reach every copy |
| `setting` | Synced settings, with per-device overrides |
| `job` | Queue for probing, thumbnails, archiving and purging |

Track preferences are stored as a description (language, and whether the track is
full dialogue, signs and songs, or commentary), not as a track number, because track
order differs between files and release groups.

### Library parsing

- **Anime:** an anitomy-style parser for the release folders and file names actually on
  disk (season folders, OVAs, specials, extras), then an AniList search to match. A
  wrong match can be corrected by hand and the correction is remembered.
- **Streams:** v1 files are grouped into broadcasts using the ID3 track, falling back to
  channel, title and a filename gap under 10 minutes. v2 recordings arrive already
  grouped.
- **Opening and ending:** chapter names are classified by a small rule list (OP,
  Opening, ED, Ending, Credits, Intro, Outro and similar, case-insensitive). When names
  are unhelpful ("Chapter 1"), a chapter 80–100 s long near the start or end counts as
  opening or ending. Only embedded chapter data is used.

## 7. Sync and sessions

**Sync.** Each device keeps a local SQLite copy of what it needs and an outbox of
changes made offline. Every change is designed so that order does not matter:
- watched ranges are merged by union;
- resume position, bookmarks, preferences and settings keep the newest write.

The server numbers each change; a device asks for "everything after number N". A
WebSocket pushes changes while the app is open. No conflict dialogs are needed.

**Position saving.** Locally every 5 s and on pause, seek and backgrounding. Uploaded on
pause, after a seek settles, when the app goes to the background, and every 30 s while
playing.

**Sessions: two lanes.** Named tabs are more than one person needs, and plain
"follow the last thing paused" makes the PC and the phone fight when one has a stream
and the other anime. Instead:
- There are two lanes: **Streams** and **Anime** (movies and TV share the anime lane).
  Each lane remembers its current item and position.
- On opening, the app opens the lane that was paused most recently on any device,
  paused at that position. Back goes to the home screen.
- The home screen's first row shows both lanes, so the other one is one tap away.
- A per-device setting chooses what opening does: follow the last pause anywhere
  (default), resume this device's own last item, or show the home screen.

## 8. Decisions PLAN.md left to me

**Hotkey defaults.**

| Key | Action |
|---|---|
| `←` / `→` | 5 s |
| `Shift` + arrows | 30 s |
| `Ctrl` + arrows | 90 s (about one opening) |
| `Alt` + arrows | 1 s |
| `[` / `]` | Speed −/+ 0.1, range 0.25×–4× |
| `/` | Normal speed ↔ previous speed |
| `Shift+M` and `Ctrl+M` | Mute (plain `M` does nothing) |
| `A` | Toggle English ↔ Japanese audio, with the remembered subtitle choice |
| `Shift+A` | Cycle through all audio tracks |
| `B` | Add a bookmark |
| `Shift+PgUp` / `Shift+PgDn` | Previous / next section (chapters and bookmarks together) |

Touch: double-tap seeks 10 s, hold plays at 2×. All of these are settings.

**Global numpad keys.** A low-level keyboard hook that matches physical scan codes, so
NumLock no longer matters, and that only swallows the keys while a video is open. Keys
pressed while an administrator window has focus need a small helper running elevated;
that is optional. The four hypotheses in PLAN.md are tested on Windows in M1 before the
design is fixed.

**Watched rules.**
- Anime, movies, TV: watched at **80%** of the duration (skipping the opening, ending
  and preview leaves about 85%).
- Streams: watched when no gap longer than **60 s** remains and gaps total under
  **3 minutes**, after the ignore-start and ignore-end windows.
- Skimming: a forward jump of **45 s or less** marks the skipped part as skimmed, which
  counts as watched and is drawn slightly differently on the timeline. A longer jump
  leaves a gap.

**Recycle-bin TTL by free space on the media disk.**

| Free space | TTL |
|---|---|
| 15% or more (about 1.1 TB) | 60 days |
| 5–15% | 7 days |
| Under 5% (about 365 GB) | 1 day |

The recycle bin is a folder on the media disk, so moving a file there is instant.

**Thumbnails.** The server builds sprite sheets (160×90; one frame per 10 s for streams,
per 5 s for other video) from keyframes only, which is cheap. They are built when an
item is first opened or queued for download, capped at 10 GB with oldest-unused
eviction, and downloaded with offline copies so the seek bar works offline.

**Loudness.** The server measures each audio track once (EBU R128). The client applies
a fixed gain towards −16 LUFS with a peak limiter. A fixed gain does not pump or change
dynamics. An optional "night mode" adds compression for quiet dialogue.

**Auto speed (streams).** Two signals at first, both computed on the server: speech and
silence from the loudness pass, and chat rate against the stream's own rolling
baseline. Dead air speeds up towards the maximum; a chat spike slows playback to normal
starting about 15 s before the spike, because chat reacts late. Changes are smoothed and
bounded by the user's minimum and maximum.

**Offline downloads (phone).**
- Candidates: the next 3 unwatched episodes of series in progress, and the current and
  next unwatched broadcast.
- The app asks once per series or channel and remembers the answer. A storage budget and
  the storage location (internal or SD card) are settings.
- **Portable renditions:** a 6-hour stream is 17 GB as `.ts`, and its AV1 archive may
  not play smoothly on a phone without AV1 hardware decoding. For stream downloads the
  server makes an HEVC copy with QuickSync (fast on the server's CPU graphics). The same
  code feeds the web player.

**Windows PiP.** The main window switches to a small, borderless, always-on-top mode
with adjustable opacity that lets clicks pass through. Holding a modifier (default
`Ctrl+Alt`) makes it solid so it can be dragged and resized. No chat in PiP.

**Bookmarks.** Two fixed top-level folders, Anime and Streams, filled automatically by
media kind, with user subfolders beneath. Bookmarks show as markers on the timeline and
in a panel. Thumbnails are generated by the server on demand. The PotPlayer import is a
one-time tool that reads the `.reg` backups and maps `E:\Media\…` paths onto the
library.

**Chat.** The server fetches from Rustlog by range, caches each finished broadcast as a
compressed file, resolves emotes and badges (Twitch, 7TV, BTTV, FFZ) and proxies the
images, so Twitch keys stay on the server and chat can be downloaded for offline use.
The heatmap is the message count per 5 s. As in PotPlayerChat, emotes are today's sets,
not the sets at the time of the stream.

## 9. Updates, CI and releases

**Cadence.** Every push to `main` that passes checks becomes a `nightly` build, with
pushes inside a 30-minute window batched into one. A `vX.Y.Z` tag becomes `stable`.
Each device picks a channel; the default is `nightly`.

| Platform | How it updates |
|---|---|
| Windows | Velopack: per-user install, background download, signature check, versions installed side by side so rollback is possible |
| Android | The app downloads the APK from GitHub Releases and installs it with Android's package installer. Silent on Android 12+ after one approval |
| Server and web | Docker image on GHCR. The server pulls the channel tag; each container restarts only when idle |
| iOS / macOS (later) | macOS through Velopack. iOS cannot self-update outside TestFlight or the App Store |

The user setting from PLAN.md applies on every platform: install on the next restart, or
install when idle and never during playback.

**M0 release decisions.** Main releases use a cancellable 30-minute debounce and
one rolling prerelease named `nightly`, bounding stored release assets. Stable is
`vX.Y.Z`; nightly uses the next patch after the highest stable tag (initial base
0.1.0). Android versionCode is the shared release workflow run number plus one;
Windows uses `X.Y.Z.build` so Velopack compares successive builds numerically.
Stable display/versionName is X.Y.Z, with the same increasing build code.
Ed25519 signs the exact `update.json` bytes; that manifest binds channel, version,
package filename, byte length and SHA-256. Its detached signature is verified with
the compiled public key, and package hashes are checked again before install.
The signing private key is a CI secret. Velopack 1.2.161 checks package size and
SHA-256 (SHA-1 fallback), not a signature under our key; the manifest supplies
publisher authentication. No delta packages in M0. The Windows launcher disables
Velopack's automatic startup apply so only authenticated packages are applied.
A complete player session (even paused) blocks installation; idle means no player
and no pointer interaction for a minute. Pending updates apply at the next launch
for restart policy. Channel changes do not downgrade; stable may require waiting
for a version newer than the installed nightly. Server updates are manual pulls
and restarts in M0; no server self-updater is included.

**CI.** GitHub-hosted runners: Linux for the server, web and Android; Windows for the
Windows build. Checks on pull requests are filtered by path. Release signing keys
(Android keystore, update-signing key) are GitHub secrets, which pull requests from
forks cannot read.

**Limits.**
- Windows builds are unsigned, so SmartScreen warns on the first install. Updates are
  not affected.
- Android cannot downgrade, so a bad nightly there is fixed by a newer build.

## 10. TwitchLiveDownloader v2

v2 is the `recorder` container.
- **Download:** streamlink as a subprocess, because it already handles Twitch's
  playlists, tokens and ads. v1's reconnect merging and low-disk fallback are kept in
  simpler form.
- **Output:** the same folders and file names as v1, so existing tools keep working.
- **New metadata, saved in the database and in a small JSON file beside each
  recording:** Twitch stream ID, start and end, part boundaries, every title and
  category change with its time (these become chapters even if no VOD is ever
  published), and the VOD ID and VOD chapters once they exist.
- **Existing v1 recordings** get chapters from Twitch when the VOD still exists, and
  none otherwise.
- **Cut-over:** recording must never stop. v2 first records the same broadcasts as v1
  into a separate folder. It replaces v1 only after its files match v1's for several
  broadcasts, and v1 stays installed, stopped, as a fallback. The existing
  v2 repo is scrapped apart from its table design.

## 11. TranscodeX rebuild

A job in the `worker` container, a few hundred lines:
1. Pick the oldest `.ts` older than a set age with no archive beside it.
2. One ffmpeg pass to `name.mkv.part` next to the source (SVT-AV1, 10-bit, audio
   copied), so no scratch space is needed.
3. Verify: duration, stream count and frame count match, and the output decodes without
   errors.
4. Rename into place, move the `.ts` to the recycle bin, and record the result. The
   position-to-wall-clock map from the ID3 track is kept in the database and the JSON
   file, so chat still lines up.

Dropped: the cluster and remote workers, its own web UI and login, segment checkpoints,
journals, repair, VMAF.

**Speed is the open issue.** At today's 0.23× real time the backlog (about 1,750 hours
of video) would take close to a year. Before building, benchmark a faster preset and
more threads. The Windows PC's graphics card (RX 6700 XT) cannot encode AV1, so there is no
GPU shortcut on either machine. If the benchmark cannot reach a useful speed, the
alternatives are a second CPU worker on the Windows PC or archiving to HEVC with QuickSync
(many times faster, larger files); that would be a decision for the user.

## 12. Jellyfin and Plex

**Not reused.**
- Their metadata for this library is empty (section 2).
- Watch ranges, broadcasts with parts, chat, per-series track memory, lanes and
  auto-delete all fall outside their data models, so Vokoma would need its own database
  anyway, and theirs would become a second copy to keep in agreement.
- The server-side transcoding Vokoma needs is one ffmpeg command.

They stay running and are not touched. Retiring them later is the user's decision. The
Streams folder is **not** moved, so their libraries, Samba and WebDAV keep working.

## 13. Risks

| Risk | Mitigation |
|---|---|
| `media_kit` falls behind or blocks an mpv feature | Own pinned libmpv builds; M0 is a go/no-go; fallback stack named in section 4 |
| Real phone decodes worse than hoped (AV1, `.ts` hardware decoding) | Test on the phone in M0; portable renditions |
| mpv reverse mode is unreliable | Not used in the first version; seek-based stepping is exact |
| Exact seeks in `.ts` land late | mpv demuxer-offset setting, confirmed in M0 |
| Media disk is full now | Not solved until archiving and auto-delete run. The archive job is scheduled early and nothing is deleted without approval |
| System drive space | Size caps on thumbnails, chat cache and renditions; toolchains kept in one capped folder |
| Unsigned builds, Android one-time approval | Accepted for a single user |
| Twitch changes break recording or chapters | streamlink carries most of it; chapters degrade to none, recording keeps working |
| Public repo leaks details of the home server | No hostnames, addresses or paths in code; see question 1 |
| Agent-built scope creep | One milestone at a time, each ending in a build the user runs; Opus review before merge |

## 14. Milestones

Each milestone ends with an installed, auto-updated build.

| | Milestone | Contents |
|---|---|---|
| M0 | Foundations and engine gate | Repo, CI, `AGENTS.md`. Server with login, scan and file serving. Client that plays the sample files on Windows and the real phone with stepping and seeking. Auto-update working on both. Benchmark repeated inside the app on the phone. **Go/no-go on the engine.** |
| M1 | Player | All hotkeys including global numpad, speed, tracks and per-series memory, chapters and opening/ending skip, loudness, zoom and crop, resume, lanes, watch ranges, thumbnails |
| M2 | Library | Anime parser and AniList sync, broadcasts from parts, home screen (from mockups with the user), bookmarks and PotPlayer import, manual watched |
| M3 | Chat | Rustlog, emotes and badges, heatmap, phone layouts |
| M4 | Phone | Offline downloads and SD card, portable renditions, system PiP, touch controls |
| M5 | Storage | Recycle bin and TTL, season delete with qBittorrent, removal of device copies |
| M6 | Recorder | TwitchLiveDownloader v2, chapters, cut-over from v1 |
| M7 | Web and extras | Web player, Windows PiP, auto speed |

**Parallel server track:** the archive job (section 11) does not depend on the client
and can start right after M0, because it is what frees the disk.

## 15. Decisions and open questions

Settled on 2026-11-14:
- **Public docs:** host names, addresses, paths and the phone model were removed from
  PLAN.md and this file and kept in a private note outside Git.
- **Where v2 lives:** in this repo, as the `recorder` container (section 10), not as a
  branch of the TwitchLiveDownloader repo. The condition is that recording never stops:
  v1 keeps running unchanged until v2 has recorded the same broadcasts beside it without
  loss, and v1 stays installed as a fallback after the cut-over.

- **TranscodeX:** replaced later by the archive job in section 11. Until then the
  existing TranscodeX is kept running and tuned through its settings only (less scratch
  space, faster preset if the size cost is small). The user approved this.
