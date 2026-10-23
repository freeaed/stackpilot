import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/ini.dart';
import 'package:stackpilot/core/stack_adoption.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_adopt_');
    root = p.join(temp.path, 'laragon');

    void createFile(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    createFile(r'usr\laragon.ini', '''
[preferences]
AutoVirtualHosts=-1
DataDir=$root\\data
DocumentRootList=$root\\www|

[apache]
Use=-1
SSLEnabled=0
DocumentRoot=$root\\www

[php]
Version=php-8.3.30

[mysql]
Use=-1
Port=3306
''');
    createFile(
      r'usr\profile\default.ini',
      '[php]\nVersion=php-8.3.30\n'
          '\n[apache]\nVersion=httpd-2.4.69\n',
    );
    createFile(r'www\index.php', '<?php');

    createFile(r'bin\php\php-8.3.30\php.exe');
    createFile(r'bin\php\php-8.3.30\php.ini', '[PHP]\nmemory_limit=128M\n');
    createFile(r'bin\php\php-8.4.1\php.exe');
    createFile(r'bin\php\php-8.4.1\php.ini', '[PHP]\nmemory_limit=256M\n');

    createFile(r'bin\apache\httpd-2.4.69\bin\httpd.exe');
    createFile(
      r'bin\apache\httpd-2.4.69\conf\httpd.conf',
      'ServerRoot "C:/laragon/bin/apache/httpd-2.4.69"\nListen 80\n',
    );
    createFile(r'bin\apache\httpd-2.4.69\modules\mod_mpm_winnt.so');
    createFile(r'bin\apache\httpd-2.4.69\modules\mod_dir.so');
    createFile(
      r'etc\apache2\mod_php.conf',
      '# PHP for Apache\n'
          'LoadModule php_module "C:/old/php8apache2_4.dll"\n',
    );
    Directory(p.join(root, r'etc\apache2\sites-enabled')).createSync(
      recursive: true,
    );
    createFile(
      r'bin\laragon\laragon.cmd',
      '@SET "PATH=$root\\bin\\php\\php-8.3.30;%PATH%"',
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('adopts a Laragon stack in place', () {
    final result = StackAdoption.adopt(root, now: DateTime.utc(2026, 10, 23));

    expect(result.layout.flavor, StackFlavor.stackpilot);
    expect(result.warnings, isEmpty);

    final marker = File(p.join(root, 'usr', 'stackpilot.ini'));
    expect(marker.existsSync(), isTrue);
    final parsed = IniDocument.parse(marker.readAsStringSync());
    expect(parsed.value('stackpilot', 'AdoptedFrom'), 'laragon');
    expect(
      parsed.value('stackpilot', 'AdoptedAt'),
      '2026-10-23T00:00:00.000Z',
    );

    // Laragon can still open the folder.
    expect(File(p.join(root, 'usr', 'laragon.ini')).existsSync(), isTrue);

    final launcher = File(p.join(root, 'bin', 'stackpilot.cmd'));
    expect(launcher.existsSync(), isTrue);
    expect(launcher.readAsStringSync(), contains('STACKPILOT_ROOT'));

    final apacheConfig = File(
      p.join(root, 'bin', 'apache', 'httpd-2.4.69', 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(apacheConfig, contains('StackPilot Apache configuration'));

    expect(
      result.layout.activeVersion(StackComponent.php)?.version,
      'php-8.3.30',
    );
    expect(
      result.layout.activeVersion(StackComponent.apache)?.version,
      'httpd-2.4.69',
    );
  });

  test('keeps versions that only the Laragon launcher knows', () {
    final profile = File(p.join(root, 'usr', 'profile', 'default.ini'));
    profile.writeAsStringSync(
      profile.readAsStringSync().replaceAll('Version=php-8.3.30\n', ''),
    );
    final marker = File(p.join(root, 'usr', 'laragon.ini'));
    marker.writeAsStringSync(
      marker.readAsStringSync().replaceAll('Version=php-8.3.30\n', ''),
    );

    final result = StackAdoption.adopt(root);

    expect(
      result.layout.activeVersion(StackComponent.php)?.version,
      'php-8.3.30',
    );
    expect(result.warnings.join('\n'), isNot(contains('Php')));
  });

  test('keeps both markers in sync after adoption', () {
    final result = StackAdoption.adopt(root);
    final php84 = result.layout
        .installedVersions(StackComponent.php)
        .firstWhere((install) => install.version == 'php-8.4.1');

    StackEditor(result.layout).selectVersion(StackComponent.php, php84);
    StackEditor(
      result.layout,
    ).setServiceEnabled(StackComponent.mysql, false);

    for (final name in ['stackpilot.ini', 'laragon.ini']) {
      final parsed = IniDocument.parse(
        File(p.join(root, 'usr', name)).readAsStringSync(),
      );
      expect(parsed.value('php', 'Version'), 'php-8.4.1');
      expect(parsed.value('mysql', 'Use'), '0');
    }
  });

  test('falls back to the newest installed version with a warning', () {
    File(p.join(root, 'usr', 'profile', 'default.ini'))
      ..deleteSync()
      ..createSync(recursive: true)
      ..writeAsStringSync('[stackpilot]\nLayoutVersion=1\n');
    final marker = File(p.join(root, 'usr', 'laragon.ini'));
    marker.writeAsStringSync(
      marker.readAsStringSync().replaceAll('Version=php-8.3.30\n', ''),
    );
    // Without a launcher PATH or marker version, Laragon has no active PHP.
    File(p.join(root, 'bin', 'laragon', 'laragon.cmd')).deleteSync();

    final result = StackAdoption.adopt(root);

    expect(
      result.layout.activeVersion(StackComponent.php)?.version,
      'php-8.4.1',
    );
    expect(result.warnings.join('\n'), contains('no active version'));
  });

  test('rejects a stack StackPilot already manages', () {
    final native = StackBootstrap.create(root: p.join(temp.path, 'native'));

    expect(
      () => StackAdoption.adopt(native.root),
      throwsA(
        isA<StackAdoptionException>().having(
          (error) => error.message,
          'message',
          contains('already managed'),
        ),
      ),
    );
  });
}
