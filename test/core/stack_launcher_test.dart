import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late StackInstall php83;
  late StackInstall php84;
  late StackInstall apache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_launcher_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));

    php83 = _install(layout, StackComponent.php, 'php-8.3.30', 'php.exe');
    php84 = _install(layout, StackComponent.php, 'php-8.4.1', 'php.exe');
    apache = _install(
      layout,
      StackComponent.apache,
      'httpd-2.4.69',
      p.join('bin', 'httpd.exe'),
    );
    File(p.join(apache.directory, 'conf', 'openssl.cnf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(
      p.join(apache.directory, 'modules', 'mod_mpm_winnt.so'),
    ).createSync(recursive: true);
    File(p.join(apache.directory, 'conf', 'httpd.conf'))
        .writeAsStringSync('ServerRoot "C:/Apache24"\nListen 80\n');
    layout = StackLayout.detect(layout.root)!;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('generates a StackPilot launcher for its own stacks', () {
    StackEditor(layout).selectVersion(StackComponent.php, php83);

    final launcher = File(p.join(layout.root, 'bin', 'stackpilot.cmd'));
    expect(launcher.existsSync(), isTrue);
    expect(
      File(p.join(layout.root, 'bin', 'laragon', 'laragon.cmd')).existsSync(),
      isFalse,
    );

    final contents = launcher.readAsStringSync();
    expect(contents, contains('set "STACKPILOT_ROOT='));
    expect(contents, contains('set "PATH=${php83.directory};%PATH%"'));
    expect(contents, contains('if "%~1"==""'));
    expect(contents, isNot(contains(php84.directory)));
  });

  test('rewrites the launcher when the active version changes', () {
    final editor = StackEditor(layout);
    editor.selectVersion(StackComponent.php, php83);
    editor.selectVersion(StackComponent.php, php84);

    final contents = File(
      p.join(layout.root, 'bin', 'stackpilot.cmd'),
    ).readAsStringSync();
    expect(contents, contains(php84.directory));
    expect(contents, isNot(contains(php83.directory)));
  });

  test('puts Apache bin and OPENSSL_CONF on the launcher environment', () {
    StackEditor(layout).selectVersion(StackComponent.apache, apache);

    final contents = File(
      p.join(layout.root, 'bin', 'stackpilot.cmd'),
    ).readAsStringSync();
    expect(contents, contains(p.join(apache.directory, 'bin')));
    expect(
      contents,
      contains(
        'set "OPENSSL_CONF=${p.join(apache.directory, 'conf', 'openssl.cnf').replaceAll('\\', '/')}"',
      ),
    );
  });

  test('ensureLauncher recreates the launchers from the active versions', () {
    StackEditor(layout).selectVersion(StackComponent.php, php83);
    final launcher = File(p.join(layout.root, 'bin', 'stackpilot.cmd'));
    final script = File(p.join(layout.root, 'bin', 'stackpilot.ps1'));
    launcher.deleteSync();
    if (script.existsSync()) {
      script.deleteSync();
    }

    final path = StackEditor(layout).ensureLauncher();

    expect(path, launcher.path);
    expect(launcher.existsSync(), isTrue);
    expect(launcher.readAsStringSync(), contains(php83.directory));

    expect(script.existsSync(), isTrue);
    final contents = script.readAsStringSync();
    expect(contents, contains(r'$env:PATH'));
    expect(contents, contains(php83.directory));
    expect(contents, contains(r'$env:STACKPILOT_ROOT'));
  });

  test('ensureLauncher keeps a Laragon launcher and adds a PowerShell one', () {
    final root = p.join(temp.path, 'laragon');
    File(p.join(root, 'usr', 'laragon.ini')).createSync(recursive: true);
    Directory(p.join(root, 'bin')).createSync(recursive: true);
    final vendor = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
      ..createSync(recursive: true)
      ..writeAsStringSync('SET "PATH=C:\\laragon\\bin\\php;%PATH%"\r\n');
    final laragon = StackLayout.detect(root)!;
    final editor = StackEditor(laragon);

    final path = editor.ensureLauncher();

    expect(path, vendor.path);
    expect(vendor.readAsStringSync(), contains(r'C:\laragon'));
    expect(
      editor.powerShellLauncherPath,
      p.join(root, 'bin', 'laragon', 'laragon.ps1'),
    );
    expect(File(editor.powerShellLauncherPath).existsSync(), isTrue);
  });

  test('ensureLauncher creates one when a Laragon stack has none', () {
    final root = p.join(temp.path, 'laragon-empty');
    File(p.join(root, 'usr', 'laragon.ini')).createSync(recursive: true);
    Directory(p.join(root, 'bin')).createSync(recursive: true);
    final laragon = StackLayout.detect(root)!;
    final editor = StackEditor(laragon);

    final path = editor.ensureLauncher();

    expect(path, p.join(root, 'bin', 'laragon', 'laragon.cmd'));
    expect(File(path).readAsStringSync(), contains('@echo off'));
    expect(File(editor.powerShellLauncherPath).existsSync(), isTrue);
  });
}

StackInstall _install(
  StackLayout layout,
  StackComponent component,
  String version,
  String executable,
) {
  final directory = p.join(layout.root, 'bin', component.directoryName, version);
  File(p.join(directory, executable))
    ..createSync(recursive: true)
    ..writeAsStringSync('');
  return StackInstall(
    component: component,
    version: version,
    directory: directory,
    executablePath: p.join(directory, executable),
  );
}
