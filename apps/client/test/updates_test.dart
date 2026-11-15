import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/updates/release.dart';

void main() {
  test('numeric versions order releases across patch and build boundaries', () {
    int compare(String a, String b) => ReleaseVersion.parse(a).compareTo(ReleaseVersion.parse(b));
    expect(compare('0.1.1-nightly.100', '0.1.1-nightly.99'), greaterThan(0));
    expect(compare('v0.1.2', '0.1.1-nightly.999'), greaterThan(0));
    expect(compare('0.1.1+100', '0.1.1+99'), 0);
    expect(compare('1.10.0-nightly.2', '1.9.0-nightly.999'), greaterThan(0));
    expect(compare('v0.1.1', '0.1.1-nightly.999'), greaterThan(0));
    expect(() => ReleaseVersion.parse('0.1.1-malicious'), throwsFormatException);
  });
  test('nightly discovery ignores drafts and stable releases during publication', () {
    final releases = [
      {'draft': true, 'prerelease': true, 'tag_name': 'nightly-new', 'published_at': '2026-02-01T00:00:00Z'},
      {'draft': false, 'prerelease': false, 'tag_name': 'v1.0.0', 'published_at': '2026-02-01T00:00:00Z'},
      {'draft': false, 'prerelease': true, 'tag_name': 'nightly-old', 'published_at': '2026-01-01T00:00:00Z'},
    ];
    expect(selectRelease(releases, UpdateChannel.nightly)['tag_name'], 'nightly-old');
    releases.first['draft'] = false;
    expect(selectRelease(releases, UpdateChannel.nightly)['tag_name'], 'nightly-new');
  });
  test('authentic manifest accepted, corruption and a different publisher rejected', () async {
    // RFC 8032 test vector 1: independent known signature, not produced by our code.
    List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
    final public = base64Encode(hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'));
    final signature = hex(
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    );
    expect(await verifyManifest([], signature, publicKey: public), isTrue);
    expect(await verifyManifest([1], signature, publicKey: public), isFalse);
    expect(await verifyManifest([], signature), isFalse);
    final pair = await Ed25519().newKeyPair();
    final bytes = utf8.encode('{"schema":1,"channel":"nightly"}');
    final signed = await Ed25519().sign(bytes, keyPair: pair);
    expect(
      await verifyManifest(bytes, signed.bytes, publicKey: base64Encode((await pair.extractPublicKey()).bytes)),
      isTrue,
    );
  });
  test('restart policy waits; idle policy requires a minute; player always vetoes', () {
    for (final policy in InstallPolicy.values) {
      for (final startup in [false, true]) {
        expect(
          mayInstall(policy: policy, startup: startup, playerOpen: true, idleFor: const Duration(days: 1)),
          isFalse,
        );
      }
    }
    expect(
      mayInstall(policy: InstallPolicy.restart, startup: false, playerOpen: false, idleFor: const Duration(days: 1)),
      isFalse,
    );
    expect(mayInstall(policy: InstallPolicy.restart, startup: true, playerOpen: false, idleFor: Duration.zero), isTrue);
    expect(
      mayInstall(policy: InstallPolicy.idle, startup: false, playerOpen: false, idleFor: const Duration(seconds: 59)),
      isFalse,
    );
    expect(
      mayInstall(policy: InstallPolicy.idle, startup: false, playerOpen: false, idleFor: const Duration(minutes: 1)),
      isTrue,
    );
  });
  test('metadata binds channel, version, safe filename, complete size and hash', () {
    final json = {
      'schema': 1,
      'channel': 'nightly',
      'version': '0.1.1-nightly.52',
      'assets': {
        'android': {'name': 'Vokoma.apk', 'sha256': List.filled(64, 'a').join(), 'size': 123},
      },
    };
    ReleaseManifest parse() => ReleaseManifest.parse(utf8.encode(jsonEncode(json)), UpdateChannel.nightly);
    expect(parse().assets['android']!.size, 123);
    json['channel'] = 'stable';
    expect(parse, throwsFormatException);
    json['channel'] = 'nightly';
    final asset = (json['assets'] as Map)['android'] as Map;
    asset['name'] = '../Vokoma.apk';
    expect(parse, throwsFormatException);
    asset['name'] = 'Vokoma.apk';
    asset['sha256'] = '';
    expect(parse, throwsFormatException);
    asset['sha256'] = List.filled(64, 'a').join();
    asset['size'] = 0;
    expect(parse, throwsFormatException);
  });
}
