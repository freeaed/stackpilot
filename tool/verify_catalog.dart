// Verifies every URL in the component and app catalogs.
//
//   dart run tool/verify_catalog.dart
//
// The script sends a HEAD request to the primary URL and every mirror, follows
// redirects by hand, and compares the Content-Length with the size pinned in
// the catalog. A 404, a moved archive, or a re-uploaded build changes the size
// and makes this command fail, so CI catches a broken pin before a release.
//
// Exit codes: 0 everything answered as expected, 1 at least one pin is broken.

import 'dart:io';

import 'package:stackpilot/core/app_catalog.dart';
import 'package:stackpilot/core/component_catalog.dart';

const _shaPattern = r'^[0-9a-f]{64}$';

Future<void> main(List<String> args) async {
  final quiet = args.contains('--quiet');
  var failures = 0;
  var warnings = 0;

  if (!quiet) {
    stdout.writeln('Checking ${ComponentCatalog.releases.length} components '
        'and ${AppCatalog.apps.length} applications…\n');
  }

  for (final release in ComponentCatalog.releases) {
    final result = await _checkPins(
      '${release.label} (${release.installName})',
      release.urls,
      release.sha256,
      release.sizeBytes,
      quiet: quiet,
    );
    failures += result.$1;
    warnings += result.$2;
  }

  for (final app in AppCatalog.apps) {
    final result = await _checkPins(
      '${app.label} (${app.installName})',
      app.urls,
      app.sha256,
      app.sizeBytes,
      quiet: quiet,
    );
    failures += result.$1;
    warnings += result.$2;
  }

  stdout.writeln(
    '\n${failures == 0 ? 'Catalog OK' : 'Catalog broken'}: '
    '$failures failed pin(s), $warnings warning(s).',
  );
  exitCode = failures == 0 ? 0 : 1;
}

/// Returns (failures, warnings).
Future<(int, int)> _checkPins(
  String label,
  List<String> urls,
  String sha256,
  int? sizeBytes, {
  required bool quiet,
}) async {
  var failures = 0;
  var warnings = 0;

  if (!RegExp(_shaPattern).hasMatch(sha256)) {
    stdout.writeln('FAIL  $label: sha256 is not a lower-case digest');
    return (1, 0);
  }
  if (sizeBytes == null) {
    warnings++;
    if (!quiet) {
      stdout.writeln('WARN  $label: no pinned size, only the URL is checked');
    }
  }

  for (final url in urls) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      stdout.writeln('FAIL  $label: not an HTTPS URL: $url');
      failures++;
      continue;
    }
    final probe = await _probe(uri);
    if (probe.error != null) {
      stdout.writeln('FAIL  $label\n      $url\n      ${probe.error}');
      failures++;
      continue;
    }
    if (probe.status != HttpStatus.ok) {
      stdout.writeln(
        'FAIL  $label\n      $url\n      HTTP ${probe.status}'
        '${probe.finalUrl != null ? ' (after ${probe.finalUrl})' : ''}',
      );
      failures++;
      continue;
    }
    if (sizeBytes != null && probe.length != null && probe.length != sizeBytes) {
      stdout.writeln(
        'FAIL  $label\n      $url\n      expected $sizeBytes bytes, '
        'server reports ${probe.length}',
      );
      failures++;
      continue;
    }
    if (sizeBytes != null && probe.length == null) {
      warnings++;
      if (!quiet) {
        stdout.writeln('WARN  $label\n      $url\n      no Content-Length');
      }
      continue;
    }
    if (!quiet) {
      stdout.writeln('ok    $label\n      $url'
          '${probe.length == null ? '' : ' (${probe.length} bytes)'}');
    }
  }

  return (failures, warnings);
}

class _Probe {
  const _Probe({this.status, this.length, this.finalUrl, this.error});

  final int? status;
  final int? length;
  final Uri? finalUrl;
  final String? error;
}

Future<_Probe> _probe(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    var current = uri;
    for (var hop = 0; hop < 6; hop++) {
      final request = await client.headUrl(current);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'StackPilot catalog check',
      );
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location != null && _isRedirect(response.statusCode)) {
        await response.drain<void>();
        current = current.resolve(location);
        continue;
      }
      final length = response.contentLength > 0
          ? response.contentLength
          : null;
      await response.drain<void>();
      return _Probe(
        status: response.statusCode,
        length: length,
        finalUrl: current == uri ? null : current,
      );
    }
    return const _Probe(error: 'redirected too often');
  } on Object catch (error) {
    return _Probe(error: '$error');
  } finally {
    client.close(force: true);
  }
}

bool _isRedirect(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == 308;
