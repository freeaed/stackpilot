import 'dart:io';

import 'package:path/path.dart' as p;

import 'stack_layout.dart';

/// Raised when a stack cannot be created at the requested location.
class StackBootstrapException implements Exception {
  const StackBootstrapException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Creates the folder layout StackPilot needs, without a third-party installer.
///
/// A StackPilot stack has the same shape as a Laragon stack, so the existing
/// readers, service manager, and editor work unchanged:
///
/// ```
/// <root>/
///   bin/                       installed component versions
///   usr/stackpilot.ini         stack marker and settings
///   usr/profile/default.ini    active component versions
///   etc/apache2/sites-enabled/
///   etc/apache2/alias/
///   etc/nginx/
///   www/                       document root
///   data/                      service data (MySQL, PostgreSQL, ...)
///   logs/
///   tmp/                       sessions, PIDs, and temporary files
/// ```
///
/// Creating a stack only writes configuration. Component binaries are added
/// afterwards, one version at a time, through the version controls.
class StackBootstrap {
  const StackBootstrap._();

  static const defaultStackName = 'default';

  /// Marker file that makes a folder a StackPilot stack.
  static const markerFileName = 'stackpilot.ini';

  /// Parent folder for stacks StackPilot creates:
  /// `%LOCALAPPDATA%\StackPilot\stacks`.
  static String defaultStacksFolder({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final localAppData = env['LOCALAPPDATA'];
    final base = (localAppData == null || localAppData.trim().isEmpty)
        ? p.join(
            env['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Local',
          )
        : localAppData;
    return p.join(base, 'StackPilot', 'stacks');
  }

  /// Folder proposed on first run.
  static String defaultRoot({Map<String, String>? environment}) =>
      p.join(defaultStacksFolder(environment: environment), defaultStackName);

  /// True when [root] does not exist yet or is an empty folder.
  static bool isCreatable(String root) {
    final trimmed = root.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final directory = Directory(p.normalize(trimmed));
    if (!directory.existsSync()) {
      return true;
    }
    try {
      return directory.listSync().isEmpty;
    } on FileSystemException {
      return false;
    }
  }

  /// Creates a stack at [root] and returns the detected layout.
  ///
  /// Throws [StackBootstrapException] when the folder is not usable or when the
  /// files cannot be written.
  static StackLayout create({
    required String root,
    int mysqlPort = 3306,
    int postgresqlPort = 5432,
    DateTime? now,
  }) {
    final trimmed = root.trim();
    if (trimmed.isEmpty) {
      throw const StackBootstrapException('Choose a folder for the stack.');
    }
    _checkPort('MySQL', mysqlPort);
    _checkPort('PostgreSQL', postgresqlPort);

    final resolved = p.normalize(p.absolute(trimmed));
    if (StackLayout.isStackRoot(resolved)) {
      throw StackBootstrapException(
        'That folder is already a stack. Open it instead of creating a new one.',
      );
    }
    if (!isCreatable(resolved)) {
      throw StackBootstrapException(
        'That folder already contains files. Choose an empty folder, or open '
        'the existing stack.',
      );
    }

    final documentRoot = p.join(resolved, 'www');
    final dataDirectory = p.join(resolved, 'data');
    final createdAt = (now ?? DateTime.now()).toIso8601String();

    try {
      for (final directory in [
        p.join(resolved, 'bin'),
        p.join(resolved, 'usr', 'profile'),
        p.join(resolved, 'etc', 'apache2', 'sites-enabled'),
        p.join(resolved, 'etc', 'apache2', 'alias'),
        p.join(resolved, 'etc', 'nginx'),
        documentRoot,
        dataDirectory,
        p.join(resolved, 'logs'),
        p.join(resolved, 'tmp'),
      ]) {
        Directory(directory).createSync(recursive: true);
      }

      _writeText(
        p.join(resolved, 'usr', markerFileName),
        _markerContents(
          name: p.basename(resolved),
          createdAt: createdAt,
          documentRoot: documentRoot,
          dataDirectory: dataDirectory,
          mysqlPort: mysqlPort,
          postgresqlPort: postgresqlPort,
        ),
      );
      _writeText(
        p.join(resolved, 'usr', 'profile', 'default.ini'),
        _profileContents(),
      );
      _writeText(
        p.join(documentRoot, 'index.html'),
        _landingPage(name: p.basename(resolved)),
      );
    } on FileSystemException catch (error) {
      throw StackBootstrapException(
        'Could not create the stack at $resolved: ${error.message}',
      );
    }

    final layout = StackLayout.detect(resolved);
    if (layout == null) {
      throw StackBootstrapException(
        'The stack files were written but $resolved could not be read back.',
      );
    }
    return layout;
  }

  static void _checkPort(String label, int port) {
    if (port < 1 || port > 65535) {
      throw StackBootstrapException(
        '$label port must be between 1 and 65535 (got $port).',
      );
    }
  }

  static void _writeText(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents, flush: true);
  }

  static String _markerContents({
    required String name,
    required String createdAt,
    required String documentRoot,
    required String dataDirectory,
    required int mysqlPort,
    required int postgresqlPort,
  }) {
    return [
      '; StackPilot stack configuration.',
      '; Created by StackPilot on $createdAt.',
      '; This file identifies the stack. Keep it at usr\\$markerFileName.',
      '',
      '[stackpilot]',
      'Name=$name',
      'LayoutVersion=1',
      'Created=$createdAt',
      '',
      '[preferences]',
      'DocumentRootList=$documentRoot|',
      'DataDir=$dataDirectory',
      'AutoVirtualHosts=1',
      '',
      '[apache]',
      'Use=1',
      'DocumentRoot=$documentRoot',
      '',
      '[nginx]',
      'Use=0',
      '',
      '[mysql]',
      'Use=1',
      'Port=$mysqlPort',
      '',
      '[postgresql]',
      'Use=0',
      'Port=$postgresqlPort',
      '',
      '[redis]',
      'Use=0',
      '',
      '[memcached]',
      'Use=0',
      '',
      '[mailpit]',
      'Use=1',
      '',
    ].join('\r\n');
  }

  static String _profileContents() {
    return [
      '; Active component versions for this stack.',
      '; StackPilot updates this file when a version is selected.',
      '',
      '[stackpilot]',
      'LayoutVersion=1',
      '',
    ].join('\r\n');
  }

  static String _landingPage({required String name}) {
    return '''<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>StackPilot stack</title>
    <style>
      :root { color-scheme: light; }
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        font-family: "Segoe UI", system-ui, sans-serif;
        background: #f4f7f5;
        color: #14352a;
      }
      main {
        max-width: 32rem;
        padding: 2rem;
        background: #fff;
        border: 1px solid #e1e8e4;
        border-radius: 14px;
      }
      h1 { margin: 0 0 .5rem; font-size: 1.35rem; }
      p { margin: 0 0 .75rem; line-height: 1.55; color: #52605a; }
      code { background: #f0f4f1; padding: .1rem .3rem; border-radius: 4px; }
    </style>
  </head>
  <body>
    <main>
      <h1>$name is ready</h1>
      <p>This is the document root of your StackPilot stack.</p>
      <p>
        Add a project folder here, then install a web server and PHP from
        StackPilot's version menus.
      </p>
      <p>Configuration lives in <code>usr\\stackpilot.ini</code>.</p>
    </main>
  </body>
</html>
''';
  }
}
