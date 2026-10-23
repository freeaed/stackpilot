import 'dart:io';

import 'package:path/path.dart' as p;

import 'stack_layout.dart';

/// Finds stacks inside a folder.
class StackCatalog {
  const StackCatalog._();

  /// Returns stack roots directly inside [folder], sorted by name.
  ///
  /// When [folder] is itself a stack, it is returned on its own so a user who
  /// points at a stack root instead of its parent still gets a usable result.
  static List<String> scan(String folder) {
    final directory = Directory(folder);
    if (!directory.existsSync()) {
      return const [];
    }

    final resolved = p.normalize(folder);
    if (StackLayout.isStackRoot(resolved)) {
      return [resolved];
    }

    final roots = <String>[];
    try {
      for (final entry in directory.listSync(followLinks: true)) {
        if (entry is! Directory) {
          continue;
        }
        if (StackLayout.isStackRoot(entry.path)) {
          roots.add(p.normalize(entry.path));
        }
      }
    } on FileSystemException {
      // Return whatever was found before the folder became unreadable.
    }

    roots.sort((a, b) => p.basename(a).toLowerCase().compareTo(
      p.basename(b).toLowerCase(),
    ));
    return roots;
  }
}
