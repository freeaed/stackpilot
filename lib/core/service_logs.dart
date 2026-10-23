import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'stack_layout.dart';

/// A log file that belongs to one service of the current stack.
class ServiceLogFile {
  const ServiceLogFile({
    required this.component,
    required this.path,
    required this.label,
  });

  final StackComponent component;

  /// Absolute path of the file.
  final String path;

  /// Short name for menus, for example `error.log`.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ServiceLogFile &&
      other.component == component &&
      other.path.toLowerCase() == path.toLowerCase();

  @override
  int get hashCode => Object.hash(component, path.toLowerCase());

  @override
  String toString() => '$component: $path';
}

/// The end of a log file, as shown in the log viewer.
class ServiceLogTail {
  const ServiceLogTail({
    required this.text,
    required this.truncated,
    required this.modified,
    required this.bytesShown,
  });

  static const empty = ServiceLogTail(
    text: '',
    truncated: false,
    modified: null,
    bytesShown: 0,
  );

  final String text;

  /// True when older lines were left out of [text].
  final bool truncated;

  final DateTime? modified;

  /// Number of bytes read from the end of the file.
  final int bytesShown;

  bool get exists => modified != null;
}

/// Finds the log files a stack's services write.
///
/// Discovery only reads the file system. A service that has not run yet often
/// has no log file, so callers should treat an empty result as normal.
class ServiceLogs {
  ServiceLogs(this.layout);

  final StackLayout layout;

  static const int defaultMaxLines = 500;
  static const int defaultMaxBytes = 256 * 1024;

  /// Every existing log file, in service order.
  List<ServiceLogFile> discover() {
    return [
      ..._apacheOrNginx(StackComponent.apache),
      ..._apacheOrNginx(StackComponent.nginx),
      ..._mysqlLogs(),
      ..._postgresqlLogs(),
      ..._redisLogs(),
    ];
  }

  /// Reads the end of [file] without loading a large log into memory.
  ServiceLogTail readTail(
    ServiceLogFile file, {
    int maxLines = defaultMaxLines,
    int maxBytes = defaultMaxBytes,
  }) {
    final handle = File(file.path);
    if (!handle.existsSync()) {
      return ServiceLogTail.empty;
    }

    try {
      final length = handle.lengthSync();
      final start = math.max(0, length - maxBytes);
      final reader = handle.openSync();
      final String text;
      try {
        reader.setPositionSync(start);
        text = utf8.decode(
          reader.readSync(length - start),
          allowMalformed: true,
        );
      } finally {
        reader.closeSync();
      }

      var visible = text;
      if (start > 0) {
        final firstLineBreak = visible.indexOf('\n');
        if (firstLineBreak >= 0) {
          visible = visible.substring(firstLineBreak + 1);
        }
      }

      final lines = visible.split(RegExp(r'\r?\n'));
      if (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }
      final truncated = start > 0 || lines.length > maxLines;
      final kept = lines.length > maxLines
          ? lines.sublist(lines.length - maxLines)
          : lines;

      return ServiceLogTail(
        text: kept.join('\n'),
        truncated: truncated,
        modified: handle.lastModifiedSync(),
        bytesShown: length - start,
      );
    } on FileSystemException {
      return ServiceLogTail.empty;
    }
  }

  List<StackInstall> _orderedInstalls(StackComponent component) {
    final installs = layout.installedVersions(component).toList();
    final active = layout.activeVersion(component);
    if (active != null) {
      installs.removeWhere((install) => install.directory == active.directory);
      installs.insert(0, active);
    }
    return installs;
  }

  Iterable<ServiceLogFile> _apacheOrNginx(StackComponent component) sync* {
    final installs = _orderedInstalls(component);
    for (final install in installs) {
      for (final name in const ['error.log', 'access.log']) {
        final path = p.join(install.directory, 'logs', name);
        if (!File(path).existsSync()) {
          continue;
        }
        yield ServiceLogFile(
          component: component,
          path: path,
          label: installs.length > 1
              ? '${install.displayVersion} · $name'
              : name,
        );
      }
    }
  }

  Iterable<ServiceLogFile> _mysqlLogs() sync* {
    final directories = <String>{
      p.join(layout.dataDirectory, 'mysql'),
      p.join(layout.root, 'data', 'mysql'),
    };
    final active = layout.activeVersion(StackComponent.mysql);
    if (active != null) {
      directories.add(p.join(active.directory, 'data'));
    }

    final seen = <String>{};
    for (final directory in directories) {
      final files = _logFilesIn(directory)
          .where((file) {
            final extension = p.extension(file.path).toLowerCase();
            if (extension == '.err') {
              return true;
            }
            return extension == '.log' &&
                !p.basename(file.path).toLowerCase().startsWith('ib_');
          })
          .toList()
        ..sort((a, b) {
          final aErr = p.extension(a.path).toLowerCase() == '.err';
          final bErr = p.extension(b.path).toLowerCase() == '.err';
          if (aErr != bErr) {
            return aErr ? -1 : 1;
          }
          return p.basename(a.path).compareTo(p.basename(b.path));
        });

      for (final file in files) {
        if (!seen.add(p.normalize(file.path).toLowerCase())) {
          continue;
        }
        yield ServiceLogFile(
          component: StackComponent.mysql,
          path: file.path,
          label: p.basename(file.path),
        );
      }
    }
  }

  Iterable<ServiceLogFile> _postgresqlLogs() sync* {
    final data = layout.postgresqlDataDirectory;
    final directories = [
      p.join(data, 'log'),
      p.join(data, 'pg_log'),
      data,
    ];

    final seen = <String>{};
    for (final directory in directories) {
      final files = _logFilesIn(
        directory,
      ).where((file) => p.extension(file.path).toLowerCase() == '.log');
      for (final file in files) {
        if (!seen.add(p.normalize(file.path).toLowerCase())) {
          continue;
        }
        yield ServiceLogFile(
          component: StackComponent.postgresql,
          path: file.path,
          label: p.basename(file.path),
        );
      }
    }
  }

  Iterable<ServiceLogFile> _redisLogs() sync* {
    final installs = _orderedInstalls(StackComponent.redis);
    for (final install in installs) {
      for (final directory in [
        install.directory,
        p.join(install.directory, 'logs'),
      ]) {
        for (final file in _logFilesIn(directory).where(
          (file) => p.extension(file.path).toLowerCase() == '.log',
        )) {
          yield ServiceLogFile(
            component: StackComponent.redis,
            path: file.path,
            label: installs.length > 1
                ? '${install.displayVersion} · ${p.basename(file.path)}'
                : p.basename(file.path),
          );
        }
      }
    }
  }

  List<File> _logFilesIn(String directory) {
    final folder = Directory(directory);
    if (!folder.existsSync()) {
      return const [];
    }
    try {
      return folder.listSync().whereType<File>().toList();
    } on FileSystemException {
      return const [];
    }
  }
}
