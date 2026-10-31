import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'app_catalog.dart';
import 'bundled_payload.dart';
import 'component_catalog.dart';
import 'download_cache.dart';
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
  const ProvisionFailure(
    this.release,
    this.message, {
    this.url,
    this.expectedSha256,
    this.actualSha256,
  });

  final ComponentRelease release;
  final String message;

  /// URL that produced the failure, when it came from a download.
  final String? url;

  /// Expected and actual digests for a checksum mismatch.
  final String? expectedSha256;
  final String? actualSha256;

  bool get isChecksumMismatch => expectedSha256 != null;

  @override
  String toString() => '${release.label}: $message';
}

/// Outcome of installing several components.
///
/// A failed component does not roll back the others: the stack keeps whatever
/// was installed successfully and the report lists what needs a retry.
class ProvisionReport {
  const ProvisionReport({
    required this.installed,
    required this.failures,
    this.cancelled = false,
  });

  final List<ProvisionedComponent> installed;
  final List<ProvisionFailure> failures;

  /// True when the user stopped the run before every component was handled.
  final bool cancelled;

  bool get ok => failures.isEmpty && !cancelled;
}

class ProvisionException implements Exception {
  const ProvisionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown internally when the user cancels an install.
class ProvisionCancelled implements Exception {
  const ProvisionCancelled();

  @override
  String toString() => 'The download was cancelled.';
}

/// An archive whose digest did not match the catalog.
///
/// Carries the details the setup dialog shows so the user can retry, try a
/// mirror, or install a ZIP they already have.
class ChecksumException extends ProvisionException {
  const ChecksumException({
    required this.label,
    required this.expectedSha256,
    required this.actualSha256,
    required this.url,
    required String message,
  }) : super(message);

  final String label;
  final String expectedSha256;
  final String actualSha256;
  final String url;
}

/// Raised when a download can be retried (connection drop, timeout, 5xx).
class _RetryableDownload implements Exception {
  const _RetryableDownload(this.message);

  final String message;
}

/// Lets the setup dialog stop an install between components and while an
/// archive is streaming.
class ProvisionCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
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
    ProvisionCancellation? cancellation,
    DownloadCache? cache,
  }) : _run = run ?? _runProcess,
       _digest = digest ?? _sha256OfFile,
       _payload = payload ?? BundledPayload.locate(),
       _cache = cache ?? DownloadCache() {
    _download = download;
    _cancellation = cancellation;
  }

  final StackLayout layout;
  late final ProvisionDownload? _download;
  final ProvisionCommand _run;
  final ProvisionDigest _digest;
  final ProvisionInstall? installArchive;
  late final ProvisionCancellation? _cancellation;
  final BundledPayload? _payload;
  final DownloadCache _cache;

  bool get _cancelled => _cancellation?.isCancelled ?? false;

  /// Offline archives found next to the app, if any.
  BundledPayload? get payload => _payload;

  /// Latest view of the stack, refreshed after every install.
  StackLayout get _current => StackLayout.detect(layout.root) ?? layout;

  /// Installs one component and makes it the active version.
  Future<ProvisionedComponent> install(
    ComponentRelease release, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
    bool preferMirror = false,
    bool reinstall = false,
  }) => _install(
    release,
    onProgress: onProgress,
    activate: activate,
    index: 1,
    count: 1,
    preferMirror: preferMirror,
    reinstall: reinstall,
  );

  /// Installs [releases] in dependency order and reports per-component
  /// failures instead of stopping at the first one.
  ///
  /// When [reinstall] is true an already installed version is moved aside and
  /// installed again from the archive.
  Future<ProvisionReport> installAll(
    Iterable<ComponentRelease> releases, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
    bool reinstall = false,
  }) async {
    final ordered = releases.toList()
      ..sort(
        (a, b) =>
            _orderOf(a.component).compareTo(_orderOf(b.component)),
      );
    final installed = <ProvisionedComponent>[];
    final failures = <ProvisionFailure>[];
    var cancelled = false;

    for (var index = 0; index < ordered.length; index++) {
      final release = ordered[index];
      final position = index + 1;
      if (_cancelled) {
        cancelled = true;
        break;
      }
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
            reinstall: reinstall,
          ),
        );
      } on ProvisionCancelled {
        cancelled = true;
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: 'Cancelled.',
          ),
        );
        break;
      } on ChecksumException catch (error) {
        failures.add(
          ProvisionFailure(
            release,
            error.message,
            url: error.url,
            expectedSha256: error.expectedSha256,
            actualSha256: error.actualSha256,
          ),
        );
        onProgress?.call(
          ProvisionProgress(
            release: release,
            phase: ProvisionPhase.failed,
            index: position,
            count: ordered.length,
            message: error.message,
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

    return ProvisionReport(
      installed: installed,
      failures: failures,
      cancelled: cancelled,
    );
  }

  Future<ProvisionedComponent> _install(
    ComponentRelease release, {
    void Function(ProvisionProgress)? onProgress,
    required bool activate,
    required int index,
    required int count,
    bool reinstall = false,
    bool preferMirror = false,
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

    if (_cancelled) {
      throw const ProvisionCancelled();
    }

    final existing = _existingInstall(release);
    if (existing != null && !reinstall) {
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

    // Re-download: keep the old copy aside until the new one is configured, so
    // a failed download never leaves the stack without a working version.
    Directory? backup;
    if (existing != null) {
      report(
        ProvisionPhase.queued,
        message: 'Replacing the installed copy…',
      );
      backup = Directory('${existing.directory}.stackpilot-previous');
      _deleteQuietly(backup);
      Directory(existing.directory).renameSync(backup.path);
    }

    final bundled = _payload?.archiveFor(release);
    _FetchedArchive? fetched;
    try {
      if (bundled != null) {
        fetched = _FetchedArchive(bundled);
        report(
          ProvisionPhase.verifying,
          message: 'Using the bundled ${p.basename(bundled.path)}.',
        );
        AppLog.info('Installing ${release.label} from ${bundled.path}');
        await _verifyArchive(
          bundled,
          label: release.label,
          sha256: release.sha256,
          url: bundled.path,
        );
      } else {
        fetched = await _fetchArchive(
          label: release.label,
          urls: release.urls,
          sha256: release.sha256,
          sizeBytes: release.sizeBytes,
          preferMirror: preferMirror,
          report: (
            phase, {
            int received = 0,
            int? total,
            String? message,
          }) => report(
            phase,
            received: received,
            total: total,
            message: message,
          ),
        );
      }

      final archive = fetched.file;
      report(ProvisionPhase.installing);
      final install = await installArchiveFor(release, archive.path);

      report(ProvisionPhase.configuring);
      await _configure(release, install, fresh: true);

      final activated = activate ? _activate(release, install) : false;
      report(ProvisionPhase.done);
      _deleteQuietly(backup);
      return ProvisionedComponent(
        release: release,
        install: install,
        activated: activated,
        alreadyInstalled: false,
      );
    } catch (error) {
      if (backup != null && backup.existsSync()) {
        final installedDirectory = existing!.directory;
        _deleteQuietly(Directory(installedDirectory));
        try {
          backup.renameSync(installedDirectory);
        } on FileSystemException {
          // Keep the backup folder; the failure message names the component.
        }
      }
      rethrow;
    } finally {
      _deleteQuietly(fetched?.temporary);
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

  /// Installs a ZIP the user picked, after checking it against the catalog.
  Future<ProvisionedComponent> installFromArchive(
    ComponentRelease release,
    File archive,
  ) async {
    if (!archive.existsSync()) {
      throw ProvisionException('Archive not found: ${archive.path}');
    }
    await _verifyArchive(
      archive,
      label: release.label,
      sha256: release.sha256,
      url: archive.path,
    );
    final install = await installArchiveFor(release, archive.path);
    await _configure(release, install, fresh: true);
    final activated = _activate(release, install);
    return ProvisionedComponent(
      release: release,
      install: install,
      activated: activated,
      alreadyInstalled: false,
    );
  }

  /// Downloads [release]'s archive (or reuses the cache) and verifies it.
  ///
  /// Tries every URL in order, resuming a partial file when the server allows
  /// it. A digest mismatch raises [ChecksumException] with the details the UI
  /// needs.
  Future<_FetchedArchive> _fetchArchive({
    required String label,
    required List<String> urls,
    required String sha256,
    required int? sizeBytes,
    required void Function(
      ProvisionPhase phase, {
      int received,
      int? total,
      String? message,
    })
    report,
    bool preferMirror = false,
  }) async {
    final ordered = preferMirror && urls.length > 1
        ? [...urls.skip(1), urls.first]
        : urls;

    final injectable = _download;
    if (injectable == null) {
      final cached = _cache.archiveFor(sha256);
      if (cached.existsSync() &&
          await _matches(cached, sha256: sha256, sizeBytes: sizeBytes)) {
        AppLog.info('Using cached ${p.basename(cached.path)}');
        report(
          ProvisionPhase.verifying,
          message: 'Using the cached archive…',
        );
        return _FetchedArchive(cached);
      }

      final part = _cache.partFor(sha256);
      part.parent.createSync(recursive: true);
      final result = await _downloadFromMirrors(
        ordered,
        part,
        label: label,
        report: report,
      );

      report(ProvisionPhase.verifying);
      final actual = (await _digest(part)).toLowerCase();
      if (actual != sha256.toLowerCase()) {
        _deleteFileQuietly(part);
        throw ChecksumException(
          label: label,
          expectedSha256: sha256.toLowerCase(),
          actualSha256: actual,
          url: result?.toString() ?? urls.first,
          message:
              'The $label archive from ${result ?? urls.first} did not match '
              'its published checksum, so it was not installed. Expected '
              '$sha256 but received $actual.',
        );
      }

      if (cached.existsSync()) {
        _deleteFileQuietly(cached);
      }
      try {
        part.renameSync(cached.path);
      } on FileSystemException {
        // Leave a verified copy where the next step can read it.
        return _FetchedArchive(part);
      }
      return _FetchedArchive(cached);
    }

    final temporary = Directory.systemTemp.createTempSync(
      'stackpilot_provision_',
    );
    final archive = File(p.join(temporary.path, 'download.zip'));
    final result = await _downloadFromMirrors(
      ordered,
      archive,
      label: label,
      report: report,
      download: injectable,
    );

    report(ProvisionPhase.verifying);
    final actual = (await _digest(archive)).toLowerCase();
    if (actual != sha256.toLowerCase()) {
      _deleteQuietly(temporary);
      throw ChecksumException(
        label: label,
        expectedSha256: sha256.toLowerCase(),
        actualSha256: actual,
        url: result?.toString() ?? urls.first,
        message:
            'The $label archive did not match its published checksum, so it '
            'was not installed. Expected $sha256 but received $actual.',
      );
    }
    return _FetchedArchive(archive, temporary: temporary);
  }

  /// Tries each URL until one completes.
  ///
  /// Returns the URL that succeeded, or throws the last error.
  Future<Uri?> _downloadFromMirrors(
    List<String> urls,
    File destination, {
    required String label,
    required void Function(
      ProvisionPhase phase, {
      int received,
      int? total,
      String? message,
    })
    report,
    ProvisionDownload? download,
  }) async {
    Object? lastError;
    for (final raw in urls) {
      final uri = Uri.tryParse(raw.trim());
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        lastError = ProvisionException(
          '$label has no valid HTTP download URL: $raw',
        );
        continue;
      }
      if (_cancelled) {
        throw const ProvisionCancelled();
      }
      report(
        ProvisionPhase.downloading,
        message: 'Downloading from ${uri.host}…',
      );
      try {
        await (download ?? _httpDownload)(uri, destination, (received, total) {
          report(
            ProvisionPhase.downloading,
            received: received,
            total: total,
            message: 'Downloading from ${uri.host}…',
          );
        });
        return uri;
      } on ProvisionCancelled {
        rethrow;
      } on ChecksumException {
        rethrow;
      } on Object catch (error) {
        lastError = error;
        AppLog.warn('Downloading $label from $uri failed: $error');
      }
    }

    final message = lastError is ProvisionException
        ? lastError.message
        : lastError == null
        ? 'No download URL is configured for $label.'
        : 'Could not download $label: $lastError';
    throw ProvisionException(message);
  }

  /// Checks an archive against [sha256] and raises [ChecksumException] with
  /// the exact digests when it differs.
  Future<void> _verifyArchive(
    File archive, {
    required String label,
    required String sha256,
    required String url,
  }) async {
    final actual = (await _digest(archive)).toLowerCase();
    if (actual == sha256.toLowerCase()) {
      return;
    }
    throw ChecksumException(
      label: label,
      expectedSha256: sha256.toLowerCase(),
      actualSha256: actual,
      url: url,
      message:
          'The $label archive did not match its published checksum, so it '
          'was not installed. Expected $sha256 but received $actual.',
    );
  }

  Future<bool> _matches(
    File file, {
    required String sha256,
    required int? sizeBytes,
  }) async {
    if (sizeBytes != null && file.lengthSync() != sizeBytes) {
      return false;
    }
    return (await _digest(file)).toLowerCase() == sha256.toLowerCase();
  }

  /// Installs a catalog application (phpMyAdmin, …) into `etc/apps`.
  ///
  /// The archive goes through the same cache, mirror and checksum path as the
  /// components. Returns the installed folder.
  Future<String> installApp(
    CatalogApp app, {
    void Function(int received, int? total)? onProgress,
    bool preferMirror = false,
  }) async {
    final fetched = await _fetchArchive(
      label: app.name,
      urls: app.urls,
      sha256: app.sha256,
      sizeBytes: app.sizeBytes,
      preferMirror: preferMirror,
      report: (
        phase, {
        int received = 0,
        int? total,
        String? message,
      }) {
        if (phase == ProvisionPhase.downloading) {
          onProgress?.call(received, total);
        }
      },
    );
    try {
      return await StackEditor(_current).installPhpMyAdminArchive(
        fetched.file.path,
        targetDirectory: p.join(layout.root, 'etc', 'apps', app.installName),
      );
    } finally {
      _deleteQuietly(fetched.temporary);
    }
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
        '<VirtualHost *:${layout.apachePort}>',
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
    final phpMyAdmin = _slash(p.join(layout.root, 'etc', 'apps', 'phpmyadmin'));
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
        '        listen ${layout.nginxPort};',
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
        '',
        '        # phpMyAdmin from etc/apps, installed by StackPilot.',
        '        location /phpmyadmin/ {',
        '            alias "$phpMyAdmin/";',
        '            index index.php;',
        '            try_files \$uri \$uri/ =404;',
        '        }',
        '',
        '        location ~ ^/phpmyadmin/(.+\\.php)\$ {',
        '            alias "$phpMyAdmin/\$1";',
        '            fastcgi_pass 127.0.0.1:9000;',
        '            fastcgi_index index.php;',
        '            fastcgi_param SCRIPT_FILENAME \$request_filename;',
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

  /// Downloads [uri], retrying connection failures and resuming a partial file.
  Future<void> _httpDownload(
    Uri uri,
    File destination,
    void Function(int received, int? total) onProgress,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        await _httpDownloadOnce(uri, destination, onProgress);
        return;
      } on ProvisionCancelled {
        rethrow;
      } on _RetryableDownload catch (error) {
        attempt++;
        if (attempt >= 3) {
          throw ProvisionException(error.message);
        }
        final delay = Duration(seconds: attempt == 1 ? 1 : 3);
        AppLog.warn(
          'Retrying $uri in ${delay.inSeconds}s: ${error.message}',
        );
        await Future<void>.delayed(delay);
      }
    }
  }

  Future<void> _httpDownloadOnce(
    Uri uri,
    File destination,
    void Function(int received, int? total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final existing = destination.existsSync() ? destination.lengthSync() : 0;
      var current = uri;
      for (var hop = 0; hop < 6; hop++) {
        if (_cancelled) {
          throw const ProvisionCancelled();
        }
        final request = await client.getUrl(current);
        // Redirects are followed by hand so 308 responses, which some vendor
        // CDNs use, work on every Dart version.
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'StackPilot (Windows stack manager)',
        );
        if (existing > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        }
        final response = await request.close();

        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && _isRedirect(response.statusCode)) {
          await response.drain<void>();
          current = current.resolve(location);
          continue;
        }

        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          await response.drain<void>();
          _deleteFileQuietly(destination);
          throw const _RetryableDownload(
            'The partial download could not be resumed.',
          );
        }

        final partial = response.statusCode == HttpStatus.partialContent;
        if (response.statusCode != HttpStatus.ok && !partial) {
          await response.drain<void>();
          final message =
              'Download failed with HTTP ${response.statusCode} from '
              '${current.host}.';
          if (response.statusCode >= 500 ||
              response.statusCode == HttpStatus.requestTimeout ||
              response.statusCode == HttpStatus.tooManyRequests) {
            throw _RetryableDownload(message);
          }
          throw ProvisionException(message);
        }

        final append = partial && existing > 0;
        final contentLength = response.contentLength > 0
            ? response.contentLength
            : null;
        final total = contentLength == null
            ? null
            : contentLength + (append ? existing : 0);
        var received = append ? existing : 0;
        final sink = destination.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        try {
          await for (final chunk in response) {
            if (_cancelled) {
              throw const ProvisionCancelled();
            }
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
      throw _RetryableDownload('Download failed: ${error.message}');
    } on HttpException catch (error) {
      throw _RetryableDownload('Download failed: ${error.message}');
    } on HandshakeException catch (error) {
      throw _RetryableDownload('Download failed: ${error.message}');
    } on TimeoutException catch (error) {
      throw _RetryableDownload('Download failed: $error');
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

  static void _deleteQuietly(Directory? directory) {
    if (directory == null) {
      return;
    }
    try {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Temporary folders are best-effort cleanup.
    }
  }

  static void _deleteFileQuietly(File? file) {
    if (file == null) {
      return;
    }
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on FileSystemException {
      // A locked file is removed by the next attempt.
    }
  }
}

/// An archive that is ready to install, plus the temporary folder to remove.
class _FetchedArchive {
  const _FetchedArchive(this.file, {this.temporary});

  final File file;
  final Directory? temporary;
}
