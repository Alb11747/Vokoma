# Vokoma client

The Flutter app for Windows and Android (web, iOS and macOS later). M0 scope:
log in, browse the server's media folders, play a file with the M0 hotkeys. See
[docs/milestones/M0.md](../../docs/milestones/M0.md).

## Toolchain

Flutter **3.47.9** (stable), pinned in `pubspec.yaml` (`environment.flutter`);
CI reads it from there. Android builds need JDK 17 and the Android SDK
(platform 36; Gradle downloads the rest on first build).

## Commands

Run from `apps/client/`:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release     # Android, signed with the debug key for now
flutter build windows --release # Windows (needs Windows and Visual Studio)
```

CI (`.github/workflows/client.yml`) runs the same checks on pull requests and
builds both platforms as workflow artifacts. The APK is signed with the Android
debug key until release signing is set up (M0 part C); do not distribute it.

## Layout

```
lib/api/          Server API client, token storage, and the loopback media proxy
lib/engine/       PlayerEngine and MpvEngine — the only code that touches mpv/media_kit
lib/features/     login, browser, player (hotkeys, controller, screen)
lib/platform/     Calls into the native runners (Windows fullscreen)
windows/          Runner; libmpv.cmake pins the bundled libmpv
test/             Unit tests, with a fake server in test/fake_server.dart
```

## How things work

**Tokens.** The access token is kept in memory only. The refresh token and
device id are stored with flutter_secure_storage: on Windows a DPAPI-encrypted
file whose key is held in Credential Manager, on Android values encrypted with
a key in the Android Keystore. Refresh happens a minute before expiry and after
any 401, one refresh at a time, because the refresh token rotates. A 401 on
refresh signs the device out.

**Streaming with expiring tokens.** mpv reads its `http-header-fields` once when
it opens a file and reuses those headers for every later range request, so a
real access token in that header would start failing 15 minutes into playback.
Instead the player opens `http://127.0.0.1:<port>/files/<fileId>` on a loopback
proxy inside the app (`lib/api/media_proxy.dart`) and sends a random per-run
secret in its `Authorization` header, through mpv's header option. The proxy
checks the secret, adds the current access token (refreshing on 401) and
streams the server's response back with backpressure. Tokens never reach mpv or
any URL.

**Frame stepping.** `,` uses mpv's seek-based `frame-back-step`, which is exact.
Each key press steps once; while the key is held, a repeat is taken only when
the previous step has shown its frame, so releasing the key stops at once.

**MPEG-TS seeks.** FFmpeg's TS demuxer seeks to the first keyframe after the
target, so exact seeks landed up to one keyframe interval (2 s on Twitch
recordings) late. `.ts` files get `hr-seek-demuxer-offset=3`, which makes exact
seeks and back steps land on the right frame; see `hrSeekDemuxerOffsetFor` in
`lib/engine/mpv_engine.dart` for the measurements.

**libmpv.** On Windows, `windows/libmpv.cmake` downloads the official mpv
0.42.0 libmpv release (hash-checked) and installs it over media_kit's bundled
2023 build; CI checks the result. Pass `-DVOKOMA_PINNED_LIBMPV=OFF` to CMake to
use media_kit's library instead. Android still uses media_kit's library (an mpv
snapshot from October 2023 with FFmpeg 6.0).

## Hotkeys (Windows, M0)

Space play/pause · `←`/`→` 5 s, Shift 30 s, Ctrl 90 s, Alt 1 s · `,`/`.`
previous/next frame · `[`/`]` speed −/+0.1 (0.25×–4×) · `/` normal ↔ previous
speed · `F` fullscreen · `Shift+M`/`Ctrl+M` mute · `Esc` leaves fullscreen,
then the player. Mouse clicks on the video and number keys do nothing.

Android: tap the video to show play/pause, a seek bar and frame step buttons.
