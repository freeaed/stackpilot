import 'dart:convert';
import 'dart:io';

import 'service_processes.dart';

/// The program that is listening on a port.
class PortOwner {
  const PortOwner({
    required this.port,
    required this.pid,
    this.name,
    this.executablePath,
  });

  final int port;
  final int pid;
  final String? name;
  final String? executablePath;

  /// `httpd.exe (C:\...)` or `PID 1234`.
  String get description {
    final app = (name == null || name!.trim().isEmpty) ? 'PID $pid' : name!;
    final path = executablePath;
    return path == null || path.isEmpty ? app : '$app ($path)';
  }
}

typedef PortCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

typedef PortProcessResolver = Future<InspectedProcess?> Function(int pid);

/// Finds the process listening on [port] through `netstat -ano` + CIM.
///
/// Returns null when nothing listens, or when the lookup itself is not
/// available (non-Windows, permissions). The caller uses it only for a
/// message, so a missing answer is not an error.
Future<PortOwner?> findPortOwner(
  int port, {
  PortCommandRunner? run,
  PortProcessResolver? resolve,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (!Platform.isWindows) {
    return null;
  }
  final runner = run ?? (executable, arguments) => Process.run(executable, arguments);
  try {
    final result = await runner('netstat', [
      '-ano',
      '-p',
      'tcp',
    ]).timeout(timeout);
    final pid = parseListeningPid(result.stdout.toString(), port);
    if (pid == null) {
      return null;
    }
    final process = await (resolve ?? _resolveProcess)(pid);
    return PortOwner(
      port: port,
      pid: pid,
      name: process?.name,
      executablePath: process?.executablePath,
    );
  } on Object {
    return null;
  }
}

/// Parses the PID listening on [port] from `netstat -ano` output.
int? parseListeningPid(String output, int port) {
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 5) {
      continue;
    }
    if (parts[0].toUpperCase() != 'TCP' ||
        parts[3].toUpperCase() != 'LISTENING') {
      continue;
    }
    final local = parts[1];
    final match = RegExp(r':(\d+)$').firstMatch(local);
    if (match != null && int.tryParse(match.group(1)!) == port) {
      return int.tryParse(parts[4]);
    }
  }
  return null;
}

Future<InspectedProcess?> _resolveProcess(int pid) async {
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-CimInstance Win32_Process -Filter "ProcessId = $pid" | '
          'Select-Object ProcessId,Name,ExecutablePath | '
          'ConvertTo-Json -Compress',
    ]);
    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final name = decoded['Name'];
    final path = decoded['ExecutablePath'];
    return InspectedProcess(
      pid: pid,
      name: name is String ? name : '',
      executablePath: path is String ? path : '',
    );
  } on Object {
    return null;
  }
}
