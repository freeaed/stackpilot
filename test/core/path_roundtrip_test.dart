import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/paths.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_settings.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late String apacheDirectory;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_paths_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'default'));

    apacheDirectory = p.join(layout.root, 'bin', 'apache', 'httpd-2.4');
    Directory(p.join(apacheDirectory, 'bin')).createSync(recursive: true);
    File(
      p.join(apacheDirectory, 'bin', 'httpd.exe'),
    ).writeAsStringSync('stub');

    File(p.join(layout.root, 'usr', 'profile', 'default.ini'))
        .writeAsStringSync(
          '[stackpilot]\r\nLayoutVersion=1\r\n\r\n[apache]\r\n'
          'Version=httpd-2.4\r\n',
        );

    final oldRoot = layout.documentRoot.replaceAll(r'\', '/');
    File(p.join(apacheDirectory, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('DocumentRoot "$oldRoot"\r\n');
    File(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled', '00-default.conf'),
    ).writeAsStringSync('    DocumentRoot "$oldRoot"\r\n');

    layout = StackLayout.detect(layout.root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('a path keeps its capital S through ini, httpd.conf and reload', () {
    const documentRoot = r'D:\StackPilot_stacks\www';

    StackEditor(layout).applySettings(
      StackSettings.load(layout).copyWith(
        documentRoot: documentRoot,
        dataDirectory: layout.dataDirectory,
      ),
    );

    final marker = File(
      p.join(layout.root, 'usr', 'stackpilot.ini'),
    ).readAsStringSync();
    expect(marker, contains('DocumentRoot=$documentRoot'));
    expect(marker, contains('DocumentRootList=$documentRoot|'));
    expect(marker, isNot(contains(r':\tackPilot')));
    expect(marker, isNot(contains(':/tackPilot')));

    final httpd = File(
      p.join(apacheDirectory, 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(httpd, contains('D:/StackPilot_stacks/www'));
    expect(httpd, isNot(contains(':/tackPilot')));

    final vhost = File(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled', '00-default.conf'),
    ).readAsStringSync();
    expect(vhost, contains('D:/StackPilot_stacks/www'));

    final reloaded = StackLayout.detect(layout.root)!;
    expect(reloaded.documentRoot, documentRoot);
  });

  test('normalizes slashes and quotes before writing', () {
    StackEditor(layout).applySettings(
      StackSettings.load(layout).copyWith(
        documentRoot: '  "D:/StackPilot_stacks/www/"  ',
        dataDirectory: layout.dataDirectory,
      ),
    );

    expect(
      StackLayout.detect(layout.root)!.documentRoot,
      normalizeWindowsPath(r'D:\StackPilot_stacks\www'),
    );
  });
}
