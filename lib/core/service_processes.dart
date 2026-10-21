import 'dart:convert';
import 'dart:io';

class InspectedProcess {
  const InspectedProcess({
    required this.pid,
    required this.name,
    required this.executablePath,
  });

  final int pid;
  final String name;
  final String executablePath;
}

abstract class ProcessInspector {
  Future<List<InspectedProcess>> inspect();

  Future<bool> isAlive(int pid);

  Future<InspectedProcess?> find(int pid);
}

/// Reads service processes through CIM so paths, not just names, are checked.
class WindowsProcessInspector implements ProcessInspector {
  const WindowsProcessInspector({this.timeout = const Duration(seconds: 8)});

  static const _script = r'''
$names = @('httpd.exe','nginx.exe','mysqld.exe','redis-server.exe','mailpit.exe','memcached.exe');
Get-CimInstance Win32_Process |
  Where-Object { $names -contains $_.Name } |
  Select-Object ProcessId, Name, ExecutablePath |
  ConvertTo-Json -Compress
''';

  final Duration timeout;

  @override
  Future<List<InspectedProcess>> inspect() async {
    if (!Platform.isWindows) {
      return const [];
    }

    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      _script,
    ]).timeout(timeout);

    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const [],
        'Could not list service processes.',
        result.exitCode,
      );
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return const [];
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(output);
    } on FormatException {
      throw ProcessException(
        'powershell.exe',
        const [],
        'Unexpected service process output.',
      );
    }

    final items = decoded is List ? decoded : [decoded];
    final processes = <InspectedProcess>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final pid = item['ProcessId'];
      final path = item['ExecutablePath'];
      if (pid is! int || path is! String || path.isEmpty) {
        continue;
      }
      processes.add(
        InspectedProcess(
          pid: pid,
          name: item['Name'] is String ? item['Name'] as String : '',
          executablePath: path,
        ),
      );
    }
    return processes;
  }

  @override
  Future<bool> isAlive(int pid) async {
    if (!Platform.isWindows) {
      return false;
    }
    final result = await Process.run('tasklist.exe', [
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ]);
    return result.exitCode == 0 && result.stdout.toString().contains('"$pid"');
  }

  @override
  Future<InspectedProcess?> find(int pid) async {
    for (final process in await inspect()) {
      if (process.pid == pid) {
        return process;
      }
    }
    return null;
  }
}
