import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/phpmyadmin_health.dart';

void main() {
  test('reports a healthy status', () async {
    final probe = await probePhpMyAdmin(
      fetch: (_) async => 200,
    );

    expect(probe.ok, isTrue);
    expect(probe.statusCode, 200);
    expect(probe.summary, 'HTTP 200');
    expect(probe.url, 'http://127.0.0.1/phpmyadmin/');
  });

  test('accepts a redirect as a working alias', () async {
    final probe = await probePhpMyAdmin(fetch: (_) async => 302);

    expect(probe.ok, isTrue);
  });

  test('treats 403 and 500 as failures', () async {
    for (final status in [403, 404, 500]) {
      final probe = await probePhpMyAdmin(fetch: (_) async => status);
      expect(probe.ok, isFalse, reason: '$status');
      expect(probe.summary, 'HTTP $status');
    }
  });

  test('reports a connection failure instead of throwing', () async {
    final probe = await probePhpMyAdmin(
      fetch: (_) async => throw const SocketException('Connection refused'),
    );

    expect(probe.ok, isFalse);
    expect(probe.statusCode, isNull);
    expect(probe.summary, contains('Apache'));
    expect(probe.summary, contains('Connection refused'));
  });

  test('retries while Apache is still starting', () async {
    var calls = 0;
    final probe = await probePhpMyAdmin(
      retries: 3,
      retryDelay: Duration.zero,
      fetch: (_) async {
        calls++;
        if (calls < 3) {
          throw const SocketException('Connection refused');
        }
        return 200;
      },
    );

    expect(probe.ok, isTrue);
    expect(calls, 3);
  });

  test('stops retrying once Apache answers', () async {
    var calls = 0;
    final probe = await probePhpMyAdmin(
      retries: 3,
      retryDelay: Duration.zero,
      fetch: (_) async {
        calls++;
        return 403;
      },
    );

    expect(probe.ok, isFalse);
    expect(calls, 1);
  });

  test('rejects an invalid URL', () async {
    final probe = await probePhpMyAdmin(url: 'not a url');

    expect(probe.ok, isFalse);
    expect(probe.summary, contains('not valid'));
  });
}
