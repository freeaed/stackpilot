import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_settings.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_bootstrap_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('creates a stack that StackLayout can read', () {
    final root = p.join(temp.path, 'default');

    final layout = StackBootstrap.create(
      root: root,
      mysqlPort: 3307,
      postgresqlPort: 5433,
    );

    expect(layout.flavor, StackFlavor.stackpilot);
    expect(layout.root, p.normalize(p.absolute(root)));
    expect(layout.markerPath, p.join(root, 'usr', 'stackpilot.ini'));
    expect(layout.documentRoot, p.join(root, 'www'));
    expect(layout.dataDirectory, p.join(root, 'data'));
    expect(layout.mysqlPort, 3307);
    expect(layout.postgresqlPort, 5433);
    expect(layout.autoVirtualHosts, isTrue);
    expect(layout.serviceEnabled(StackComponent.apache), isTrue);
    expect(layout.serviceEnabled(StackComponent.mysql), isTrue);
    expect(layout.serviceEnabled(StackComponent.nginx), isFalse);
    expect(layout.installedVersions(StackComponent.php), isEmpty);
  });

  test('creates the folder skeleton and a landing page', () {
    final root = p.join(temp.path, 'default');
    StackBootstrap.create(root: root);

    for (final directory in [
      'bin',
      p.join('usr', 'profile'),
      p.join('etc', 'apache2', 'sites-enabled'),
      p.join('etc', 'apache2', 'alias'),
      p.join('etc', 'nginx'),
      'www',
      'data',
      'logs',
      'tmp',
    ]) {
      expect(
        Directory(p.join(root, directory)).existsSync(),
        isTrue,
        reason: directory,
      );
    }

    expect(
      File(p.join(root, 'usr', 'profile', 'default.ini')).existsSync(),
      isTrue,
    );
    expect(File(p.join(root, 'www', 'index.html')).existsSync(), isTrue);
  });

  test('writes the document root and data folder as absolute paths', () {
    final root = p.join(temp.path, 'default');
    StackBootstrap.create(root: root);

    final marker = File(p.join(root, 'usr', 'stackpilot.ini'))
        .readAsStringSync();

    expect(marker, contains('DocumentRootList=$root\\www|'));
    expect(marker, contains('DataDir=$root\\data'));
    expect(marker, contains('[stackpilot]'));
  });

  test('refuses a folder that already contains files', () {
    final root = p.join(temp.path, 'occupied');
    File(p.join(root, 'notes.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep me');

    expect(
      () => StackBootstrap.create(root: root),
      throwsA(isA<StackBootstrapException>()),
    );
  });

  test('refuses to overwrite an existing stack', () {
    final root = p.join(temp.path, 'default');
    StackBootstrap.create(root: root);

    expect(
      () => StackBootstrap.create(root: root),
      throwsA(
        isA<StackBootstrapException>().having(
          (error) => error.message,
          'message',
          contains('already a stack'),
        ),
      ),
    );
  });

  test('rejects a port outside the valid range', () {
    expect(
      () => StackBootstrap.create(
        root: p.join(temp.path, 'default'),
        mysqlPort: 70000,
      ),
      throwsA(isA<StackBootstrapException>()),
    );
    expect(Directory(p.join(temp.path, 'default')).existsSync(), isFalse);
  });

  test('defaults to the StackPilot folder under LOCALAPPDATA', () {
    final environment = {'LOCALAPPDATA': p.join(temp.path, 'AppData', 'Local')};

    expect(
      StackBootstrap.defaultStacksFolder(environment: environment),
      p.join(temp.path, 'AppData', 'Local', 'StackPilot', 'stacks'),
    );
    expect(
      StackBootstrap.defaultRoot(environment: environment),
      p.join(temp.path, 'AppData', 'Local', 'StackPilot', 'stacks', 'default'),
    );
  });

  test('isCreatable accepts a missing or empty folder', () {
    expect(StackBootstrap.isCreatable(p.join(temp.path, 'missing')), isTrue);

    final empty = p.join(temp.path, 'empty');
    Directory(empty).createSync(recursive: true);
    expect(StackBootstrap.isCreatable(empty), isTrue);

    File(p.join(empty, 'file.txt')).writeAsStringSync('x');
    expect(StackBootstrap.isCreatable(empty), isFalse);
    expect(StackBootstrap.isCreatable(''), isFalse);
  });

  test('settings changes are written to the StackPilot marker', () {
    final root = p.join(temp.path, 'default');
    final layout = StackBootstrap.create(root: root);

    final settings = StackSettings.load(layout).copyWith(mysqlPort: 3308);
    StackEditor(layout).applySettings(settings);

    final marker = File(layout.markerPath).readAsStringSync();
    expect(marker, contains('Port=3308'));
    expect(File(layout.markerPath).existsSync(), isTrue);
    expect(File('${layout.markerPath}.stackpilot.bak').existsSync(), isTrue);

    final reloaded = StackLayout.detect(root)!;
    expect(reloaded.mysqlPort, 3308);
  });
}
