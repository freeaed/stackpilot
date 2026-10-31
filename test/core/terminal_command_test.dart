import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/terminal.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late String documentRoot;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_terminal_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
    documentRoot = layout.documentRoot;

    final php = p.join(
      layout.root,
      'bin',
      'php',
      'php-8.3.30',
    );
    File(p.join(php, 'php.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(layout.root, 'usr', 'profile', 'default.ini'))
        .writeAsStringSync('[php]\r\nVersion=php-8.3.30\r\n');
    layout = StackLayout.detect(layout.root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  TerminalLauncher launcherFor(
    TerminalShell shell, {
    bool windowsTerminalAvailable = false,
    List<TerminalCommand>? opened,
  }) {
    return TerminalLauncher(
      layout: layout,
      editor: StackEditor(layout),
      shell: shell,
      windowsTerminalAvailable: windowsTerminalAvailable,
      start: (command) async => opened?.add(command),
    );
  }

  test('command prompt starts a new console with the stack launcher', () async {
    final opened = <TerminalCommand>[];
    await launcherFor(
      TerminalShell.cmd,
      opened: opened,
    ).open();

    final command = opened.single;
    expect(command.executable, 'cmd.exe');
    expect(command.shell, TerminalShell.cmd);
    expect(command.arguments.take(5), [
      '/c',
      'start',
      '"StackPilot"',
      '/D',
      documentRoot,
    ]);
    expect(command.arguments[5], 'cmd.exe');
    expect(command.arguments[6], '/k');
    expect(command.arguments.last, endsWith('stackpilot.cmd'));
    expect(command.workingDirectory, layout.root);
  });

  test('automatic uses the command prompt when Windows Terminal is absent', () async {
    final opened = <TerminalCommand>[];
    await launcherFor(
      TerminalShell.auto,
      windowsTerminalAvailable: false,
      opened: opened,
    ).open();

    expect(opened.single.shell, TerminalShell.cmd);
  });

  test('automatic uses Windows Terminal when it is installed', () async {
    final opened = <TerminalCommand>[];
    await launcherFor(
      TerminalShell.auto,
      windowsTerminalAvailable: true,
      opened: opened,
    ).open();

    final command = opened.single;
    expect(command.shell, TerminalShell.windowsTerminal);
    expect(command.executable, 'wt.exe');
    expect(command.arguments.take(3), ['-d', documentRoot, 'cmd.exe']);
    expect(command.arguments[3], '/k');
    expect(command.arguments.last, endsWith('stackpilot.cmd'));
  });

  test('PowerShell runs the generated .ps1 launcher', () async {
    final opened = <TerminalCommand>[];
    await launcherFor(
      TerminalShell.powershell,
      opened: opened,
    ).open();

    final command = opened.single;
    expect(command.executable, 'cmd.exe');
    expect(command.arguments, contains('powershell.exe'));
    expect(command.arguments, contains('-NoExit'));
    expect(command.arguments, contains('-Command'));
    final script = command.arguments.last;
    expect(script, startsWith(". '"));
    expect(script, contains('stackpilot.ps1'));
    expect(
      File(p.join(layout.root, 'bin', 'stackpilot.ps1')).existsSync(),
      isTrue,
    );
  });

  test('quotes a launcher path that contains spaces', () async {
    final spaced = StackBootstrap.create(
      root: p.join(temp.path, 'A stack with spaces'),
    );
    final editor = StackEditor(spaced);
    final command = TerminalLauncher(
      layout: spaced,
      editor: editor,
      shell: TerminalShell.cmd,
      windowsTerminalAvailable: false,
      start: (_) async {},
    ).build(
      directory: spaced.documentRoot,
      shell: TerminalShell.cmd,
      launcherPath: p.join(spaced.root, 'bin', 'stackpilot.cmd'),
      powerShellPath: p.join(spaced.root, 'bin', 'stackpilot.ps1'),
    );

    expect(command.arguments.last, startsWith('"'));
    expect(command.arguments.last, endsWith('stackpilot.cmd"'));
  });

  test('opens in the requested project directory', () async {
    final project = Directory(p.join(documentRoot, 'blog'))..createSync();
    final opened = <TerminalCommand>[];
    await launcherFor(
      TerminalShell.cmd,
      opened: opened,
    ).open(directory: project.path);

    expect(opened.single.arguments[4], project.path);
  });
}
