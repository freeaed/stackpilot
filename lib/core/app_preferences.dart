import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_info.dart';

/// Settings that belong to StackPilot rather than to one stack.
///
/// They are stored outside the stack so they survive switching to a different
/// stack folder.
class AppPreferences {
  const AppPreferences({
    this.stacksFolder,
    this.activeStack,
    this.minimizeToTray = true,
    this.updateChannel = ReleaseChannel.stable,
    this.updateManifestUrl,
    this.autoCheckUpdates = true,
  });

  static const empty = AppPreferences();

  static const _unset = Object();

  /// Folder that contains one or more stacks.
  final String? stacksFolder;

  /// Stack root that was used last.
  final String? activeStack;

  /// Hide the window to the notification area instead of minimizing or closing.
  final bool minimizeToTray;

  /// Release channel followed by update checks.
  final ReleaseChannel updateChannel;

  /// Overrides the manifest URL compiled into the build.
  final String? updateManifestUrl;

  /// Check for a new release shortly after startup.
  final bool autoCheckUpdates;

  AppPreferences copyWith({
    String? stacksFolder,
    String? activeStack,
    bool? minimizeToTray,
    ReleaseChannel? updateChannel,
    Object? updateManifestUrl = _unset,
    bool? autoCheckUpdates,
  }) {
    return AppPreferences(
      stacksFolder: stacksFolder ?? this.stacksFolder,
      activeStack: activeStack ?? this.activeStack,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      updateChannel: updateChannel ?? this.updateChannel,
      updateManifestUrl: identical(updateManifestUrl, _unset)
          ? this.updateManifestUrl
          : updateManifestUrl as String?,
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
    );
  }

  Map<String, Object?> toJson() => {
    if (stacksFolder != null) 'stacksFolder': stacksFolder,
    if (activeStack != null) 'activeStack': activeStack,
    'minimizeToTray': minimizeToTray,
    'updateChannel': updateChannel.id,
    if (updateManifestUrl != null) 'updateManifestUrl': updateManifestUrl,
    'autoCheckUpdates': autoCheckUpdates,
  };

  factory AppPreferences.fromJson(Map<String, Object?> json) {
    final rawChannel = json['updateChannel'];
    return AppPreferences(
      stacksFolder: _path(json['stacksFolder']),
      activeStack: _path(json['activeStack']),
      minimizeToTray: json['minimizeToTray'] is bool
          ? json['minimizeToTray'] as bool
          : empty.minimizeToTray,
      // A file written before channels existed follows the build's channel.
      updateChannel: rawChannel is String && ReleaseChannel.isKnown(rawChannel)
          ? ReleaseChannel.parse(rawChannel)
          : AppInfo.channel,
      updateManifestUrl: _url(json['updateManifestUrl']),
      autoCheckUpdates: json['autoCheckUpdates'] is bool
          ? json['autoCheckUpdates'] as bool
          : empty.autoCheckUpdates,
    );
  }

  static String? _path(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return p.normalize(value.trim());
  }

  static String? _url(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
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
      return _defaults();
    }

    final String source;
    try {
      source = _file.readAsStringSync();
    } on FileSystemException {
      return _defaults();
    }
    if (source.trim().isEmpty) {
      return _defaults();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return _defaults();
    }
    if (decoded is! Map<String, Object?>) {
      return _defaults();
    }
    return AppPreferences.fromJson(decoded);
  }

  /// Defaults follow the channel this build was compiled for.
  AppPreferences _defaults() =>
      AppPreferences(updateChannel: AppInfo.channel);

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
