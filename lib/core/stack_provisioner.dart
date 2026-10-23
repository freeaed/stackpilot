import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'bundled_payload.dart';
import 'component_catalog.dart';
import 'ini.dart';
import 'stack_editor.dart';
import 'stack_layout.dart';

/// Where a component is in the download → verify → install → configure cycle.
enum ProvisionPhase {
  queued,
  downloading,
  verifying,
  installing,
  configuring,
  done,
  failed,
}

/// Progress for one component installation.
class ProvisionProgress {
  const ProvisionProgress({
    required this.release,
    required this.phase,
    this.index = 0,
    this.count = 0,
    this.received = 0,
    this.total,
    this.message,
  });

  final ComponentRelease release;
  final ProvisionPhase phase;

  /// 1-based position of [release] in the current run.
  final int index;
  final int count;

  final int received;
  final int? total;
  final String? message;

  /// Download fraction, or null when the server did not send a length.
  double? get fraction {
    final length = total;
    if (length == null || length <= 0) {
      return null;
    }
    return (received / length).clamp(0.0, 1.0);
  }

  @override
  String toString() => '${release.label}: ${phase.name}';
}

/// A component that is installed and configured in the stack.
class ProvisionedComponent {
  const ProvisionedComponent({
    required this.release,
    required this.install,
    required this.activated,
    required this.alreadyInstalled,
  });

  final ComponentRelease release;
  final StackInstall install;
  final bool activated;
  final bool alreadyInstalled;
}

class ProvisionFailure {
  const ProvisionFailure(this.release, this.message);

  final ComponentRelease release;
  final String message;

  @override
  String toString() => '${release.label}: $message';
}

/// Outcome of installing several components.
///
/// A failed component does not roll back the others: the stack keeps whatever
/// was installed successfully and the report lists what needs a retry.
class ProvisionReport {
  const ProvisionReport({required this.installed, required this.failures});

  final List<ProvisionedComponent> installed;
  final List<ProvisionFailure> failures;

  bool get ok => failures.isEmpty;
}

class ProvisionException implements Exception {
  const ProvisionException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef ProvisionDownload =
    Future<void> Function(
      Uri uri,
      File destination,
      void Function(int received, int? total) onProgress,
    );

typedef ProvisionCommand =
    Future<int> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
    );

typedef ProvisionDigest = Future<String> Function(File file);

typedef ProvisionInstall =
    Future<StackInstall> Function(
      StackComponent component,
      String archivePath,
      String installName,
    );

/// Downloads pinned component builds and configures them for one stack.
///
/// The provisioner never touches another tool's files: archives land in
/// `bin/<component>/<version>`, service data goes to this stack's `data/`
/// folder, and generated configs point at this stack's paths.
class StackProvisioner {
  StackProvisioner(
    this.layout, {
    ProvisionDownload? download,
    ProvisionCommand? run,
    ProvisionDigest? digest,
    this.installArchive,
    BundledPayload? payload,
  }) : _download = download ?? _httpDownload,
       _run = run ?? _runProcess,
       _digest = digest ?? _sha256OfFile,
       _payload = payload ?? BundledPayload.locate();

  final StackLayout layout;
  final ProvisionDownload _download;
  final ProvisionCommand _run;
  final ProvisionDigest _digest;
  final ProvisionInstall? installArchive;
  final BundledPayload? _payload;

  /// Offline archives found next to the app, if any.
  BundledPayload? get payload => _payload;

  /// Latest view of the stack, refreshed after every install.
  StackLayout get _current => StackLayout.detect(layout.root) ?? layout;

  /// Installs one component and makes it the active version.
  Future<ProvisionedComponent> install(
    ComponentRelease release, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
  }) => _install(
    release,
    onProgress: onProgress,
    activate: activate,
    index: 1,
    count: 1,
  );

  /// Installs [releases] in dependency order and reports per-component
  /// failures instead of stopping at the first one.
  Future<ProvisionReport> installAll(
    Iterable<ComponentRelease> releases, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
  }) async {
    final ordered = releases.toList()
      ..sort(
        (a, b) =>
            _orderOf(a.component).compareTo(_orderOf(b.component)),
      );
    final installed = <ProvisionedComponent>[];
    final failures = <ProvisionFailure>[];

    for (var index = 0; index < ordered.length; index++) {
      final release = ordered[index];
      final position = index + 1;
      onProgress?.call(
        ProvisionProgress(
          release: release,
          phase: ProvisionPhase.queued,
          index: position,
          count: ordered.length,
        ),
      );
      try {
        installed.add(
          await _install(
            release,
            onProgress: onProgress,
            activate: activate,
            index: position,
            count: ordered.length,
          ),
        );
      } on ProvisionException catch (error) {
        failures.add(ProvisionFailure(release, error.message));
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: error.message,
          ),
        );
      } on StackEditException catch (error) {
        failures.add(ProvisionFailure(release, error.message));
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: error.message,
          ),
        );
      } on FileSystemException catch (error) {
        final message = 'Could not install ${release.label}: '
            '${error.message}';
        failures.add(ProvisionFailure(release, message));
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: message,
          ),
        );
      } on ProcessException catch (error) {
        final message = 'Could not install ${release.label}: '
            '${error.message}';
        failures.add(ProvisionFailure(release, message));
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: message,
          ),
        );
      }
    }

    return ProvisionReport(installed: installed, failures: failures);
  }

  Future<ProvisionedComponent> _install(
    ComponentRelease release, {
    void Function(ProvisionProgress)? onProgress,
    required bool activate,
    required int index,
    required int count,
  }) async {
    void report(
      ProvisionPhase phase, {
      int received = 0,
      int? total,
      String? message,
    }) {
      onProgress?.call(
        ProvisionProgress(
          release: release,
          phase: phase,
          index: index,
          count: count,
          received: received,
          total: total,
          message: message,
        ),
      );
    }

    final existing = _existingInstall(release);
    if (existing != null) {
      report(
        ProvisionPhase.configuring,
        message: 'Already installed, checking its configuration…',
      );
      await _configure(release, existing, fresh: false);
      final activated = activate ? _activate(release, existing) : false;
      report(ProvisionPhase.done, message: 'Already installed');
      return ProvisionedComponent(
        release: release,
        install: existing,
        activated: activated,
        alreadyInstalled: true,
      );
    }

    final bundled = _payload?.archiveFor(release);
    Directory? temporary;
    final File archive;
    if (bundled != null) {
      archive = bundled;
      report(
        ProvisionPhase.verifying,
        message: 'Using the bundled ${p.basename(bundled.path)}.',
      );
      AppLog.info('Installing ${release.label} from ${bundled.path}');
    } else {
      final uri = Uri.tryParse(release.url);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw ProvisionException(
          '${release.label} has no valid HTTPS download URL.',
        );
      }

      temporary = Directory.systemTemp.createTempSync(
        'stackpilot_provision_',
      );
      archive = File(p.join(temporary.path, 'download.zip'));
      report(ProvisionPhase.downloading);
      await _download(uri, archive, (received, total) {
        report(ProvisionPhase.downloading, received: received, total: total);
      });
    }

    try {
      report(ProvisionPhase.verifying);
      final digest = (await _digest(archive)).toLowerCase();
      if (digest != release.sha256.toLowerCase()) {
        throw ProvisionException(
          'The ${release.label} archive did not match its published '
          'checksum, so it was not installed. Check the connection and try '
          'again.',
        );
      }

      report(ProvisionPhase.installing);
      final install = await installArchiveFor(release, archive.path);

      report(ProvisionPhase.configuring);
      await _configure(release, install, fresh: true);

      final activated = activate ? _activate(release, install) : false;
      report(ProvisionPhase.done);
      return ProvisionedComponent(
        release: release,
        install: install,
        activated: activated,
        alreadyInstalled: false,
      );
    } finally {
      if (temporary != null) {
        _deleteQuietly(temporary);
      }
    }
  }

  Future<StackInstall> installArchiveFor(
    ComponentRelease release,
    String archivePath,
  ) async {
    final installer = installArchive;
    if (installer != null) {
      return installer(release.component, archivePath, release.installName);
    }
    return StackEditor(
      _current,
    ).installArchive(
      release.component,
      archivePath,
      installName: release.installName,
    );
  }

  StackInstall? _existingInstall(ComponentRelease release) {
    for (final install in _current.installedVersions(release.component)) {
      if (install.version.toLowerCase() ==
          release.installName.toLowerCase()) {
        return install;
      }
    }
    return null;
  }

  /// Selects [install], enables its service, and returns whether it is active.
  bool _activate(ComponentRelease release, StackInstall install) {
    final editor = StackEditor(_current);
    try {
      editor.selectVersion(release.component, install);
    } on StackEditException {
      return false;
    }

    if (StackLayout.serviceComponents.contains(release.component)) {
      final apache = _current.activeVersion(StackComponent.apache);
      final keepDisabled =
          release.component == StackComponent.nginx && apache != null;
      if (!keepDisabled) {
        editor.setServiceEnabled(release.component, true);
      }
    }
    return true;
  }

  Future<void> _configure(
    ComponentRelease release,
    StackInstall install, {
    required bool fresh,
  }) async {
    Directory(p.join(layout.root, 'logs')).createSync(recursive: true);
    Directory(p.join(layout.root, 'tmp')).createSync(recursive: true);

    final editor = StackEditor(_current);
    switch (release.component) {
      case StackComponent.php:
        editor.preparePhp(install);
        editor.refreshApacheConfig();
      case StackComponent.apache:
        editor.prepareApacheConfig(install);
        _writeApacheVhost();
        editor.refreshApacheConfig();
      case StackComponent.mysql:
        await _configureMysql(install, fresh: fresh);
      case StackComponent.nginx:
        _writeNginxConfig(install, fresh: fresh);
      case StackComponent.redis:
        _writeRedisConfig(install, fresh: fresh);
      case StackComponent.postgresql:
        await _configurePostgresql(install);
      case StackComponent.nodejs:
      case StackComponent.memcached:
      case StackComponent.mailpit:
        break;
    }
  }

  // --- Apache -------------------------------------------------------------

  void _writeApacheVhost() {
    final file = File(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled', '00-default.conf'),
    );
    if (file.existsSync()) {
      return;
    }
    final root = _slash(layout.documentRoot);
    final logs = _slash(p.join(layout.root, 'logs'));
    _writeText(
      file,
      [
        '# Default virtual host, generated by StackPilot.',
        '<VirtualHost *:80>',
        '    DocumentRoot "$root"',
        '    <Directory "$root">',
        '        Options Indexes FollowSymLinks',
        '        AllowOverride All',
        '        Require all granted',
        '    </Directory>',
        '    ErrorLog "$logs/default-error.log"',
        '    CustomLog "$logs/default-access.log" common',
        '</VirtualHost>',
        '',
      ].join('\r\n'),
    );
  }

  // --- MySQL / MariaDB ----------------------------------------------------

  Future<void> _configureMysql(
    StackInstall install, {
    required bool fresh,
  }) async {
    final dataDirectory = p.join(layout.dataDirectory, 'mysql');
    Directory(dataDirectory).createSync(recursive: true);

    final ini = File(p.join(install.directory, 'my.ini'));
    if (!ini.existsSync()) {
      _writeText(
        ini,
        _mysqlIni(install: install, dataDirectory: dataDirectory),
      );
    } else if (fresh) {
      _writeText(
        ini,
        _mysqlIni(install: install, dataDirectory: dataDirectory),
      );
    } else {
      _patchMysqlIni(ini, install: install, dataDirectory: dataDirectory);
    }

    final systemTables = Directory(p.join(dataDirectory, 'mysql'));
    if (systemTables.existsSync()) {
      return;
    }

    final installer = File(
      p.join(install.directory, 'bin', 'mysql_install_db.exe'),
    );
    final int code;
    if (installer.existsSync()) {
      code = await _run(
        installer.path,
        [
          '--datadir=$dataDirectory',
          '--password=',
          '--port=${layout.mysqlPort}',
          '--config=${ini.path}',
        ],
        install.directory,
      );
    } else {
      code = await _run(
        install.executablePath,
        ['--defaults-file=${ini.path}', '--initialize-insecure'],
        install.directory,
      );
    }
    if (code != 0) {
      throw ProvisionException(
        'MySQL/MariaDB could not initialise its data directory '
        '(exit code $code).',
      );
    }
  }

  String _mysqlIni({
    required StackInstall install,
    required String dataDirectory,
  }) {
    final base = _slash(install.directory);
    final data = _slash(dataDirectory);
    final errorLog = _slash(
      p.join(layout.root, 'logs', 'mysql-error.log'),
    );
    return [
      '# MySQL/MariaDB configuration generated by StackPilot.',
      '[mysqld]',
      'basedir="$base"',
      'datadir="$data"',
      'port=${layout.mysqlPort}',
      'bind-address=127.0.0.1',
      'character-set-server=utf8mb4',
      'collation-server=utf8mb4_unicode_ci',
      'max_allowed_packet=64M',
      'innodb_flush_log_at_trx_commit=2',
      'log_error="$errorLog"',
      '',
      '[client]',
      'port=${layout.mysqlPort}',
      'host=127.0.0.1',
      'default-character-set=utf8mb4',
      '',
    ].join('\r\n');
  }

  void _patchMysqlIni(
    File ini, {
    required StackInstall install,
    required String dataDirectory,
  }) {
    final String source;
    try {
      source = ini.readAsStringSync();
    } on FileSystemException {
      return;
    }
    var updated = setIniDirective(source, 'basedir', '"${_slash(install.directory)}"');
    updated = setIniDirective(
      updated,
      'datadir',
      '"${_slash(dataDirectory)}"',
    );
    updated = setIniDirective(
      updated,
      'port',
      '${layout.mysqlPort}',
      all: true,
    );
    if (updated != source) {
      _writeText(ini, updated);
    }
  }

  // --- Nginx --------------------------------------------------------------

  void _writeNginxConfig(StackInstall install, {required bool fresh}) {
    final file = File(p.join(install.directory, 'conf', 'nginx.conf'));
    if (!fresh && file.existsSync()) {
      return;
    }

    final documentRoot = _slash(layout.documentRoot);
    final logs = _slash(p.join(layout.root, 'logs'));
    final pid = _slash(p.join(layout.root, 'tmp', 'nginx.pid'));
    _writeText(
      file,
      [
        '# Generated by StackPilot. Nginx configuration for this stack.',
        'worker_processes 1;',
        'error_log "$logs/nginx-error.log" warn;',
        'pid "$pid";',
        '',
        'events {',
        '    worker_connections 1024;',
        '}',
        '',
        'http {',
        '    include conf/mime.types;',
        '    default_type application/octet-stream;',
        '    access_log "$logs/nginx-access.log";',
        '    sendfile on;',
        '    keepalive_timeout 65;',
        '',
        '    server {',
        '        listen 80;',
        '        server_name localhost;',
        '        root "$documentRoot";',
        '        index index.php index.html index.htm;',
        '',
        '        location / {',
        '            try_files \$uri \$uri/ =404;',
        '        }',
        '',
        '        # Start php-cgi from the PHP version card to serve PHP here.',
        '        location ~ \\.php\$ {',
        '            fastcgi_pass 127.0.0.1:9000;',
        '            fastcgi_index index.php;',
        '            fastcgi_param SCRIPT_FILENAME '
            '\$document_root\$fastcgi_script_name;',
        '            include conf/fastcgi_params;',
        '        }',
        '    }',
        '}',
        '',
      ].join('\r\n'),
    );
  }

  // --- Redis --------------------------------------------------------------

  void _writeRedisConfig(StackInstall install, {required bool fresh}) {
    final file = File(p.join(install.directory, 'redis.conf'));
    if (!fresh && file.existsSync()) {
      return;
    }

    final dataDirectory = p.join(layout.dataDirectory, 'redis');
    Directory(dataDirectory).createSync(recursive: true);
    final log = _slash(p.join(layout.root, 'logs', 'redis.log'));

    final vendor = File(p.join(install.directory, 'redis.windows.conf'));
    var source = _isReadable(vendor)
        ? vendor.readAsStringSync()
        : _defaultRedisConfig;
    source = _setSpaceDirective(source, 'port', '6379');
    source = _setSpaceDirective(source, 'bind', '127.0.0.1');
    source = _setSpaceDirective(source, 'dir', '"${_slash(dataDirectory)}"');
    source = _setSpaceDirective(source, 'logfile', '"$log"');
    source = _setSpaceDirective(source, 'appendonly', 'no');
    if (!source.contains('Generated by StackPilot')) {
      source =
          '# Generated by StackPilot. Redis configuration for this stack.\r\n'
          '$source';
    }
    _writeText(file, source);
  }

  static const _defaultRedisConfig = '''
port 6379
bind 127.0.0.1
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
appendonly no
''';

  // --- PostgreSQL ---------------------------------------------------------

  Future<void> _configurePostgresql(StackInstall install) async {
    final dataDirectory = layout.postgresqlDataDirectory;
    if (!File(p.join(dataDirectory, 'PG_VERSION')).existsSync()) {
      Directory(p.dirname(dataDirectory)).createSync(recursive: true);
      final code = await _run(
        p.join(install.directory, 'bin', 'initdb.exe'),
        [
          '-D',
          dataDirectory,
          '-U',
          'postgres',
          '-A',
          'trust',
          '-E',
          'UTF8',
          '--no-locale',
        ],
        install.directory,
      );
      if (code != 0) {
        throw ProvisionException(
          'PostgreSQL could not initialise $dataDirectory '
          '(exit code $code).',
        );
      }
    }

    final conf = File(layout.postgresqlConfigPath);
    if (!conf.existsSync()) {
      return;
    }
    final String source;
    try {
      source = conf.readAsStringSync();
    } on FileSystemException {
      return;
    }
    var updated = setIniDirective(
      source,
      'port',
      '${layout.postgresqlPort}',
    );
    updated = setIniDirective(updated, 'listen_addresses', "'127.0.0.1'");
    if (updated != source) {
      _writeText(conf, updated);
    }
  }

  // --- Helpers ------------------------------------------------------------

  static int _orderOf(StackComponent component) {
    final index = ComponentCatalog.installOrder.indexOf(component);
    return index < 0 ? ComponentCatalog.installOrder.length : index;
  }

  static bool _isReadable(File file) {
    if (!file.existsSync()) {
      return false;
    }
    try {
      file.readAsStringSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static void _writeText(File file, String contents) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents, flush: true);
  }

  static String _slash(String value) => value.replaceAll('\\', '/');

  /// Sets a space-separated directive, the syntax Redis uses.
  static String _setSpaceDirective(String source, String key, String value) {
    final pattern = RegExp(
      '^([ \\t]*${RegExp.escape(key)}[ \\t]+)([^\\r\\n]*)',
      caseSensitive: false,
      multiLine: true,
    );
    if (pattern.hasMatch(source)) {
      return source.replaceFirstMapped(
        pattern,
        (match) => '${match.group(1)}$value',
      );
    }
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final needsEol = source.isNotEmpty && !source.endsWith('\n');
    return '$source${needsEol ? eol : ''}$key $value$eol';
  }

  static Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static Future<void> _httpDownload(
    Uri uri,
    File destination,
    void Function(int received, int? total) onProgress,
  ) async {
    final client = HttpClient();
    try {
      var current = uri;
      for (var hop = 0; hop < 6; hop++) {
        final request = await client.getUrl(current);
        // Redirects are followed by hand so 308 responses, which some vendor
        // CDNs use, work on every Dart version.
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'StackPilot (Windows stack manager)',
        );
        final response = await request.close();

        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && _isRedirect(response.statusCode)) {
          await response.drain<void>();
          current = current.resolve(location);
          continue;
        }

        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw ProvisionException(
            'Download failed with HTTP ${response.statusCode}.',
          );
        }

        final total = response.contentLength > 0
            ? response.contentLength
            : null;
        var received = 0;
        final sink = destination.openWrite();
        try {
          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            onProgress(received, total);
          }
        } finally {
          await sink.close();
        }
        return;
      }
      throw const ProvisionException('The download redirected too often.');
    } on SocketException catch (error) {
      throw ProvisionException('Download failed: ${error.message}');
    } on HttpException catch (error) {
      throw ProvisionException('Download failed: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == 308;

  static Future<int> _runProcess(
    String executable,
    List<String> arguments,
    String workingDirectory,
  ) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    return result.exitCode;
  }

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
