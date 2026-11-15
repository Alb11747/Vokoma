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
flutter build apk --release     # Local/PR builds are debug-signed; never distribute
flutter build windows --release # Windows (needs Windows and Visual Studio)
```

CI (`.github/workflows/client.yml`) runs the same checks on pull requests and
builds both platforms as workflow artifacts. The APK is signed with the Android
debug key; do not distribute it. Release builds use the existing CI keystore secrets.

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

## Releases and updates

Install the Windows Setup executable or Android APK from this repository's GitHub
Releases. Nightly is the default channel. About / updates (available before login
and in the browser toolbar) shows current version, channel, last successful check,
status and Check now. Checks run at launch and every four hours; downloads happen
in the background. Choose install on next restart or install when idle. Idle means
one minute without pointer or keyboard interaction and no open player, including paused players.
Updates are never applied during a player session. Channel changes never downgrade.

Release workflow: main pushes debounce for 30 minutes, then run all server/client
checks and build both native packages. Each nightly uploads all assets to a draft before publication; three published
nightlies are retained; a `vX.Y.Z` tag produces stable. Android build codes share one increasing
workflow counter across channels. Do not delete/recreate the release workflow's
run history or lower its counter. Nightly versions are X.Y.Z-nightly.build; stable
versions match the tag. From Actions,
Release → Run workflow → dry_run uses a debug-signed APK and throwaway manifest key, without production
secrets or publication. Never
use pull-request artifacts for distribution: they are debug-signed and cannot
update a production installation because the certificate differs.

The updater verifies the Ed25519 detached signature on update.json and checks the
signed package SHA-256 and size, including immediately before applying. The public
key is in lib/updates/release.dart and tools/release/update-public.pem. A key change
requires shipping a client trusting it before changing the signing secret. No
private key belongs in this repository. Windows uses Velopack 1.2.161 through a
self-contained .NET launcher (no separate .NET installation needed); its own
size/hash verification is additional integrity checking, not publisher signature
verification. Windows Setup is per-user and not Authenticode signed; expect the
initial SmartScreen warning. Delta packages are not generated.

Android additionally compares APK package name, increasing versionCode and the
exact installed signing certificate set. PackageInstaller validates the APK's
signature at commit. Allow Vokoma to install unknown apps once when requested,
then Check now again. Android 12+ requests USER_ACTION_NOT_REQUIRED for self-updates
and declares UPDATE_PACKAGES_WITHOUT_USER_ACTION; OS policy and target-SDK rules
can still require confirmation. Earlier Android versions require confirmation.

Before release acceptance, test two successive builds on Windows and a real phone,
both policies, both channels, playback veto, interrupted downloads, corrupt packages,
certificate mismatch, denied approval and the OS confirmation fallback. CI does not
prove those device behaviors. Velopack checksum behavior is documented in its
[UpdateManager source](https://github.com/velopack/velopack/blob/1.2.161/src/lib-csharp/UpdateManager.cs).
Android silent-install conditions are in the
[SessionParams API](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)).

Production signing setup: create a `release-signing` GitHub environment with selected
deployment policies for branch `main` and tag pattern `v*`. Move
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
`UPDATE_SIGNING_KEY` into that environment and remove the repository-level copies.
Only the publication job reads them, after rechecking that its main/tag commit is
an ancestor of origin/main. Dry runs cannot produce updates trusted by the app.
Failed Windows apply attempts are remembered by version and shown in About / updates;
the launcher restarts the player on failure instead of closing it on every launch.
