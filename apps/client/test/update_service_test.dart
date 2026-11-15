import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vokoma/updates/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;
  late SimpleKeyPair key;
  late String public;
  final payload = utf8.encode('generated package fixture');
  late List<int> metadata;
  late List<int> signature;
  final requests = <String>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vokoma-update-test-');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    key = await Ed25519().newKeyPair();
    public = base64Encode((await key.extractPublicKey()).bytes);
    requests.clear();
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<void> manifest({String version = '0.1.1-nightly.52', String channel = 'nightly'}) async {
    metadata = utf8.encode(
      jsonEncode({
        'schema': 1,
        'channel': channel,
        'version': version,
        'assets': {
          'android': {'name': 'Vokoma.apk', 'size': payload.length, 'sha256': sha256.convert(payload).toString()},
          'windows': {
            'name': 'Vokoma-full.nupkg',
            'size': payload.length,
            'sha256': sha256.convert(payload).toString(),
          },
        },
      }),
    );
    signature = (await Ed25519().sign(metadata, keyPair: key)).bytes;
  }

  Future<void> pending() async {
    await File('${directory.path}/update.json').writeAsBytes(metadata);
    await File('${directory.path}/update.json.sig').writeAsBytes(signature);
    await File('${directory.path}/Vokoma.apk').writeAsBytes(payload);
    await File('${directory.path}/Vokoma-full.nupkg').writeAsBytes(payload);
  }

  http.Client client({bool tamper = false}) => MockClient((request) async {
    requests.add(request.url.path);
    if (request.url.host == 'api.github.com') {
      return http.Response(
        jsonEncode([
          {
            'draft': false,
            'prerelease': true,
            'tag_name': 'nightly-0.1.1-nightly.52',
            'published_at': '2026-01-01T00:00:00Z',
            'assets': [
              for (final name in ['update.json', 'update.json.sig', 'Vokoma.apk', 'Vokoma-full.nupkg'])
                {
                  'name': name,
                  'browser_download_url': 'https://github.com/Alb11747/Vokoma/releases/download/nightly-fixture/$name',
                },
            ],
          },
        ]),
        200,
      );
    }
    return http.Response.bytes(
      request.url.path.endsWith('update.json')
          ? metadata
          : request.url.path.endsWith('.sig')
          ? signature
          : tamper
          ? List.filled(payload.length, 0)
          : payload,
      200,
    );
  });
  Future<void> initialize(UpdateService service, {String version = '0.1.0+1'}) =>
      service.initialize(preferences: preferences, directory: directory, version: version);

  test('episode A finishing shutdown cannot release episode B playback veto', () async {
    await manifest();
    await pending();
    var installs = 0;
    final service = UpdateService(
      publicKey: public,
      platform: 'android',
      androidInstall: (_) async {
        installs++;
        return 'Installed';
      },
    );
    addTearDown(service.dispose);
    final releaseA = service.reservePlayer();
    final shutdownA = Completer<void>();
    final closedA = shutdownA.future.whenComplete(releaseA);
    final releaseB = service.reservePlayer();
    shutdownA.complete();
    await closedA;
    releaseA(); // A duplicate completion must not release B either.
    await initialize(service);
    expect(service.playerOpen, isTrue);
    expect(installs, 0);
    releaseB();
    await initialize(service);
    expect(installs, 1);
    expect(service.playerOpen, isFalse);
  });
  test('a valid signed downgrade never downloads a package or starts installation', () async {
    await manifest();
    var installs = 0;
    final service = UpdateService(
      client: client(),
      publicKey: public,
      platform: 'android',
      androidInstall: (_) async {
        installs++;
        return 'Installed';
      },
    );
    addTearDown(service.dispose);
    await initialize(service, version: '0.2.0+80');
    await service.check();
    expect(service.status, contains('never downgrade'));
    expect(installs, 0);
    expect(requests.where((path) => path.endsWith('.apk')), isEmpty);
    expect(await File('${directory.path}/update.json').exists(), isFalse);
  });
  test('a payload hash mismatch cannot become a pending update', () async {
    await manifest();
    var installs = 0;
    final service = UpdateService(
      client: client(tamper: true),
      publicKey: public,
      platform: 'android',
      androidInstall: (_) async {
        installs++;
        return 'Installed';
      },
    );
    addTearDown(service.dispose);
    await initialize(service);
    await service.check();
    expect(service.status, contains('hash/size mismatch'));
    expect(installs, 0);
    expect(await File('${directory.path}/update.json').exists(), isFalse);
  });
  test('pending metadata from the old channel is ignored at startup', () async {
    await manifest(channel: 'stable', version: '0.2.0');
    await pending();
    var installs = 0;
    final service = UpdateService(
      publicKey: public,
      platform: 'android',
      androidInstall: (_) async {
        installs++;
        return 'Installed';
      },
    );
    addTearDown(service.dispose);
    await initialize(service);
    expect(installs, 0);
    expect(service.applyError, isNull);
    expect(await File('${directory.path}/update.json').exists(), isTrue);
  });
  test('failed Windows version is remembered across launches and checks, and error is visible', () async {
    await manifest();
    await pending();
    var attempts = 0;
    UpdateService service() => UpdateService(
      client: client(),
      publicKey: public,
      platform: 'windows',
      windowsError: () async => 'Velopack could not read the package',
      windowsApply: (_, _) async {
        attempts++;
        throw const FileSystemException('Velopack failed');
      },
    );
    final first = service();
    addTearDown(first.dispose);
    await initialize(first);
    expect(attempts, 1);
    expect(first.installing, isFalse);
    expect(preferences.getString('updateAttemptedVersion'), '0.1.1-nightly.52');
    final second = service();
    addTearDown(second.dispose);
    await initialize(second);
    await second.check();
    expect(attempts, 1);
    expect(second.applyError, contains('Velopack could not read'));
  });
  test('lost Android callback times out and releases the installation lock', () async {
    await manifest();
    await pending();
    final service = UpdateService(
      publicKey: public,
      platform: 'android',
      installTimeout: const Duration(milliseconds: 1),
      androidInstall: (_) => Completer<String?>().future,
    );
    addTearDown(service.dispose);
    await initialize(service);
    expect(service.installing, isFalse);
    expect(service.applyError, contains('did not report a result'));
  });
}
