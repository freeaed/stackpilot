import 'package:path/path.dart' as p;

/// Normalizes a path exactly the way StackPilot stores it.
///
/// Every path that enters the app (text fields, folder pickers, INI values, and
/// config templates) goes through this helper. It only trims whitespace, drops
/// one level of quotes, converts separators to the Windows separator, and
/// resolves `.`/`..` segments — it never interprets backslash sequences, so a
/// folder named `D:\StackPilot_stacks` keeps its capital `S`.
String normalizeWindowsPath(String value) {
  var path = value.trim();
  if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
    path = path.substring(1, path.length - 1).trim();
  }
  if (path.isEmpty) {
    return '';
  }

  // Windows-style input on any host: drive letter (`D:`), UNC (`\\server`) or
  // a path that already uses backslashes.
  final looksWindows =
      RegExp(r'^[A-Za-z]:').hasMatch(path) ||
      path.startsWith(r'\\') ||
      path.contains(r'\');
  path = looksWindows
      ? p.windows.normalize(path)
      : p.normalize(path);

  // Keep `C:\` as it is; drop trailing separators everywhere else.
  final minimum = RegExp(r'^[A-Za-z]:\\$').hasMatch(path) ? 3 : 1;
  while (path.length > minimum &&
      (path.endsWith(r'\') || path.endsWith('/'))) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// True when both values name the same folder on this platform.
///
/// Windows comparisons are case-insensitive and accept either separator.
bool sameWindowsPath(String first, String second) {
  final left = normalizeWindowsPath(first).replaceAll('/', r'\');
  final right = normalizeWindowsPath(second).replaceAll('/', r'\');
  return left.toLowerCase() == right.toLowerCase();
}

/// True when [candidate] is [parent] or lives inside it.
bool isWithinWindowsPath(String parent, String candidate) {
  final root = normalizeWindowsPath(parent).toLowerCase();
  final child = normalizeWindowsPath(candidate).toLowerCase();
  if (root.isEmpty || child.isEmpty) {
    return false;
  }
  if (root == child) {
    return true;
  }
  final prefix = root.endsWith(r'\') ? root : '$root\\';
  return child.startsWith(prefix);
}
