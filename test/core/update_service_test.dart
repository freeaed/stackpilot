import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_info.dart';
import 'package:stackpilot/core/app_preferences.dart';
import 'package:stackpilot/core/update_service.dart';

void main() {
  late Directory temp;
  late Directory cache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_update_');
    cache = Directory(p.join(temp.path, 'cache'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const installerBytes = 'signed-installer-payload';
  final installerDigest = sha256
      .convert(utf8.encode(installerBytes))
      .toString();
  final installerSize = utf8.encode(installerBytes).length;

  Map<String, Object?> manifestJson({
    String stableVersion = '1.3.0',
    String? previewVersion,
    String installerUrl = 'https://example.com/StackPilot-Setup.exe',
    String sha256Digest = '',
  }) {
    return {
      'schema': 1,
      'generated': '2026-10-01T00:00:00Z',
      'channels': {
        'stable': {
          'version': stableVersion,
          'notes': 'A calmer start.',
          'published': '2026-10-01T00:00:00Z',
          'installer': {
            'url': installerUrl,
            'sha256': sha256Digest.isEmpty ? installerDigest : sha256Digest,
            'size': installerSize,
          },
        },
        if (previewVersion != null)
          'preview': {
            'version': previewVersion,
            'notes': 'Preview notes.',
            'installer': {
              'url': installerUrl,
              'sha256': installerDigest,
              'size': installerSize,
            },
          },
      },
    };
  }

  Future<({List<int> bytes, String signature, String publicKey})> sign(
    Map<String, Object?> json,
  ) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final bytes = utf8.encode(jsonEncode(json));
    final signature = await algorithm.sign(bytes, keyPair: keyPair);
    final publicKey = await keyPair.extractPublicKey();
    return (
      bytes: bytes,
      signature: base64Encode(signature.bytes),
      publicKey: base64Encode(publicKey.bytes),
    );
  }

  UpdateService service({
    required String publicKey,
    required List<int> manifestBytes,
    required String signature,
    String currentVersion = '1.2.0',
    ReleaseChannel channel = ReleaseChannel.stable,
    UpdateDownload? download,
  }) {
    final manifestUri = Uri.parse('https://example.com/updates/manifest.json');
    return UpdateService(
      manifestUri: manifestUri,
      publicKey: publicKey,
      currentVersion: currentVersion,
      channel: channel,
      cacheDirectory: cache,
      fetchBytes: (uri) async {
        expect(uri, manifestUri);
        return manifestBytes;
      },
      fetchText: (uri) async {
        expect(uri.toString(), '${manifestUri.toString()}.sig');
        return signature;
      },
      download:
          download ??
          (uri, destination, onProgress) async {
            throw StateError('download was not expected');
          },
    );
  }

  test(
    'accepts a correctly signed manifest and finds a newer release',
    () async {
      final signed = await sign(manifestJson());

      final result = await service(
        publicKey: signed.publicKey,
        manifestBytes: signed.bytes,
        signature: signed.signature,
      ).check();

      expect(result.hasUpdate, isTrue);
      expect(result.release?.version, '1.3.0');
      expect(result.release?.notes, 'A calmer start.');
      expect(result.release?.installerUrl.toString(), contains('https://'));
    },
  );

  test('reports the build as current when no channel is newer', () async {
    final signed = await sign(manifestJson(stableVersion: '1.2.0'));

    final result = await service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
    ).check();

    expect(result.hasUpdate, isFalse);
  });

  test('rejects a manifest whose bytes do not match the signature', () async {
    final signed = await sign(manifestJson());
    final tampered = utf8.encode(
      jsonEncode(manifestJson(stableVersion: '9.9.9')),
    );

    await expectLater(
      service(
        publicKey: signed.publicKey,
        manifestBytes: tampered,
        signature: signed.signature,
      ).check(),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('signature is not valid'),
        ),
      ),
    );
  });

  test('rejects a signature that is not base64', () async {
    final signed = await sign(manifestJson());

    await expectLater(
      service(
        publicKey: signed.publicKey,
        manifestBytes: signed.bytes,
        signature: 'not base64!',
      ).check(),
      throwsA(isA<UpdateException>()),
    );
  });

  test('rejects a build whose signing key is invalid', () async {
    final signed = await sign(manifestJson());

    await expectLater(
      service(
        publicKey: 'definitely-not-a-key',
        manifestBytes: signed.bytes,
        signature: signed.signature,
      ).check(),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('public key'),
        ),
      ),
    );
  });

  test('a preview build takes a newer preview release', () async {
    final signed = await sign(
      manifestJson(stableVersion: '1.2.0', previewVersion: '1.4.0-beta.1'),
    );

    final result = await service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      channel: ReleaseChannel.preview,
    ).check();

    expect(result.release?.version, '1.4.0-beta.1');
  });

  test('a preview build falls back to a newer stable release', () async {
    final signed = await sign(
      manifestJson(stableVersion: '1.5.0', previewVersion: '1.4.0-beta.1'),
    );

    final result = await service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      channel: ReleaseChannel.preview,
    ).check();

    expect(result.release?.version, '1.5.0');
  });

  test('downloads an installer and verifies its checksum', () async {
    final signed = await sign(manifestJson());
    final serviceUnderTest = service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      download: (uri, destination, onProgress) async {
        final bytes = utf8.encode(installerBytes);
        destination.writeAsBytesSync(bytes);
        onProgress(bytes.length, bytes.length);
      },
    );
    final release = (await serviceUnderTest.check()).release!;

    final progress = <double>[];
    final file = await serviceUnderTest.download(
      release,
      onProgress: (received, total) {
        if (total != null) {
          progress.add(received / total);
        }
      },
    );

    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), installerBytes);
    expect(p.basename(file.path), 'StackPilot-1.3.0-Setup.exe');
    expect(File('${file.path}.part').existsSync(), isFalse);
    expect(progress, [1.0]);
  });

  test('rejects and deletes an installer that fails its checksum', () async {
    final signed = await sign(manifestJson());
    final serviceUnderTest = service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      download: (uri, destination, onProgress) async {
        destination.writeAsStringSync('tampered');
      },
    );
    final release = (await serviceUnderTest.check()).release!;

    await expectLater(
      serviceUnderTest.download(release),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('did not match its published checksum'),
        ),
      ),
    );

    expect(
      cache.existsSync() &&
          cache.listSync().any((entity) => entity.path.endsWith('.exe')),
      isFalse,
    );
  });

  test('reuses a verified installer that is already cached', () async {
    final signed = await sign(manifestJson());
    final cached = File(p.join(cache.path, 'StackPilot-1.3.0-Setup.exe'));
    cached.parent.createSync(recursive: true);
    cached.writeAsStringSync(installerBytes);
    var downloaded = false;
    final serviceUnderTest = service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      download: (uri, destination, onProgress) async {
        downloaded = true;
      },
    );
    final release = (await serviceUnderTest.check()).release!;

    final file = await serviceUnderTest.download(release);

    expect(file.path, cached.path);
    expect(downloaded, isFalse);
  });

  test('lists cached installers newest first', () {
    cache.createSync(recursive: true);
    for (final version in ['1.0.0', '2.0.0', '1.10.0']) {
      File(p.join(cache.path, 'StackPilot-$version-Setup.exe'))
          .writeAsStringSync(version);
    }
    File(p.join(cache.path, 'notes.txt')).writeAsStringSync('ignored');

    final serviceUnderTest = UpdateService(
      manifestUri: Uri.parse('https://example.com/manifest.json'),
      publicKey: 'unused',
      currentVersion: '1.0.0',
      channel: ReleaseChannel.stable,
      cacheDirectory: cache,
    );

    expect(
      serviceUnderTest.cachedInstallers().map((installer) => installer.version),
      ['2.0.0', '1.10.0', '1.0.0'],
    );
  });

  test('refuses to launch an installer that is missing', () async {
    await expectLater(
      UpdateService.runInstaller(File(p.join(temp.path, 'gone.exe'))),
      throwsA(isA<UpdateException>()),
    );
  });

  test('rejects a manifest that is not served over HTTPS', () async {
    final serviceUnderTest = UpdateService(
      manifestUri: Uri.parse('http://example.com/manifest.json'),
      publicKey: 'unused',
      currentVersion: '1.0.0',
      channel: ReleaseChannel.stable,
      cacheDirectory: cache,
    );

    await expectLater(
      serviceUnderTest.check(),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('HTTPS'),
        ),
      ),
    );
  });

  test('removes a partial download when the transfer fails', () async {
    final signed = await sign(manifestJson());
    final serviceUnderTest = service(
      publicKey: signed.publicKey,
      manifestBytes: signed.bytes,
      signature: signed.signature,
      download: (uri, destination, onProgress) async {
        destination.writeAsStringSync('half an installer');
        throw const UpdateException('the connection dropped');
      },
    );
    final release = (await serviceUnderTest.check()).release!;

    await expectLater(
      serviceUnderTest.download(release),
      throwsA(isA<UpdateException>()),
    );

    expect(
      cache.existsSync() &&
          cache.listSync().any((entity) => entity.path.endsWith('.part')),
      isFalse,
    );
  });

  test('only configures updates for an HTTPS manifest and a key', () {
    expect(UpdateService.fromConfig(AppPreferences.empty), isNull);
    expect(
      UpdateService.fromConfig(
        const AppPreferences(updateManifestUrl: 'http://example.com/m.json'),
      ),
      isNull,
    );
  });

  test('rejects an unknown channel name in the manifest', () {
    expect(
      () => UpdateManifest.parse(
        jsonEncode({
          'schema': 1,
          'channels': {
            'nightly': {
              'version': '1.0.0',
              'installer': {
                'url': 'https://example.com/a.exe',
                'sha256': installerDigest,
              },
            },
          },
        }),
      ),
      throwsA(isA<UpdateException>()),
    );
  });

  test('rejects an installer URL that is not HTTPS', () async {
    final signed = await sign(
      manifestJson(installerUrl: 'http://example.com/StackPilot-Setup.exe'),
    );

    await expectLater(
      service(
        publicKey: signed.publicKey,
        manifestBytes: signed.bytes,
        signature: signed.signature,
      ).check(),
      throwsA(isA<UpdateException>()),
    );
  });

  test('rejects a manifest from a future schema', () {
    expect(
      () => UpdateManifest.parse(jsonEncode({'schema': 2, 'channels': {}})),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('schema'),
        ),
      ),
    );
  });

  test('parses a version label with a pre-release', () {
    expect(AppVersion.tryParse('2.0.0-rc.1')?.toString(), '2.0.0-rc.1');
  });
}
