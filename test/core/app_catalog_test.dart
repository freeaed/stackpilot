import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_catalog.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_provisioner.dart';

void main() {
  test('every app is pinned to an HTTPS archive with a SHA-256', () {
    for (final app in AppCatalog.apps) {
      expect(Uri.tryParse(app.url)?.scheme, 'https', reason: app.label);
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(app.sha256),
        isTrue,
        reason: app.label,
      );
      expect(app.installName, isNotEmpty, reason: app.label);
      expect(
        RegExp(r'[\\/:*?"<>|]').hasMatch(app.installName),
        isFalse,
        reason: app.installName,
      );
    }
    expect(AppCatalog.byId('phpmyadmin'), same(AppCatalog.phpMyAdmin));
    expect(AppCatalog.byId('adminer'), isNull);
  });

  test('phpMyAdmin installs into etc/apps and is served from there', () async {
    final temp = Directory.systemTemp.createTempSync('stackpilot_app_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));

    final source = Directory(p.join(temp.path, 'source', 'phpMyAdmin-5.2.3'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'index.php'))
      ..createSync()
      ..writeAsStringSync('<?php');
    File(p.join(source.path, 'libraries', 'classes', 'Index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');
    File(p.join(source.path, 'themes', 'theme.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final archive = p.join(temp.path, 'phpmyadmin.zip');
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -LiteralPath '
          "'${source.path.replaceAll("'", "''")}' "
          "-DestinationPath '$archive' -Force",
    ]);
    expect(compress.exitCode, 0, reason: compress.stderr.toString());

    final app = AppCatalog.phpMyAdmin;
    final provisioner = StackProvisioner(
      layout,
      download: (uri, destination, onProgress) async {
        destination.writeAsBytesSync(File(archive).readAsBytesSync());
        onProgress(1, 1);
      },
      digest: (_) async => app.sha256,
    );

    final directory = await provisioner.installApp(app);

    expect(directory, p.join(layout.root, 'etc', 'apps', 'phpmyadmin'));
    expect(File(p.join(directory, 'index.php')).existsSync(), isTrue);
    final detected = StackLayout.detect(layout.root)!;
    expect(detected.phpMyAdminDirectory, directory);
    expect(detected.phpMyAdminUrl, 'http://127.0.0.1/phpmyadmin/');

    final alias = File(
      p.join(layout.root, 'etc', 'apache2', 'alias', 'phpmyadmin.conf'),
    ).readAsStringSync();
    expect(alias, contains('Alias /phpmyadmin'));
    expect(alias, contains('${directory.replaceAll('\\', '/')}/'));
    expect(alias, contains('Require all granted'));
  });
}
