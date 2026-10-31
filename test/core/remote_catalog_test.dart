import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/catalog_export.dart';
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/remote_catalog.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  const manifest = '''
{
  "schema": 1,
  "generated": "2026-10-31T10:00:00Z",
  "components": [
    {
      "component": "php",
      "version": "8.5.12-1",
      "installName": "php-8.5.12-1-Win32-vs17-x64",
      "urls": [
        "https://windows.php.net/downloads/releases/php-8.5.12-1-Win32-vs17-x64.zip",
        "https://windows.php.net/downloads/releases/archives/php-8.5.12-1-Win32-vs17-x64.zip"
      ],
      "sha256": "0dacd6484b092b5e9ae9fa3d7f96a937caf9d874eee2d980b68ed3129741144a",
      "size": 36453069
    }
  ],
  "apps": [
    {
      "id": "phpmyadmin",
      "name": "phpMyAdmin",
      "version": "5.2.3",
      "installName": "phpmyadmin",
      "urls": ["https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip"],
      "sha256": "2d2e13c735366d318425c78e4ee2cc8fc648d77faba3ddea2cd516e43885733f"
    }
  ]
}
''';

  test('parses components and apps', () {
    final snapshot = CatalogSnapshot.parse(manifest);

    expect(snapshot.components, hasLength(1));
    final php = snapshot.components.single;
    expect(php.component, StackComponent.php);
    expect(php.urls, hasLength(2));
    expect(php.mirrors.single, contains('/releases/archives/'));
    expect(php.sizeBytes, 36453069);
    expect(snapshot.apps.single.id, 'phpmyadmin');
    expect(snapshot.apps.single.version, '5.2.3');
    expect(snapshot.generated, DateTime.utc(2026, 10, 31, 10));
  });

  test('rejects unknown components and non-HTTPS URLs', () {
    expect(
      () => CatalogSnapshot.parse(
        manifest.replaceAll('"component": "php"', '"component": "unknown"'),
      ),
      throwsA(isA<RemoteCatalogException>()),
    );
    expect(
      () => CatalogSnapshot.parse(
        manifest.replaceAll(
          'https://files.phpmyadmin.net/',
          'http://files.phpmyadmin.net/',
        ),
      ),
      throwsA(isA<RemoteCatalogException>()),
    );
    expect(
      () => CatalogSnapshot.parse('{"schema": 2}'),
      throwsA(isA<RemoteCatalogException>()),
    );
  });

  test('the exported catalog parses back unchanged', () {
    final json = jsonEncode(
      buildCatalogManifest(now: DateTime.utc(2026, 10, 31)),
    );

    final snapshot = CatalogSnapshot.parse(json);

    expect(snapshot.components, hasLength(ComponentCatalog.releases.length));
    expect(snapshot.components.first.component, StackComponent.php);
    expect(snapshot.apps.single.id, 'phpmyadmin');
    expect(snapshot.generated, DateTime.utc(2026, 10, 31));
  });

  test('accepts a manifest signed with the update key', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(
      utf8.encode(manifest),
      keyPair: keyPair,
    );

    final remote = RemoteCatalog(
      manifestUri: Uri.parse('https://example.com/catalog.json'),
      publicKey: base64Encode(publicKey.bytes),
      fetchBytes: (_) async => utf8.encode(manifest),
      fetchText: (_) async => base64Encode(signature.bytes),
    );

    final snapshot = await remote.fetch();

    expect(snapshot.components.single.version, '8.5.12-1');
    expect(snapshot.apps.single.name, 'phpMyAdmin');
  });

  test('refuses a manifest whose signature does not match', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final otherKeyPair = await algorithm.newKeyPair();
    final signature = await algorithm.sign(
      utf8.encode(manifest),
      keyPair: otherKeyPair,
    );

    final remote = RemoteCatalog(
      manifestUri: Uri.parse('https://example.com/catalog.json'),
      publicKey: base64Encode(publicKey.bytes),
      fetchBytes: (_) async => utf8.encode(manifest),
      fetchText: (_) async => base64Encode(signature.bytes),
    );

    await expectLater(
      remote.fetch(),
      throwsA(
        isA<RemoteCatalogException>().having(
          (error) => error.message,
          'message',
          contains('signature is not valid'),
        ),
      ),
    );
  });
}
