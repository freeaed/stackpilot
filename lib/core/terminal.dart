import 'dart:io';

import 'app_log.dart';
import 'stack_editor.dart';
import 'stack_layout.dart';

/// Which terminal StackPilot opens.
enum TerminalShell {
  auto('auto', 'Automatic'),
  cmd('cmd', 'Command Prompt'),
  powershell('powershell', 'PowerShell'),
  windowsTerminal('windowsTerminal', 'Windows Terminal');

  const TerminalShell(this.id, this.label);

  final String id;
  final String label;

  static TerminalShell parse(String? value) {
    final normalized = value?.trim().toLowerCase();
    for (final shell in TerminalShell.values) {
      if (shell.id.toLowerCase() == normalized) {
        return shell;
      }
    }
    return TerminalShell.auto;
  }
}

/// The process that opens a terminal window.
class TerminalCommand {
  const TerminalCommand({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.shell,
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;

  /// The shell actually used after resolving [TerminalShell.auto].
  final TerminalShell shell;

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

typedef TerminalProcessStarter = Future<void> Function(TerminalCommand command);

/// Opens a terminal window with the stack's binaries on `PATH`.
///
/// A GUI process cannot simply start `cmd.exe`: Dart's normal mode gives the
/// child pipes but no console, and the detached mode uses `DETACHED_PROCESS`,
/// so `cmd.exe` exits immediately. `cmd /c start` asks Windows to create a new
/// console window for the launcher instead, which is what makes Terminal work.
class TerminalLauncher {
  TerminalLauncher({
    required this.layout,
    required this.editor,
    this.shell = TerminalShell.auto,
    this.windowsTerminalAvailable,
    TerminalProcessStarter? start,
  }) : _start = start ?? _defaultStart;

  final StackLayout layout;
  final StackEditor editor;
  final TerminalShell shell;

  /// Overrides `where wt.exe` detection; null runs the real check.
  final bool? windowsTerminalAvailable;

  final TerminalProcessStarter _start;

  /// Opens the terminal in [directory] (default: the document root).
  Future<void> open({String? directory}) async {
    final target = directory?.trim().isNotEmpty == true
        ? directory!.trim()
        : layout.documentRoot;
    final resolved = await _resolveShell();
    final launcher = editor.ensureLauncher();
    final command = build(
      directory: target,
      shell: resolved,
      launcherPath: launcher,
      powerShellPath: editor.powerShellLauncherPath,
    );
    AppLog.info('Opening a terminal: $command');
    await _start(command);
  }

  /// Builds the command line for [shell].
  TerminalCommand build({
    required String directory,
    required TerminalShell shell,
    required String launcherPath,
    required String powerShellPath,
  }) {
    final workingDirectory = layout.root;
    switch (shell) {
      case TerminalShell.windowsTerminal:
        return TerminalCommand(
          executable: 'wt.exe',
          arguments: [
            '-d',
            directory,
            'cmd.exe',
            '/k',
            _quote(launcherPath),
          ],
          workingDirectory: workingDirectory,
          shell: shell,
        );
      case TerminalShell.powershell:
        return TerminalCommand(
          executable: 'cmd.exe',
          arguments: [
            '/c',
            'start',
            '"StackPilot"',
            '/D',
            directory,
            'powershell.exe',
            '-NoExit',
            '-Command',
            ". '${powerShellPath.replaceAll("'", "''")}'",
          ],
          workingDirectory: workingDirectory,
          shell: shell,
        );
      case TerminalShell.cmd:
      case TerminalShell.auto:
        return TerminalCommand(
          executable: 'cmd.exe',
          arguments: [
            '/c',
            'start',
            '"StackPilot"',
            '/D',
            directory,
            'cmd.exe',
            '/k',
            _quote(launcherPath),
          ],
          workingDirectory: workingDirectory,
          shell: shell == TerminalShell.auto ? TerminalShell.cmd : shell,
        );
    }
  }

  Future<TerminalShell> _resolveShell() async {
    if (shell != TerminalShell.auto) {
      return shell;
    }
    final available =
        windowsTerminalAvailable ?? await detectWindowsTerminal();
    return available ? TerminalShell.windowsTerminal : TerminalShell.cmd;
  }

  /// True when `wt.exe` is on `PATH`.
  static Future<bool> detectWindowsTerminal() async {
    try {
      final result = await Process.run('where', ['wt.exe']);
      return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
    } on ProcessException {
      return false;
    }
  }

  static String _quote(String value) => value.contains(' ')
      ? '"$value"'
      : value;

  static Future<void> _defaultStart(TerminalCommand command) async {
    await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      mode: ProcessStartMode.detached,
    );
  }
}
