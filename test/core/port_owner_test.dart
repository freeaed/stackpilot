import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/port_owner.dart';
import 'package:stackpilot/core/service_processes.dart';

void main() {
  const netstat = '''
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:80             0.0.0.0:0              LISTENING       4120
  TCP    127.0.0.1:3306         0.0.0.0:0              LISTENING       5120
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       900
  TCP    127.0.0.1:80           127.0.0.1:52344        ESTABLISHED     4120
''';

  test('finds the listening PID for a port', () {
    expect(parseListeningPid(netstat, 80), 4120);
    expect(parseListeningPid(netstat, 3306), 5120);
    expect(parseListeningPid(netstat, 8080), isNull);
  });

  test('returns the process that holds the port', () async {
    final owner = await findPortOwner(
      80,
      run: (executable, arguments) async {
        expect(executable, 'netstat');
        return ProcessResult(0, 0, netstat, '');
      },
      resolve: (pid) async => InspectedProcess(
        pid: pid,
        name: 'httpd.exe',
        executablePath: r'C:\laragon\bin\apache\httpd.exe',
      ),
    );

    expect(owner, isNotNull);
    expect(owner!.port, 80);
    expect(owner.pid, 4120);
    expect(owner.description, contains('httpd.exe'));
    expect(owner.description, contains(r'C:\laragon'));
  });

  test('returns null when nothing listens or netstat fails', () async {
    expect(
      await findPortOwner(
        9999,
        run: (_, _) async => ProcessResult(0, 0, netstat, ''),
      ),
      isNull,
    );

    expect(
      await findPortOwner(
        80,
        run: (_, _) async => ProcessResult(0, 1, '', 'access denied'),
      ),
      isNull,
    );
  });

  test('falls back to the PID when the process cannot be resolved', () async {
    final owner = await findPortOwner(
      3306,
      run: (_, _) async => ProcessResult(0, 0, netstat, ''),
      resolve: (_) async => null,
    );

    expect(owner!.description, 'PID 5120');
  });
}
