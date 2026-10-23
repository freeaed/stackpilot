import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_info.dart';
import 'app_log.dart';
import 'app_preferences.dart';
import 'stack_layout.dart';

/// A diagnostics archive ready to attach to a problem report.
class DiagnosticsBundle {
  const DiagnosticsBundle({required this.file, required this.entries});

  final File file;

  /// Names of the files inside the archive, for display in the UI.
  final List<String> entries;
}

/// Collects logs, build information, and stack metadata into one ZIP.
///
/// The bundle deliberately contains paths and versions, not database contents,
/// project files, or credentials.
class Diagnostics {
  const Diagnostics._();

  static const _markerLimit = 32 * 1024;

  /// `%LOCALAPPDATA%\StackPilot\reports`, with a profile fallback.
  static Directory defaultOutputDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData == null || localAppData.trim().isEmpty)
        ? p.join(
            Platform.environment['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Local',
          )
        : localAppData;
    return Directory(p.join(base, 'StackPilot', 'reports'));
  }

  static DiagnosticsBundle create({
    AppPreferences preferences = AppPreferences.empty,
    StackLayout? layout,
    Iterable<StackComponent> runningServices = const [],
    Directory? outputDirectory,
    Directory? logDirectory,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final entries = <String>[];
    final archive = Archive();

    void addText(String name, String contents) {
      final bytes = utf8.encode(contents);
      archive.addFile(ArchiveFile.bytes(name, bytes));
      entries.add(name);
    }

    addText('app.txt', _appReport(timestamp));
    addText('preferences.json', _preferencesReport(preferences));
    addText('stack.txt', _stackReport(layout, runningServices));
    addText('README.txt', _readme());

    final logs = _logFiles(logDirectory);
    for (final file in logs) {
      try {
        final bytes = file.readAsBytesSync();
        final name = 'logs/${p.basename(file.path)}';
        archive.addFile(ArchiveFile.bytes(name, bytes));
        entries.add(name);
      } on FileSystemException {
        // A locked log is skipped; the rest of the bundle is still useful.
      }
    }

    final marker = layout == null ? null : File(layout.markerPath);
    if (marker != null && marker.existsSync()) {
      try {
        final source = marker.readAsStringSync();
        addText(
          'stack/${p.basename(marker.path)}',
          source.length <= _markerLimit
              ? source
              : '${source.substring(0, _markerLimit)}\n... truncated ...\n',
        );
      } on FileSystemException {
        // Marker is optional.
      }
    }

    final directory = outputDirectory ?? defaultOutputDirectory();
    directory.createSync(recursive: true);
    final file = _uniqueFile(directory, timestamp);
    final bytes = ZipEncoder().encode(archive);
    file.writeAsBytesSync(bytes, flush: true);

    AppLog.info('Diagnostics bundle written to ${file.path}');
    return DiagnosticsBundle(file: file, entries: entries);
  }

  static String _appReport(DateTime timestamp) {
    final environment = Platform.environment;
    return [
      '${AppInfo.name} ${AppInfo.versionLabel}',
      'Channel: ${AppInfo.channel.id}',
      'Created: ${timestamp.toUtc().toIso8601String()}',
      'Operating system: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
      'Dart: ${Platform.version}',
      'Executable: ${Platform.resolvedExecutable}',
      'Current directory: ${Directory.current.path}',
      'Processor count: ${Platform.numberOfProcessors}',
      'Locale: ${environment['LANG'] ?? environment['LC_ALL'] ?? 'unknown'}',
      'Log folder: ${AppLog.directoryPath ?? 'not initialized'}',
      '',
    ].join('\r\n');
  }

  static String _preferencesReport(AppPreferences preferences) {
    return '${const JsonEncoder.withIndent('  ').convert(preferences.toJson())}\n';
  }

  static String _stackReport(
    StackLayout? layout,
    Iterable<StackComponent> runningServices,
  ) {
    if (layout == null) {
      return 'No stack is open.\r\n';
    }

    final lines = <String>[
      'Root: ${layout.root}',
      'Flavor: ${layout.flavor.label}',
      'Marker: ${layout.markerPath}',
      'Document root: ${layout.documentRoot}',
      'Data directory: ${layout.dataDirectory}',
      'MySQL port: ${layout.mysqlPort}',
      'PostgreSQL port: ${layout.postgresqlPort}',
      'Redis port: ${layout.redisPort}',
      'Mailpit port: ${layout.mailpitPort}',
      'Running services: '
          '${runningServices.map((component) => component.directoryName).join(', ')}',
      '',
      'Components:',
    ];

    for (final component in StackComponent.values) {
      final installed = layout.installedVersions(component);
      if (installed.isEmpty) {
        continue;
      }
      final active = layout.activeVersion(component);
      lines.add(
        '- ${component.directoryName}: '
        'active=${active?.version ?? 'none'}, '
        'enabled=${layout.serviceEnabled(component)}, '
        'installed=${installed.map((install) => install.version).join(', ')}',
      );
    }
    lines.add('');
    return lines.join('\r\n');
  }

  static String _readme() {
    return [
      'StackPilot diagnostics bundle',
      '',
      'This archive contains:',
      '  app.txt          build, channel, and operating-system details',
      '  stack.txt        stack paths, versions, ports, and running services',
      '  preferences.json non-sensitive StackPilot preferences',
      '  stack/*.ini      the active stack marker (paths and versions only)',
      '  logs/*.log       recent StackPilot log files',
      '',
      'It does not contain database data, project files, passwords, or',
      'environment variables. Review the files before sharing the archive.',
      '',
    ].join('\r\n');
  }

  static List<File> _logFiles(Directory? logDirectory) {
    final active = AppLog.directoryPath;
    final directory =
        logDirectory ??
        (active == null ? AppLog.defaultDirectory() : Directory(active));
    if (!directory.existsSync()) {
      return const [];
    }
    final files = <File>[];
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        // Rotated logs are named stackpilot.log.1, stackpilot.log.2, ...
        final name = p.basename(entity.path).toLowerCase();
        if (name.startsWith('stackpilot.log')) {
          files.add(entity);
        }
      }
    } on FileSystemException {
      return const [];
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static File _uniqueFile(Directory directory, DateTime timestamp) {
    final stamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[-:T]'), '')
        .split('.')
        .first;
    var file = File(p.join(directory.path, 'StackPilot-report-$stamp.zip'));
    var suffix = 2;
    while (file.existsSync()) {
      file = File(
        p.join(directory.path, 'StackPilot-report-$stamp-$suffix.zip'),
      );
      suffix++;
    }
    return file;
  }
}
