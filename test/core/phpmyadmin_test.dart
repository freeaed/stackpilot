import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late String root;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_pma_');
    root = temp.path;

    void createFile(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    createFile(r'bin\mysql\mysql-8.4.3\bin\mysqld.exe');
    createFile(r'usr\laragon.ini', '''
[preferences]
DocumentRootList=$root\\www|

[mysql]
Use=-1
Port=3307

[apache]
Use=-1
DocumentRoot=$root\\www
''');
    Directory(p.join(root, 'www')).createSync(recursive: true);

    layout = StackLayout.detect(root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('finds phpMyAdmin in the document root', () {
    File(p.join(root, 'www', 'phpmyadmin', 'index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');
    File(p.join(root, 'www', 'phpmyadmin', 'sql.php')).writeAsStringSync('');

    final detected = StackLayout.detect(root)!;

    expect(detected.phpMyAdminDirectory, p.join(root, 'www', 'phpmyadmin'));
    expect(detected.phpMyAdminUrl, 'http://localhost/phpmyadmin/');
  });

  test('reports no phpMyAdmin when the web root has none', () {
    expect(layout.phpMyAdminDirectory, isNull);
    expect(layout.phpMyAdminUrl, isNull);
  });

  test('installs phpMyAdmin from a ZIP with a Laragon-style config', () async {
    final source = Directory(
      p.join(temp.path, 'downloads', 'phpMyAdmin-5.2.2-all-languages'),
    )..createSync(recursive: true);
    File(p.join(source.path, 'index.php')).writeAsStringSync('<?php');
    File(p.join(source.path, 'sql.php')).writeAsStringSync('');
    File(p.join(source.path, 'README')).writeAsStringSync('phpMyAdmin');

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

    final directory = await StackEditor(
      layout,
    ).installPhpMyAdminArchive(archive);

    expect(directory, p.join(root, 'www', 'phpmyadmin'));
    expect(File(p.join(directory, 'index.php')).existsSync(), isTrue);
    expect(File(p.join(directory, 'README')).existsSync(), isTrue);

    final config = File(p.join(directory, 'config.inc.php')).readAsStringSync();
    expect(config, contains(r"$cfg['Servers'][$i]['port'] = '3307';"));
    expect(config, contains(r"$cfg['Servers'][$i]['AllowNoPassword'] = true;"));
    expect(RegExp(r"blowfish_secret'\] = '[0-9a-f]{32}'").hasMatch(config), isTrue);

    expect(StackLayout.detect(root)!.phpMyAdminUrl, 'http://localhost/phpmyadmin/');
  });

  test('refuses an archive without a phpMyAdmin folder', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'something'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'readme.txt')).writeAsStringSync('nothing');

    final archive = p.join(temp.path, 'other.zip');
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -LiteralPath '
          "'${source.path.replaceAll("'", "''")}' "
          "-DestinationPath '$archive' -Force",
    ]);
    expect(compress.exitCode, 0, reason: compress.stderr.toString());

    await expectLater(
      StackEditor(layout).installPhpMyAdminArchive(archive),
      throwsA(isA<StackEditException>()),
    );
    expect(Directory(p.join(root, 'www', 'phpmyadmin')).existsSync(), isFalse);
  });

  test('refuses to overwrite an existing phpMyAdmin folder', () async {
    File(p.join(root, 'www', 'phpmyadmin', 'index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');

    final source = Directory(p.join(temp.path, 'downloads', 'phpMyAdmin'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'index.php')).writeAsStringSync('<?php');
    File(p.join(source.path, 'sql.php')).writeAsStringSync('');
    final archive = p.join(temp.path, 'phpmyadmin-again.zip');
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -LiteralPath '
          "'${source.path.replaceAll("'", "''")}' "
          "-DestinationPath '$archive' -Force",
    ]);
    expect(compress.exitCode, 0, reason: compress.stderr.toString());

    await expectLater(
      StackEditor(layout).installPhpMyAdminArchive(archive),
      throwsA(
        isA<StackEditException>().having(
          (error) => error.message,
          'message',
          contains('already installed'),
        ),
      ),
    );
  });
}
