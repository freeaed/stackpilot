import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/ini.dart';
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

  /// Builds a phpMyAdmin-shaped source folder with the nested class tree that
  /// broke earlier builds (`libraries/classes/Index.php`).
  Directory phpMyAdminSource(String name, {String? parent}) {
    final source = Directory(p.join(parent ?? temp.path, 'downloads', name))
      ..createSync(recursive: true);
    File(p.join(source.path, 'index.php')).writeAsStringSync('<?php');
    File(p.join(source.path, 'README')).writeAsStringSync('phpMyAdmin');
    File(p.join(source.path, 'libraries', 'classes', 'Index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php class Index {}');
    File(p.join(source.path, 'libraries', 'classes', 'Sql.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php class Sql {}');
    File(p.join(source.path, 'themes', 'pmahomme', 'theme.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    return source;
  }

  Future<String> zipFolder(Directory folder, String archiveName) async {
    final archive = p.join(temp.path, archiveName);
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -LiteralPath '
          "'${folder.path.replaceAll("'", "''")}' "
          "-DestinationPath '$archive' -Force",
    ]);
    expect(compress.exitCode, 0, reason: compress.stderr.toString());
    return archive;
  }

  test('finds phpMyAdmin in the document root', () {
    File(p.join(root, 'www', 'phpmyadmin', 'index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');
    File(p.join(root, 'www', 'phpmyadmin', 'libraries', 'classes', 'Core.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(root, 'www', 'phpmyadmin', 'themes', 'theme.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final detected = StackLayout.detect(root)!;

    expect(detected.phpMyAdminDirectory, p.join(root, 'www', 'phpmyadmin'));
    expect(detected.phpMyAdminUrl, 'http://127.0.0.1/phpmyadmin/');
  });

  test('does not mistake the libraries/classes folder for phpMyAdmin', () {
    final classes = Directory(
      p.join(root, 'www', 'phpmyadmin', 'libraries', 'classes'),
    )..createSync(recursive: true);
    File(p.join(classes.path, 'Index.php')).writeAsStringSync('<?php');
    File(p.join(classes.path, 'Sql.php')).writeAsStringSync('<?php');

    final detected = StackLayout.detect(root)!;

    expect(detected.phpMyAdminDirectory, isNull);
    expect(detected.phpMyAdminUrl, isNull);
  });

  test('reports no phpMyAdmin when the web root has none', () {
    expect(layout.phpMyAdminDirectory, isNull);
    expect(layout.phpMyAdminUrl, isNull);
  });

  test('installs phpMyAdmin from a ZIP with a Laragon-style config', () async {
    final source = phpMyAdminSource('phpMyAdmin-5.2.2-all-languages');
    final archive = await zipFolder(source, 'phpmyadmin.zip');

    final directory = await StackEditor(layout)
        .installPhpMyAdminArchive(archive);

    expect(directory, p.join(root, 'etc', 'apps', 'phpmyadmin'));
    expect(File(p.join(directory, 'index.php')).existsSync(), isTrue);
    expect(File(p.join(directory, 'README')).existsSync(), isTrue);
    expect(
      File(p.join(directory, 'libraries', 'classes', 'Index.php')).existsSync(),
      isTrue,
    );

    final config = File(p.join(directory, 'config.inc.php')).readAsStringSync();
    expect(config, contains(r"$cfg['Servers'][$i]['port'] = '3307';"));
    expect(config, contains(r"$cfg['Servers'][$i]['AllowNoPassword'] = true;"));
    expect(
      RegExp(r"blowfish_secret'\] = '[0-9a-f]{32}'").hasMatch(config),
      isTrue,
    );

    expect(
      StackLayout.detect(root)!.phpMyAdminUrl,
      'http://127.0.0.1/phpmyadmin/',
    );
    expect(
      Directory(p.join(root, 'www', 'phpmyadmin')).existsSync(),
      isFalse,
      reason: 'phpMyAdmin must not live in the document root',
    );
  });

  test('points the Apache alias at the installed copy', () async {
    final aliasDirectory = Directory(p.join(root, 'etc', 'apache2', 'alias'))
      ..createSync(recursive: true);
    final vendor = File(p.join(aliasDirectory.path, 'phpmyadmin.conf'));
    vendor.writeAsStringSync('''
Alias /phpmyadmin "C:/missing/etc/apps/phpMyAdmin/"

<Directory "C:/missing/etc/apps/phpMyAdmin/">
    Options Indexes FollowSymLinks
    AllowOverride all
    Require local
</Directory>
''');

    final source = phpMyAdminSource('phpMyAdmin-5.2.2-all-languages');
    final archive = await zipFolder(source, 'phpmyadmin-alias.zip');
    final directory = await StackEditor(layout)
        .installPhpMyAdminArchive(archive);

    final alias = File(p.join(aliasDirectory.path, 'phpmyadmin.conf'))
        .readAsStringSync();
    final target = directory.replaceAll('\\', '/');
    expect(alias, contains('Alias /phpmyadmin "$target/"'));
    expect(alias, isNot(contains('C:/missing')));
    expect(alias, contains('<Directory "$target/">'));
    expect(alias, contains('DirectoryIndex index.php'));
    expect(alias, contains('Require all granted'));
    expect(alias, isNot(contains('Require local')));
    expect(vendor.existsSync(), isTrue);
    expect(
      File('${vendor.path}.stackpilot.bak').readAsStringSync(),
      contains('C:/missing'),
    );
  });

  test('replaces the libraries/classes folder left by older builds', () async {
    final broken = Directory(p.join(root, 'www', 'phpmyadmin'))
      ..createSync(recursive: true);
    File(p.join(broken.path, 'Index.php')).writeAsStringSync('<?php');
    File(p.join(broken.path, 'Sql.php')).writeAsStringSync('<?php');
    File(p.join(broken.path, 'config.inc.php')).writeAsStringSync('<?php');

    expect(StackLayout.detect(root)!.phpMyAdminDirectory, isNull);

    final source = phpMyAdminSource('phpMyAdmin-5.2.2-all-languages');
    final archive = await zipFolder(source, 'phpmyadmin-repair.zip');

    final directory = await StackEditor(layout)
        .installPhpMyAdminArchive(archive);

    final names = Directory(directory)
        .listSync()
        .map((entity) => p.basename(entity.path))
        .toSet();
    expect(names.contains('Index.php'), isFalse);
    expect(names.contains('index.php'), isTrue);
    expect(names.contains('libraries'), isTrue);
    expect(layout.phpMyAdminDirectory, directory);
  });

  test('refuses an archive without a phpMyAdmin folder', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'something'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'readme.txt')).writeAsStringSync('nothing');
    final archive = await zipFolder(source, 'other.zip');

    await expectLater(
      StackEditor(layout).installPhpMyAdminArchive(archive),
      throwsA(isA<StackEditException>()),
    );
    expect(Directory(p.join(root, 'www', 'phpmyadmin')).existsSync(), isFalse);
  });

  test('refuses to overwrite a complete phpMyAdmin install', () async {
    File(
      p.join(root, 'etc', 'apps', 'phpmyadmin', 'index.php'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');
    File(
      p.join(root, 'etc', 'apps', 'phpmyadmin', 'libraries', 'classes', 'Core.php'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(root, 'etc', 'apps', 'phpmyadmin', 'themes', 'theme.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final source = phpMyAdminSource('phpMyAdmin');
    final archive = await zipFolder(source, 'phpmyadmin-again.zip');

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

  test('serves the installed copy through the alias and mod_php', () async {
    File(p.join(root, 'etc', 'apps', 'phpmyadmin', 'index.php'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<?php');
    File(
      p.join(root, 'etc', 'apps', 'phpmyadmin', 'libraries', 'classes', 'Core.php'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(root, 'etc', 'apps', 'phpmyadmin', 'themes', 'theme.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final php = p.join(root, 'bin', 'php', 'php-8.3.30');
    File(p.join(php, 'php.exe')).createSync(recursive: true);
    File(p.join(php, 'php8apache2_4.dll')).createSync(recursive: true);
    final marker = File(p.join(root, 'usr', 'laragon.ini'));
    marker.writeAsStringSync(
      '${marker.readAsStringSync()}\n[php]\nVersion=php-8.3.30\n',
    );

    final editor = StackEditor(StackLayout.detect(root)!);
    final serving = editor.ensurePhpMyAdminServing();

    expect(serving, isNotNull);
    expect(serving!.url, 'http://127.0.0.1/phpmyadmin/');
    expect(serving.changed, isTrue);

    final modPhp = File(p.join(root, 'etc', 'apache2', 'mod_php.conf'));
    expect(modPhp.existsSync(), isTrue);
    expect(modPhp.readAsStringSync(), contains(php.replaceAll('\\', '/')));

    final alias = File(
      p.join(root, 'etc', 'apache2', 'alias', 'phpmyadmin.conf'),
    ).readAsStringSync();
    expect(alias, contains('Require all granted'));
  });

  test('rewrites the config when the MySQL port changes', () async {
    final source = phpMyAdminSource('phpMyAdmin-5.2.3');
    final archive = await zipFolder(source, 'phpmyadmin-port.zip');
    final directory = await StackEditor(
      layout,
    ).installPhpMyAdminArchive(archive);
    final config = File(p.join(directory, 'config.inc.php'));

    expect(config.readAsStringSync(), contains("'port'] = '3307';"));

    final marker = File(layout.markerPath);
    final editor = IniEditor.parse(marker.readAsStringSync())
      ..setValue('mysql', 'Port', '3308');
    marker.writeAsStringSync(editor.serialize());

    StackEditor(
      StackLayout.detect(root)!,
    ).ensurePhpMyAdminServing();

    expect(config.readAsStringSync(), contains("'port'] = '3308';"));
  });

  test('validates the Apache config with httpd -t', () async {
    final apache = p.join(root, 'bin', 'apache', 'httpd-2.4.69');
    File(p.join(apache, 'bin', 'httpd.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(apache, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('Listen 127.0.0.1:80\n');
    final marker = File(p.join(root, 'usr', 'laragon.ini'));
    marker.writeAsStringSync(
      '${marker.readAsStringSync()}\n[apache]\nVersion=httpd-2.4.69\n',
    );

    final editor = StackEditor(StackLayout.detect(root)!);

    final ok = await editor.verifyApacheConfig(
      run: (executable, arguments, workingDirectory) async {
        expect(arguments, contains('-t'));
        return ProcessResult(0, 0, 'Syntax OK', '');
      },
    );
    expect(ok.ok, isTrue);
    expect(ok.output, 'Syntax OK');

    final bad = await editor.verifyApacheConfig(
      run: (executable, arguments, workingDirectory) async =>
          ProcessResult(0, 1, '', 'AH00526: bad config'),
    );
    expect(bad.ok, isFalse);
    expect(bad.output, contains('AH00526'));
  });
}
