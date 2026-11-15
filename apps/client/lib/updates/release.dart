import 'dart:convert';

import 'package:cryptography/cryptography.dart';

enum UpdateChannel { nightly, stable }

enum InstallPolicy { restart, idle }

/// Nightly's numeric prerelease counter sorts below the corresponding stable tag.
/// Build metadata is display-only, as required by SemVer and Velopack.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(this.parts, this.nightlyBuild);
  final List<int> parts;
  final int? nightlyBuild;
  factory ReleaseVersion.parse(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-nightly\.(\d+))?(?:\+(\d+))?$').firstMatch(value);
    if (match == null) throw const FormatException('Invalid release version');
    return ReleaseVersion([
      for (var i = 1; i <= 3; i++) int.parse(match[i]!),
    ], match[4] == null ? null : int.parse(match[4]!));
  }
  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    if (nightlyBuild == null) return other.nightlyBuild == null ? 0 : 1;
    if (other.nightlyBuild == null) return -1;
    return nightlyBuild!.compareTo(other.nightlyBuild!);
  }
}

bool mayInstall({
  required InstallPolicy policy,
  required bool startup,
  required bool playerOpen,
  required Duration idleFor,
}) => !playerOpen && (startup || (policy == InstallPolicy.idle && idleFor >= const Duration(minutes: 1)));

class ReleaseAsset {
  ReleaseAsset(this.name, this.sha256, this.size);
  final String name;
  final String sha256;
  final int size;
}

class ReleaseManifest {
  ReleaseManifest(this.version, this.channel, this.assets);
  final String version;
  final UpdateChannel channel;
  final Map<String, ReleaseAsset> assets;
  factory ReleaseManifest.parse(List<int> bytes, UpdateChannel expected) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (json['schema'] != 1 || json['channel'] != expected.name) {
      throw const FormatException('Wrong update channel/schema');
    }
    final version = json['version'] as String;
    ReleaseVersion.parse(version);
    final assets = <String, ReleaseAsset>{};
    for (final entry in (json['assets'] as Map<String, dynamic>).entries) {
      final a = entry.value as Map<String, dynamic>;
      final name = a['name'] as String;
      final hash = a['sha256'] as String;
      final size = a['size'] as int;
      if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
          name.contains('..') ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          size <= 0) {
        throw const FormatException('Invalid update asset');
      }
      assets[entry.key] = ReleaseAsset(name, hash, size);
    }
    return ReleaseManifest(version, expected, assets);
  }
}

const updatePublicKey = 'z/IgEZjxE404NXTPRK2ARSfIRnSJHcC/Jhj4sieTVgs=';
Future<bool> verifyManifest(List<int> bytes, List<int> signature, {String publicKey = updatePublicKey}) =>
    Ed25519().verify(
      bytes,
      signature: Signature(signature, publicKey: SimplePublicKey(base64Decode(publicKey), type: KeyPairType.ed25519)),
    );

/// GitHub's latest endpoint excludes prereleases, which is essential for stable.
Uri releaseEndpoint(UpdateChannel channel) => Uri.https(
  'api.github.com',
  '/repos/Alb11747/Vokoma/releases/${channel == UpdateChannel.nightly ? 'tags/nightly' : 'latest'}',
);
