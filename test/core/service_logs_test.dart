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

  test('reads the Apache log paths from httpd.conf', () {
    final apache = p.join(root, r'bin\apache\httpd-2.4.66');
    final slashApache = apache.replaceAll(r'\', '/');
    File(p.join(apache, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'Define SRVROOT "$slashApache"\r\n'
        'ServerRoot "\${SRVROOT}"\r\n'
        'ErrorLog "logs/error_log"\r\n'
        'CustomLog "logs/access_log" combined\r\n',
      );
    writeLog(r'bin\apache\httpd-2.4.66\logs\error_log', 'apache error');
    writeLog(r'bin\apache\httpd-2.4.66\logs\access_log', 'apache access');

    final files = ServiceLogs(
      layout,
    ).discover().where((file) => file.component == StackComponent.apache);

    expect(
      files.map((file) => p.basename(file.path)),
      containsAll(['error_log', 'access_log']),
    );
  });

  test('finds Laragon logs at the stack root', () {
    final apache = p.join(root, r'bin\apache\httpd-2.4.66');
    File(p.join(apache, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'ServerRoot "${apache.replaceAll(r'\', '/')}"\r\n'
        'ErrorLog "logs/error.log"\r\n'
        'CustomLog "logs/access.log" common\r\n',
      );
    writeLog(r'logs\error_log', 'laragon error');
    writeLog(r'logs\access_log', 'laragon access');

    final paths = ServiceLogs(layout)
        .discover()
        .where((file) => file.component == StackComponent.apache)
        .map((file) => p.basename(file.path));

    expect(paths, containsAll(['error_log', 'access_log']));
  });

  test('reads the MySQL error log from my.ini', () {
    final mysql = p.join(root, r'bin\mysql\mysql-8.4.3');
    final target = p.join(root, 'logs', 'custom-mysql.err');
    File(p.join(mysql, 'my.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '[mysqld]\r\nlog-error="${target.replaceAll(r'\', '/')}"\r\n',
      );
    File(target)
      ..createSync(recursive: true)
      ..writeAsStringSync('mysql error');

    final files = ServiceLogs(
      layout,
    ).discover().where((file) => file.component == StackComponent.mysql);

    expect(files.map((file) => file.path), contains(p.normalize(target)));
  });

  test('reads nginx, redis and PostgreSQL log settings', () {
    final nginx = p.join(root, r'bin\nginx\nginx-1.28.2');
    File(p.join(nginx, 'conf', 'nginx.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'error_log "logs/nginx-error.log" warn;\r\n'
        'http {\r\n'
        '    access_log "logs/nginx-access.log";\r\n'
        '}\r\n',
      );
    writeLog(r'bin\nginx\nginx-1.28.2\logs\nginx-error.log', 'nginx error');
    writeLog(r'bin\nginx\nginx-1.28.2\logs\nginx-access.log', 'nginx access');

    final redis = p.join(root, r'bin\redis\redis-x64-5.0.14.1');
    final redisLog = p.join(root, 'logs', 'custom-redis.log');
    File(p.join(redis, 'redis.conf')).writeAsStringSync(
      'logfile "${redisLog.replaceAll(r'\', '/')}"\r\n',
    );
    File(redisLog)
      ..createSync(recursive: true)
      ..writeAsStringSync('redis log');

    File(p.join(root, r'data\postgresql\postgresql.conf'))
        .writeAsStringSync("log_directory = 'pg_log2'\r\n");
    writeLog(r'data\postgresql\pg_log2\postgresql.log', 'pg log');

    final files = ServiceLogs(layout).discover();
    expect(
      files
          .where((file) => file.component == StackComponent.nginx)
          .map((file) => p.basename(file.path)),
      containsAll(['nginx-error.log', 'nginx-access.log']),
    );
    expect(
      files
          .where((file) => file.component == StackComponent.redis)
          .map((file) => p.basename(file.path)),
      contains('custom-redis.log'),
    );
    expect(
      files
          .where((file) => file.component == StackComponent.postgresql)
          .map((file) => p.basename(file.path)),
      contains('postgresql.log'),
    );
  });

  test('lists captured console output', () {
    writeLog(r'logs\mailpit-console.log', '[10:00:00] mailpit ready');

    final files = ServiceLogs(layout).discover();

    final console = files.singleWhere(
      (file) => file.component == StackComponent.mailpit,
    );
    expect(console.label, 'console');
    expect(console.path, p.join(root, 'logs', 'mailpit-console.log'));
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
