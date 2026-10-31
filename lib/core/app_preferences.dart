import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_info.dart';
import 'paths.dart';
import 'terminal.dart';

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
    this.onboardingCompleted = false,
    this.pendingComponents = const [],
    this.pendingDownloadMode,
    this.terminalShell = 'auto',
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

  /// True once the user finished the first-run setup.
  ///
  /// When it is false the first-run screen always explains what StackPilot is
  /// about. Afterwards a missing stack still opens the screen, but only as a
  /// recovery view instead of the welcome tour.
  final bool onboardingCompleted;

  /// Components chosen in the installer, by directory name (`php`, `apache`,
  /// `mysql`, …). The setup wizard preselects them on first launch and then
  /// clears the list.
  final List<String> pendingComponents;

  /// Download mode chosen in the installer: `now`, `onFirstRun`, or `manual`.
  final String? pendingDownloadMode;

  /// Terminal to open: `auto`, `cmd`, `powershell`, or `windowsTerminal`.
  final String terminalShell;

  AppPreferences copyWith({
    String? stacksFolder,
    String? activeStack,
    bool? minimizeToTray,
    ReleaseChannel? updateChannel,
    Object? updateManifestUrl = _unset,
    bool? autoCheckUpdates,
    bool? onboardingCompleted,
    List<String>? pendingComponents,
    Object? pendingDownloadMode = _unset,
    String? terminalShell,
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
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      pendingComponents: pendingComponents ?? this.pendingComponents,
      pendingDownloadMode: identical(pendingDownloadMode, _unset)
          ? this.pendingDownloadMode
          : pendingDownloadMode as String?,
      terminalShell: terminalShell ?? this.terminalShell,
    );
  }

  Map<String, Object?> toJson() => {
    if (stacksFolder != null) 'stacksFolder': stacksFolder,
    if (activeStack != null) 'activeStack': activeStack,
    'minimizeToTray': minimizeToTray,
    'updateChannel': updateChannel.id,
    if (updateManifestUrl != null) 'updateManifestUrl': updateManifestUrl,
    'autoCheckUpdates': autoCheckUpdates,
    'onboardingCompleted': onboardingCompleted,
    if (pendingComponents.isNotEmpty) 'pendingComponents': pendingComponents,
    if (pendingDownloadMode != null) 'pendingDownloadMode': pendingDownloadMode,
    'terminalShell': terminalShell,
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
      onboardingCompleted: json['onboardingCompleted'] is bool
          ? json['onboardingCompleted'] as bool
          : empty.onboardingCompleted,
      pendingComponents: _components(json['pendingComponents']),
      pendingDownloadMode: _url(json['pendingDownloadMode']),
      terminalShell: TerminalShell.parse(
        json['terminalShell'] is String ? json['terminalShell'] as String : null,
      ).id,
    );
  }

  static List<String> _components(Object? value) {
    if (value is! List) {
      return const [];
    }
    return [
      for (final entry in value)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    ];
  }

  static String? _path(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return normalizeWindowsPath(value);
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
      // Preferences are a few hundred bytes, so writing them synchronously
      // keeps the UI state consistent and avoids a half-written file when the
      // app is closed right after a change.
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(preferences.toJson())}\n',
        flush: true,
      );
    } on FileSystemException {
      // Persisting preferences is best effort; the app still works this run.
    }
  }
}
