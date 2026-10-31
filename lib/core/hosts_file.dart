import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows hosts file that maps StackPilot site names to `127.0.0.1`.
///
/// Writing it normally needs administrator rights, so [writeHostsFile] keeps a
/// direct write as the fast path and falls back to a single elevated copy when
/// Windows denies it.
class HostsFile {
  const HostsFile(this.path);

  static const defaultPath = r'C:\Windows\System32\drivers\etc\hosts';

  static const blockStart =
      '# StackPilot virtual hosts - managed block, do not edit';
  static const blockEnd = '# End StackPilot virtual hosts';

  final String path;

  List<String> readLines() => readHostsLines(path);

  /// True when [host] already resolves to `127.0.0.1`, managed block or not.
  bool maps(String host) => hostsFileMaps(readLines(), host);

  /// Adds [hosts] to the managed block and writes the file.
  ///
  /// Returns the names that were actually added. [allowElevation] enables the
  /// UAC prompt used when the app does not run as administrator.
  Future<HostsUpdate> add(
    Iterable<String> hosts, {
    bool allowElevation = true,
  }) async {
    final lines = readLines();
    final document = HostsDocument.parse(lines);
    final pending = <String>[];
    for (final host in hosts) {
      final name = host.trim();
      if (name.isEmpty ||
          document.hasHost(name) ||
          hostsFileMaps(lines, name)) {
        continue;
      }
      pending.add(name);
    }

    if (pending.isEmpty) {
      return const HostsUpdate(written: true, added: []);
    }

    final result = await writeHostsFile(
      path,
      document.addHosts(pending).render(),
      allowElevation: allowElevation,
    );
    if (!result.written) {
      return HostsUpdate(written: false, added: const [], error: result.error);
    }

    // A security product can let the copy report success and still block it.
    final applied = readHostsLines(path);
    final missing = pending
        .where((host) => !hostsFileMaps(applied, host))
        .toList();
    if (missing.isNotEmpty) {
      return HostsUpdate(
        written: false,
        added: const [],
        error:
            'The hosts file was written but ${missing.length} '
            '${missing.length == 1 ? 'entry is' : 'entries are'} still '
            'missing from $path. Add them by hand or allow the write in your '
            'security software.',
      );
    }
    return HostsUpdate(written: true, added: pending);
  }
}

/// One parsed hosts file: the lines outside StackPilot's managed block plus
/// the host names inside it.
class HostsDocument {
  HostsDocument._({
    required List<String> outside,
    required List<String> hosts,
    required this.hadBlock,
  }) : outside = List<String>.unmodifiable(outside),
       hosts = List<String>.unmodifiable(hosts);

  factory HostsDocument.parse(Iterable<String> lines) {
    final outside = <String>[];
    final hosts = <String>[];
    var inBlock = false;
    var hadBlock = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.toLowerCase() == HostsFile.blockStart.toLowerCase()) {
        inBlock = true;
        hadBlock = true;
        continue;
      }
      if (trimmed.toLowerCase() == HostsFile.blockEnd.toLowerCase()) {
        inBlock = false;
        continue;
      }
      if (inBlock) {
        final parts = trimmed.split(RegExp(r'\s+'));
        for (final name in parts.skip(1)) {
          if (name.isNotEmpty) {
            hosts.add(name);
          }
        }
        continue;
      }
      outside.add(line);
    }

    return HostsDocument._(outside: outside, hosts: hosts, hadBlock: hadBlock);
  }

  /// Lines that do not belong to the managed block.
  final List<String> outside;

  /// Host names inside the managed block.
  final List<String> hosts;

  /// Whether the file already carried a managed block.
  final bool hadBlock;

  bool hasHost(String host) =>
      hosts.any((existing) => existing.toLowerCase() == host.toLowerCase());

  HostsDocument addHosts(Iterable<String> newHosts) {
    final updated = <String>[...hosts];
    for (final host in newHosts) {
      if (updated.any(
        (existing) => existing.toLowerCase() == host.toLowerCase(),
      )) {
        continue;
      }
      updated.add(host);
    }
    return HostsDocument._(outside: outside, hosts: updated, hadBlock: true);
  }

  /// Full file contents with the managed block rewritten in place.
  String render() {
    final body = <String>[...outside];
    while (body.isNotEmpty && body.last.trim().isEmpty) {
      body.removeLast();
    }

    return <String>[
      ...body,
      if (body.isNotEmpty) '',
      HostsFile.blockStart,
      for (final host in hosts) '127.0.0.1 $host',
      HostsFile.blockEnd,
      '',
    ].join('\r\n');
  }
}

/// Outcome of a hosts file update.
class HostsUpdate {
  const HostsUpdate({required this.written, required this.added, this.error});

  final bool written;
  final List<String> added;
  final String? error;

  bool get changed => added.isNotEmpty;
}

List<String> readHostsLines(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const [];
  }
  try {
    return file.readAsLinesSync();
  } on FormatException {
    // Legacy hosts files are sometimes saved in the ANSI code page. Decoding
    // them as Latin-1 keeps every byte instead of failing the whole page.
    try {
      return const LineSplitter().convert(
        latin1.decode(file.readAsBytesSync()),
      );
    } on FileSystemException {
      return const [];
    }
  } on FileSystemException {
    return const [];
  }
}

/// True when any active `127.0.0.1 <host>` line maps [host].
bool hostsFileMaps(Iterable<String> lines, String host) {
  for (final line in lines) {
    final content = line.split('#').first.trim();
    if (content.isEmpty) {
      continue;
    }
    final parts = content.split(RegExp(r'\s+'));
    if (parts.length < 2 || parts.first != '127.0.0.1') {
      continue;
    }
    for (final name in parts.skip(1)) {
      if (name.toLowerCase() == host.toLowerCase()) {
        return true;
      }
    }
  }
  return false;
}

/// Replaces the hosts file with [contents].
///
/// The direct write works when StackPilot already runs elevated. Otherwise
/// Windows raises an access-denied error and the same bytes are copied in by a
/// short-lived elevated PowerShell process, so only the hosts update needs a
/// UAC prompt.
Future<HostsUpdate> writeHostsFile(
  String path,
  String contents, {
  bool allowElevation = true,
}) async {
  try {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return const HostsUpdate(written: true, added: []);
  } on FileSystemException catch (error) {
    if (!allowElevation || !Platform.isWindows) {
      return HostsUpdate(written: false, added: const [], error: error.message);
    }
  }

  return _writeElevated(path, contents);
}

/// Opens the hosts file in Notepad with administrator rights.
Future<bool> openHostsFileElevated(String path) async {
  if (!Platform.isWindows) {
    return false;
  }
  final command =
      "Start-Process -FilePath 'notepad.exe' -Verb RunAs "
      "-ArgumentList '${_psEscape(path)}'";
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<HostsUpdate> _writeElevated(String path, String contents) async {
  Directory temporary;
  try {
    temporary = Directory.systemTemp.createTempSync('stackpilot_hosts_');
  } on FileSystemException catch (error) {
    return HostsUpdate(written: false, added: const [], error: error.message);
  }

  try {
    final source = File(p.join(temporary.path, 'hosts'));
    source.writeAsStringSync(contents);
    final script = File(p.join(temporary.path, 'apply-hosts.ps1'));
    script.writeAsStringSync(
      '\$ErrorActionPreference = \'Stop\'\r\n'
      'Copy-Item -LiteralPath \'${_psEscape(source.path)}\' '
      '-Destination \'${_psEscape(path)}\' -Force\r\n',
    );

    // Start-Process is what raises the UAC prompt. The outer process waits for
    // the elevated copy and forwards its exit code.
    final command =
        '\$p = Start-Process -FilePath \'powershell.exe\' -Verb RunAs '
        '-WindowStyle Hidden -PassThru -Wait '
        '-ArgumentList \'-NoProfile\',\'-ExecutionPolicy\',\'Bypass\','
        '\'-File\',\'${_psEscape(script.path)}\'; exit \$p.ExitCode';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ]);

    if (result.exitCode != 0) {
      return HostsUpdate(
        written: false,
        added: const [],
        error:
            'Windows did not allow the hosts file to be updated. Approve the '
            'administrator prompt, or add the lines by hand.',
      );
    }

    await _flushDns();
    return const HostsUpdate(written: true, added: []);
  } on ProcessException catch (error) {
    return HostsUpdate(written: false, added: const [], error: error.message);
  } on FileSystemException catch (error) {
    return HostsUpdate(written: false, added: const [], error: error.message);
  } finally {
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the elevated copy locked for a moment; the system temp
      // folder cleans it up later.
    }
  }
}

Future<void> _flushDns() async {
  try {
    await Process.run('ipconfig.exe', ['/flushdns']);
  } on ProcessException {
    // Resolving localhost names does not depend on a flushed cache.
  }
}

String _psEscape(String value) => value.replaceAll("'", "''");
