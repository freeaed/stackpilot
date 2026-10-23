import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'service_processes.dart';
import 'stack_layout.dart';
import 'windows_job.dart';

/// A process owned by StackPilot for the lifetime of one service run.
abstract class RunningProcess {
  int get pid;
  Future<int> get exitCode;
}

typedef StartProcess = Future<RunningProcess> Function(
  String executable,
  List<String> arguments,
  String workingDirectory,
);

typedef RunProcess = Future<int> Function(
  String executable,
  List<String> arguments,
);

typedef KillProcessTree = Future<void> Function(int pid);

typedef AdoptProcess = bool Function(int pid);

class ServiceException implements Exception {
  const ServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ServiceCommand {
  const ServiceCommand({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

/// Starts and stops services for a stack.
///
/// Owned services are assigned to a Windows job so they exit with StackPilot.
/// Services started elsewhere are adopted only after their executable path is
/// verified to live inside this stack, and are never adopted silently.
class ServiceManager {
  ServiceManager(
    StackLayout layout, {
    StartProcess? startProcess,
    RunProcess? runProcess,
    KillProcessTree? killProcessTree,
    ProcessInspector? inspector,
    AdoptProcess? adoptProcess,
    this.stopTimeout = const Duration(seconds: 8),
  }) : _layout = layout,
       _startProcess = startProcess ?? _defaultStart,
       _runProcess = runProcess ?? _defaultRun,
       _killProcessTree = killProcessTree ?? _defaultKillTree,
       _inspector = inspector ?? const WindowsProcessInspector(),
       _adoptProcess = adoptProcess ?? _defaultAdopt;

  static const _startOrder = [
    StackComponent.apache,
    StackComponent.nginx,
    StackComponent.mysql,
    StackComponent.postgresql,
    StackComponent.redis,
    StackComponent.mailpit,
    StackComponent.memcached,
  ];

  static const _labels = {
    StackComponent.apache: 'Apache',
    StackComponent.nginx: 'Nginx',
    StackComponent.mysql: 'MySQL',
    StackComponent.postgresql: 'PostgreSQL',
    StackComponent.php: 'PHP',
    StackComponent.nodejs: 'Node.js',
    StackComponent.redis: 'Redis',
    StackComponent.memcached: 'Memcached',
    StackComponent.mailpit: 'Mailpit',
  };

  final Duration stopTimeout;
  final StartProcess _startProcess;
  final RunProcess _runProcess;
  final KillProcessTree _killProcessTree;
  final ProcessInspector _inspector;
  final AdoptProcess _adoptProcess;

  StackLayout _layout;
  final Map<StackComponent, _OwnedService> _owned = {};
  final Map<StackComponent, _ExternalService> _external = {};

  StackLayout get layout => _layout;

  /// Replaces the detected stack after configuration changed, keeping owned
  /// processes tracked so a running service is not forgotten.
  void updateLayout(StackLayout layout) {
    _layout = layout;
  }

  bool isRunning(StackComponent component) =>
      _owned.containsKey(component) || _external.containsKey(component);

  bool isExternal(StackComponent component) => _external.containsKey(component);

  bool get hasRunningServices => _owned.isNotEmpty || _external.isNotEmpty;

  Iterable<StackComponent> get runningComponents => {
    ..._owned.keys,
    ..._external.keys,
  };

  bool canStart(StackComponent component) =>
      !isRunning(component) && layout.activeVersion(component) != null;

  /// Finds services already started by another process, such as Laragon.
  Future<void> refreshExternal() async {
    final inspected = await _inspector.inspect();
    final ownedPids = _owned.values
        .map((service) => service.process.pid)
        .toSet();
    final external = <StackComponent, _ExternalService>{};

    for (final process in inspected) {
      if (ownedPids.contains(process.pid)) {
        continue;
      }
      for (final component in StackComponent.values) {
        if (external.containsKey(component)) {
          continue;
        }
        final install = _installContaining(component, process.executablePath);
        if (install != null) {
          external[component] = _ExternalService(
            pid: process.pid,
            install: install,
            executablePath: process.executablePath,
          );
          break;
        }
      }
    }

    _external
      ..clear()
      ..addAll(external);
  }

  Future<void> start(StackComponent component) async {
    if (_owned.containsKey(component)) {
      return;
    }
    if (_external.containsKey(component)) {
      throw ServiceException(
        '${_labels[component]} is already running outside StackPilot.',
      );
    }

    final install = layout.activeVersion(component);
    if (install == null) {
      throw ServiceException(
        'No active ${_labels[component]} version is selected in '
        'usr/profile/default.ini.',
      );
    }

    final command = _startCommand(install);
    final process = await _startProcess(
      command.executable,
      command.arguments,
      command.workingDirectory,
    );
    _owned[component] = _OwnedService(process: process, install: install);
    _adoptProcess(process.pid);

    unawaited(
      process.exitCode.then((_) {
        final owned = _owned[component];
        if (owned != null && identical(owned.process, process)) {
          _owned.remove(component);
        }
      }),
    );
  }

  Future<List<ServiceException>> startEnabled() async {
    final failures = <ServiceException>[];
    for (final component in _startOrder) {
      if (!layout.serviceEnabled(component) || isRunning(component)) {
        continue;
      }
      try {
        await start(component);
      } on ServiceException catch (error) {
        failures.add(error);
      } on ProcessException catch (error) {
        failures.add(
          ServiceException(
            '${_labels[component]} failed to start: ${error.message}',
          ),
        );
      }
    }
    return failures;
  }

  Future<void> stop(StackComponent component) async {
    final owned = _owned.remove(component);
    if (owned != null) {
      await _stopOwned(owned);
      return;
    }

    final external = _external.remove(component);
    if (external != null) {
      await _stopExternal(external);
    }
  }

  Future<List<ServiceException>> stopEnabled() async {
    final failures = <ServiceException>[];
    for (final component in _startOrder.reversed) {
      if (!isRunning(component)) {
        continue;
      }
      try {
        await stop(component);
      } on ProcessException catch (error) {
        failures.add(
          ServiceException(
            '${_labels[component]} failed to stop: ${error.message}',
          ),
        );
      }
    }
    return failures;
  }

  Future<void> _stopOwned(_OwnedService owned) async {
    if (await _requestStop(owned.install)) {
      if (await _waitForExit(owned.process)) {
        return;
      }
    }

    await _killProcessTree(owned.process.pid);
  }

  Future<void> _stopExternal(_ExternalService external) async {
    if (await _requestStop(external.install)) {
      if (await _waitForExternalExit(external.pid)) {
        return;
      }
    }

    final current = await _inspector.find(external.pid);
    if (current == null) {
      return;
    }
    if (!_sameExecutable(current.executablePath, external.executablePath)) {
      return;
    }
    await _killProcessTree(external.pid);
  }

  Future<bool> _requestStop(StackInstall install) async {
    final command = _stopCommand(install);
    if (command == null) {
      return false;
    }
    try {
      await _runProcess(
        command.executable,
        command.arguments,
      ).timeout(stopTimeout);
    } on TimeoutException {
      // Fall through to a forced stop.
    } on ProcessException {
      // Fall through to a forced stop.
    }
    return true;
  }

  Future<bool> _waitForExternalExit(int pid) async {
    final deadline = DateTime.now().add(stopTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _inspector.isAlive(pid)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  StackInstall? _installContaining(
    StackComponent component,
    String executablePath,
  ) {
    final path = p.normalize(executablePath).toLowerCase();
    for (final install in layout.installedVersions(component)) {
      final directory = p.normalize(install.directory).toLowerCase();
      if (path == directory || path.startsWith('$directory${p.separator}')) {
        return install;
      }
    }
    return null;
  }

  static bool _sameExecutable(String left, String right) =>
      p.normalize(left).toLowerCase() == p.normalize(right).toLowerCase();

  Future<bool> _waitForExit(RunningProcess process) async {
    try {
      await process.exitCode.timeout(stopTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  ServiceCommand _startCommand(StackInstall install) {
    final directory = install.directory;
    switch (install.component) {
      case StackComponent.apache:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: ['-f', p.join(directory, 'conf', 'httpd.conf')],
          workingDirectory: directory,
        );
      case StackComponent.nginx:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: ['-p', _prefix(directory), '-c', 'conf/nginx.conf'],
          workingDirectory: directory,
        );
      case StackComponent.mysql:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: ['--defaults-file=${p.join(directory, 'my.ini')}'],
          workingDirectory: directory,
        );
      case StackComponent.postgresql:
        if (!layout.postgresqlInitialized) {
          throw ServiceException(
            'PostgreSQL has no initialized data directory at '
            '${layout.postgresqlDataDirectory}. Run initdb once or start '
            'PostgreSQL from the stack first.',
          );
        }
        return ServiceCommand(
          executable: install.executablePath,
          arguments: ['-D', layout.postgresqlDataDirectory],
          workingDirectory: directory,
        );
      case StackComponent.redis:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: [p.join(directory, 'redis.conf')],
          workingDirectory: directory,
        );
      case StackComponent.mailpit:
      case StackComponent.memcached:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: const [],
          workingDirectory: directory,
        );
      case StackComponent.php:
      case StackComponent.nodejs:
        throw ServiceException(
          '${_labels[install.component]} is a runtime, not a service.',
        );
    }
  }

  ServiceCommand? _stopCommand(StackInstall install) {
    final directory = install.directory;
    switch (install.component) {
      case StackComponent.apache:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: [
            '-f',
            p.join(directory, 'conf', 'httpd.conf'),
            '-k',
            'stop',
          ],
          workingDirectory: directory,
        );
      case StackComponent.nginx:
        return ServiceCommand(
          executable: install.executablePath,
          arguments: ['-p', _prefix(directory), '-s', 'stop'],
          workingDirectory: directory,
        );
      case StackComponent.mysql:
        return ServiceCommand(
          executable: p.join(directory, 'bin', 'mysqladmin.exe'),
          arguments: [
            '--defaults-file=${p.join(directory, 'my.ini')}',
            '--user=root',
            '--connect-timeout=5',
            'shutdown',
          ],
          workingDirectory: directory,
        );
      case StackComponent.postgresql:
        return ServiceCommand(
          executable: p.join(directory, 'bin', 'pg_ctl.exe'),
          arguments: [
            '-D',
            layout.postgresqlDataDirectory,
            '-m',
            'fast',
            'stop',
          ],
          workingDirectory: directory,
        );
      case StackComponent.redis:
        final port = layout.config.value('redis', 'Port')?.trim();
        return ServiceCommand(
          executable: p.join(directory, 'redis-cli.exe'),
          arguments: [
            '-h',
            '127.0.0.1',
            '-p',
            (port == null || port.isEmpty) ? '6379' : port,
            'shutdown',
          ],
          workingDirectory: directory,
        );
      case StackComponent.mailpit:
      case StackComponent.memcached:
      case StackComponent.php:
      case StackComponent.nodejs:
        return null;
    }
  }

  static String _prefix(String directory) =>
      directory.endsWith(p.separator) ? directory : '$directory${p.separator}';

  static Future<RunningProcess> _defaultStart(
    String executable,
    List<String> arguments,
    String workingDirectory,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    return _DartRunningProcess(process);
  }

  static Future<int> _defaultRun(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    return result.exitCode;
  }

  static Future<void> _defaultKillTree(int pid) async {
    try {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
    } on ProcessException {
      // The process may have exited between the timeout and this call.
    }
  }

  static bool _defaultAdopt(int pid) =>
      WindowsJob.instance?.adopt(pid) ?? false;
}

class _OwnedService {
  const _OwnedService({required this.process, required this.install});

  final RunningProcess process;
  final StackInstall install;
}

class _ExternalService {
  const _ExternalService({
    required this.pid,
    required this.install,
    required this.executablePath,
  });

  final int pid;
  final StackInstall install;
  final String executablePath;
}

class _DartRunningProcess implements RunningProcess {
  const _DartRunningProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;
}
