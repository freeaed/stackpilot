import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/service_console.dart';
import 'package:stackpilot/core/service_manager.dart';
import 'package:stackpilot/core/service_processes.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:path/path.dart' as p;

class _FakeProcess implements RunningProcess {
  _FakeProcess(this.pid);

  @override
  final int pid;

  final Completer<int> _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  void finish([int code = 0]) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
  }
}

class _FakeOutputProcess extends _FakeProcess
    implements RunningProcessWithOutput {
  _FakeOutputProcess(super.pid);

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  void write(String line) {
    _stdout.add(utf8.encode('$line\n'));
  }

  @override
  void finish([int code = 0]) {
    super.finish(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

class _StartCall {
  const _StartCall(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

class _RunCall {
  const _RunCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class _FakeInspector implements ProcessInspector {
  _FakeInspector(this.processes);

  final List<InspectedProcess> processes;
  bool alive = true;

  @override
  Future<List<InspectedProcess>> inspect() async => processes;

  @override
  Future<bool> isAlive(int pid) async => alive;

  @override
  Future<InspectedProcess?> find(int pid) async {
    for (final process in processes) {
      if (process.pid == pid) {
        return process;
      }
    }
    return null;
  }
}

void main() {
  late Directory temp;
  late String root;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_services_');
    root = temp.path;

    void createFile(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    createFile(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    createFile(r'bin\nginx\nginx-1.28.2\nginx.exe');
    createFile(r'bin\mysql\mysql-8.4.3\bin\mysqld.exe');
    createFile(r'bin\mysql\mysql-8.4.3\my.ini');
    createFile(r'bin\postgresql\postgresql-x64-16\bin\postgres.exe');
    createFile(r'bin\postgresql\postgresql-x64-16\bin\pg_ctl.exe');
    createFile(r'data\postgresql\PG_VERSION', '16');
    createFile(r'data\postgresql\postgresql.conf', 'port = 5432\n');
    createFile(r'bin\redis\redis-x64-5.0.14.1\redis-server.exe');
    createFile(r'bin\redis\redis-x64-5.0.14.1\redis-cli.exe');
    createFile(r'bin\mailpit\1.22.3\mailpit.exe');
    createFile(r'bin\php\php-8.3.30\php.exe');
    createFile(r'bin\nodejs\node-v22\node.exe');

    createFile(r'usr\laragon.ini', '''
[preferences]
AutoVirtualHosts=-1
DocumentRootList=$root\\www|

[apache]
Use=-1

[mysql]
Use=-1

[nginx]
Use=0

[redis]
Use=-1

[mailpit]
Use=-1
''');

    createFile(r'usr\profile\default.ini', '''
[apache]
Version=httpd-2.4.66

[mysql]
Version=mysql-8.4.3

[postgresql]
Version=postgresql-x64-16

[nginx]
Version=nginx-1.28.2

[redis]
Version=redis-x64-5.0.14.1

[mailpit]
Version=1.22.3

[php]
Version=php-8.3.30

[nodejs]
Version=node-v22
''');

    layout = StackLayout.detect(root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  ServiceManager createManager({
    RunProcess? runProcess,
    Duration stopTimeout = const Duration(milliseconds: 80),
    List<_StartCall>? starts,
    List<_RunCall>? runs,
    List<int>? killed,
    List<_FakeProcess>? processes,
    ProcessInspector? inspector,
    List<int>? adopted,
    bool portFree = true,
  }) {
    var nextPid = 4200;
    return ServiceManager(
      layout,
      stopTimeout: stopTimeout,
      verifyStart: false,
      isPortFree: (port) async => portFree,
      startProcess: (executable, arguments, workingDirectory) async {
        starts?.add(_StartCall(executable, arguments, workingDirectory));
        final process = _FakeProcess(nextPid++);
        processes?.add(process);
        return process;
      },
      runProcess: (executable, arguments) async {
        runs?.add(_RunCall(executable, arguments));
        if (runProcess != null) {
          return runProcess(executable, arguments);
        }
        return 0;
      },
      killProcessTree: (pid) async {
        killed?.add(pid);
      },
      inspector: inspector,
      adoptProcess: (pid) {
        adopted?.add(pid);
        return true;
      },
    );
  }

  test('starts Apache once with its own config', () async {
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts);

    await manager.start(StackComponent.apache);
    await manager.start(StackComponent.apache);

    expect(starts, hasLength(1));
    expect(starts.single.executable, endsWith(r'bin\httpd.exe'));
    expect(starts.single.arguments, [
      '-f',
      p.join(root, 'bin', 'apache', 'httpd-2.4.66', 'conf', 'httpd.conf'),
    ]);
    expect(
      starts.single.workingDirectory,
      p.join(root, 'bin', 'apache', 'httpd-2.4.66'),
    );
    expect(manager.isRunning(StackComponent.apache), isTrue);
  });

  test('refuses to start when its port is already in use', () async {
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts, portFree: false);

    await expectLater(
      manager.start(StackComponent.apache),
      throwsA(
        isA<ServiceException>().having(
          (error) => error.message,
          'message',
          contains('port 80'),
        ),
      ),
    );
    expect(starts, isEmpty);
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('reads the HTTP port from the Apache config', () async {
    final config = File(
      p.join(root, 'bin', 'apache', 'httpd-2.4.66', 'conf', 'httpd.conf'),
    );
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('Listen 0.0.0.0:8080\n');

    final manager = createManager(portFree: false);

    await expectLater(
      manager.start(StackComponent.apache),
      throwsA(
        isA<ServiceException>().having(
          (error) => error.message,
          'message',
          contains('port 8080'),
        ),
      ),
    );
  });

  test('stops Apache gracefully without killing its tree', () async {
    final runs = <_RunCall>[];
    final killed = <int>[];
    final processes = <_FakeProcess>[];
    final manager = createManager(
      runs: runs,
      killed: killed,
      processes: processes,
      runProcess: (executable, arguments) async {
        processes.single.finish();
        return 0;
      },
    );

    await manager.start(StackComponent.apache);
    await manager.stop(StackComponent.apache);

    expect(runs, hasLength(1));
    expect(runs.single.arguments, containsAllInOrder(['-k', 'stop']));
    expect(killed, isEmpty);
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('forces a stop when the graceful command does not exit', () async {
    final killed = <int>[];
    final manager = createManager(
      killed: killed,
      stopTimeout: const Duration(milliseconds: 40),
    );

    await manager.start(StackComponent.mysql);
    await manager.stop(StackComponent.mysql);

    expect(killed, [4200]);
    expect(manager.isRunning(StackComponent.mysql), isFalse);
  });

  test('kills services without a graceful stop command', () async {
    final runs = <_RunCall>[];
    final killed = <int>[];
    final manager = createManager(runs: runs, killed: killed);

    await manager.start(StackComponent.mailpit);
    await manager.stop(StackComponent.mailpit);

    expect(runs, isEmpty);
    expect(killed, [4200]);
  });

  test('startEnabled starts only enabled services in start order', () async {
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts);

    final failures = await manager.startEnabled();

    expect(failures, isEmpty);
    expect(starts.map((call) => p.basename(call.executable)), [
      'httpd.exe',
      'mysqld.exe',
      'redis-server.exe',
      'mailpit.exe',
    ]);
  });

  test('starts PostgreSQL with this stack data folder', () async {
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts);

    await manager.start(StackComponent.postgresql);

    expect(starts, hasLength(1));
    expect(starts.single.executable, endsWith(r'bin\postgres.exe'));
    expect(starts.single.arguments, [
      '-D',
      p.join(root, 'data', 'postgresql'),
    ]);
    expect(manager.isRunning(StackComponent.postgresql), isTrue);
  });

  test('refuses to start PostgreSQL without an initialized data folder', () async {
    Directory(p.join(root, 'data', 'postgresql')).deleteSync(recursive: true);
    layout = StackLayout.detect(root)!;
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts);

    await expectLater(
      manager.start(StackComponent.postgresql),
      throwsA(
        isA<ServiceException>().having(
          (error) => error.message,
          'message',
          contains('no initialized data directory'),
        ),
      ),
    );
    expect(starts, isEmpty);
    expect(manager.isRunning(StackComponent.postgresql), isFalse);
  });

  test('stops PostgreSQL with pg_ctl', () async {
    final runs = <_RunCall>[];
    final killed = <int>[];
    final processes = <_FakeProcess>[];
    final manager = createManager(
      runs: runs,
      killed: killed,
      processes: processes,
      runProcess: (executable, arguments) async {
        processes.single.finish();
        return 0;
      },
    );

    await manager.start(StackComponent.postgresql);
    await manager.stop(StackComponent.postgresql);

    expect(runs, hasLength(1));
    expect(runs.single.executable, endsWith(r'bin\pg_ctl.exe'));
    expect(runs.single.arguments, [
      '-D',
      p.join(root, 'data', 'postgresql'),
      '-m',
      'fast',
      'stop',
    ]);
    expect(killed, isEmpty);
    expect(manager.isRunning(StackComponent.postgresql), isFalse);
  });

  test('adopts started services into the job object', () async {
    final adopted = <int>[];
    final manager = createManager(adopted: adopted);

    await manager.start(StackComponent.apache);

    expect(adopted, [4200]);
  });

  test('finds and stops a stack service started outside StackPilot', () async {
    final httpd = p.join(
      root,
      'bin',
      'apache',
      'httpd-2.4.66',
      'bin',
      'httpd.exe',
    );
    final inspector = _FakeInspector([
      InspectedProcess(pid: 9001, name: 'httpd.exe', executablePath: httpd),
    ]);
    final runs = <_RunCall>[];
    final killed = <int>[];
    final manager = createManager(
      inspector: inspector,
      runs: runs,
      killed: killed,
      runProcess: (executable, arguments) async {
        inspector.alive = false;
        return 0;
      },
    );

    await manager.refreshExternal();
    expect(manager.isExternal(StackComponent.apache), isTrue);
    expect(manager.canStart(StackComponent.apache), isFalse);

    await manager.stop(StackComponent.apache);

    expect(runs.single.arguments, containsAllInOrder(['-k', 'stop']));
    expect(killed, isEmpty);
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('ignores services whose executable is outside the stack', () async {
    final inspector = _FakeInspector([
      const InspectedProcess(
        pid: 9002,
        name: 'httpd.exe',
        executablePath: r'C:\Other\Apache\bin\httpd.exe',
      ),
    ]);
    final manager = createManager(inspector: inspector);

    await manager.refreshExternal();

    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('startEnabled does not restart adopted services', () async {
    final httpd = p.join(
      root,
      'bin',
      'apache',
      'httpd-2.4.66',
      'bin',
      'httpd.exe',
    );
    final inspector = _FakeInspector([
      InspectedProcess(pid: 9003, name: 'httpd.exe', executablePath: httpd),
    ]);
    final starts = <_StartCall>[];
    final manager = createManager(starts: starts, inspector: inspector);
    await manager.refreshExternal();

    final failures = await manager.startEnabled();

    expect(failures, isEmpty);
    expect(starts.map((call) => p.basename(call.executable)), [
      'mysqld.exe',
      'redis-server.exe',
      'mailpit.exe',
    ]);
  });

  test('refuses to start without an active version', () async {
    File(p.join(root, 'usr', 'profile', 'default.ini')).deleteSync();
    layout = StackLayout.detect(root)!;
    final manager = createManager();

    await expectLater(
      manager.start(StackComponent.apache),
      throwsA(isA<ServiceException>()),
    );
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('reports a service that exits right after starting', () async {
    final process = _FakeOutputProcess(4300);
    final exits = <ServiceExit>[];
    final reported = Completer<void>();
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      verifyStart: false,
      startProcess: (_, _, _) async => process,
      runProcess: (_, _) async => 0,
      killProcessTree: (_) async {},
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
      earlyExitThreshold: const Duration(seconds: 2),
    );
    manager.onServiceExit = (exit) {
      exits.add(exit);
      if (!reported.isCompleted) {
        reported.complete();
      }
    };

    await manager.start(StackComponent.mailpit);
    process.write('Error: port 8025 is already in use');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.finish(1);
    await reported.future.timeout(const Duration(seconds: 2));

    expect(exits.single.component, StackComponent.mailpit);
    expect(exits.single.exitCode, 1);
    expect(exits.single.unexpected, isTrue);
    expect(
      exits.single.recentLines.join('\n'),
      contains('port 8025 is already in use'),
    );
  });

  test('does not report a service StackPilot stopped', () async {
    late _FakeProcess process;
    var reported = false;
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      verifyStart: false,
      startProcess: (_, _, _) async {
        process = _FakeProcess(4400);
        return process;
      },
      runProcess: (_, _) async {
        process.finish();
        return 0;
      },
      killProcessTree: (_) async {},
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
      earlyExitThreshold: const Duration(seconds: 2),
    );
    manager.onServiceExit = (_) => reported = true;

    await manager.start(StackComponent.apache);
    await manager.stop(StackComponent.apache);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(reported, isFalse);
  });

  test('does not report a service that ran for a while', () async {
    final process = _FakeProcess(4500);
    var reported = false;
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      verifyStart: false,
      startProcess: (_, _, _) async => process,
      runProcess: (_, _) async => 0,
      killProcessTree: (_) async {},
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
      earlyExitThreshold: const Duration(milliseconds: 20),
    );
    manager.onServiceExit = (_) => reported = true;

    await manager.start(StackComponent.mailpit);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    process.finish();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(reported, isFalse);
  });

  test('reports the port when it is already in use', () async {
    final manager = createManager(portFree: false);

    await expectLater(
      manager.start(StackComponent.apache),
      throwsA(
        isA<ServiceException>()
            .having((error) => error.port, 'port', 80)
            .having((error) => error.component, 'component', StackComponent.apache),
      ),
    );
  });

  test('waits for the port before reporting a service as running', () async {
    final process = _FakeProcess(4700);
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      isPortOpen: (_) async => true,
      startupTimeout: const Duration(seconds: 1),
      stabilityWindow: Duration.zero,
      startProcess: (_, _, _) async => process,
      runProcess: (_, _) async => 0,
      killProcessTree: (_) async {},
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
    );

    await manager.start(StackComponent.apache);

    expect(manager.isRunning(StackComponent.apache), isTrue);
  });

  test('fails when the port never opens, with the captured output', () async {
    late _FakeOutputProcess process;
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      isPortOpen: (_) async => false,
      startupTimeout: const Duration(milliseconds: 120),
      stabilityWindow: Duration.zero,
      startProcess: (_, _, _) async {
        process = _FakeOutputProcess(4600);
        process.write('AH00526: bad config line');
        return process;
      },
      runProcess: (_, _) async => 0,
      killProcessTree: (_) async => process.finish(1),
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
    );

    await expectLater(
      manager.start(StackComponent.apache),
      throwsA(
        isA<ServiceException>()
            .having((error) => error.port, 'port', 80)
            .having(
              (error) => error.message,
              'message',
              contains('did not accept connections'),
            ),
      ),
    );
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('fails when the process exits before the port opens', () async {
    late _FakeProcess process;
    final manager = ServiceManager(
      layout,
      isPortFree: (_) async => true,
      isPortOpen: (_) async => false,
      startupTimeout: const Duration(seconds: 2),
      stabilityWindow: Duration.zero,
      startProcess: (_, _, _) async {
        process = _FakeProcess(4800);
        return process;
      },
      runProcess: (_, _) async => 0,
      killProcessTree: (_) async {},
      adoptProcess: (_) => true,
      console: ServiceConsole(root),
    );

    final starting = manager.start(StackComponent.apache);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.finish(1);

    await expectLater(starting, throwsA(isA<ServiceException>()));
    expect(manager.isRunning(StackComponent.apache), isFalse);
  });

  test('stops nginx with -s quit', () async {
    final runs = <_RunCall>[];
    final processes = <_FakeProcess>[];
    final manager = createManager(
      runs: runs,
      processes: processes,
      runProcess: (_, _) async {
        processes.single.finish();
        return 0;
      },
    );

    await manager.start(StackComponent.nginx);
    await manager.stop(StackComponent.nginx);

    expect(runs.single.arguments, containsAllInOrder(['-s', 'quit']));
  });
}
