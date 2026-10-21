import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/service_logs.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late String root;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_logs_');
    root = temp.path;

    void file(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    file(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    file(r'bin\nginx\nginx-1.28.2\nginx.exe');
    file(r'bin\mysql\mysql-8.4.3\bin\mysqld.exe');
    file(r'bin\postgresql\postgresql-x64-16\bin\postgres.exe');
    file(r'bin\redis\redis-x64-5.0.14.1\redis-server.exe');
    file(r'bin\redis\redis-x64-5.0.14.1\redis.conf');
    file(r'data\postgresql\PG_VERSION', '16');
    file(r'data\postgresql\postgresql.conf', '#port = 5432\n');
    file(
      r'usr\laragon.ini',
      '[preferences]\nDataDir=$root\\data\n[apache]\nUse=-1\n',
    );
    file('usr/profile/default.ini', '''
[apache]
Version=httpd-2.4.66
[nginx]
Version=nginx-1.28.2
[mysql]
Version=mysql-8.4.3
[postgresql]
Version=postgresql-x64-16
[redis]
Version=redis-x64-5.0.14.1
''');

    layout = StackLayout.detect(root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void writeLog(String relativePath, String contents) {
    File(p.join(root, relativePath))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  test('discovers logs for every service that writes a file', () {
    writeLog(r'bin\apache\httpd-2.4.66\logs\error.log', 'apache error');
    writeLog(r'bin\apache\httpd-2.4.66\logs\access.log', 'apache access');
    writeLog(r'bin\nginx\nginx-1.28.2\logs\error.log', 'nginx error');
    writeLog(r'data\mysql\DESKTOP.err', 'mysql error');
    writeLog(r'data\mysql\slow.log', 'slow query');
    writeLog(r'data\postgresql\log\postgresql-2026-10-21.log', 'pg log');
    writeLog(r'bin\redis\redis-x64-5.0.14.1\redis.log', 'redis log');

    final files = ServiceLogs(layout).discover();

    expect(
      files.map((file) => file.component),
      [
        StackComponent.apache,
        StackComponent.apache,
        StackComponent.nginx,
        StackComponent.mysql,
        StackComponent.mysql,
        StackComponent.postgresql,
        StackComponent.redis,
      ],
    );
    expect(
      files.map((file) => file.label),
      [
        'error.log',
        'access.log',
        'error.log',
        'DESKTOP.err',
        'slow.log',
        'postgresql-2026-10-21.log',
        'redis.log',
      ],
    );
  });

  test('ignores unrelated files and missing log folders', () {
    writeLog(r'bin\apache\httpd-2.4.66\logs\notes.txt', 'not a log');
    writeLog(r'bin\redis\redis-x64-5.0.14.1\dump.rdb', 'binary');
    writeLog(r'data\postgresql\pg_log\postgresql.log', 'pg log');

    final files = ServiceLogs(layout).discover();

    expect(files, hasLength(1));
    expect(files.single.component, StackComponent.postgresql);
    expect(files.single.label, 'postgresql.log');
  });

  test('reads the end of a log without a trailing newline', () {
    writeLog(r'bin\apache\httpd-2.4.66\logs\error.log', 'first\nsecond\nthird');

    final file = ServiceLogs(layout).discover().single;
    final tail = ServiceLogs(layout).readTail(file);

    expect(tail.text, 'first\nsecond\nthird');
    expect(tail.truncated, isFalse);
    expect(tail.exists, isTrue);
    expect(tail.bytesShown, greaterThan(0));
  });

  test('normalizes CRLF line endings', () {
    writeLog(
      r'bin\apache\httpd-2.4.66\logs\error.log',
      'first\r\nsecond\r\nthird\r\n',
    );

    final tail = ServiceLogs(
      layout,
    ).readTail(ServiceLogs(layout).discover().single);

    expect(tail.text, 'first\nsecond\nthird');
  });

  test('keeps only the newest lines and reports truncation', () {
    final lines = List.generate(40, (index) => 'line $index');
    writeLog(
      r'bin\apache\httpd-2.4.66\logs\error.log',
      lines.join('\n'),
    );

    final tail = ServiceLogs(
      layout,
    ).readTail(ServiceLogs(layout).discover().single, maxLines: 4);

    expect(tail.text, 'line 36\nline 37\nline 38\nline 39');
    expect(tail.truncated, isTrue);
  });

  test('skips the partial first line when reading a byte limit', () {
    final lines = List.generate(30, (index) => 'line $index ${'x' * 40}');
    writeLog(
      r'bin\apache\httpd-2.4.66\logs\error.log',
      lines.join('\n'),
    );

    final tail = ServiceLogs(layout).readTail(
      ServiceLogs(layout).discover().single,
      maxBytes: 300,
      maxLines: 20,
    );

    expect(tail.truncated, isTrue);
    expect(tail.text.split('\n').every((line) => line.startsWith('line ')), isTrue);
    expect(tail.text, endsWith(lines.last));
  });

  test('reports a removed log file as empty', () {
    const file = ServiceLogFile(
      component: StackComponent.apache,
      path: r'C:\missing\error.log',
      label: 'error.log',
    );

    final tail = ServiceLogs(layout).readTail(file);

    expect(tail.exists, isFalse);
    expect(tail.text, isEmpty);
    expect(tail.truncated, isFalse);
  });
}
