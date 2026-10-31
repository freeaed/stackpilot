import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_mover.dart';

void main() {
  late Directory temp;
  late String source;
  late String target;
  late String apacheDirectory;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_move_');
    source = p.join(temp.path, 'StackPilot_stacks', 'default');
    target = p.join(temp.path, 'D', 'stacks', 'default');

    final layout = StackBootstrap.create(root: source);
    apacheDirectory = p.join(layout.root, 'bin', 'apache', 'httpd-2.4');
    Directory(p.join(apacheDirectory, 'bin')).createSync(recursive: true);
    File(
      p.join(apacheDirectory, 'bin', 'httpd.exe'),
    ).writeAsStringSync('stub');

    final slashSource = source.replaceAll(r'\', '/');
    File(p.join(apacheDirectory, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'Define SRVROOT "$slashSource/bin/apache/httpd-2.4"\r\n'
        'DocumentRoot "$slashSource/www"\r\n'
        'ErrorLog "$slashSource/logs/default-error.log"\r\n'
        'LoadModule php_module "$slashSource/bin/php/php.exe"\r\n',
      );
    File(
      p.join(layout.root, 'bin', 'stackpilot.cmd'),
    ).writeAsStringSync('SET "PATH=$source\\bin\\php;%PATH%"\r\n');
    File(
      p.join(layout.root, 'etc', 'apache2', 'alias', 'phpmyadmin.conf'),
    ).writeAsStringSync(
      'Alias /phpmyadmin "$slashSource/etc/apps/phpmyadmin/"\r\n',
    );
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('copies the stack and rewrites every generated config', () {
    final result = StackMover.move(sourceRoot: source, targetRoot: target);

    expect(result.clean, isTrue, reason: result.leftovers.join('\n'));
    expect(result.layout.root, p.normalize(target));
    expect(result.rewritten, isNotEmpty);
    expect(Directory(source).existsSync(), isTrue);

    final newSlash = target.replaceAll(r'\', '/');
    final httpd = File(
      p.join(target, 'bin', 'apache', 'httpd-2.4', 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(httpd, contains('$newSlash/www'));
    expect(httpd.toLowerCase(), isNot(contains(source.toLowerCase())));
    expect(httpd, isNot(contains(':/tackPilot')));

    final launcher = File(
      p.join(target, 'bin', 'stackpilot.cmd'),
    ).readAsStringSync();
    expect(launcher, contains('SET "PATH=$target\\bin\\php'));

    final alias = File(
      p.join(target, 'etc', 'apache2', 'alias', 'phpmyadmin.conf'),
    ).readAsStringSync();
    expect(alias, contains('$newSlash/etc/apps/phpmyadmin/'));
  });

  test('leaves the document root inside the copied stack', () {
    final result = StackMover.move(sourceRoot: source, targetRoot: target);

    expect(
      result.layout.documentRoot.toLowerCase(),
      p.join(target, 'www').toLowerCase(),
    );
  });

  test('moves the stack on a background isolate', () async {
    final result = await StackMover.moveInBackground(
      sourceRoot: source,
      targetRoot: target,
    );

    expect(result.clean, isTrue);
    expect(result.layout.root, p.normalize(target));
    expect(Directory(source).existsSync(), isTrue);
  });

  test('refuses a target inside the source', () {
    expect(
      () => StackMover.move(
        sourceRoot: source,
        targetRoot: p.join(source, 'nested'),
      ),
      throwsA(isA<StackMoveException>()),
    );
  });

  test('refuses a target that already holds files', () {
    final occupied = p.join(temp.path, 'occupied');
    File(p.join(occupied, 'keep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('data');

    expect(
      () => StackMover.move(sourceRoot: source, targetRoot: occupied),
      throwsA(isA<StackMoveException>()),
    );
  });
}
