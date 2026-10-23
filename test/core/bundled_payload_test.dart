import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/bundled_payload.dart';
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late Directory payloadDirectory;
  late File archive;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_payload_');
    payloadDirectory = Directory(p.join(temp.path, 'payload'))
      ..createSync(recursive: true);
    archive = File(p.join(payloadDirectory.path, 'php.zip'))
      ..writeAsStringSync('php archive bytes');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  String digestOf(File file) =>
      sha256.convert(file.readAsBytesSync()).toString();

  ComponentRelease releaseFor(String sha256) {
    return ComponentRelease(
      component: StackComponent.php,
      version: '8.5.11',
      installName: 'php-8.5.11-Win32-vs17-x64',
      url: 'https://example.com/php.zip',
      sha256: sha256,
    );
  }

  void writeManifest(List<Map<String, Object?>> components, {int schema = 1}) {
    File(p.join(payloadDirectory.path, BundledPayload.manifestName))
        .writeAsStringSync(
          jsonEncode({'schema': schema, 'components': components}),
        );
  }

  test('finds an archive that matches the catalog checksum', () {
    final digest = digestOf(archive);
    writeManifest([
      {
        'id': releaseFor(digest).id,
        'file': 'php.zip',
        'sha256': digest.toUpperCase(),
        'size': archive.lengthSync(),
      },
    ]);

    final payload = BundledPayload.load(payloadDirectory);

    expect(payload, isNotNull);
    expect(payload!.count, 1);
    expect(payload.components.single.id, releaseFor(digest).id);
    expect(payload.archiveFor(releaseFor(digest))?.path, archive.path);
  });

  test('ignores an archive whose checksum differs from the catalog', () {
    writeManifest([
      {
        'id': releaseFor(digestOf(archive)).id,
        'file': 'php.zip',
        'sha256': digestOf(archive),
      },
    ]);

    final payload = BundledPayload.load(payloadDirectory);

    expect(payload, isNotNull);
    expect(payload!.archiveFor(releaseFor('0' * 64)), isNull);
  });

  test('ignores a payload without a manifest', () {
    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('ignores a manifest with an unsupported schema', () {
    writeManifest([
      {'id': 'php', 'file': 'php.zip', 'sha256': digestOf(archive)},
    ], schema: 2);

    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('ignores malformed JSON', () {
    File(p.join(payloadDirectory.path, BundledPayload.manifestName))
        .writeAsStringSync('{ not json');

    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('ignores entries that point outside the payload folder', () {
    writeManifest([
      {'id': 'php', 'file': '../php.zip', 'sha256': digestOf(archive)},
    ]);

    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('ignores entries for files that are missing', () {
    writeManifest([
      {'id': 'php', 'file': 'missing.zip', 'sha256': digestOf(archive)},
    ]);

    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('ignores entries with an invalid checksum', () {
    writeManifest([
      {'id': 'php', 'file': 'php.zip', 'sha256': 'not-a-checksum'},
    ]);

    expect(BundledPayload.load(payloadDirectory), isNull);
  });

  test('locates a payload in an explicit root', () {
    final digest = digestOf(archive);
    writeManifest([
      {'id': 'php', 'file': 'php.zip', 'sha256': digest},
    ]);

    expect(BundledPayload.locate(root: payloadDirectory)?.count, 1);
  });
}
