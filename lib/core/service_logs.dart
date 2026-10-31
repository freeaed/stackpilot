import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'ini.dart';
import 'service_console.dart';
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

  /// Short name for menus, for example `error_log` or `console`.
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
    this.size = 0,
  });

  static const empty = ServiceLogTail(
    text: '',
    truncated: false,
    modified: null,
    bytesShown: 0,
    size: 0,
  );

  final String text;

  /// True when older lines were left out of [text].
  final bool truncated;

  final DateTime? modified;

  /// Number of bytes read from the end of the file.
  final int bytesShown;

  /// Size of the whole file.
  final int size;

  bool get exists => modified != null;
}

/// Finds the log files a stack's services write.
///
/// Discovery reads each service's real configuration (`ErrorLog`, `CustomLog`,
/// `log-error`, `error_log`, `logfile`, `log_directory`) and falls back to the
/// names Laragon, StackPilot, and the vendors use. A service that has not run
/// yet often has no log file, so callers should treat an empty result as
/// normal.
class ServiceLogs {
  ServiceLogs(this.layout);

  final StackLayout layout;

  static const int defaultMaxLines = 500;
  static const int defaultMaxBytes = 256 * 1024;

  /// Every existing log file, in service order.
  List<ServiceLogFile> discover() {
    final files = <ServiceLogFile>[];
    final seen = <String>{};

    void add(StackComponent component, String path, String label) {
      final normalized = p.normalize(path);
      if (!seen.add(normalized.toLowerCase())) {
        return;
      }
      if (!File(normalized).existsSync()) {
        return;
      }
      files.add(
        ServiceLogFile(
          component: component,
          path: normalized,
          label: label,
        ),
      );
    }

    for (final component in [
      StackComponent.apache,
      StackComponent.nginx,
      StackComponent.mysql,
      StackComponent.postgresql,
      StackComponent.redis,
      StackComponent.php,
      StackComponent.mailpit,
    ]) {
      for (final file in _componentLogs(component)) {
        add(component, file.path, file.label);
      }
      add(
        component,
        ServiceConsole.fileFor(layout.root, component).path,
        'console',
      );
    }
    return files;
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
        size: length,
      );
    } on FileSystemException {
      return ServiceLogTail.empty;
    }
  }

  // --- Discovery -----------------------------------------------------------

  /// Candidate files for [component], without duplicates.
  Iterable<ServiceLogFile> _componentLogs(StackComponent component) sync* {
    final candidates = <String, ({String path, String label})>{};

    void add(String path, [String? label]) {
      final normalized = p.normalize(path);
      candidates.putIfAbsent(
        normalized.toLowerCase(),
        () => (path: normalized, label: label ?? p.basename(normalized)),
      );
    }

    switch (component) {
      case StackComponent.apache:
        _apacheConfigLogs(add);
        for (final name in const [
          'error_log',
          'access_log',
          'error.log',
          'access.log',
        ]) {
          add(p.join(layout.root, 'logs', name));
        }
        for (final name in const [
          'default-error.log',
          'default-access.log',
        ]) {
          add(p.join(layout.root, 'logs', name));
        }
        final install = layout.activeVersion(component);
        if (install != null) {
          for (final name in const [
            'error_log',
            'access_log',
            'error.log',
            'access.log',
          ]) {
            add(p.join(install.directory, 'logs', name));
          }
        }
      case StackComponent.nginx:
        _nginxConfigLogs(add);
        for (final name in const [
          'nginx-error.log',
          'nginx-access.log',
        ]) {
          add(p.join(layout.root, 'logs', name));
        }
        final install = layout.activeVersion(component);
        if (install != null) {
          add(p.join(install.directory, 'logs', 'error.log'));
          add(p.join(install.directory, 'logs', 'access.log'));
        }
      case StackComponent.mysql:
        _mysqlConfigLogs(add);
        add(p.join(layout.root, 'logs', 'mysql-error.log'));
        for (final directory in _mysqlDataDirectories()) {
          for (final file in _filesIn(directory)) {
            final extension = p.extension(file.path).toLowerCase();
            final name = p.basename(file.path).toLowerCase();
            if (extension == '.err' ||
                (extension == '.log' && !name.startsWith('ib_'))) {
              add(file.path);
            }
          }
        }
        final install = layout.activeVersion(component);
        if (install != null) {
          for (final file in _filesIn(p.join(install.directory, 'data'))) {
            final extension = p.extension(file.path).toLowerCase();
            if (extension == '.err' || extension == '.log') {
              add(file.path);
            }
          }
        }
      case StackComponent.postgresql:
        _postgresqlConfigLogs(add);
        for (final directory in _postgresqlLogDirectories()) {
          for (final file in _filesIn(directory)) {
            if (p.extension(file.path).toLowerCase() == '.log') {
              add(file.path);
            }
          }
        }
        add(p.join(layout.root, 'logs', 'postgresql.log'));
      case StackComponent.redis:
        _redisConfigLogs(add);
        add(p.join(layout.root, 'logs', 'redis.log'));
        final install = layout.activeVersion(component);
        if (install != null) {
          add(p.join(install.directory, 'redis.log'));
          add(p.join(install.directory, 'logs', 'redis.log'));
          for (final file in _filesIn(install.directory)) {
            if (p.extension(file.path).toLowerCase() == '.log') {
              add(file.path);
            }
          }
        }
      case StackComponent.php:
        _phpConfigLogs(add);
        add(p.join(layout.root, 'logs', 'php-error.log'));
        add(p.join(layout.root, 'logs', 'php_errors.log'));
      case StackComponent.nodejs:
      case StackComponent.memcached:
      case StackComponent.mailpit:
        break;
    }

    for (final entry in candidates.values) {
      if (File(entry.path).existsSync()) {
        yield ServiceLogFile(
          component: component,
          path: entry.path,
          label: entry.label,
        );
      }
    }
  }

  void _apacheConfigLogs(void Function(String path, [String? label]) add) {
    final install = layout.activeVersion(StackComponent.apache);
    if (install == null) {
      return;
    }
    final config = File(p.join(install.directory, 'conf', 'httpd.conf'));
    final source = _read(config);
    if (source != null) {
      final vars = _apacheVars(source);
      final serverRoot = _apacheServerRoot(
        source,
        fallback: install.directory,
        vars: vars,
      );
      for (final entry in _apacheLogDirectives(source)) {
        for (final path in _resolveCandidates(
          entry,
          base: serverRoot,
          fallbacks: [install.directory, layout.root],
          vars: vars,
        )) {
          add(path);
        }
      }
    }

    // Virtual hosts and aliases may point somewhere else.
    final vhosts = Directory(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled'),
    );
    for (final file in _filesIn(vhosts.path, extension: '.conf')) {
      final text = _read(file);
      if (text == null) {
        continue;
      }
      for (final entry in _apacheLogDirectives(text)) {
        for (final path in _resolveCandidates(
          entry,
          base: layout.root,
          fallbacks: [install.directory, layout.root],
        )) {
          add(path);
        }
      }
    }
  }

  void _nginxConfigLogs(void Function(String path, [String? label]) add) {
    final install = layout.activeVersion(StackComponent.nginx);
    if (install == null) {
      return;
    }
    final source = _read(File(p.join(install.directory, 'conf', 'nginx.conf')));
    if (source == null) {
      return;
    }
    for (final match in RegExp(
      r'^[ \t]*(?:error_log|access_log)[ \t]+([^;\r\n]+)',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(source)) {
      final value = _firstArgument(match.group(1)!);
      if (value == null) {
        continue;
      }
      for (final path in _resolveCandidates(
        value,
        base: install.directory,
        fallbacks: [layout.root],
      )) {
        add(path);
      }
    }
  }

  void _mysqlConfigLogs(void Function(String path, [String? label]) add) {
    final install = layout.activeVersion(StackComponent.mysql);
    if (install == null) {
      return;
    }
    final source = _read(File(p.join(install.directory, 'my.ini'))) ??
        _read(File(p.join(install.directory, 'my.cnf')));
    if (source == null) {
      return;
    }
    final ini = IniDocument.parse(source);
    for (final key in const ['log-error', 'log_error', 'log']) {
      final value = ini.value('mysqld', key) ?? ini.value('mariadb', key);
      if (value == null || value.trim().isEmpty) {
        continue;
      }
      final clean = _unquote(value);
      if (clean.toLowerCase() == 'stderr') {
        continue;
      }
      for (final path in _resolveCandidates(
        clean,
        base: install.directory,
        fallbacks: [layout.dataDirectory, layout.root],
      )) {
        add(path);
      }
    }
  }

  void _postgresqlConfigLogs(void Function(String path, [String? label]) add) {
    final data = layout.postgresqlDataDirectory;
    final source = _read(File(p.join(data, 'postgresql.conf')));
    if (source == null) {
      return;
    }
    final match = RegExp(
      r'^[ \t]*log_directory[ \t]*=[ \t]*([^#\r\n]*)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(source);
    final directory = match == null
        ? 'log'
        : _unquote(match.group(1)!.trim());
    if (directory.isEmpty || directory.toLowerCase() == 'stderr') {
      return;
    }
    final resolved = p.isAbsolute(directory)
        ? directory
        : p.join(data, directory);
    for (final file in _filesIn(resolved)) {
      if (p.extension(file.path).toLowerCase() == '.log') {
        add(file.path);
      }
    }
  }

  void _redisConfigLogs(void Function(String path, [String? label]) add) {
    final install = layout.activeVersion(StackComponent.redis);
    if (install == null) {
      return;
    }
    final source = _read(File(p.join(install.directory, 'redis.conf')));
    if (source == null) {
      return;
    }
    final match = RegExp(
      r'^[ \t]*logfile[ \t]+(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(source);
    final value = match == null ? null : _firstArgument(match.group(1)!);
    if (value == null || value.isEmpty || value == '""') {
      return;
    }
    for (final path in _resolveCandidates(
      value,
      base: install.directory,
      fallbacks: [layout.root],
    )) {
      add(path);
    }
  }

  void _phpConfigLogs(void Function(String path, [String? label]) add) {
    final install = layout.activeVersion(StackComponent.php);
    if (install == null) {
      return;
    }
    final source = _read(File(p.join(install.directory, 'php.ini')));
    if (source == null) {
      return;
    }
    final match = RegExp(
      r'^[ \t]*error_log[ \t]*=[ \t]*([^\r\n;]*)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(source);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty || value.toLowerCase() == 'syslog') {
      return;
    }
    for (final path in _resolveCandidates(
      _unquote(value),
      base: install.directory,
      fallbacks: [layout.root],
    )) {
      add(path);
    }
  }

  Set<String> _mysqlDataDirectories() => {
    p.join(layout.dataDirectory, 'mysql'),
    p.join(layout.root, 'data', 'mysql'),
  };

  Set<String> _postgresqlLogDirectories() {
    final data = layout.postgresqlDataDirectory;
    return {
      p.join(data, 'log'),
      p.join(data, 'pg_log'),
      data,
    };
  }

  // --- Parsing helpers -----------------------------------------------------

  /// `ErrorLog` and `CustomLog` values in an Apache config.
  Iterable<String> _apacheLogDirectives(String source) sync* {
    final pattern = RegExp(
      r'^[ \t]*(ErrorLog|CustomLog)[ \t]+(.+)$',
      caseSensitive: false,
      multiLine: true,
    );
    for (final match in pattern.allMatches(source)) {
      final rest = match.group(2)!.trim();
      if (rest.startsWith('|') || rest.toLowerCase().startsWith('syslog')) {
        continue;
      }
      final value = _firstArgument(rest);
      if (value != null && value.isNotEmpty) {
        yield value;
      }
    }
  }

  static Map<String, String> _apacheVars(String source) {
    final vars = <String, String>{};
    for (final match in RegExp(
      r'^[ \t]*Define[ \t]+([A-Za-z0-9_]+)[ \t]+(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(source)) {
      vars[match.group(1)!] = _unquote(match.group(2)!.trim());
    }
    return vars;
  }

  static String _apacheServerRoot(
    String source, {
    required String fallback,
    required Map<String, String> vars,
  }) {
    final match = RegExp(
      r'^[ \t]*ServerRoot[ \t]+(.+)$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(source);
    final value = match == null
        ? null
        : _expand(_unquote(match.group(1)!.trim()), vars);
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return p.isAbsolute(value) ? value : p.join(fallback, value);
  }

  /// Expands `${NAME}` and `%NAME%` variables from Apache `Define` lines.
  static String _expand(String value, Map<String, String> vars) {
    var result = value;
    for (final entry in vars.entries) {
      result = result.replaceAll('\${${entry.key}}', entry.value);
      result = result.replaceAll('%${entry.key}%', entry.value);
    }
    return result;
  }

  List<String> _resolveCandidates(
    String value, {
    required String base,
    required List<String> fallbacks,
    Map<String, String> vars = const {},
  }) {
    final expanded = _expand(_unquote(value.trim()), vars);
    if (expanded.isEmpty) {
      return const [];
    }
    final absolute = p.isAbsolute(expanded)
        ? p.normalize(expanded)
        : p.normalize(p.join(base, expanded));
    final candidates = <String>{absolute};
    final name = p.basename(absolute);
    for (final fallback in fallbacks) {
      candidates.add(p.join(fallback, 'logs', name));
      candidates.add(p.join(fallback, name));
    }
    return candidates.toList();
  }

  static String _unquote(String value) {
    var result = value.trim();
    if (result.length >= 2 &&
        ((result.startsWith('"') && result.endsWith('"')) ||
            (result.startsWith("'") && result.endsWith("'")))) {
      result = result.substring(1, result.length - 1);
    }
    return result;
  }

  static String? _firstArgument(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('"')) {
      final end = trimmed.indexOf('"', 1);
      return end < 0 ? null : trimmed.substring(1, end);
    }
    final space = trimmed.indexOf(RegExp(r'\s'));
    return space < 0 ? trimmed : trimmed.substring(0, space);
  }

  static String? _read(File file) {
    try {
      return file.existsSync() ? file.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  static List<File> _filesIn(String directory, {String? extension}) {
    final folder = Directory(directory);
    if (!folder.existsSync()) {
      return const [];
    }
    try {
      return folder
          .listSync(followLinks: false)
          .whereType<File>()
          .where(
            (file) =>
                extension == null ||
                p.extension(file.path).toLowerCase() ==
                    extension.toLowerCase(),
          )
          .toList();
    } on FileSystemException {
      return const [];
    }
  }
}
