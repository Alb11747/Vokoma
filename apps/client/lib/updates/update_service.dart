import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'release.dart';

class UpdateService extends ChangeNotifier {
  static final instance = UpdateService();
  static const _native = MethodChannel('app.vokoma/updates');
  UpdateChannel channel = UpdateChannel.nightly;
  InstallPolicy policy = InstallPolicy.restart;
  String currentVersion = '0.0.0.0';
  String status = 'Not checked';
  DateTime? lastCheck;
  bool playerOpen = false;
  bool installing = false;
  bool _busy = false;
  bool _ready = false;
  DateTime _interaction = DateTime.now();
  late SharedPreferences _preferences;
  late Directory _directory;
  Timer? _timer;
  final _http = http.Client();

  void interact() => _interaction = DateTime.now();
  void setPlayerOpen(bool value) {
    playerOpen = value;
    interact();
  }

  Future<void> start() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      channel = UpdateChannel.values.byName(_preferences.getString('updateChannel') ?? 'nightly');
      policy = InstallPolicy.values.byName(_preferences.getString('installPolicy') ?? 'restart');
      lastCheck = DateTime.tryParse(_preferences.getString('updateLastCheck') ?? '');
      final info = await PackageInfo.fromPlatform();
      currentVersion = '${info.version}.${info.buildNumber}';
      _directory = Directory('${(await getApplicationSupportDirectory()).path}/updates');
      await _directory.create(recursive: true);
      _ready = true;
      await _apply(startup: true);
      await check();
      _timer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!_ready || _busy || installing) return;
        if (lastCheck == null || DateTime.now().difference(lastCheck!) >= const Duration(hours: 4)) {
          await check();
        } else {
          _busy = true;
          try {
            await _apply();
          } catch (error) {
            status = 'Update failed: $error';
            notifyListeners();
          } finally {
            _busy = false;
          }
        }
      });
    } catch (error) {
      status = 'Updates unavailable: $error';
      notifyListeners();
    }
  }

  Future<void> configure(UpdateChannel value, InstallPolicy installPolicy) async {
    if (!_ready || _busy || installing) return;
    await _preferences.setString('updateChannel', value.name);
    await _preferences.setString('installPolicy', installPolicy.name);
    channel = value;
    policy = installPolicy;
    notifyListeners();
    await check();
  }

  Future<List<int>> _get(Uri uri) async {
    final response = await _http
        .get(uri, headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) throw HttpException('Update HTTP ${response.statusCode}');
    return response.bodyBytes;
  }

  Future<void> check() async {
    if (!_ready || _busy || installing) return;
    _busy = true;
    status = 'Checking';
    notifyListeners();
    try {
      final release = jsonDecode(utf8.decode(await _get(releaseEndpoint(channel)))) as Map<String, dynamic>;
      if (release['draft'] == true || (channel == UpdateChannel.stable && release['prerelease'] == true)) {
        throw const FormatException('Not a published release on this channel');
      }
      final assets = {
        for (final a in release['assets'] as List) a['name'] as String: Uri.parse(a['browser_download_url'] as String),
      };
      Uri url(String name) {
        final uri = assets[name];
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host != 'github.com' ||
            !uri.path.startsWith('/Alb11747/Vokoma/releases/download/')) {
          throw const FormatException('Missing or invalid release asset');
        }
        return uri;
      }

      final bytes = await _get(url('update.json'));
      final signature = await _get(url('update.json.sig'));
      if (!await verifyManifest(bytes, signature)) throw const FormatException('Invalid update signature');
      final manifest = ReleaseManifest.parse(bytes, channel);
      lastCheck = DateTime.now();
      await _preferences.setString('updateLastCheck', lastCheck!.toIso8601String());
      if (ReleaseVersion.parse(manifest.version).compareTo(ReleaseVersion.parse(currentVersion)) <= 0) {
        status = 'Up to date (channel changes never downgrade)';
        return;
      }
      final asset = manifest.assets[Platform.isWindows ? 'windows' : 'android'];
      if (asset == null) throw const FormatException('Missing platform package');
      status = 'Downloading ${manifest.version}';
      notifyListeners();
      final file = File('${_directory.path}/${asset.name}');
      if (!await _matches(file, asset)) {
        final response = await _http.send(http.Request('GET', url(asset.name))).timeout(const Duration(seconds: 45));
        if (response.statusCode != 200) throw HttpException('Package HTTP ${response.statusCode}');
        final sink = file.openWrite();
        var count = 0;
        try {
          await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
            count += chunk.length;
            if (count > asset.size) throw const FormatException('Package exceeds signed size');
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (!await _matches(file, asset)) throw const FormatException('Package hash/size mismatch');
      }
      // Publish pending metadata only after the complete download was authenticated.
      await File('${_directory.path}/update.json.sig').writeAsBytes(signature, flush: true);
      await File('${_directory.path}/update.json').writeAsBytes(bytes, flush: true);
      await for (final old in _directory.list()) {
        if (old is File && old.path != file.path && (old.path.endsWith('.nupkg') || old.path.endsWith('.apk'))) {
          await old.delete();
        }
      }
      status = 'Ready: ${manifest.version}';
      await _apply();
    } catch (error) {
      status = 'Update failed: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> _matches(File file, ReleaseAsset asset) async =>
      await file.exists() &&
      await file.length() == asset.size &&
      (await sha256.bind(file.openRead()).first).toString() == asset.sha256;

  Future<void> _apply({bool startup = false}) async {
    if (installing ||
        !mayInstall(
          policy: policy,
          startup: startup,
          playerOpen: playerOpen,
          idleFor: DateTime.now().difference(_interaction),
        )) {
      return;
    }
    final metadata = File('${_directory.path}/update.json');
    if (!await metadata.exists()) return;
    final bytes = await metadata.readAsBytes();
    if (!await verifyManifest(bytes, await File('${_directory.path}/update.json.sig').readAsBytes())) {
      throw const FormatException('Pending update signature invalid');
    }
    // A channel change invalidates a pending update from the old channel.
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (json['channel'] != channel.name) return;
    final manifest = ReleaseManifest.parse(bytes, channel);
    if (ReleaseVersion.parse(manifest.version).compareTo(ReleaseVersion.parse(currentVersion)) <= 0) return;
    final asset = manifest.assets[Platform.isWindows ? 'windows' : 'android']!;
    final file = File('${_directory.path}/${asset.name}');
    if (!await _matches(file, asset)) throw const FormatException('Pending package changed');
    // Re-check after every asynchronous verification; opening a player wins.
    if (!mayInstall(
      policy: policy,
      startup: startup,
      playerOpen: playerOpen,
      idleFor: DateTime.now().difference(_interaction),
    )) {
      return;
    }
    installing = true;
    try {
      if (Platform.isWindows) {
        // Feed is constructed from authenticated bytes, never fetched from the network.
        final feed = {
          'Assets': [
            {
              'PackageId': 'Vokoma',
              'Version': manifest.version,
              'Type': 'Full',
              'FileName': asset.name,
              'SHA1': (await sha1.bind(file.openRead()).first).toString().toUpperCase(),
              'SHA256': asset.sha256.toUpperCase(),
              'Size': asset.size,
            },
          ],
        };
        if (playerOpen) return;
        await File('${_directory.path}/releases.win.json').writeAsString(jsonEncode(feed));
        if (playerOpen) return;
        final launcher = File('${File(Platform.resolvedExecutable).parent.path}/VokomaLauncher.exe');
        if (!await launcher.exists()) throw const FileSystemException('Install the Windows release to enable updates');
        await Process.start(launcher.path, ['--apply', _directory.path, '$pid'], mode: ProcessStartMode.detached);
        exit(0);
      } else if (Platform.isAndroid) {
        final result = await _native.invokeMethod<String>('install', {'path': file.path});
        status = result ?? 'Install requested';
        // Do not repeatedly prompt on each timer tick. A new launch/check retries.
        await metadata.delete();
      }
    } finally {
      installing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _http.close();
    super.dispose();
  }
}
