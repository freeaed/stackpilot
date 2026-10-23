import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Settings that belong to StackPilot rather than to one stack.
///
/// They are stored outside the stack so they survive switching to a different
/// stack folder.
class AppPreferences {
  const AppPreferences({
    this.stacksFolder,
    this.activeStack,
    this.minimizeToTray = true,
  });

  static const empty = AppPreferences();

  /// Folder that contains one or more stacks.
  final String? stacksFolder;

  /// Stack root that was used last.
  final String? activeStack;

  /// Hide the window to the notification area instead of minimizing or closing.
  final bool minimizeToTray;

  AppPreferences copyWith({
    String? stacksFolder,
    String? activeStack,
    bool? minimizeToTray,
  }) {
    return AppPreferences(
      stacksFolder: stacksFolder ?? this.stacksFolder,
      activeStack: activeStack ?? this.activeStack,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    );
  }

  Map<String, Object?> toJson() => {
    if (stacksFolder != null) 'stacksFolder': stacksFolder,
    if (activeStack != null) 'activeStack': activeStack,
    'minimizeToTray': minimizeToTray,
  };

  factory AppPreferences.fromJson(Map<String, Object?> json) {
    return AppPreferences(
      stacksFolder: _path(json['stacksFolder']),
      activeStack: _path(json['activeStack']),
      minimizeToTray: json['minimizeToTray'] is bool
          ? json['minimizeToTray'] as bool
          : empty.minimizeToTray,
    );
  }

  static String? _path(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return p.normalize(value.trim());
  }
}

/// Reads and writes [AppPreferences] as JSON.
///
/// A missing, unreadable, or malformed file is treated as empty preferences so
/// a damaged file never stops the app from starting.
class AppPreferencesStore {
  AppPreferencesStore({File? file}) : _file = file ?? defaultFile();

  final File _file;

  File get file => _file;

  static File defaultFile() {
    final appData = Platform.environment['APPDATA'];
    final base = (appData == null || appData.trim().isEmpty)
        ? p.join(
            Platform.environment['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Roaming',
          )
        : appData;
    return File(p.join(base, 'StackPilot', 'preferences.json'));
  }

  AppPreferences load() {
    if (!_file.existsSync()) {
      return AppPreferences.empty;
    }

    final String source;
    try {
      source = _file.readAsStringSync();
    } on FileSystemException {
      return AppPreferences.empty;
    }
    if (source.trim().isEmpty) {
      return AppPreferences.empty;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return AppPreferences.empty;
    }
    if (decoded is! Map<String, Object?>) {
      return AppPreferences.empty;
    }
    return AppPreferences.fromJson(decoded);
  }

  Future<void> save(AppPreferences preferences) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(preferences.toJson())}\n',
      );
    } on FileSystemException {
      // Persisting preferences is best effort; the app still works this run.
    }
  }
}
