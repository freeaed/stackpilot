import 'dart:io';

import 'package:path/path.dart' as p;

import 'ini.dart';

/// A service/tool directory that StackPilot can detect inside a stack.
enum StackComponent {
  apache('apache'),
  nginx('nginx'),
  mysql('mysql'),
  postgresql('postgresql'),
  php('php'),
  nodejs('nodejs'),
  redis('redis'),
  memcached('memcached'),
  mailpit('mailpit');

  const StackComponent(this.directoryName);

  final String directoryName;
}

/// One installed version of a [StackComponent].
class StackInstall {
  const StackInstall({
    required this.component,
    required this.version,
    required this.directory,
    required this.executablePath,
  });

  final StackComponent component;
  final String version;
  final String directory;
  final String executablePath;

  /// A short label such as `8.3.30` for menus and cards.
  ///
  /// The full directory name stays available as [version] and is used for
  /// writing Laragon's configuration.
  String get displayVersion {
    final dotted = RegExp(r'\d+(?:\.\d+)+').firstMatch(version);
    if (dotted != null) {
      return dotted.group(0)!;
    }
    final major = RegExp(r'v(\d+)', caseSensitive: false).firstMatch(version);
    return major?.group(1) ?? version;
  }

  @override
  String toString() => '${component.directoryName} $version';
}

/// Read-only view of a Laragon-compatible stack directory.
///
/// Detection only reads files. It never starts services or writes config.
class StackLayout {
  StackLayout._({
    required this.root,
    required this.config,
    required Map<StackComponent, List<StackInstall>> installed,
    required Map<StackComponent, StackInstall?> active,
  }) : _installed = Map.unmodifiable(installed),
       _active = Map.unmodifiable(active);

  /// Components StackPilot can start and stop as Windows services.
  static const List<StackComponent> serviceComponents = [
    StackComponent.apache,
    StackComponent.nginx,
    StackComponent.mysql,
    StackComponent.postgresql,
    StackComponent.redis,
    StackComponent.memcached,
    StackComponent.mailpit,
  ];

  /// Components that are runtimes rather than long-running services.
  static const List<StackComponent> runtimeComponents = [
    StackComponent.php,
    StackComponent.nodejs,
  ];

  static const Map<StackComponent, List<String>> _executableParts = {
    StackComponent.apache: ['bin', 'httpd.exe'],
    StackComponent.nginx: ['nginx.exe'],
    StackComponent.mysql: ['bin', 'mysqld.exe'],
    StackComponent.postgresql: ['bin', 'postgres.exe'],
    StackComponent.php: ['php.exe'],
    StackComponent.nodejs: ['node.exe'],
    StackComponent.redis: ['redis-server.exe'],
    StackComponent.memcached: ['memcached.exe'],
    StackComponent.mailpit: ['mailpit.exe'],
  };

  final String root;
  final IniDocument config;
  final Map<StackComponent, List<StackInstall>> _installed;
  final Map<StackComponent, StackInstall?> _active;

  /// True when [root] contains the files that identify a Laragon stack.
  static bool isStackRoot(String root) {
    final resolved = _normalizeRoot(root);
    return File(p.join(resolved, 'usr', 'laragon.ini')).existsSync() &&
        Directory(p.join(resolved, 'bin')).existsSync();
  }

  /// Returns a layout when [root] contains `usr/laragon.ini` and `bin/`.
  static StackLayout? detect(String root) {
    final resolved = _normalizeRoot(root);
    if (!isStackRoot(resolved)) {
      return null;
    }
    final configFile = File(p.join(resolved, 'usr', 'laragon.ini'));

    final IniDocument config;
    try {
      config = IniDocument.parse(configFile.readAsStringSync());
    } on FileSystemException {
      return null;
    }

    final installed = <StackComponent, List<StackInstall>>{};
    for (final component in StackComponent.values) {
      installed[component] = _discover(resolved, component);
    }

    return StackLayout._(
      root: resolved,
      config: config,
      installed: installed,
      active: _readActive(resolved, installed, config),
    );
  }

  List<StackInstall> installedVersions(StackComponent component) =>
      List<StackInstall>.unmodifiable(
        _installed[component] ?? const <StackInstall>[],
      );

  StackInstall? activeVersion(StackComponent component) => _active[component];

  bool serviceEnabled(StackComponent component) =>
      _isEnabled(config.value(component.directoryName, 'Use'));

  String get documentRoot {
    final apacheRoot = config.value('apache', 'DocumentRoot');
    if (apacheRoot != null && apacheRoot.trim().isNotEmpty) {
      return _cleanPath(apacheRoot);
    }

    final rootList = config.value('preferences', 'DocumentRootList');
    if (rootList != null) {
      final first = rootList.split('|').first.trim();
      if (first.isNotEmpty) {
        return _cleanPath(first);
      }
    }

    return p.join(root, 'www');
  }

  String get dataDirectory {
    final configured = config.value('preferences', 'DataDir');
    if (configured != null && configured.trim().isNotEmpty) {
      return _cleanPath(configured);
    }
    return p.join(root, 'data');
  }

  int get mysqlPort =>
      int.tryParse(config.value('mysql', 'Port')?.trim() ?? '') ?? 3306;

  /// PostgreSQL binaries keep their cluster in a data folder rather than next
  /// to the version, so the first existing candidate wins.
  String get postgresqlDataDirectory {
    final candidates = [
      p.join(dataDirectory, 'postgresql'),
      p.join(dataDirectory, 'pgsql'),
      p.join(dataDirectory, 'postgres'),
    ];
    for (final candidate in candidates) {
      if (File(p.join(candidate, 'PG_VERSION')).existsSync()) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }
    return candidates.first;
  }

  String get postgresqlConfigPath =>
      p.join(postgresqlDataDirectory, 'postgresql.conf');

  bool get postgresqlInitialized =>
      File(p.join(postgresqlDataDirectory, 'PG_VERSION')).existsSync();

  int get postgresqlPort {    final configured = int.tryParse(
      config.value('postgresql', 'Port')?.trim() ?? '',
    );
    if (configured != null) {
      return configured;
    }
    return _postgresqlConfPort() ?? 5432;
  }

  int? _postgresqlConfPort() {
    final file = File(postgresqlConfigPath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final match = RegExp(
        r'^[ \t]*port[ \t]*=[ \t]*(\d+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(file.readAsStringSync());
      return int.tryParse(match?.group(1) ?? '');
    } on FileSystemException {
      return null;
    }
  }

  bool get autoVirtualHosts =>
      _isEnabled(config.value('preferences', 'AutoVirtualHosts'));

  /// Folder that serves phpMyAdmin, when one is installed in the web root.
  String? get phpMyAdminDirectory {
    for (final name in const ['phpmyadmin', 'phpMyAdmin', 'pma']) {
      final candidate = p.join(documentRoot, name);
      if (File(p.join(candidate, 'index.php')).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String? get phpMyAdminUrl {
    final directory = phpMyAdminDirectory;
    if (directory == null) {
      return null;
    }
    return 'http://localhost/${Uri.encodeComponent(p.basename(directory))}/';
  }

  /// Absolute path to the executable that identifies [component] inside
  /// [directory].
  static String executablePath(StackComponent component, String directory) =>
      p.joinAll([directory, ..._executableParts[component]!]);

  /// True when [directory] looks like an installed version of [component].
  static bool isInstallDirectory(StackComponent component, String directory) =>
      File(executablePath(component, directory)).existsSync();

  static List<StackInstall> _discover(String root, StackComponent component) {
    final componentDirectory = Directory(
      p.join(root, 'bin', component.directoryName),
    );
    if (!componentDirectory.existsSync()) {
      return const <StackInstall>[];
    }

    final executableParts = _executableParts[component]!;
    final installs = <StackInstall>[];

    for (final entry in componentDirectory.listSync(followLinks: false)) {
      if (entry is! Directory) {
        continue;
      }
      final executable = File(p.joinAll([entry.path, ...executableParts]));
      if (!executable.existsSync()) {
        continue;
      }
      installs.add(
        StackInstall(
          component: component,
          version: p.basename(entry.path),
          directory: entry.path,
          executablePath: executable.path,
        ),
      );
    }

    installs.sort(
      (a, b) => a.version.toLowerCase().compareTo(b.version.toLowerCase()),
    );
    return installs;
  }

  static Map<StackComponent, StackInstall?> _readActive(
    String root,
    Map<StackComponent, List<StackInstall>> installed,
    IniDocument config,
  ) {
    final active = <StackComponent, StackInstall?>{
      for (final component in StackComponent.values) component: null,
    };

    _readProfile(root, installed, active);
    _readConfigVersions(config, installed, active);
    _readLauncherPath(root, installed, active);
    return active;
  }

  /// Older Laragon releases keep the selected version in `usr/laragon.ini`
  /// rather than `usr/profile/default.ini`.
  static void _readConfigVersions(
    IniDocument config,
    Map<StackComponent, List<StackInstall>> installed,
    Map<StackComponent, StackInstall?> active,
  ) {
    for (final component in StackComponent.values) {
      if (active[component] != null) {
        continue;
      }
      final version = config.value(component.directoryName, 'Version')?.trim();
      if (version == null || version.isEmpty) {
        continue;
      }
      for (final install in installed[component] ?? const <StackInstall>[]) {
        if (install.version.toLowerCase() == version.toLowerCase()) {
          active[component] = install;
          break;
        }
      }
    }
  }

  static void _readProfile(
    String root,
    Map<StackComponent, List<StackInstall>> installed,
    Map<StackComponent, StackInstall?> active,
  ) {
    final profileFile = File(p.join(root, 'usr', 'profile', 'default.ini'));
    if (!profileFile.existsSync()) {
      return;
    }

    final IniDocument profile;
    try {
      profile = IniDocument.parse(profileFile.readAsStringSync());
    } on FileSystemException {
      return;
    }

    for (final component in StackComponent.values) {
      final version = profile.value(component.directoryName, 'Version')?.trim();
      if (version == null || version.isEmpty) {
        continue;
      }
      for (final install in installed[component] ?? const <StackInstall>[]) {
        if (install.version.toLowerCase() == version.toLowerCase()) {
          active[component] = install;
          break;
        }
      }
    }
  }

  static void _readLauncherPath(
    String root,
    Map<StackComponent, List<StackInstall>> installed,
    Map<StackComponent, StackInstall?> active,
  ) {
    final launcher = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'));
    if (!launcher.existsSync()) {
      return;
    }

    final String contents;
    try {
      contents = launcher.readAsStringSync();
    } on FileSystemException {
      return;
    }

    final pathMatch = RegExp(
      r'SET\s+"PATH=([^"]*)"',
      caseSensitive: false,
    ).firstMatch(contents);
    if (pathMatch == null) {
      return;
    }

    final pathEntries = pathMatch
        .group(1)!
        .split(';')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();

    for (final component in StackComponent.values) {
      if (active[component] != null) {
        continue;
      }
      StackInstall? best;
      for (final install in installed[component] ?? const <StackInstall>[]) {
        final isActive = pathEntries.any(
          (entry) => _isWithin(entry, install.directory),
        );
        if (isActive &&
            (best == null ||
                install.directory.length > best.directory.length)) {
          best = install;
        }
      }
      active[component] = best;
    }
  }

  static bool _isWithin(String candidate, String directory) {
    final normalizedCandidate = p.normalize(candidate).toLowerCase();
    final normalizedDirectory = p.normalize(directory).toLowerCase();
    return normalizedCandidate == normalizedDirectory ||
        normalizedCandidate.startsWith('$normalizedDirectory${p.separator}');
  }

  static bool _isEnabled(String? value) {
    final normalized = value?.trim();
    return normalized != null &&
        normalized.isNotEmpty &&
        normalized != '0' &&
        normalized.toLowerCase() != 'false';
  }

  static String _cleanPath(String value) {
    var path = value.trim();
    if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
      path = path.substring(1, path.length - 1);
    }
    path = p.normalize(path);
    while (path.length > 3 && (path.endsWith('\\') || path.endsWith('/'))) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  static String _normalizeRoot(String root) => _cleanPath(root);
}
