import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  test('every release is pinned to an HTTPS archive with a SHA-256', () {
    for (final release in ComponentCatalog.releases) {
      expect(
        Uri.tryParse(release.url)?.scheme,
        'https',
        reason: release.label,
      );
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(release.sha256),
        isTrue,
        reason: release.label,
      );
      expect(release.installName, isNotEmpty, reason: release.label);
      expect(
        RegExp(r'[\\/:*?"<>|]').hasMatch(release.installName),
        isFalse,
        reason: release.installName,
      );
      expect(release.version, isNotEmpty, reason: release.label);
    }
  });

  test('release ids and install folders are unique', () {
    final ids = ComponentCatalog.releases.map((release) => release.id).toSet();
    final names = ComponentCatalog.releases
        .map((release) => release.installName.toLowerCase())
        .toSet();
    final components = ComponentCatalog.releases
        .map((release) => release.component)
        .toSet();

    expect(ids, hasLength(ComponentCatalog.releases.length));
    expect(names, hasLength(ComponentCatalog.releases.length));
    expect(components, hasLength(ComponentCatalog.releases.length));
  });

  test('the starter stack has a server, PHP, a database, and mail', () {
    final components = ComponentCatalog.recommended
        .map((release) => release.component)
        .toSet();

    expect(
      components,
      containsAll([
        StackComponent.apache,
        StackComponent.php,
        StackComponent.mysql,
        StackComponent.mailpit,
      ]),
    );
    expect(
      ComponentCatalog.recommended.every((release) => release.isRecommended),
      isTrue,
    );
  });

  test('MariaDB stands in for the MySQL component', () {
    final release = ComponentCatalog.latest(StackComponent.mysql);

    expect(release, isNotNull);
    expect(release!.productName, 'MariaDB');
    expect(release.label, 'MariaDB 11.4.13');
    expect(release.component.directoryName, 'mysql');
  });

  test('find resolves a release by version, folder, or id', () {
    final release = ComponentCatalog.php;

    expect(ComponentCatalog.find('php', '8.5.12'), same(release));
    expect(
      ComponentCatalog.find('php', 'php-8.5.12-Win32-vs17-x64'),
      same(release),
    );
    expect(ComponentCatalog.byId(release.id), same(release));
    expect(ComponentCatalog.find('php', '8.4.0'), isNull);
    expect(ComponentCatalog.find('apache', '8.5.12'), isNull);
  });

  test('missingFrom skips a component that is already installed', () {
    final temp = Directory.systemTemp.createTempSync('stackpilot_catalog_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
    final php = ComponentCatalog.php;
    final directory = p.join(
      layout.root,
      'bin',
      php.component.directoryName,
      php.installName,
    );
    File(p.join(directory, 'php.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');

    final detected = StackLayout.detect(layout.root)!;
    final missing = ComponentCatalog.missingFrom(detected);

    expect(ComponentCatalog.isInstalled(detected, php), isTrue);
    expect(missing, isNot(contains(php)));
    expect(missing, hasLength(ComponentCatalog.releases.length - 1));
  });

  test('labels keep a short size for the setup dialog', () {
    expect(ComponentCatalog.php.sizeLabel, endsWith('MB'));
    expect(ComponentCatalog.apache.label, 'Apache 2.4.69');
    expect(ComponentCatalog.mariadb.sizeLabel, endsWith('MB'));
  });
}
