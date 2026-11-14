# Vokoma — requirements brief

Status: requirements gathering, round 2 (2026-11-14). This is the brief for the
Fable-led project. It records what the user stated and what was observed in their
environment. It makes no design decisions: anything not stated is under "Left to Fable"
or "Open questions".

## Process

- **Stack and architecture:** Fable proposes, the user approves.
- **Roles:** Fable designs and supervises; Opus and Sol implement.
- **Review:** an Opus review agent reviews code for now. When `gpt-6.2-sol` is released,
  Sol 6.2 reviews code, including a retroactive review of earlier work.
- **Repo:** public GitHub. Releases come from GitHub Releases. Agent and CI infrastructure
  modelled on t3code. A self-hosted GitHub Actions runner already runs on the
  home server.
- **Name:** **Vokoma** (VOD + コマ *koma*, "frame"). No GitHub repo with this exact name was
  found on 2026-11-14; app stores and trademarks were not checked.

## Environment observed (2026-11-14)

Host names, addresses and paths are kept out of this public file; see the private notes
beside the repo.

- **Server:** one home Linux server. Media is on one disk in two folders:
  `Torrents` (anime/movies, 2.1 TB) and `Streams` (5.1 TB). **The disk is at 100%:
  10 GB free of 7.3 TB.**
- **Services already running there:** Jellyfin, Plex, qBittorrent (behind a VPN
  container), Rustlog with ClickHouse, nginx, Samba with a recycle-bin pruner,
  TwitchLiveDownloader (v1), TranscodeX (AV1 archiving).
- **Rustlog** is served at a public address, which PotPlayerChat already
  points at. It logs many channels.
- **Anime files** (about 3,950 MKVs):
  - Video: mostly HEVC 10-bit; also H.264 and AV1.
  - Audio: often dual (Japanese and English). Some files add an "English Commentary" track.
  - Subtitles: ASS with embedded fonts (7–29 attachments), or PGS. Usually both a
    "Full/Dialogue" track and a "Signs & Songs" track.
  - Chapters: typically 6–8. Chapter names vary by release group, so opening/ending
    detection cannot rely on one naming scheme.
  - Keyframes: irregular, gaps of up to about 10 s.
  - Layout: release-group folders with seasons, OVAs, specials and extras. Most folders
    have `.nfo` files (2,592), so Jellyfin/Sonarr-style metadata already exists.
- **Stream files:** channel folders, named
  `[ISO-timestamp] channel - title.ext`.
  - Containers: `.ts` (633), plus `.mkv` (13) and `.mp4` (2). The `.mkv` files are
    probably TranscodeX AV1 archives.
  - Each recording has H.264 1080p60 video, AAC audio and a timed ID3 data track.
    Keyframes every 2 s.
  - Image sidecars (jpeg/png) sit next to the recordings.
  - **TwitchLiveDownloader is producing many 0-byte `.ts` parts about 30 s apart**
    (e.g. 2026-11-10). This is probably related to the full disk.
- **PotPlayer bookmarks** are stored in the registry (`BMList` plus `BMItem_*`; position in
  ms, a name and a JPEG thumbnail). Backups exist as `.reg` exports.
  - The Laptop profile holds anime bookmarks (`E:\Media\Torrents`).
  - The PC profiles hold stream bookmarks (`E:\Media\Streams`).
  - The user does **not** want to keep this per-device split. Both kinds of bookmarks must be
  usable on every device, organized with something like bookmark folders (Fable chooses).
- **Secrets in plaintext:** backed-up PotPlayer playlists (`.dpl`) have WebDAV credentials
  embedded in their URLs. The new app must not repeat this pattern.

## Current hotkeys (from PotPlayer `MainShortCutList` and PowerToys Keyboard Manager)

PotPlayer stores each binding as `VK,modifiers,command,global`, with modifiers
1 = Shift, 2 = Ctrl, 4 = Alt. Some command meanings below are inferred from the key and
need confirmation (question 8).

| Key | Action | Notes |
|---|---|---|
| `/` | Normal speed; press again to return to the previous speed | `PrevSpeed` is currently 1.8× |
| `[` / `]` | Slower / faster | |
| `,` / `.` | Previous / next frame | |
| `←` / `→` | Seek back / forward | The user wants Shift, Alt and Ctrl to change the jump size |
| `F` | Fullscreen (inferred) | |
| `Alt+M` | Mute | The user wants `Shift+M` or `Ctrl+M`. Plain `M` is deliberately unbound |
| `Shift+PgUp` / `Shift+PgDn` | Probably previous / next chapter | |
| `Ctrl+W` | Close | |
| Numpad 1 / 2 / 3 (global) | Seek back / play-pause / seek forward | Registered both bare and with Alt |
| Numpad 4 / 5 / 6 (global) | Slower / normal speed / faster | Registered both bare and with Alt |
| Numpad 0, Backspace, `Q`, `Ctrl+S`, `Esc`, `'`, `M` | Deliberately unbound | |
| Laptop only: `Ctrl+R`, `Alt+R`, `Alt+T`, `Alt+Y`, `Alt+,`, `Alt+.` | Unknown commands | |

PowerToys Keyboard Manager remaps:
- Numpad 1–6 send Alt plus the same numpad key. This is the modifier workaround.
- Numpad 7 and 9 send media previous/next track.
- Caps Lock sends F13.
- The Copilot key (Win+Shift+F23) sends `/`.

**Why bare global numpad keys sometimes failed.** These are hypotheses for Fable to
verify; none is confirmed:
1. NumLock state changes the virtual key the numpad sends (off sends Home/End/arrows).
2. UIPI: a non-elevated hook or hotkey misses keys while an elevated window has focus.
3. Fullscreen games using raw input.
4. Conflicts with other apps' `RegisterHotKey` registrations.

The Alt workaround also overlaps Windows Alt-codes (Alt+numpad digits). The goal is to
make bare numpad global hotkeys work reliably.

## Locked requirements

### Platforms, access and updates
- Windows, Android phone (no tablet, no TV) and web now. iOS and Mac later; the stack must
  not rule them out.
- Single user, with **one normal username/password account** (works with password
  managers).
- Web access over the public internet with login. When on the LAN, the app uses the LAN
  path for speed.
- **Web:** for now, a full player that accepts browser limits. TODO: full parity with
  desktop, using server transcoding if needed.
- **Auto-update:** in-app on every platform. Fable decides whether every push to main
  becomes an update, or only tagged versions. Silent install, either applied on the next
  restart or never during playback. Which of the two is a user setting.
- New server. PotPlayerSync is not reused.

### Library
- **Media lives only on the server.** Clients cache locally. To add local files, the user
  uploads them to the server.
- **Primary types:** anime and Twitch stream recordings. **Secondary:** movies and TV,
  which follow the anime rules.
- **Streams:** support TwitchLiveDownloader v1 output and a new v2. The current v2 code can
  be scrapped. Split parts of one broadcast are combined.
- **Anime metadata and progress:** AniList/MAL progress sync, and series metadata.
  Library parsing should be based on the actual files described above.
- **Audio/subtitle defaults:** remember tracks per series.
  - Default audio: English (never a commentary track).
  - Default subtitles: English Signs & Songs.
  - **`A` or `Shift+A` toggles audio between English and Japanese.** If the user has
    manually chosen a different subtitle track for a language (e.g. full subtitles with
    Japanese audio), the toggle switches to that remembered choice instead of the default.
- **Jellyfin and Plex** (already running): whether to ignore, reuse or replace them is left
  to Fable.
- **TranscodeX:** Fable may rebuild its AV1 archiving, possibly inside the new project. The
  user considers the current TranscodeX overengineered.

### Player
- YouTube-like main interface. **No previous/next-video buttons near the centre.** The
  home screen is left to the user's mockups with Fable.
- **Tap and hold:** YouTube-style tap controls and the same speed controls as YouTube.
  Hold for faster speed (touch): 2× by default, configurable.
- **Mouse click on desktop does nothing.** Desktop has no hold-for-speed; the user uses `/`.
- **Desktop hotkeys:**
  - Arrow keys seek; Shift, Alt and Ctrl change the jump size. Jump sizes, double-tap seek
    size, the speed step and the maximum speed are configurable, with defaults chosen by
    Fable.
  - `,` / `.` previous / next frame.
  - `[` / `]` speed down / up.
  - `/` toggles between normal and the previous speed.
  - `Shift+M` and/or `Ctrl+M` mutes (Fable chooses). Plain `M` does not.
  - Keep `F` (fullscreen) and `Shift+PgUp` / `Shift+PgDn` (previous / next chapter). The
    other Laptop-only PotPlayer bindings can be dropped.
  - **Number keys must not jump around the timeline** the way YouTube's do.
  - Global numpad hotkeys as in the current setup, made reliable.
- **Previous/next section:** before the first marker, "previous" goes to the start of the
  video; after the last marker, "next" goes to the end. No wrap-around.
- **Opening/ending skipping** uses only chapter data embedded in the file.
- **Stream chapters** come from Twitch VOD chapter data.
- **Auto speed:** streams only, with a YouTube-style toggle. Signals and algorithm are left
  to Fable.
- **Frame step** forward and backward, reliable on every codec and container in use
  (HEVC 10-bit, H.264, AV1; MKV, TS, MP4).
- **Seeking:** optimized for latency.
- **Seek-bar thumbnails:** should also work on offline downloads where possible.
- **Loudness normalization:** applied at playback time with good client-side settings.
  Files are never modified. The settings themselves are left to Fable.
- **Zoom and crop:** pinch zoom with a high activation threshold, mainly for small text.
  Crop goes in the overflow (⋮) menu. No swipe gestures for brightness or volume.
- **Picture-in-picture:**
  - Android: system PiP.
  - Windows (ideal): a transparent, click-through window, dragged and resized while
    holding a modifier key. Fable may propose the details.
  - Chat in PiP: probably not; at most a setting.
- **Tentative:** upscaling. **Not needed:** HDR, A–B loop, screenshots, clip export.

### Chat
- Side chat panel synced to playback, based on PotPlayerChat (emotes, badges and so on),
  sourced from Rustlog.
- If Rustlog has no logs for a recording, show no chat.
- **Mobile:** below the video in portrait, like YouTube live chat. A side panel in
  landscape, which can be hidden.
- **Heatmap:** chat activity only, styled like YouTube's "most replayed" graph.
- **Watched ranges** on the timeline: watched parts brighter, unwatched parts greyish.

### Watch tracking
- Record exactly which parts were watched (bilibili-style).
- **Streams:** marked watched only when no significant part was missed.
  - Skimming (short forward seeks or clicks close together on the timeline) counts as
    watched.
  - "Ignore start" setting: if everything except the first 15 minutes (configurable) was
    watched, the stream counts as watched.
  - "Ignore end" setting works the same way for the end.
- **Anime, movies and TV:** watched once X% of the video has been watched (Fable picks X).
- **Playback speed never affects whether a part counts as watched.**
- The user can mark a video watched (and presumably unwatched) manually.

### Auto-delete
- **Streams only.**
  - Watched streams go to a recycle bin.
  - The TTL depends on free storage: 60 days, 7 days or 1 day. Fable sets the free-space
    thresholds.
  - Rewatching does not restart the TTL.
  - Deletion removes the server file and every device's offline copy.
  - A phone's offline copy is deleted 24 hours after the video is watched, or
    immediately if the phone needs the storage.
- **Anime:** when a season is watched, recommend deleting it. Accepting deletes the files
  and the corresponding qBittorrent torrent.
- **Existing streams (5.1 TB):** the user has not watched them yet, so they start as
  unwatched. Bookmarks usually mark streams the user intends to watch; import the
  PotPlayer bookmarks and use those videos. The new project may move the Streams folder,
  provided it updates everything that uses it: TwitchLiveDownloader, Samba/WebDAV, and
  the Jellyfin/Plex libraries.
  Streams without a bookmark are treated the same as bookmarked ones: unwatched, kept and
  shown in the library.
- **Bookmarks** are deleted with their video and do not protect it.
- A cheap watched log (enough to know what was watched) is kept after the file is gone.

### Bookmarks
- Bookmarks are timestamps inside a video (PotPlayer-style), synced across devices.
- Anime and stream bookmarks are kept separate, the way they are now separated by the
  Laptop and PC PotPlayer profiles.
- One-time manual import of the existing PotPlayer bookmarks from the `.reg` backups.
- Everything else about bookmarks is left to Fable.

### Resume and sessions
- Frequent local position saves. Pausing uploads the position to the server.
- Opening the app on another device automatically opens the same media, **paused at the
  correct place**. To watch something else, the user goes back.
- **Multiple devices:** either every device follows the last thing paused, or named
  sessions/tabs. Possibly the user can switch between the two modes. Fable may change this
  or propose something better.

### Offline
- **Phone:** a mid-range 2022 Android phone, to be replaced by a better phone
  later. It most likely lacks AV1 hardware decoding (unverified), so AV1 files may
  fall back to software decoding there. Don't tune the design to this phone. Offline storage
  must support the phone's **SD card** as well as internal storage.
- The phone downloads likely-next videos on Wi-Fi, using the LAN path when on the home
  network. (USB was dropped.)
- What gets downloaded is left to Fable, but configurable, and probably asks when a
  download is offered.

## Left to Fable
- Stack, engine, repo layout and server design.
- Sync protocol and the session model (within the options above).
- Thumbnail pipeline.
- Auto-speed signals.
- Skim-detection thresholds.
- Loudness settings.
- Offline prediction.
- PiP mechanics.
- Bookmark UI and folders.
- Jellyfin/Plex reuse.
- TranscodeX rebuild.
- Hotkey defaults (jump sizes, speed step, mute key).
- Anime watched % and TTL thresholds.
- Release cadence.
- Home screen (mocked together with the user).

## Open questions
None. The brief is ready for Fable.
