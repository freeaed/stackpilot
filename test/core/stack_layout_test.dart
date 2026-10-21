import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_stack_');
    root = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void createFile(String relativePath) {
    File(p.join(root, relativePath))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }

  void createStack() {
    createFile(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    createFile(r'bin\nginx\nginx-1.28.2\nginx.exe');
    createFile(r'bin\mysql\mysql-8.4.3\bin\mysqld.exe');
    createFile(r'bin\php\php-8.3.30\php.exe');
    createFile(r'bin\php\php-8.5.11\php.exe');
    createFile(r'bin\nodejs\node-v22\node.exe');
    createFile(r'bin\redis\redis-x64-5.0.14.1\redis-server.exe');
    createFile(r'bin\mailpit\1.22.3\mailpit.exe');

    File(p.join(root, 'usr', 'laragon.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[preferences]
AutoVirtualHosts=-1
DataDir=$root\\data
DocumentRootList=$root\\www|

[apache]
Use=-1
DocumentRoot=$root\\www

[mysql]
Use=-1
Port=3307

[nginx]
Use=0

[mailpit]
Use=-1
''');

    final path = [
      r'bin\php\php-8.3.30',
      r'bin\apache\httpd-2.4.66\bin',
      r'bin\mysql\mysql-8.4.3\bin',
      r'bin\nginx\nginx-1.28.2',
      r'bin\nodejs\node-v22',
      r'bin\redis\redis-x64-5.0.14.1',
    ].map((entry) => p.join(root, entry)).join(';');

    File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '@SET "LARAGON_ROOT=$root\\\\" && SET "PATH=$path;%PATH%;"',
      );

    File(p.join(root, 'usr', 'profile', 'default.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[mailpit]
Version=1.22.3
''');
  }

  test('detects a Laragon-compatible stack and its active versions', () {
    createStack();

    final layout = StackLayout.detect(root);

    expect(layout, isNotNull);
    expect(layout!.documentRoot, p.join(root, 'www'));
    expect(layout.dataDirectory, p.join(root, 'data'));
    expect(layout.mysqlPort, 3307);
    expect(layout.autoVirtualHosts, isTrue);
    expect(layout.serviceEnabled(StackComponent.apache), isTrue);
    expect(layout.serviceEnabled(StackComponent.nginx), isFalse);
    expect(layout.serviceEnabled(StackComponent.mailpit), isTrue);

    expect(
      layout
          .installedVersions(StackComponent.php)
          .map((install) => install.version),
      ['php-8.3.30', 'php-8.5.11'],
    );
    expect(layout.activeVersion(StackComponent.php)?.version, 'php-8.3.30');
    expect(
      layout.activeVersion(StackComponent.apache)?.version,
      'httpd-2.4.66',
    );
    expect(layout.activeVersion(StackComponent.nodejs)?.version, 'node-v22');
    expect(layout.activeVersion(StackComponent.mailpit)?.version, '1.22.3');
  });

  test('prefers the profile selection over the launcher PATH', () {
    createStack();
    File(p.join(root, 'usr', 'profile', 'default.ini')).writeAsStringSync('''
[php]
Version=php-8.5.11
''');

    final layout = StackLayout.detect(root);

    expect(layout, isNotNull);
    expect(layout!.activeVersion(StackComponent.php)?.version, 'php-8.5.11');
    expect(
      layout.activeVersion(StackComponent.apache)?.version,
      'httpd-2.4.66',
    );
  });

  test('falls back to the version stored in laragon.ini', () {
    createStack();
    File(p.join(root, 'usr', 'profile', 'default.ini')).deleteSync();
    final config = File(p.join(root, 'usr', 'laragon.ini'));
    config.writeAsStringSync(
      '${config.readAsStringSync()}\n[php]\nVersion=php-8.5.11\n',
    );

    final layout = StackLayout.detect(root);

    expect(layout, isNotNull);
    expect(layout!.activeVersion(StackComponent.php)?.version, 'php-8.5.11');
  });

  test('returns null when the directory is not a stack root', () {
    expect(StackLayout.detect(p.join(root, 'missing')), isNull);
  });

  test('leaves active versions unknown without a Laragon launcher', () {
    createStack();
    File(p.join(root, 'bin', 'laragon', 'laragon.cmd')).deleteSync();

    final layout = StackLayout.detect(root);

    expect(layout, isNotNull);
    expect(layout!.activeVersion(StackComponent.php), isNull);
    expect(layout.installedVersions(StackComponent.php), hasLength(2));
  });
}
