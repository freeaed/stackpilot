import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'paths.dart';
import 'stack_layout.dart';

/// Raised when a stack cannot be moved or renamed.
class StackMoveException implements Exception {
  const StackMoveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Outcome of copying a stack to a new location.
class StackMoveResult {
  const StackMoveResult({
    required this.sourceRoot,
    required this.targetRoot,
    required this.layout,
    required this.rewritten,
    required this.leftovers,
    required this.warnings,
  });

  final String sourceRoot;
  final String targetRoot;

  /// Layout of the copied stack.
  final StackLayout layout;

  /// Config files whose absolute paths were rewritten.
  final List<String> rewritten;

  /// Config files that still mention the old location.
  final List<String> leftovers;

  /// Non-fatal problems worth showing to the user.
  final List<String> warnings;

  bool get clean => leftovers.isEmpty;
}

/// Copies a whole stack to another folder and re-points every generated config.
///
/// The source is never modified. The caller deletes it only after the user
/// confirms, so a failed move always leaves a working stack behind.
class StackMover {
  const StackMover._();

  /// Folders whose text files may embed absolute stack paths.
  static const _configFolders = ['usr', 'etc', 'bin'];

  /// Text files inside `data/` that embed the data directory.
  static const _dataFileNames = {'postgresql.conf', 'pg_hba.conf', 'my.ini'};

  static const _textExtensions = {
    '.ini',
    '.conf',
    '.cnf',
    '.cmd',
    '.bat',
    '.ps1',
    '.psm1',
    '.json',
    '.php',
    '.yaml',
    '.yml',
    '.properties',
  };

  static const int _maxRewriteBytes = 2 * 1024 * 1024;

  /// Copies the stack at [sourceRoot] to [targetRoot].
  ///
  /// [targetRoot] must not exist yet, or must be an empty folder. Throws
  /// [StackMoveException] when the source is not a stack, when the target is
  /// not usable, or when the copy cannot be completed.
  static StackMoveResult move({
    required String sourceRoot,
    required String targetRoot,
    void Function(String message)? onProgress,
  }) {
    final source = normalizeWindowsPath(sourceRoot);
    final target = normalizeWindowsPath(targetRoot);
    if (source.isEmpty || target.isEmpty) {
      throw const StackMoveException('Choose both a source and a target folder.');
    }
    if (sameWindowsPath(source, target)) {
      throw const StackMoveException(
        'The target folder is the same as the current stack.',
      );
    }
    if (isWithinWindowsPath(source, target)) {
      throw const StackMoveException(
        'Move the stack outside its own folder.',
      );
    }
    if (isWithinWindowsPath(target, source)) {
      throw const StackMoveException(
        'The target folder is inside the current stack.',
      );
    }

    if (StackLayout.detect(source) == null) {
      throw StackMoveException('$source is not a stack folder.');
    }

    final targetDirectory = Directory(target);
    if (targetDirectory.existsSync()) {
      final empty = _isEmpty(targetDirectory);
      if (!empty) {
        throw StackMoveException(
          'The target folder already contains files: $target',
        );
      }
    }

    final warnings = <String>[];
    onProgress?.call('Copying $source to $target…');
    try {
      _copyTree(Directory(source), targetDirectory);
    } on FileSystemException catch (error) {
      throw StackMoveException(
        'Could not copy the stack to $target: ${error.message}',
      );
    }

    onProgress?.call('Rewriting configuration files…');
    final rewritten = <String>[];
    final leftovers = <String>[];
    for (final file in _configFiles(target)) {
      final changed = _rewriteFile(file, source, target);
      if (changed) {
        rewritten.add(file.path);
      }
    }
    for (final file in _configFiles(target)) {
      if (_mentions(file, source)) {
        leftovers.add(file.path);
      }
    }

    onProgress?.call('Checking the new stack…');
    final movedLayout = StackLayout.detect(target);
    if (movedLayout == null) {
      try {
        targetDirectory.deleteSync(recursive: true);
      } on FileSystemException {
        // Keep whatever was copied; the message points at the target.
      }
      throw StackMoveException(
        'The stack was copied to $target but could not be read back. The '
        'original stack was not changed.',
      );
    }

    if (!isWithinWindowsPath(target, movedLayout.documentRoot)) {
      warnings.add(
        'The document root (${movedLayout.documentRoot}) is outside the new '
        'stack folder. Its projects were not copied.',
      );
    }

    return StackMoveResult(
      sourceRoot: source,
      targetRoot: target,
      layout: movedLayout,
      rewritten: rewritten,
      leftovers: leftovers,
      warnings: warnings,
    );
  }

  /// Runs [move] on a background isolate so a multi-gigabyte stack copy does
  /// not freeze the window.
  static Future<StackMoveResult> moveInBackground({
    required String sourceRoot,
    required String targetRoot,
  }) {
    return Isolate.run(
      () => move(sourceRoot: sourceRoot, targetRoot: targetRoot),
    );
  }

  /// Deletes the stack folder that a move left behind.
  ///
  /// Only call this after the user confirmed and after [move] reported a clean
  /// result.
  static void deleteSource(String root) {
    final directory = Directory(normalizeWindowsPath(root));
    if (!directory.existsSync()) {
      return;
    }
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      throw StackMoveException(
        'Could not delete $root: ${error.message}',
      );
    }
  }

  /// True when [path] is a config file whose absolute paths may need changing.
  static bool isConfigFile(String path) {
    final name = p.basename(path).toLowerCase();
    if (_dataFileNames.contains(name)) {
      return true;
    }
    return _textExtensions.contains(p.extension(name).toLowerCase());
  }

  static Iterable<File> _configFiles(String root) sync* {
    for (final folder in _configFolders) {
      final directory = Directory(p.join(root, folder));
      if (!directory.existsSync()) {
        continue;
      }
      yield* _walk(directory);
    }

    final data = Directory(p.join(root, 'data'));
    if (data.existsSync()) {
      yield* _walkFiles(data, onlyNames: _dataFileNames);
    }
  }

  static Iterable<File> _walk(Directory directory) sync* {
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      if (entry is Directory) {
        yield* _walk(entry);
      } else if (entry is File && isConfigFile(entry.path)) {
        yield entry;
      }
    }
  }

  static Iterable<File> _walkFiles(
    Directory directory, {
    required Set<String> onlyNames,
  }) sync* {
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      if (entry is Directory) {
        yield* _walkFiles(entry, onlyNames: onlyNames);
      } else if (entry is File &&
          onlyNames.contains(p.basename(entry.path).toLowerCase())) {
        yield entry;
      }
    }
  }

  static bool _rewriteFile(File file, String oldRoot, String newRoot) {
    final int size;
    try {
      size = file.lengthSync();
    } on FileSystemException {
      return false;
    }
    if (size > _maxRewriteBytes) {
      return false;
    }

    final String source;
    try {
      source = file.readAsStringSync();
    } on FileSystemException {
      return false;
    }

    var updated = _replacePath(
      source,
      oldRoot.replaceAll(r'\', '/'),
      newRoot.replaceAll(r'\', '/'),
    );
    updated = _replacePath(
      updated,
      oldRoot.replaceAll('/', r'\'),
      newRoot.replaceAll('/', r'\'),
    );
    if (updated == source) {
      return false;
    }
    try {
      file.writeAsStringSync(updated, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _mentions(File file, String root) {
    try {
      if (file.lengthSync() > _maxRewriteBytes) {
        return false;
      }
      final source = file.readAsStringSync();
      return _containsPath(source, root.replaceAll(r'\', '/')) ||
          _containsPath(source, root.replaceAll('/', r'\'));
    } on FileSystemException {
      return false;
    }
  }

  static String _replacePath(String source, String oldPath, String newPath) {
    if (oldPath.isEmpty) {
      return source;
    }
    final pattern = RegExp(RegExp.escape(oldPath), caseSensitive: false);
    return source.replaceAllMapped(pattern, (_) => newPath);
  }

  static bool _containsPath(String source, String needle) {
    if (needle.isEmpty) {
      return false;
    }
    return source.toLowerCase().contains(needle.toLowerCase());
  }

  static bool _isEmpty(Directory directory) {
    try {
      return directory.listSync().isEmpty;
    } on FileSystemException {
      return false;
    }
  }

  static void _copyTree(Directory source, Directory target) {
    target.createSync(recursive: true);
    for (final entry in source.listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final destination = p.join(target.path, name);
      if (entry is Directory) {
        _copyTree(entry, Directory(destination));
      } else if (entry is File) {
        entry.copySync(destination);
      }
      // Links and other entities are skipped: a stack must stay self-contained.
    }
  }
}
