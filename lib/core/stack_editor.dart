import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'ini.dart';
import 'paths.dart';
import 'stack_layout.dart';
import 'stack_settings.dart';

class StackEditException implements Exception {
  const StackEditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// URL for phpMyAdmin plus whether Apache has to reload to serve it.
class PhpMyAdminServing {
  const PhpMyAdminServing({required this.url, required this.changed});

  final String url;
  final bool changed;
}

/// Result of `httpd -t`.
class ApacheConfigCheck {
  const ApacheConfigCheck({required this.ok, required this.output});

  final bool ok;
  final String output;
}

typedef ApacheProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  String workingDirectory,
);

/// Writes the small set of stack files involved in changing a version or a
/// setting. Every existing file is backed up once as `<name>.stackpilot.bak`.
class StackEditor {
  StackEditor(this.layout);

  static const _backupSuffix = '.stackpilot.bak';
  static const _legacyBackupSuffix = '.laraserver.bak';

  final StackLayout layout;

  String get _root => layout.root;
  String get _markerPath => layout.markerPath;
  String get _profilePath => p.join(_root, 'usr', 'profile', 'default.ini');
  String get _launcherPath => layout.launcherPath;

  /// Selects an installed version everywhere the stack reads it from.
  void selectVersion(StackComponent component, StackInstall install) {
    if (install.component != component) {
      throw const StackEditException(
        'The selected version is for another component.',
      );
    }
    final directory = p.normalize(install.directory);
    if (!StackLayout.isInstallDirectory(component, directory)) {
      throw StackEditException(
        'That ${component.directoryName} version is no longer installed in '
        '${p.dirname(directory)}.',
      );
    }

    _ensureVersionConfig(component, install);
    _writeProfileVersion(component, install.version);
    _writeMarkerVersion(component, install.version);
    _updateLauncher(component, install);

    if (component == StackComponent.php) {
      _updateApachePhp(install);
      _ensurePhpExtensionDir(install);
    }

    if (component == StackComponent.mysql) {
      _updateMysqlPort(layout.mysqlPort, install: install);
    }

    if (component == StackComponent.postgresql) {
      _updatePostgresqlPort(layout.postgresqlPort);
    }
  }

  /// Installs phpMyAdmin from a ZIP.
  ///
  /// By default the copy goes to `<document root>/phpmyadmin`; pass
  /// [targetDirectory] to install it elsewhere, such as the Laragon-compatible
  /// `<stack>/etc/apps/phpmyadmin`. The archive is unpacked in a temporary
  /// folder so a failed download never leaves a half-installed copy behind.
  Future<String> installPhpMyAdminArchive(
    String archivePath, {
    String? targetDirectory,
  }) async {
    final archive = File(archivePath);
    if (!archive.existsSync()) {
      throw StackEditException('Archive not found: $archivePath');
    }

    final explicitTarget = targetDirectory?.trim() ?? '';
    final target = explicitTarget.isEmpty
        ? p.join(_root, 'etc', 'apps', 'phpmyadmin')
        : normalizeWindowsPath(explicitTarget);
    final existing = Directory(target);
    if (existing.existsSync()) {
      if (StackLayout.isPhpMyAdminDirectory(target)) {
        throw StackEditException('phpMyAdmin is already installed at $target.');
      }
      // Earlier builds copied `libraries/classes` here because Windows matched
      // its `Index.php`/`Sql.php` classes against `index.php`/`sql.php`. That
      // folder can never serve phpMyAdmin, so replace it.
      _deleteQuietly(existing);
    }

    final staging = Directory.systemTemp.createTempSync('stackpilot_pma_');
    try {
      await _extractArchive(archive, staging);
      final source = _locatePhpMyAdmin(staging);
      if (source == null) {
        throw const StackEditException(
          'That archive does not contain a phpMyAdmin folder. Download the '
          '"all languages" ZIP from phpmyadmin.net.',
        );
      }
      await _copyDirectory(source, Directory(target));
      _writePhpMyAdminConfig(target, force: true);
      _writePhpMyAdminAlias(target);
      return target;
    } finally {
      _deleteQuietly(staging);
    }
  }

  /// Downloads a phpMyAdmin ZIP and installs it into the web root.
  Future<String> downloadPhpMyAdmin(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw const StackEditException('Enter a valid download URL.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const StackEditException('Only HTTP and HTTPS downloads work.');
    }

    final name = p.basename(uri.path);
    final download = File(
      p.join(
        Directory.systemTemp.path,
        'stackpilot-${DateTime.now().microsecondsSinceEpoch}-'
        '${name.isEmpty ? 'phpmyadmin.zip' : name}',
      ),
    );
    try {
      await _download(uri, download);
      return await installPhpMyAdminArchive(download.path);
    } finally {
      try {
        if (download.existsSync()) {
          download.deleteSync();
        }
      } on FileSystemException {
        // The temporary file is cleaned up by the OS if it is still locked.
      }
    }
  }

  static Directory? _locatePhpMyAdmin(Directory root) {
    final queue = <({Directory directory, int depth})>[
      (directory: root, depth: 0),
    ];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (StackLayout.isPhpMyAdminDirectory(current.directory.path)) {
        return current.directory;
      }
      if (current.depth >= 3) {
        continue;
      }
      List<FileSystemEntity> entries;
      try {
        entries = current.directory.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        if (entry is Directory) {
          queue.add((directory: entry, depth: current.depth + 1));
        }
      }
    }
    return null;
  }

  /// Writes a Laragon-style config that connects as root with no password.
  ///
  /// Rewrites the file when the configured MySQL port changed; returns whether
  /// anything was written.
  bool _writePhpMyAdminConfig(String directory, {bool force = false}) {
    final file = File(p.join(directory, 'config.inc.php'));
    if (file.existsSync() && !force) {
      final existing = _readText(file) ?? '';
      final port = RegExp(
        r"\['port'\]\s*=\s*'(\d+)'",
      ).firstMatch(existing)?.group(1);
      if (port == '${layout.mysqlPort}' &&
          existing.contains("'127.0.0.1'") &&
          existing.contains('AllowNoPassword')) {
        return false;
      }
    }

    final random = Random.secure();
    final secret = List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''<?php
\$cfg['blowfish_secret'] = '$secret';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'config';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = '${layout.mysqlPort}';
\$cfg['Servers'][\$i]['user'] = 'root';
\$cfg['Servers'][\$i]['password'] = '';
\$cfg['Servers'][\$i]['AllowNoPassword'] = true;
''');
    return true;
  }

  /// Makes sure a locally installed phpMyAdmin is served at `/phpmyadmin`.
  ///
  /// Ensures PHP's Apache module and the alias includes are active, refreshes
  /// the config for the current MySQL port, and returns the URL to open plus
  /// whether Apache has to reload. Returns null when phpMyAdmin is not
  /// installed.
  PhpMyAdminServing? ensurePhpMyAdminServing() {
    final directory = layout.phpMyAdminDirectory;
    if (directory == null) {
      return null;
    }

    var changed = false;
    final php = layout.activeVersion(StackComponent.php);
    if (php != null) {
      final moduleFile = File(p.join(_root, 'etc', 'apache2', 'mod_php.conf'));
      final hadModule = moduleFile.existsSync();
      try {
        preparePhpModule(php);
        if (!hadModule) {
          changed = true;
        }
      } on StackEditException {
        // The page still needs PHP; the caller reports the missing module.
      }
      if (refreshApacheConfig()) {
        changed = true;
      }
    }
    if (_writePhpMyAdminConfig(directory)) {
      changed = true;
    }
    if (_writePhpMyAdminAlias(directory)) {
      changed = true;
    }
    return PhpMyAdminServing(
      url: layout.phpMyAdminUrl ?? 'http://127.0.0.1/phpmyadmin/',
      changed: changed,
    );
  }

  /// Runs `httpd -t` to validate the active Apache config.
  Future<ApacheConfigCheck> verifyApacheConfig({
    ApacheProcessRunner? run,
  }) async {
    final apache = layout.activeVersion(StackComponent.apache);
    if (apache == null) {
      return const ApacheConfigCheck(
        ok: false,
        output: 'Apache is not installed or has no active version.',
      );
    }
    final runner = run ?? Process.run;
    try {
      final result = await runner(
        apache.executablePath,
        ['-f', p.join(apache.directory, 'conf', 'httpd.conf'), '-t'],
        apache.directory,
      );
      final output = '${result.stdout}${result.stderr}'.trim();
      return ApacheConfigCheck(
        ok: result.exitCode == 0,
        output: output.isEmpty
            ? 'httpd -t exited with code ${result.exitCode}.'
            : output,
      );
    } on ProcessException catch (error) {
      return ApacheConfigCheck(
        ok: false,
        output: 'Could not run httpd -t: ${error.message}',
      );
    }
  }

  /// Points `/phpmyadmin` at [directory] through the stack's Apache alias
  /// folder.
  ///
  /// Laragon ships `etc/apache2/alias/phpmyadmin.conf` mapping the URL to
  /// `etc/apps/phpMyAdmin`. When that folder is missing the alias still wins
  /// over the document root, and Apache answers 403 because the mapped path is
  /// covered by no `<Directory>` block. Rewriting every alias that claims the
  /// URL keeps `/phpmyadmin` working on both stack flavours.
  ///
  /// `Require all granted` is deliberate: the stack binds Apache to 127.0.0.1
  /// by default, and `Require local` breaks when the browser reaches it
  /// through a `.test` host or a LAN address.
  bool _writePhpMyAdminAlias(String directory) {
    final aliasDirectory = Directory(p.join(_root, 'etc', 'apache2', 'alias'));
    aliasDirectory.createSync(recursive: true);

    final target = _slash(directory);
    final aliasTarget = target.endsWith('/') ? target : '$target/';
    final contents = <String>[
      '# StackPilot phpMyAdmin - generated, do not edit',
      'Alias /phpmyadmin "$aliasTarget"',
      '<Directory "$aliasTarget">',
      '    Options FollowSymLinks',
      '    DirectoryIndex index.php',
      '    AllowOverride All',
      '    Require all granted',
      '</Directory>',
      '',
    ].join('\r\n');

    final aliasPattern = RegExp(
      r'^[ \t]*Alias[ \t]+/(?:phpmyadmin|pma)(?![\w.-])',
      caseSensitive: false,
      multiLine: true,
    );

    var changed = false;
    var written = false;
    List<FileSystemEntity> entries;
    try {
      entries = aliasDirectory.listSync(followLinks: false);
    } on FileSystemException {
      entries = const [];
    }
    for (final entity in entries) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.conf')) {
        continue;
      }
      final text = _readText(entity);
      if (text == null || !aliasPattern.hasMatch(text)) {
        continue;
      }
      if (text != contents) {
        _writeWithBackup(entity, contents);
        changed = true;
      }
      written = true;
    }

    if (!written) {
      final file = File(p.join(aliasDirectory.path, 'phpmyadmin.conf'));
      if (_readText(file) != contents) {
        _writeWithBackup(file, contents);
        changed = true;
      }
    }

    if (_ensureApacheInclude('alias')) {
      changed = true;
    }
    return changed;
  }

  /// Adds the `sites-enabled/*.conf` include when the Apache config predates
  /// the folder, so generated virtual hosts are actually loaded.
  void ensureApacheVhostInclude() => _ensureApacheInclude('sites-enabled');

  /// Returns true when the Apache config was changed.
  bool _ensureApacheInclude(String folder) {
    final apache = layout.activeVersion(StackComponent.apache);
    if (apache == null) {
      return false;
    }
    final file = File(p.join(apache.directory, 'conf', 'httpd.conf'));
    final source = _readText(file);
    if (source == null) {
      return false;
    }
    final needle = 'etc/apache2/$folder';
    final normalized = source.toLowerCase().replaceAll('\\', '/');
    if (normalized.contains(needle)) {
      return false;
    }
    final etcPath = _slash(p.join(_root, 'etc', 'apache2'));
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    _writeWithBackup(
      file,
      '${source.trimRight()}$eol'
      'IncludeOptional "$etcPath/$folder/*.conf"$eol',
    );
    return true;
  }

  /// Copies an already extracted version folder into `bin/<component>`.
  Future<StackInstall> importFolder(
    StackComponent component,
    String sourcePath,
  ) async {
    final normalized = p.normalize(sourcePath.trim());
    final source = Directory(normalized);
    if (!source.existsSync()) {
      throw StackEditException('Folder not found: $normalized');
    }

    final name = p.basename(normalized);
    if (name.isEmpty || name == '.' || name == p.separator) {
      throw StackEditException('Choose a version folder, not a drive root.');
    }

    return _installDirectory(component, source, name);
  }

  /// Extracts a ZIP archive and moves the version folder into the stack.
  ///
  /// [preferredName] names the folder when the archive has no single top-level
  /// folder. [installName] forces the folder name even when the archive ships
  /// one, which keeps catalog installs at `bin/<component>/<version>`.
  Future<StackInstall> installArchive(
    StackComponent component,
    String archivePath, {
    String? preferredName,
    String? installName,
  }) async {
    final archive = File(archivePath);
    if (!archive.existsSync()) {
      throw StackEditException('Archive not found: $archivePath');
    }

    final temporary = Directory.systemTemp.createTempSync(
      'stackpilot_archive_',
    );
    try {
      final extracted = Directory(p.join(temporary.path, 'extracted'));
      await _extractArchive(archive, extracted);

      final source = _locateInstall(component, extracted);
      if (source == null) {
        throw StackEditException(
          'The archive does not contain a ${component.directoryName} '
          'executable.',
        );
      }

      final override = installName?.trim();
      final fallback = (override != null && override.isNotEmpty)
          ? override
          : preferredName?.trim().isNotEmpty == true
          ? preferredName!.trim()
          : p.basenameWithoutExtension(archive.path);
      final name =
          (override != null && override.isNotEmpty) ||
              p.equals(source.path, extracted.path)
          ? fallback
          : p.basename(source.path);
      return await _installDirectory(component, source, name, move: true);
    } finally {
      _deleteQuietly(temporary);
    }
  }

  /// Downloads a ZIP archive and installs it as a new version.
  Future<StackInstall> downloadAndInstall(
    StackComponent component,
    String url, {
    void Function(int received, int? total)? onProgress,
    String? installName,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const StackEditException(
        'Enter an http:// or https:// download link.',
      );
    }

    final temporary = Directory.systemTemp.createTempSync(
      'stackpilot_download_',
    );
    try {
      final archive = File(p.join(temporary.path, 'download.zip'));
      await _download(uri, archive, onProgress: onProgress);
      final name = uri.pathSegments.isEmpty
          ? null
          : p.basenameWithoutExtension(uri.pathSegments.last);
      return await installArchive(
        component,
        archive.path,
        preferredName: name,
        installName: installName,
      );
    } finally {
      _deleteQuietly(temporary);
    }
  }

  /// Applies the settings shown in the settings dialog.
  void applySettings(StackSettings settings) {
    final documentRoot = normalizeWindowsPath(settings.documentRoot);
    final dataDirectory = normalizeWindowsPath(settings.dataDirectory);
    if (documentRoot.isEmpty) {
      throw const StackEditException('Document root cannot be empty.');
    }
    if (dataDirectory.isEmpty) {
      throw const StackEditException('Data directory cannot be empty.');
    }
    if (settings.mysqlPort < 1 || settings.mysqlPort > 65535) {
      throw const StackEditException('MySQL port must be between 1 and 65535.');
    }
    if (settings.postgresqlPort < 1 || settings.postgresqlPort > 65535) {
      throw const StackEditException(
        'PostgreSQL port must be between 1 and 65535.',
      );
    }

    for (final iniFile in _markerTargets) {
      final source = _readText(iniFile) ?? '';
      final editor = IniEditor.parse(source)
        ..setValue('preferences', 'DataDir', dataDirectory)
        ..setValue(
          'preferences',
          'AutoVirtualHosts',
          settings.autoVirtualHosts ? '-1' : '0',
        )
        ..setValue(
          'preferences',
          'DocumentRootList',
          _replaceFirstRoot(
            layout.config.value('preferences', 'DocumentRootList'),
            documentRoot,
          ),
        )
        ..setValue('apache', 'DocumentRoot', documentRoot)
        ..setValue('apache', 'SSLEnabled', settings.apacheSsl ? '-1' : '0')
        ..setValue(
          'apache',
          'ListenOnLan',
          settings.apacheListenOnLan ? '-1' : '0',
        )
        ..setValue('mysql', 'Port', '${settings.mysqlPort}')
        ..setValue('postgresql', 'Port', '${settings.postgresqlPort}');

      for (final component in StackLayout.serviceComponents) {
        editor.setValue(
          component.directoryName,
          'Use',
          settings.enabledServices.contains(component) ? '-1' : '0',
        );
      }

      _writeWithBackup(iniFile, editor.serialize());
    }

    if (!p.equals(documentRoot, layout.documentRoot)) {
      _updateApacheDocumentRoot(
        layout.documentRoot,
        documentRoot,
        includeApacheConfig: layout.flavor == StackFlavor.laragon,
      );
    }
    if (settings.mysqlPort != layout.mysqlPort) {
      _updateMysqlPort(settings.mysqlPort);
    }
    if (settings.postgresqlPort != layout.postgresqlPort) {
      _updatePostgresqlPort(settings.postgresqlPort);
    }
    _applyPhpSettings(settings.php);

    // A generated Apache config carries the document root and SSL setting, so
    // rewrite it after the marker changes.
    if (layout.flavor != StackFlavor.laragon) {
      refreshApacheConfig();
    }
  }

  /// Changes the port [component] listens on.
  ///
  /// MySQL and PostgreSQL go through [applySettings] so their data files and
  /// client configs follow. The others update the stack marker plus the file
  /// the service reads at startup. Apache vhosts on the old port are moved to
  /// the new one.
  Future<void> changeServicePort(StackComponent component, int port) async {
    if (port < 1 || port > 65535) {
      throw const StackEditException('Port must be between 1 and 65535.');
    }

    switch (component) {
      case StackComponent.mysql:
      case StackComponent.postgresql:
        applySettings(
          StackSettings.load(layout).copyWith(
            mysqlPort: component == StackComponent.mysql ? port : null,
            postgresqlPort: component == StackComponent.postgresql
                ? port
                : null,
          ),
        );
      case StackComponent.apache:
        final oldPort = layout.apachePort;
        _writeMarkerValue('apache', 'Port', '$port');
        _moveApachePort(oldPort, port);
      case StackComponent.nginx:
        final oldPort = layout.nginxPort;
        _writeMarkerValue('nginx', 'Port', '$port');
        _rewriteNginxPort(oldPort, port);
      case StackComponent.redis:
        _writeMarkerValue('redis', 'Port', '$port');
        _rewriteRedisPort(port);
      case StackComponent.mailpit:
      case StackComponent.memcached:
        _writeMarkerValue(component.directoryName, 'Port', '$port');
      case StackComponent.php:
      case StackComponent.nodejs:
        throw const StackEditException('That component has no port.');
    }
  }

  void _writeMarkerValue(String section, String key, String value) {
    for (final file in _markerTargets) {
      final source = _readText(file);
      if (source == null) {
        continue;
      }
      final editor = IniEditor.parse(source)..setValue(section, key, value);
      _writeWithBackup(file, editor.serialize());
    }
  }

  /// Rewrites Apache's Listen lines and any vhost on [oldPort].
  void _moveApachePort(int oldPort, int newPort) {
    // The editor re-detects the marker, so the template and the Laragon patch
    // both pick up the new port and bind address.
    refreshApacheConfig();

    final directory = Directory(p.join(_root, 'etc', 'apache2', 'sites-enabled'));
    List<FileSystemEntity> entries;
    try {
      entries = directory.existsSync()
          ? directory.listSync(followLinks: false)
          : const [];
    } on FileSystemException {
      entries = const [];
    }
    final virtualHost = RegExp(
      r'(<VirtualHost[ \t]+[^:>\s]+:)(\d+)',
      caseSensitive: false,
    );
    for (final entry in entries) {
      if (entry is! File || !entry.path.toLowerCase().endsWith('.conf')) {
        continue;
      }
      final source = _readText(entry);
      if (source == null) {
        continue;
      }
      final updated = source.replaceAllMapped(virtualHost, (match) {
        return match.group(2) == '$oldPort'
            ? '${match.group(1)}$newPort'
            : match.group(0)!;
      });
      if (updated != source) {
        _writeWithBackup(entry, updated);
      }
    }
  }

  void _rewriteNginxPort(int oldPort, int newPort) {
    final install = layout.activeVersion(StackComponent.nginx);
    if (install == null) {
      return;
    }
    final file = File(p.join(install.directory, 'conf', 'nginx.conf'));
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final pattern = RegExp(
      r'^([ \t]*listen[ \t]+)(?:[^;\r\n:]+:)?(\d+)',
      caseSensitive: false,
      multiLine: true,
    );
    final updated = source.replaceAllMapped(pattern, (match) {
      return match.group(2) == '$oldPort'
          ? '${match.group(1)}$newPort'
          : match.group(0)!;
    });
    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  void _rewriteRedisPort(int port) {
    final install = layout.activeVersion(StackComponent.redis);
    if (install == null) {
      return;
    }
    final file = File(p.join(install.directory, 'redis.conf'));
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final updated = source.replaceAllMapped(
      RegExp(
        r'^([ \t]*port[ \t]*=[ \t]*)(\d+)',
        caseSensitive: false,
        multiLine: true,
      ),
      (match) => '${match.group(1)}$port',
    ).replaceAllMapped(
      RegExp(
        r'^([ \t]*port[ \t]+)(\d+)($)',
        caseSensitive: false,
        multiLine: true,
      ),
      (match) => '${match.group(1)}$port',
    );
    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  /// Turns a service on or off in the stack marker.
  ///
  /// Provisioning uses this after a component is installed so the service can
  /// be started without opening the settings dialog first.
  void setServiceEnabled(StackComponent component, bool enabled) {
    for (final file in _markerTargets) {
      final source = _readText(file);
      if (source == null) {
        continue;
      }
      final editor = IniEditor.parse(source)
        ..setValue(component.directoryName, 'Use', enabled ? '-1' : '0');
      _writeWithBackup(file, editor.serialize());
    }
  }

  /// Marker files to keep in sync.
  ///
  /// An adopted Laragon stack keeps both `usr/stackpilot.ini` and
  /// `usr/laragon.ini`, so Laragon can still open it. Writing the same version
  /// and settings to both markers keeps the two views from drifting.
  List<File> get _markerTargets {
    final files = <File>[File(_markerPath)];
    final other = layout.flavor == StackFlavor.laragon
        ? StackFlavor.stackpilot
        : StackFlavor.laragon;
    final path = p.join(_root, 'usr', other.markerFileName);
    if (!p.equals(path, _markerPath) && File(path).existsSync()) {
      files.add(File(path));
    }
    return files;
  }

  /// Re-applies the stack paths to the active Apache config.
  ///
  /// Provisioning calls this after `mod_php.conf` is created, so an Apache
  /// version installed before PHP still gains the include.
  ///
  /// Returns true when the Apache config changed.
  bool refreshApacheConfig() {
    final current = StackLayout.detect(_root);
    if (current == null) {
      return false;
    }
    final apache = current.activeVersion(StackComponent.apache);
    if (apache == null) {
      return false;
    }
    final file = File(p.join(apache.directory, 'conf', 'httpd.conf'));
    final before = _readText(file);
    StackEditor(current)._prepareApacheConfig(apache);
    return _readText(file) != before;
  }

  /// Rewrites [install]'s Apache config for this stack.
  ///
  /// Provisioning calls this after an Apache archive is unpacked, so the
  /// config points at this stack even when the version is not active yet.
  void prepareApacheConfig(StackInstall install) {
    if (install.component != StackComponent.apache) {
      throw const StackEditException('That version is not Apache.');
    }
    _prepareApacheConfig(install);
  }

  /// Creates the PHP config files this stack needs for [install].
  void preparePhp(StackInstall install) {
    if (install.component != StackComponent.php) {
      throw const StackEditException('That version is not PHP.');
    }
    _ensurePhpIni(install);
    _ensurePhpExtensionDir(install);
    preparePhpModule(install);
  }

  /// Writes `etc/apache2/mod_php.conf` when it is missing and points it at
  /// [install].
  ///
  /// Apache's config includes this file, so creating it is what makes a
  /// downloaded PHP version serve `.php` files.
  void preparePhpModule(StackInstall install) {
    if (install.component != StackComponent.php) {
      throw const StackEditException(
        'The Apache PHP module needs a PHP version.',
      );
    }

    final file = File(p.join(_root, 'etc', 'apache2', 'mod_php.conf'));
    if (!file.existsSync()) {
      final directory = _slash(install.directory);
      final crypto =
          _findDll(install.directory, 'libcrypto') ?? 'libcrypto-3-x64.dll';
      final ssl = _findDll(install.directory, 'libssl') ?? 'libssl-3-x64.dll';
      final module =
          _findPhpApacheModule(install.directory) ?? 'php8apache2_4.dll';
      _writeWithBackup(
        file,
        [
          '# PHP for Apache, generated by StackPilot.',
          'LoadFile "$directory/$crypto"',
          'LoadFile "$directory/$ssl"',
          'LoadModule php_module "$directory/$module"',
          '<IfModule php_module>',
          '    PHPIniDir "$directory"',
          '    DirectoryIndex index.php index.html',
          '    AddType application/x-httpd-php .php',
          '    AddType application/x-httpd-php-source .phps',
          '</IfModule>',
          '',
        ].join('\r\n'),
      );
    }
    _updateApachePhp(install);
  }

  Future<StackInstall> _installDirectory(
    StackComponent component,
    Directory source,
    String name, {
    bool move = false,
  }) async {
    final executable = StackLayout.executablePath(component, source.path);
    if (!File(executable).existsSync()) {
      throw StackEditException(
        'That folder does not look like a ${component.directoryName} '
        'installation (missing ${p.basename(executable)}).',
      );
    }
    if (component == StackComponent.apache &&
        !File(p.join(source.path, 'conf', 'httpd.conf')).existsSync()) {
      throw const StackEditException(
        'That Apache folder is missing conf/httpd.conf, so it cannot start.',
      );
    }

    final targetRoot = Directory(p.join(_root, 'bin', component.directoryName));
    final trimmedName = name.trim();
    if (trimmedName.isEmpty ||
        trimmedName == '.' ||
        trimmedName == '..' ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(trimmedName)) {
      throw StackEditException(
        '"$name" is not a valid ${component.directoryName} folder name.',
      );
    }
    final target = Directory(p.join(targetRoot.path, trimmedName));
    if (p.equals(p.normalize(source.path), p.normalize(target.path))) {
      throw StackEditException(
        '${component.directoryName} $name is already installed.',
      );
    }
    if (target.existsSync()) {
      throw StackEditException(
        '${component.directoryName} $name already exists in '
        '${targetRoot.path}.',
      );
    }

    targetRoot.createSync(recursive: true);
    if (move) {
      try {
        source.renameSync(target.path);
      } on FileSystemException {
        await _copyDirectory(source, target);
        _deleteQuietly(source);
      }
    } else {
      await _copyDirectory(source, target);
    }

    if (!StackLayout.isInstallDirectory(component, target.path)) {
      throw StackEditException(
        'The copied ${component.directoryName} folder is incomplete.',
      );
    }

    final install = StackInstall(
      component: component,
      version: trimmedName,
      directory: target.path,
      executablePath: StackLayout.executablePath(component, target.path),
    );
    _ensureVersionConfig(component, install);
    return install;
  }

  void _ensureVersionConfig(StackComponent component, StackInstall install) {
    if (component == StackComponent.php) {
      _ensurePhpIni(install);
      _ensurePhpExtensionDir(install);
      return;
    }

    if (component == StackComponent.apache) {
      _prepareApacheConfig(install);
      return;
    }

    if (component == StackComponent.mysql) {
      final ini = File(p.join(install.directory, 'my.ini'));
      if (ini.existsSync()) {
        return;
      }
      final active = layout.activeVersion(StackComponent.mysql);
      if (active == null) {
        return;
      }
      final source = File(p.join(active.directory, 'my.ini'));
      if (source.existsSync()) {
        _writeWithBackup(ini, _readText(source) ?? '');
      }
    }
  }

  /// Creates a working `php.ini` for a newly imported version.
  ///
  /// The active version's ini is reused so user settings survive a version
  /// change. A fresh PHP download only ships `php.ini-development`, so that
  /// fallback also enables the extensions Laragon turns on by default.
  void _ensurePhpIni(StackInstall install) {
    final ini = File(p.join(install.directory, 'php.ini'));
    if (ini.existsSync()) {
      return;
    }

    final active = layout.activeVersion(StackComponent.php);
    String? source;
    var fromDevelopment = false;
    if (active != null && !p.equals(active.directory, install.directory)) {
      source = _readText(File(p.join(active.directory, 'php.ini')));
    }
    if (source == null) {
      source = _readText(
        File(p.join(install.directory, 'php.ini-development')),
      );
      fromDevelopment = true;
    }
    if (source == null) {
      return;
    }

    final temporary = _slash(p.join(_root, 'tmp'));
    var contents = _setDirectiveIncludingComments(
      source,
      'error_log',
      '"$temporary/php_errors.log"',
    );
    contents = _setDirectiveIncludingComments(
      contents,
      'session.save_path',
      '"$temporary"',
    );
    if (fromDevelopment) {
      contents = _enableCommonPhpExtensions(contents, install.directory);
    }
    _writeWithBackup(ini, contents);
  }

  static const List<String> _commonPhpExtensions = [
    'curl',
    'fileinfo',
    'gd',
    'intl',
    'mbstring',
    'exif',
    'mysqli',
    'openssl',
    'pdo_mysql',
    'pdo_pgsql',
    'pdo_sqlite',
    'pgsql',
    'sodium',
    'sqlite3',
    'xsl',
  ];

  String _enableCommonPhpExtensions(String source, String directory) {
    final extensionDirectory = Directory(p.join(directory, 'ext'));
    if (!extensionDirectory.existsSync()) {
      return source;
    }

    final available = <String>{};
    for (final entity in extensionDirectory.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basenameWithoutExtension(entity.path);
      if (name.startsWith('php_')) {
        available.add(name.substring(4).toLowerCase());
      }
    }
    if (available.isEmpty) {
      return source;
    }

    final enabled = <String>{};
    for (final name in _commonPhpExtensions) {
      if (available.contains(name)) {
        enabled.add(name);
      } else if (name == 'gd' && available.contains('gd2')) {
        enabled.add('gd2');
      }
    }
    if (enabled.isEmpty) {
      return source;
    }

    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final extensionPattern = RegExp(
      r'^([ \t]*);([ \t]*extension[ \t]*=[ \t]*)([A-Za-z0-9_]+)(.*)$',
      caseSensitive: false,
    );
    return source
        .split(RegExp(r'\r\n|\n|\r'))
        .map((line) {
          final match = extensionPattern.firstMatch(line);
          if (match == null ||
              !enabled.contains(match.group(3)!.toLowerCase())) {
            return line;
          }
          return '${match.group(1)}${match.group(2)}'
              '${match.group(3)}${match.group(4)}';
        })
        .join(eol);
  }

  /// Writes the Apache config for this stack.
  ///
  /// StackPilot stacks get a complete config generated from a template, so the
  /// document root, SSL, and enabled modules always match the stack marker.
  /// Laragon stacks keep their vendor config and are patched in place, because
  /// Laragon still owns that file.
  void _prepareApacheConfig(StackInstall install) {
    if (layout.flavor == StackFlavor.laragon) {
      _patchApacheConfig(install);
      return;
    }
    _writeApacheConfig(install);
  }

  /// Rewrites an Apache download so it uses this stack's paths and files.
  ///
  /// Apache Lounge archives are built for `C:/Apache24`: their `ServerRoot`
  /// and `DocumentRoot` point outside the stack, Laragon's includes are
  /// missing, and modules such as rewrite/SSL start commented out. Patch
  /// those directives while keeping the rest of the vendor config intact.
  void _patchApacheConfig(StackInstall install) {
    final file = File(p.join(install.directory, 'conf', 'httpd.conf'));
    final source = _readText(file);
    if (source == null) {
      throw StackEditException(
        'Apache ${install.version} is missing conf/httpd.conf.',
      );
    }

    final installPath = _slash(install.directory);
    final documentRoot = _slash(layout.documentRoot);
    final etcDirectory = p.join(_root, 'etc', 'apache2');
    final etcPath = _slash(etcDirectory);
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final lines = source.split(RegExp(r'\r\n|\n|\r'));

    String? existingDocumentRoot;
    final documentRootLine = RegExp(
      r'^[ \t]*DocumentRoot[ \t]+(.*)$',
      caseSensitive: false,
    );
    for (final line in lines) {
      final match = documentRootLine.firstMatch(line);
      if (match != null) {
        existingDocumentRoot = _unquote(match.group(1)!);
        break;
      }
    }

    final availableModules = _availableApacheModules(install.directory);
    final includePattern = RegExp(
      r'^[ \t]*Include(Optional)?[ \t]+.*[\\/]etc[\\/]apache2(?:[\\/]|$)',
      caseSensitive: false,
    );
    final serverRootPattern = RegExp(
      r'^[ \t]*ServerRoot[ \t]',
      caseSensitive: false,
    );
    final defineRootPattern = RegExp(
      r'^[ \t]*Define[ \t]+SRVROOT[ \t]',
      caseSensitive: false,
    );
    final documentRootPattern = RegExp(
      r'^[ \t]*DocumentRoot[ \t]',
      caseSensitive: false,
    );
    final scriptAliasPattern = RegExp(
      r'^[ \t]*ScriptAlias[ \t]+/cgi-bin/',
      caseSensitive: false,
    );
    final serverNamePattern = RegExp(
      r'^[ \t]*ServerName[ \t]',
      caseSensitive: false,
    );
    final listenPattern = RegExp(
      r'^([ \t]*)Listen[ \t]+(.+)$',
      caseSensitive: false,
    );
    final hasServerName = lines.any(serverNamePattern.hasMatch);
    final directoryPattern = RegExp(
      r'^([ \t]*<Directory[ \t]+)"([^"]*)"(.*)$',
      caseSensitive: false,
    );

    final updated = <String>[];
    for (final line in lines) {
      if (serverRootPattern.hasMatch(line)) {
        updated.add('ServerRoot "$installPath"');
        continue;
      }
      if (defineRootPattern.hasMatch(line)) {
        updated.add('Define SRVROOT "$installPath"');
        continue;
      }
      if (documentRootPattern.hasMatch(line)) {
        updated.add('DocumentRoot "$documentRoot"');
        continue;
      }
      if (scriptAliasPattern.hasMatch(line)) {
        updated.add('ScriptAlias /cgi-bin/ "$installPath/cgi-bin/"');
        continue;
      }
      final listenMatch = listenPattern.firstMatch(line);
      if (listenMatch != null) {
        final rewritten = _rewriteListen(
          listenMatch.group(2)!.trim(),
          layout.apachePort,
          onLan: layout.apacheListenOnLan,
        );
        if (rewritten != null) {
          updated.add('${listenMatch.group(1)}Listen $rewritten');
          continue;
        }
      }

      final directoryMatch = directoryPattern.firstMatch(line);
      if (directoryMatch != null) {
        final path = directoryMatch.group(2)!.trim();
        if (existingDocumentRoot != null &&
            _samePath(path, existingDocumentRoot)) {
          updated.add(
            '${directoryMatch.group(1)}"$documentRoot"'
            '${directoryMatch.group(3)}',
          );
          continue;
        }
        if (_isCgiBinPath(path)) {
          updated.add(
            '${directoryMatch.group(1)}"$installPath/cgi-bin"'
            '${directoryMatch.group(3)}',
          );
          continue;
        }
      }

      if (includePattern.hasMatch(line)) {
        continue;
      }
      updated.add(_enableApacheModule(line, availableModules));
    }

    while (updated.isNotEmpty && updated.last.trim().isEmpty) {
      updated.removeLast();
    }

    // Apache cannot determine its own host name on Windows and warns
    // (AH00558) on every start; a plain ServerName keeps the log clean.
    if (!hasServerName) {
      updated.add('ServerName localhost');
    }
    if (Directory(p.join(etcDirectory, 'alias')).existsSync()) {
      updated.add('IncludeOptional "$etcPath/alias/*.conf"');
    }
    if (Directory(p.join(etcDirectory, 'sites-enabled')).existsSync()) {
      updated.add('IncludeOptional "$etcPath/sites-enabled/*.conf"');
    }
    if (File(p.join(etcDirectory, 'httpd-ssl.conf')).existsSync()) {
      updated.add('Include "$etcPath/httpd-ssl.conf"');
    }
    if (File(p.join(etcDirectory, 'mod_php.conf')).existsSync()) {
      updated.add('Include "$etcPath/mod_php.conf"');
    }

    final contents = '${updated.join(eol)}$eol';
    if (contents != source) {
      _writeWithBackup(file, contents);
    }
  }

  /// Marker at the top of the generated Apache config.
  static const _apacheTemplateMarker =
      '# StackPilot Apache configuration - generated, do not edit';

  /// Modules StackPilot loads when Apache ships their `mod_*.so` file.
  ///
  /// Order matters: MPM first, then modules other directives depend on
  /// (authentication, logging, MIME, rewrite), and SSL last. PHP is loaded by
  /// `etc/apache2/mod_php.conf`, so changing the PHP version never requires
  /// rewriting this file. Apache Lounge builds `mpm_winnt` into `httpd.exe`
  /// and has no `mod_mpm_winnt.so`, so a missing module is simply skipped.
  static const List<String> _templateApacheModules = [
    'mpm_winnt',
    'authn_core',
    'authn_file',
    'authz_core',
    'authz_host',
    'authz_user',
    'authz_groupfile',
    'access_compat',
    'auth_basic',
    'log_config',
    'logio',
    'env',
    'setenvif',
    'filter',
    'version',
    'headers',
    'alias',
    'dir',
    'autoindex',
    'mime',
    'rewrite',
    'reqtimeout',
    'expires',
    'deflate',
    'socache_shmcb',
    'ssl',
  ];

  /// Writes a complete `conf/httpd.conf` for a StackPilot stack.
  ///
  /// The Apache Lounge config is preserved as `conf/httpd.conf.vendor` the
  /// first time, so nothing is lost. Log paths stay relative to `ServerRoot`
  /// because the log viewer reads `logs/error.log` from the install directory.
  void _writeApacheConfig(StackInstall install) {
    final directory = install.directory;

    final file = File(p.join(directory, 'conf', 'httpd.conf'));
    final vendor = File('${file.path}.vendor');
    final existing = _readText(file);
    if (existing != null && !vendor.existsSync()) {
      try {
        file.copySync(vendor.path);
      } on FileSystemException {
        // The generated config below is what matters; a read-only vendor file
        // is not worth failing over.
      }
    }

    final available = _availableApacheModules(directory);
    final installPath = _slash(directory);
    final documentRoot = _slash(layout.documentRoot);
    final etcDirectory = p.join(_root, 'etc', 'apache2');
    final etcPath = _slash(etcDirectory);
    Directory(p.join(directory, 'logs')).createSync(recursive: true);

    final lines = <String>[
      _apacheTemplateMarker,
      '# The Apache Lounge original is kept as httpd.conf.vendor.',
      '',
      'ServerRoot "$installPath"',
      layout.apacheListenOnLan
          ? 'Listen ${layout.apachePort}'
          : 'Listen 127.0.0.1:${layout.apachePort}',
      'ServerName localhost',
      'ServerAdmin admin@localhost',
      '',
      '# --- Modules --------------------------------------------------------',
    ];

    for (final module in _templateApacheModules) {
      final fileName = 'mod_$module.so';
      if (!available.contains(fileName)) {
        continue;
      }
      lines.add('LoadModule ${module}_module "modules/$fileName"');
    }

    lines.addAll([
      '',
      '<IfModule mpm_winnt_module>',
      '    ThreadsPerChild 150',
      '    MaxConnectionsPerChild 0',
      '</IfModule>',
      '',
      'DocumentRoot "$documentRoot"',
      '<Directory "$documentRoot">',
      '    Options Indexes FollowSymLinks',
      '    AllowOverride All',
      '    Require all granted',
      '</Directory>',
      '<Directory />',
      '    AllowOverride None',
      '    Require all denied',
      '</Directory>',
      '<Files ".ht*">',
      '    Require all denied',
      '</Files>',
      '',
      '<IfModule dir_module>',
      '    DirectoryIndex index.php index.html index.htm',
      '</IfModule>',
      '<IfModule mime_module>',
      '    TypesConfig conf/mime.types',
      '</IfModule>',
      '',
      'ErrorLog "logs/error.log"',
      'LogLevel warn',
      'LogFormat "%h %l %u %t \\"%r\\" %>s %b" common',
      'LogFormat "%h %l %u %t \\"%r\\" %>s %b \\"%{Referer}i\\" '
          '\\"%{User-Agent}i\\"" combined',
      'CustomLog "logs/access.log" combined',
      '',
    ]);

    if (Directory(p.join(etcDirectory, 'alias')).existsSync()) {
      lines.add('IncludeOptional "$etcPath/alias/*.conf"');
    }
    if (File(p.join(etcDirectory, 'mod_php.conf')).existsSync()) {
      lines.add('Include "$etcPath/mod_php.conf"');
    }
    if (Directory(p.join(etcDirectory, 'sites-enabled')).existsSync()) {
      lines.add('IncludeOptional "$etcPath/sites-enabled/*.conf"');
    }

    final sslConfig = File(p.join(etcDirectory, 'httpd-ssl.conf'));
    final sslModule =
        available.contains('mod_ssl.so') &&
        available.contains('mod_socache_shmcb.so');
    final certificate = _firstExisting(p.join(_root, 'etc', 'ssl'), const [
      'stackpilot.crt',
      'laragon.crt',
    ]);
    final key = _firstExisting(p.join(_root, 'etc', 'ssl'), const [
      'stackpilot.key',
      'laragon.key',
    ]);
    final sslEnabled =
        _isEnabled(layout.config.value('apache', 'SSLEnabled')) &&
        certificate != null &&
        key != null;

    if (sslConfig.existsSync()) {
      lines
        ..add('')
        ..add('Include "$etcPath/httpd-ssl.conf"');
    } else if (sslEnabled && sslModule) {
      lines.addAll([
        '',
        layout.apacheListenOnLan ? 'Listen 443' : 'Listen 127.0.0.1:443',
        '<IfModule ssl_module>',
        '    SSLRandomSeed startup builtin',
        '    SSLRandomSeed connect builtin',
        '    SSLSessionCache "shmcb:logs/ssl_scache(512000)"',
        '    SSLSessionCacheTimeout 300',
        '    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1',
        '    SSLCipherSuite HIGH:!aNULL:!MD5',
        '</IfModule>',
        '<VirtualHost *:443>',
        '    ServerName localhost',
        '    DocumentRoot "$documentRoot"',
        '    SSLEngine on',
        '    SSLCertificateFile "${_slash(certificate)}"',
        '    SSLCertificateKeyFile "${_slash(key)}"',
        '    <Directory "$documentRoot">',
        '        Options Indexes FollowSymLinks',
        '        AllowOverride All',
        '        Require all granted',
        '    </Directory>',
        '</VirtualHost>',
      ]);
    }

    lines.add('');

    final contents = lines.join('\r\n');
    if (contents != existing) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }
  }

  /// Reads a boolean stack-marker value (`-1`, `1`, `on`, `true`, `yes`).
  static bool _isEnabled(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '-1' ||
        normalized == '1' ||
        normalized == 'on' ||
        normalized == 'true' ||
        normalized == 'yes';
  }

  /// First existing file in [directory] from [names], or null.
  static String? _firstExisting(String directory, List<String> names) {
    for (final name in names) {
      final path = p.join(directory, name);
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  /// Modules Laragon loads from Apache's stock `httpd.conf`.
  static const Set<String> _laragonApacheModules = {
    'access_compat_module',
    'alias_module',
    'auth_basic_module',
    'authn_core_module',
    'authn_file_module',
    'authz_core_module',
    'authz_groupfile_module',
    'authz_host_module',
    'authz_user_module',
    'autoindex_module',
    'dir_module',
    'env_module',
    'filter_module',
    'headers_module',
    'log_config_module',
    'mime_module',
    'reqtimeout_module',
    'rewrite_module',
    'setenvif_module',
    'socache_shmcb_module',
    'ssl_module',
    'version_module',
  };

  static Set<String> _availableApacheModules(String directory) {
    final modules = Directory(p.join(directory, 'modules'));
    if (!modules.existsSync()) {
      return const <String>{};
    }
    return {
      for (final entity in modules.listSync(followLinks: false))
        if (entity is File) p.basename(entity.path).toLowerCase(),
    };
  }

  static String _enableApacheModule(String line, Set<String> availableModules) {
    final match = RegExp(
      r'^([ \t]*)#[ \t]*(LoadModule[ \t]+([A-Za-z0-9_]+)[ \t]+([^ \t\r\n]+).*)$',
    ).firstMatch(line);
    if (match == null ||
        !_laragonApacheModules.contains(match.group(3)) ||
        !availableModules.contains(p.basename(match.group(4)!).toLowerCase())) {
      return line;
    }
    return '${match.group(1)}${match.group(2)}';
  }

  static String _slash(String value) => value.replaceAll('\\', '/');

  /// Rewrites a `Listen` argument to the stack port and bind address.
  ///
  /// An explicit non-loopback host (for example a named interface) is left
  /// alone. Returns null when the line should not be touched.
  static String? _rewriteListen(
    String value,
    int port, {
    required bool onLan,
  }) {
    final argument = value.split(RegExp(r'\s+')).first;
    final portMatch = RegExp(r'(\d+)$').firstMatch(argument);
    if (portMatch == null) {
      return null;
    }
    final host = argument
        .substring(0, argument.length - portMatch.group(1)!.length)
        .replaceAll(':', '')
        .replaceAll('[', '')
        .replaceAll(']', '')
        .trim();
    final wildcard =
        host.isEmpty || host == '*' || host == '0.0.0.0' || host == '::';
    if (!wildcard && host != '127.0.0.1' && host != 'localhost') {
      return null;
    }
    return onLan ? '$port' : '127.0.0.1:$port';
  }

  static String _unquote(String value) {
    var result = value.trim();
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      result = result.substring(1, result.length - 1);
    }
    return result;
  }

  static bool _samePath(String first, String second) {
    String clean(String value) {
      var result = _unquote(value).replaceAll('\\', '/').toLowerCase();
      while (result.length > 1 && result.endsWith('/')) {
        result = result.substring(0, result.length - 1);
      }
      return result;
    }

    return clean(first) == clean(second);
  }

  static bool _isCgiBinPath(String value) {
    final path = _unquote(value).replaceAll('\\', '/').toLowerCase();
    return path.endsWith('/cgi-bin') || path.endsWith('/cgi-bin/');
  }

  void _writeProfileVersion(StackComponent component, String version) {
    final file = File(_profilePath);
    final source = _readText(file) ?? '';
    final editor = IniEditor.parse(source)
      ..setValue(component.directoryName, 'Version', version);
    _writeWithBackup(file, editor.serialize());
  }

  /// Updates the version in the stack marker.
  ///
  /// A Laragon marker is only touched when it already carries a `Version` key,
  /// so an older install keeps its own shape. A StackPilot marker is ours, so
  /// the key is added when missing. Adopted stacks write both markers.
  void _writeMarkerVersion(StackComponent component, String version) {
    _writeVersionTo(
      File(_markerPath),
      component,
      version,
      addWhenMissing: layout.flavor != StackFlavor.laragon,
    );
    for (final file in _markerTargets.skip(1)) {
      _writeVersionTo(file, component, version, addWhenMissing: false);
    }
  }

  void _writeVersionTo(
    File file,
    StackComponent component,
    String version, {
    required bool addWhenMissing,
  }) {
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final parsed = IniDocument.parse(source);
    if (!addWhenMissing &&
        parsed.section(component.directoryName)?.value('Version') == null) {
      return;
    }
    final editor = IniEditor.parse(source)
      ..setValue(component.directoryName, 'Version', version);
    _writeWithBackup(file, editor.serialize());
  }

  void _updateLauncher(StackComponent component, StackInstall install) {
    if (layout.flavor == StackFlavor.laragon) {
      _patchLaragonLauncher(component, install);
    } else {
      _writeNativeLauncher(component, install);
    }
    _writePowerShellLauncher();
  }

  /// Makes sure the stack launcher exists and reflects the active versions.
  ///
  /// Returns the `.cmd` path. A terminal started through it has `php`, `mysql`,
  /// `node`, and the other active binaries on `PATH`.
  String ensureLauncher() {
    if (layout.flavor == StackFlavor.laragon) {
      final file = File(_launcherPath);
      if (file.existsSync()) {
        // Laragon keeps this file under its own control; only refresh the
        // PowerShell companion.
        _writePowerShellLauncher();
        return file.path;
      }
    }
    _writeLauncherFile(_activeInstalls());
    _writePowerShellLauncher();
    return _launcherPath;
  }

  /// Path of the PowerShell companion launcher (`. <path>` sets PATH).
  String get powerShellLauncherPath {
    final directory = p.dirname(_launcherPath);
    final name = layout.flavor == StackFlavor.laragon
        ? 'laragon.ps1'
        : 'stackpilot.ps1';
    return p.join(directory, name);
  }

  Map<StackComponent, StackInstall?> _activeInstalls() {
    // Re-read the profile: the layout passed to the editor can predate a
    // version change made in the same run.
    final current = StackLayout.detect(_root) ?? layout;
    return {
      for (final component in StackComponent.values)
        component: current.activeVersion(component),
    };
  }

  List<String> _launcherEntries(
    Map<StackComponent, StackInstall?> active,
  ) {
    final entries = <String>[];
    for (final candidate in _launcherOrder) {
      final current = active[candidate];
      if (current == null) {
        continue;
      }
      entries.add(
        candidate == StackComponent.apache
            ? p.join(current.directory, 'bin')
            : current.directory,
      );
    }
    return entries;
  }

  void _writeLauncherFile(Map<StackComponent, StackInstall?> active) {
    final entries = _launcherEntries(active);
    final apache = active[StackComponent.apache];
    final openssl = apache == null
        ? null
        : File(p.join(apache.directory, 'conf', 'openssl.cnf'));
    final lines = [
      '@echo off',
      'rem Generated by StackPilot. Rewritten when a version changes.',
      'set "STACKPILOT_ROOT=${_slash(_root)}"',
      'set "PATH=${entries.join(';')};%PATH%"',
      if (openssl != null && openssl.existsSync())
        'set "OPENSSL_CONF=${_slash(openssl.path)}"',
      'if "%~1"=="" (',
      '  "%COMSPEC%" /k',
      ') else (',
      '  %*',
      ')',
      '',
    ];
    final file = File(_launcherPath);
    file.parent.createSync(recursive: true);
    final contents = lines.join('\r\n');
    if (_readText(file) != contents) {
      file.writeAsStringSync(contents);
    }
  }

  /// Writes the PowerShell launcher used by the PowerShell terminal option.
  void _writePowerShellLauncher() {
    final active = _activeInstalls();
    final entries = _launcherEntries(active);
    final apache = active[StackComponent.apache];
    final openssl = apache == null
        ? null
        : File(p.join(apache.directory, 'conf', 'openssl.cnf'));
    final lines = [
      '# Generated by StackPilot. Dot-source this file to load the stack.',
      "\$env:STACKPILOT_ROOT = '${_psQuote(_root)}'",
      "\$env:PATH = '${_psQuote(entries.join(';'))};' + \$env:PATH",
      if (openssl != null && openssl.existsSync())
        "\$env:OPENSSL_CONF = '${_psQuote(openssl.path)}'",
      '',
    ];
    final file = File(powerShellLauncherPath);
    file.parent.createSync(recursive: true);
    final contents = lines.join('\r\n');
    if (_readText(file) != contents) {
      file.writeAsStringSync(contents);
    }
  }

  /// Rewrites `bin/stackpilot.cmd` for a StackPilot-owned stack.
  ///
  /// The script prepends the active binaries to `PATH`, so a terminal started
  /// through it can run `php`, `mysql`, `node`, and friends without the user
  /// setting up PATH by hand. It is regenerated on every version change, so it
  /// always mirrors `usr/profile/default.ini`.
  void _writeNativeLauncher(StackComponent component, StackInstall install) {
    final active = _activeInstalls();
    active[component] = install;
    _writeLauncherFile(active);
  }

  /// Order in which components are added to the launcher `PATH`.
  ///
  /// PHP and Node.js come first so `php`/`node` resolve to this stack even if
  /// another runtime is already on PATH.
  static const List<StackComponent> _launcherOrder = [
    StackComponent.php,
    StackComponent.nodejs,
    StackComponent.apache,
    StackComponent.nginx,
    StackComponent.mysql,
    StackComponent.postgresql,
    StackComponent.redis,
    StackComponent.memcached,
    StackComponent.mailpit,
  ];

  /// Adds the active binaries to a Laragon-provided launcher.
  void _patchLaragonLauncher(StackComponent component, StackInstall install) {
    final file = File(_launcherPath);
    final source = _readText(file);
    if (source == null) {
      return;
    }

    var updated = source;
    final pathPattern = RegExp(
      r'(SET\s+"PATH=)([^"]*)(")',
      caseSensitive: false,
    );
    updated = updated.replaceFirstMapped(pathPattern, (pathMatch) {
      final entries = pathMatch.group(2)!.split(';');
      final componentRoot = p.join(_root, 'bin', component.directoryName);
      final rebuilt = <String>[];
      var placed = false;
      for (final entry in entries) {
        if (_isWithin(entry, componentRoot)) {
          if (!placed) {
            rebuilt.add(
              _versionPathReplacement(entry, componentRoot, install.directory),
            );
            placed = true;
          }
          continue;
        }
        rebuilt.add(entry);
      }
      if (!placed) {
        var insertAt = rebuilt.indexWhere(
          (entry) => entry.toUpperCase().contains('%PATH%'),
        );
        if (insertAt < 0) {
          insertAt = rebuilt.length;
        }
        rebuilt.insert(insertAt, install.directory);
      }
      return '${pathMatch.group(1)}${rebuilt.join(';')}${pathMatch.group(3)}';
    });

    if (component == StackComponent.apache) {
      final opensslPattern = RegExp(
        r'(SET\s+"OPENSSL_CONF=)([^"]*)(")',
        caseSensitive: false,
      );
      final opensslFile = File(
        p.join(install.directory, 'conf', 'openssl.cnf'),
      );
      if (opensslFile.existsSync()) {
        final conf = _slash(opensslFile.path);
        updated = updated.replaceFirstMapped(
          opensslPattern,
          (match) => '${match.group(1)}$conf${match.group(3)}',
        );
      }
    }

    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  void _updateApachePhp(StackInstall install) {
    final file = File(p.join(_root, 'etc', 'apache2', 'mod_php.conf'));
    final source = _readText(file);
    if (source == null) {
      return;
    }

    final directory = _slash(install.directory);
    final crypto =
        _findDll(install.directory, 'libcrypto') ?? 'libcrypto-3-x64.dll';
    final ssl = _findDll(install.directory, 'libssl') ?? 'libssl-3-x64.dll';
    final module =
        _findPhpApacheModule(install.directory) ?? 'php8apache2_4.dll';
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final updated = source
        .split(RegExp(r'\r\n|\n|\r'))
        .map((line) {
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('LoadFile ')) {
            final value = _quotedValue(line);
            if (value == null) {
              return line;
            }
            final name = p.basename(value).toLowerCase();
            if (name.startsWith('libcrypto')) {
              return _replaceQuotedValue(line, '$directory/$crypto');
            }
            if (name.startsWith('libssl')) {
              return _replaceQuotedValue(line, '$directory/$ssl');
            }
            return _replaceQuotedValue(line, '$directory/${p.basename(value)}');
          }
          if (RegExp(
            r'^LoadModule[ \t]+php_module[ \t]',
            caseSensitive: false,
          ).hasMatch(trimmed)) {
            return _replaceQuotedValue(line, '$directory/$module');
          }
          if (trimmed.startsWith('PHPIniDir ')) {
            return _replaceQuotedValue(line, directory);
          }
          return line;
        })
        .join(eol);

    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  void _ensurePhpExtensionDir(StackInstall install) {
    final file = File(p.join(install.directory, 'php.ini'));
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final extensionDirectory = _slash(p.join(install.directory, 'ext'));
    final updated = _setDirectiveIncludingComments(
      source,
      'extension_dir',
      '"$extensionDirectory"',
    );
    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  /// Sets a directive even when its only definition is commented out.
  ///
  /// PHP's stock ini ships many useful directives as comments. Editing the
  /// existing line keeps the file readable instead of appending a duplicate.
  static String _setDirectiveIncludingComments(
    String source,
    String key,
    String value,
  ) {
    final pattern = RegExp(
      '^([ \\t]*)(?:;[ \\t]*)?'
      '(${RegExp.escape(key)}[ \\t]*=[ \\t]*)([^\\r\\n]*)',
      caseSensitive: false,
      multiLine: true,
    );
    if (pattern.hasMatch(source)) {
      return source.replaceFirstMapped(
        pattern,
        (match) => '${match.group(1)}${match.group(2)}$value',
      );
    }
    return setIniDirective(source, key, value);
  }

  static String? _findDll(String directory, String prefix) {
    final folder = Directory(directory);
    if (!folder.existsSync()) {
      return null;
    }
    final matches = <String>[];
    for (final entity in folder.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      final lower = name.toLowerCase();
      if (lower.startsWith(prefix) && lower.endsWith('.dll')) {
        matches.add(name);
      }
    }
    matches.sort();
    return matches.isEmpty ? null : matches.first;
  }

  static String? _findPhpApacheModule(String directory) {
    final folder = Directory(directory);
    if (!folder.existsSync()) {
      return null;
    }
    final pattern = RegExp(r'^php\d+apache2_4\.dll$', caseSensitive: false);
    for (final entity in folder.listSync(followLinks: false)) {
      if (entity is File && pattern.hasMatch(p.basename(entity.path))) {
        return p.basename(entity.path);
      }
    }
    return null;
  }

  static String? _quotedValue(String line) {
    final match = RegExp(r'"([^"]*)"').firstMatch(line);
    return match?.group(1);
  }

  static String _replaceQuotedValue(String line, String value) {
    return line.replaceFirstMapped(RegExp(r'"[^"]*"'), (_) => '"$value"');
  }

  void _updateApacheDocumentRoot(
    String oldRoot,
    String newRoot, {
    bool includeApacheConfig = true,
  }) {
    final apache = layout.activeVersion(StackComponent.apache);
    if (apache == null) {
      return;
    }

    final files = [
      if (includeApacheConfig)
        File(p.join(apache.directory, 'conf', 'httpd.conf')),
      File(p.join(_root, 'etc', 'apache2', 'sites-enabled', '00-default.conf')),
    ];

    for (final file in files) {
      final source = _readText(file);
      if (source == null) {
        continue;
      }
      var updated = _replacePath(
        source,
        oldRoot.replaceAll('\\', '/'),
        newRoot.replaceAll('\\', '/'),
      );
      updated = _replacePath(
        updated,
        oldRoot.replaceAll('/', '\\'),
        newRoot.replaceAll('/', '\\'),
      );
      if (updated != source) {
        _writeWithBackup(file, updated);
      }
    }
  }

  void _updateMysqlPort(int port, {StackInstall? install}) {
    final mysql = install ?? layout.activeVersion(StackComponent.mysql);
    if (mysql == null) {
      return;
    }
    final file = File(p.join(mysql.directory, 'my.ini'));
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final updated = setIniDirective(source, 'port', '$port', all: true);
    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  void _updatePostgresqlPort(int port) {
    final file = File(layout.postgresqlConfigPath);
    final source = _readText(file);
    if (source == null) {
      return;
    }
    final updated = setIniDirective(source, 'port', '$port', all: true);
    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  void _applyPhpSettings(PhpIniSettings settings) {
    final iniPath = settings.iniPath;
    if (iniPath == null) {
      return;
    }
    final file = File(iniPath);
    final source = _readText(file);
    if (source == null) {
      return;
    }

    var updated = source;
    updated = setIniDirective(updated, 'memory_limit', settings.memoryLimit);
    updated = setIniDirective(
      updated,
      'upload_max_filesize',
      settings.uploadMaxFilesize,
    );
    updated = setIniDirective(updated, 'post_max_size', settings.postMaxSize);
    updated = setIniDirective(
      updated,
      'max_execution_time',
      settings.maxExecutionTime,
    );
    updated = setIniDirective(
      updated,
      'display_errors',
      settings.displayErrors ? 'On' : 'Off',
    );

    if (updated != source) {
      _writeWithBackup(file, updated);
    }
  }

  Future<void> _download(
    Uri uri,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw StackEditException(
          'Download failed with HTTP ${response.statusCode}.',
        );
      }

      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
    } on SocketException catch (error) {
      throw StackEditException('Download failed: ${error.message}');
    } on HttpException catch (error) {
      throw StackEditException('Download failed: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _extractArchive(File archive, Directory destination) async {
    destination.createSync(recursive: true);

    final powershell = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Expand-Archive -LiteralPath ${_psQuote(archive.path)} '
          '-DestinationPath ${_psQuote(destination.path)} -Force',
    ]);
    if (powershell.exitCode == 0) {
      return;
    }

    final tar = await Process.run('tar.exe', [
      '-xf',
      archive.path,
      '-C',
      destination.path,
    ]);
    if (tar.exitCode == 0) {
      return;
    }

    throw StackEditException(
      'Could not extract ${p.basename(archive.path)}.\n'
      '${powershell.stderr}\n${tar.stderr}',
    );
  }

  Directory? _locateInstall(StackComponent component, Directory root) {
    final queue = <({Directory directory, int depth})>[
      (directory: root, depth: 0),
    ];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (StackLayout.isInstallDirectory(component, current.directory.path)) {
        return current.directory;
      }
      if (current.depth >= 3) {
        continue;
      }
      for (final entry in current.directory.listSync(followLinks: false)) {
        if (entry is Directory) {
          queue.add((directory: entry, depth: current.depth + 1));
        }
      }
    }
    return null;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    target.createSync(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        await entity.copy(destination);
      } else if (entity is Link) {
        await Link(destination).create(entity.targetSync());
      }
    }
  }

  String? _readText(File file) {
    if (!file.existsSync()) {
      return null;
    }
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  void _writeWithBackup(File file, String contents) {
    file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      final backup = File('${file.path}$_backupSuffix');
      final legacyBackup = File('${file.path}$_legacyBackupSuffix');
      if (!backup.existsSync() && !legacyBackup.existsSync()) {
        try {
          file.copySync(backup.path);
        } on FileSystemException {
          // A read-only file will fail on the write below with a clearer error.
        }
      }
    }
    file.writeAsStringSync(contents);
  }

  static String _replaceFirstRoot(String? current, String newRoot) {
    if (current == null || current.trim().isEmpty) {
      return '$newRoot|';
    }
    final parts = current.split('|');
    parts[0] = newRoot;
    return parts.join('|');
  }

  static String _replacePath(String source, String oldPath, String newPath) {
    if (oldPath.isEmpty) {
      return source;
    }
    final pattern = RegExp(RegExp.escape(oldPath), caseSensitive: false);
    return source.replaceAllMapped(pattern, (_) => newPath);
  }

  static bool _isWithin(String candidate, String directory) {
    final normalizedCandidate = p.normalize(candidate).toLowerCase();
    final normalizedDirectory = p.normalize(directory).toLowerCase();
    return normalizedCandidate == normalizedDirectory ||
        normalizedCandidate.startsWith('$normalizedDirectory${p.separator}');
  }

  /// MySQL and Apache add a trailing `bin` folder to PATH. Keep whatever
  /// follows the version directory when swapping it.
  static String _versionPathReplacement(
    String entry,
    String componentRoot,
    String installDirectory,
  ) {
    final normalizedEntry = p.normalize(entry);
    final normalizedRoot = p.normalize(componentRoot);
    var suffix = normalizedEntry.length > normalizedRoot.length
        ? normalizedEntry.substring(normalizedRoot.length)
        : '';
    while (suffix.startsWith(p.separator)) {
      suffix = suffix.substring(1);
    }
    final segments = suffix
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    final tail = segments.length > 1 ? p.joinAll(segments.skip(1)) : '';
    return tail.isEmpty ? installDirectory : p.join(installDirectory, tail);
  }

  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  static void _deleteQuietly(Directory directory) {
    try {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Temporary folders are best-effort cleanup.
    }
  }
}
