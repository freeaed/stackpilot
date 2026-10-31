import 'dart:async';
import 'dart:io';

/// Result of asking Apache for the phpMyAdmin page.
class PhpMyAdminProbe {
  const PhpMyAdminProbe({required this.url, this.statusCode, this.error});

  final String url;
  final int? statusCode;
  final String? error;

  /// True for a success or redirect, which is what a working alias returns.
  bool get ok =>
      statusCode != null && statusCode! >= 200 && statusCode! < 400;

  String get summary {
    if (statusCode != null) {
      return 'HTTP $statusCode';
    }
    return error ?? 'No response';
  }
}

typedef PhpMyAdminStatusFetcher = Future<int> Function(Uri uri);

/// Requests [url] and returns the status code.
///
/// The default probe uses `HttpClient` with a short timeout; tests inject
/// [fetch]. Connection failures are returned as a message instead of throwing,
/// so the caller can report them next to the URL. [retries] covers the moment
/// right after Apache is started, before it binds its port.
Future<PhpMyAdminProbe> probePhpMyAdmin({
  String url = 'http://127.0.0.1/phpmyadmin/',
  Duration timeout = const Duration(seconds: 5),
  Duration retryDelay = const Duration(milliseconds: 300),
  int retries = 0,
  PhpMyAdminStatusFetcher? fetch,
}) async {
  PhpMyAdminProbe result = const PhpMyAdminProbe(url: '');
  for (var attempt = 0; attempt <= retries; attempt++) {
    result = await _probeOnce(
      url,
      timeout: timeout,
      fetch: fetch,
    );
    // An HTTP answer means the server is up, even when it is an error.
    if (result.statusCode != null || attempt == retries) {
      return result;
    }
    await Future<void>.delayed(retryDelay);
  }
  return result;
}

Future<PhpMyAdminProbe> _probeOnce(
  String url, {
  required Duration timeout,
  PhpMyAdminStatusFetcher? fetch,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return PhpMyAdminProbe(url: url, error: 'The URL is not valid.');
  }
  try {
    final status = fetch != null
        ? await fetch(uri).timeout(timeout)
        : await _httpStatus(uri, timeout);
    return PhpMyAdminProbe(url: uri.toString(), statusCode: status);
  } on TimeoutException {
    return PhpMyAdminProbe(
      url: uri.toString(),
      error: 'The request timed out after ${timeout.inSeconds} s.',
    );
  } on SocketException catch (error) {
    return PhpMyAdminProbe(
      url: uri.toString(),
      error:
          'Could not connect to ${uri.host}:${uri.port}: ${error.message}. '
          'Is Apache running?',
    );
  } on HttpException catch (error) {
    return PhpMyAdminProbe(url: uri.toString(), error: error.message);
  } on Object catch (error) {
    return PhpMyAdminProbe(url: uri.toString(), error: '$error');
  }
}

Future<int> _httpStatus(Uri uri, Duration timeout) async {
  final loopback =
      uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1';
  final client = HttpClient()..connectionTimeout = timeout;
  // A system proxy must never intercept the local health check.
  client.findProxy = loopback
      ? (request) => 'DIRECT'
      : HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'StackPilot (phpMyAdmin health check)',
    );
    // Do not let a stale redirect chain decide the status.
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}
