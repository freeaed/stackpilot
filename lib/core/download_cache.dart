import 'dart:io';

import 'package:path/path.dart' as p;

/// Archive cache shared by every stack.
///
/// Downloads are stored as `%LOCALAPPDATA%\StackPilot\cache\downloads\
/// {sha256}.zip`, so installing the same component into a second stack — or
/// after a failed extraction — does not download it twice. The file name is
/// the digest, which makes a cache hit self-verifying: the caller still hashes
/// the archive before using it.
class DownloadCache {
  DownloadCache({Directory? directory})
    : directory = directory ?? defaultDirectory();

  final Directory directory;

  /// `%LOCALAPPDATA%\StackPilot\cache\downloads`, with a profile fallback.
  static Directory defaultDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData == null || localAppData.trim().isEmpty)
        ? p.join(
            Platform.environment['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Local',
          )
        : localAppData;
    return Directory(p.join(base, 'StackPilot', 'cache', 'downloads'));
  }

  /// Final archive for [sha256].
  File archiveFor(String sha256) =>
      File(p.join(directory.path, '${sha256.toLowerCase()}.zip'));

  /// In-progress download for [sha256]; kept between launches so a large
  /// archive can resume.
  File partFor(String sha256) =>
      File('${archiveFor(sha256).path}.part');

  bool get isEmpty => count == 0;

  int get count {
    if (!directory.existsSync()) {
      return 0;
    }
    try {
      return directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.zip'))
          .length;
    } on FileSystemException {
      return 0;
    }
  }

  int get sizeBytes {
    if (!directory.existsSync()) {
      return 0;
    }
    var total = 0;
    try {
      for (final entry in directory.listSync(followLinks: false)) {
        if (entry is File) {
          total += entry.lengthSync();
        }
      }
    } on FileSystemException {
      return total;
    }
    return total;
  }

  /// Removes every cached archive and partial download.
  ///
  /// Returns the number of files that were deleted.
  int clear() {
    if (!directory.existsSync()) {
      return 0;
    }
    var removed = 0;
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! File) {
        continue;
      }
      try {
        entry.deleteSync();
        removed++;
      } on FileSystemException {
        // A file still held by a running download is skipped.
      }
    }
    return removed;
  }

  /// Copies [source] into the cache under [sha256].
  File? store(File source, String sha256) {
    try {
      directory.createSync(recursive: true);
      final target = archiveFor(sha256);
      source.copySync(target.path);
      return target;
    } on FileSystemException {
      return null;
    }
  }
}
