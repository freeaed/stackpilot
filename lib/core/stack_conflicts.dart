import 'dart:convert';
import 'dart:io';

/// A process that can rewrite this stack's configuration behind StackPilot.
class StackConflict {
  const StackConflict({
    required this.pid,
    required this.name,
    required this.executablePath,
  });

  final int pid;
  final String name;
  final String executablePath;
}

typedef ConflictCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Finds a running `Laragon.exe`.
///
/// Laragon rewrites the Apache and MySQL configs of the stack it manages, so a
/// running instance can undo StackPilot's changes while both tools fight over
/// the same files. StackPilot only warns; it never kills Laragon.
Future<List<StackConflict>> findLaragonProcesses({
  ConflictCommandRunner? run,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (!Platform.isWindows) {
    return const [];
  }
  final runner = run ?? (executable, arguments) => Process.run(executable, arguments);
  try {
    final result = await runner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Get-CimInstance Win32_Process -Filter \"Name = 'laragon.exe'\" | "
          'Select-Object ProcessId,Name,ExecutablePath | '
          'ConvertTo-Json -Compress',
    ]).timeout(timeout);
    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(output);
    final items = decoded is List ? decoded : [decoded];
    final conflicts = <StackConflict>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final pid = item['ProcessId'];
      final name = item['Name'];
      final path = item['ExecutablePath'];
      if (pid is! int) {
        continue;
      }
      conflicts.add(
        StackConflict(
          pid: pid,
          name: name is String ? name : 'laragon.exe',
          executablePath: path is String ? path : '',
        ),
      );
    }
    return conflicts;
  } on Object {
    return const [];
  }
}
