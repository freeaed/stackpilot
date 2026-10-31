import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late String apache;
  late String nginx;
  late String redis;
  late String mysql;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_ports_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));

    apache = p.join(layout.root, 'bin', 'apache', 'httpd-2.4.69');
    File(p.join(apache, 'bin', 'httpd.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(apache, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ServerRoot "${apache.replaceAll(r'\', '/')}"\n'
          'Listen 80\n');
    File(p.join(layout.root, 'etc', 'apache2', 'sites-enabled', 'blog.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<VirtualHost *:80>\n</VirtualHost>\n');

    nginx = p.join(layout.root, 'bin', 'nginx', 'nginx-1.30.6');
    File(p.join(nginx, 'nginx.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(nginx, 'conf', 'nginx.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('server {\n    listen 80;\n}\n');

    redis = p.join(layout.root, 'bin', 'redis', 'redis-5.0.14.1');
    File(p.join(redis, 'redis-server.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(
      p.join(redis, 'redis.conf'),
    ).writeAsStringSync('port 6379\nbind 127.0.0.1\n');

    File(p.join(layout.root, 'bin', 'mailpit', '1.32.0', 'mailpit.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');

    mysql = p.join(layout.root, 'bin', 'mysql', 'mariadb-11.4.13');
    File(p.join(mysql, 'bin', 'mysqld.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(mysql, 'my.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[mysqld]\nport=3306\ndatadir="x"\n');

    File(p.join(layout.root, 'usr', 'profile', 'default.ini'))
        .writeAsStringSync('''
[apache]
Version=httpd-2.4.69
[nginx]
Version=nginx-1.30.6
[redis]
Version=redis-5.0.14.1
[mailpit]
Version=1.32.0
[mysql]
Version=mariadb-11.4.13
''');

    layout = StackLayout.detect(layout.root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('moves Apache and the vhost to a new port', () async {
    await StackEditor(layout).changeServicePort(StackComponent.apache, 8080);

    final detected = StackLayout.detect(layout.root)!;
    expect(detected.apachePort, 8080);
    final httpd = File(
      p.join(apache, 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(httpd, contains('Listen 127.0.0.1:8080'));
    expect(httpd, isNot(contains('Listen 127.0.0.1:80\n')));
    final vhost = File(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled', 'blog.conf'),
    ).readAsStringSync();
    expect(vhost, contains('<VirtualHost *:8080>'));
  });

  test('moves MySQL in the marker and my.ini', () async {
    await StackEditor(layout).changeServicePort(StackComponent.mysql, 3308);

    final detected = StackLayout.detect(layout.root)!;
    expect(detected.mysqlPort, 3308);
    final ini = File(p.join(mysql, 'my.ini')).readAsStringSync();
    expect(ini, contains('port=3308'));
  });

  test('moves nginx, Redis and Mailpit', () async {
    final editor = StackEditor(layout);
    await editor.changeServicePort(StackComponent.nginx, 8081);
    await editor.changeServicePort(StackComponent.redis, 6380);
    await editor.changeServicePort(StackComponent.mailpit, 8030);

    final detected = StackLayout.detect(layout.root)!;
    expect(detected.nginxPort, 8081);
    expect(detected.redisPort, 6380);
    expect(detected.mailpitPort, 8030);

    expect(
      File(p.join(nginx, 'conf', 'nginx.conf')).readAsStringSync(),
      contains('listen 8081;'),
    );
    expect(
      File(p.join(redis, 'redis.conf')).readAsStringSync(),
      contains('port 6380'),
    );
  });

  test('rejects a port outside the valid range', () async {
    expect(
      () => StackEditor(layout).changeServicePort(StackComponent.redis, 70000),
      throwsA(isA<StackEditException>()),
    );
  });
}
