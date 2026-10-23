import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Append-only application log.
///
/// The log is written synchronously and flushed after every entry, so the last
/// lines survive a crash or a hard power-off. It rotates at [maxBytes] and
/// keeps [keepFiles] older files next to the current one.
///
/// Logging never throws: a missing or read-only log folder must not stop the
/// app from starting.
class AppLog {
  AppLog._(this.directory, this.file, this._maxBytes, this._keepFiles);

  static AppLog? _instance;

  final Directory directory;
  final File file;
  final int _maxBytes;
  final int _keepFiles;

  RandomAccessFile? _handle;
  bool _closed = false;

  /// Bytes already written to the current file, used to rotate without a
  /// filesystem call for every entry.
  int _written = 0;

  /// Folder used by this process, or null before [initialize].
  static String? get directoryPath => _instance?.directory.path;

  /// Current log file, or null before [initialize].
  static File? get currentFile => _instance?.file;

  /// Starts logging under [directory], defaulting to
  /// `%LOCALAPPDATA%\StackPilot\logs`.
  static AppLog? initialize({
    Directory? directory,
    int maxBytes = 2 * 1024 * 1024,
    int keepFiles = 3,
  }) {
    final target = directory ?? defaultDirectory();
    try {
      target.createSync(recursive: true);
      final file = File(p.join(target.path, 'stackpilot.log'));
      final log = AppLog._(target, file, maxBytes, keepFiles);
      log._rotateIfNeeded();
      log._handle = file.openSync(mode: FileMode.append);
      log._written = file.lengthSync();
      _instance = log;
      return log;
    } on FileSystemException {
      _instance = null;
      return null;
    }
  }

  /// `%LOCALAPPDATA%\StackPilot\logs`, with a profile fallback.
  static Directory defaultDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData == null || localAppData.trim().isEmpty)
        ? p.join(
            Platform.environment['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Local',
          )
        : localAppData;
    return Directory(p.join(base, 'StackPilot', 'logs'));
  }

  static void info(String message) => _write('INFO', message);

  static void warn(String message, {Object? error, StackTrace? stackTrace}) =>
      _write('WARN', message, error: error, stackTrace: stackTrace);

  static void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _write('ERROR', message, error: error, stackTrace: stackTrace);

  static void _write(
    String level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final instance = _instance;
    if (instance == null) {
      return;
    }
    instance._append(level, message, error: error, stackTrace: stackTrace);
  }

  void _append(
    String level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_closed) {
      return;
    }
    final buffer = StringBuffer()
      ..write('[')
      ..write(DateTime.now().toUtc().toIso8601String())
      ..write('] ')
      ..write(level.padRight(5))
      ..write(' ')
      ..write(message);
    if (error != null) {
      buffer
        ..write('\n  error: ')
        ..write(error);
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace.toString().trimRight());
    }
    buffer.writeln();

    final bytes = utf8.encode(buffer.toString());
    if (_written > 0 && _written + bytes.length > _maxBytes) {
      _rotateOpen();
    }

    try {
      final handle = _handle;
      if (handle != null) {
        handle.writeFromSync(bytes);
        handle.flushSync();
        _written += bytes.length;
        return;
      }
      file.writeAsStringSync(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
      _written += bytes.length;
    } on FileSystemException {
      // Logging is best effort. Never let a full disk break the app.
    }
  }

  /// Closes the handle, rotates the file, and reopens a fresh log.
  void _rotateOpen() {
    try {
      _handle?.closeSync();
    } on FileSystemException {
      // Ignore.
    }
    _handle = null;
    _rotateIfNeeded(force: true);
    try {
      _handle = file.openSync(mode: FileMode.append);
      _written = file.lengthSync();
    } on FileSystemException {
      _handle = null;
      _written = 0;
    }
  }

  /// Rotates the current log when it is larger than [maxBytes].
  void _rotateIfNeeded({bool force = false}) {
    try {
      if (!file.existsSync()) {
        return;
      }
      if (!force && file.lengthSync() < _maxBytes) {
        return;
      }
      for (var index = _keepFiles; index >= 1; index--) {
        final source = File(
          index == 1 ? file.path : '${file.path}.${index - 1}',
        );
        if (!source.existsSync()) {
          continue;
        }
        final target = File('${file.path}.$index');
        if (target.existsSync()) {
          target.deleteSync();
        }
        source.renameSync(target.path);
      }
    } on FileSystemException {
      // Rotation is optional; keep appending to the current file.
    }
  }

  /// Flushes pending entries. Useful before creating a diagnostics bundle.
  static void flush() {
    try {
      _instance?._handle?.flushSync();
    } on FileSystemException {
      // Ignore.
    }
  }

  /// Closes the log. The next [initialize] opens a fresh handle.
  static void close() {
    final instance = _instance;
    if (instance == null) {
      return;
    }
    instance._closed = true;
    try {
      instance._handle?.closeSync();
    } on FileSystemException {
      // Ignore.
    }
    instance._handle = null;
    _instance = null;
  }
}
