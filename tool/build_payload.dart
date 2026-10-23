// Builds the optional offline payload from the component catalog.
//
//   dart run tool/build_payload.dart
//   dart run tool/build_payload.dart --output D:\payload --only php,apache
//
// Every archive is downloaded from the catalog URL, checked against the
// catalog SHA-256, and indexed in payload.json. The installer ships this
// folder next to stackpilot.exe; the setup wizard then installs those archives
// instead of downloading them. The catalog checksum is verified again at
// install time, so a stale or tampered payload is ignored rather than trusted.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/component_catalog.dart';

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    _printUsage();
    exitCode = 2;
    return;
  }
  if (options.help) {
    _printUsage();
    return;
  }

  final releases = ComponentCatalog.releases.where(options.includes).toList();
  if (releases.isEmpty) {
    stderr.writeln('No catalog releases match --only.');
    exitCode = 2;
    return;
  }

  final output = Directory(options.output);
  output.createSync(recursive: true);

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final components = <Map<String, Object?>>[];
  final failures = <String>[];
  final usedNames = <String>{};

  try {
    for (var index = 0; index < releases.length; index++) {
      final release = releases[index];
      final position = '[${index + 1}/${releases.length}]';
      final fileName = _uniqueFileName(release, usedNames);
      final file = File(p.join(output.path, fileName));

      stdout.writeln('$position ${release.label}');
      if (options.keep && file.existsSync() && await _matches(file, release)) {
        stdout.writeln('  reusing ${file.path}');
      } else {
        try {
          await _download(client, Uri.parse(release.url), file, release);
        } on Object catch (error) {
          failures.add('${release.label}: $error');
          stderr.writeln('  failed: $error');
          continue;
        }
        if (!await _matches(file, release)) {
          try {
            file.deleteSync();
          } on FileSystemException {
            // Ignore.
          }
          const message =
              'the archive did not match the catalog SHA-256 and was deleted';
          failures.add('${release.label}: $message');
          stderr.writeln('  failed: $message');
          continue;
        }
      }

      components.add({
        'id': release.id,
        'file': fileName,
        'sha256': release.sha256,
        'size': file.lengthSync(),
      });
    }
  } finally {
    client.close(force: true);
  }

  final manifest = File(p.join(output.path, 'payload.json'));
  manifest.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'schema': 1, 'generated': DateTime.now().toUtc().toIso8601String(), 'components': components})}\n',
    flush: true,
  );

  final totalBytes = components.fold<int>(
    0,
    (sum, component) => sum + (component['size'] as int),
  );
  stdout.writeln(
    'Payload ready: ${manifest.path} '
    '(${components.length} components, ${_megabytes(totalBytes)} MB)',
  );

  if (failures.isNotEmpty) {
    stderr.writeln('');
    stderr.writeln('${failures.length} component(s) could not be bundled:');
    for (final failure in failures) {
      stderr.writeln('  - $failure');
    }
    exitCode = 1;
  }
}

class _Options {
  _Options({
    required this.output,
    required this.only,
    required this.keep,
    required this.help,
  });

  final String output;
  final Set<String> only;
  final bool keep;
  final bool help;

  factory _Options.parse(List<String> args) {
    var output = p.join('build', 'payload');
    var keep = false;
    var help = false;
    final only = <String>{};

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      switch (arg) {
        case '--help' || '-h':
          help = true;
        case '--keep':
          keep = true;
        case '--output':
          index++;
          if (index >= args.length) {
            throw ArgumentError('--output needs a folder.');
          }
          output = args[index];
        case '--only':
          index++;
          if (index >= args.length) {
            throw ArgumentError('--only needs a comma-separated list.');
          }
          only.addAll(
            args[index]
                .split(',')
                .map((value) => value.trim().toLowerCase())
                .where((value) => value.isNotEmpty),
          );
        default:
          throw ArgumentError('Unknown option: $arg');
      }
    }

    return _Options(output: output, only: only, keep: keep, help: help);
  }

  bool includes(ComponentRelease release) {
    if (only.isEmpty) {
      return true;
    }
    return only.contains(release.id.toLowerCase()) ||
        only.contains(release.component.directoryName.toLowerCase());
  }
}

void _printUsage() {
  stdout.writeln('''
Build the optional StackPilot offline payload.

Usage: dart run tool/build_payload.dart [options]

Options:
  --output <dir>   Destination folder (default: build/payload).
  --only <list>    Comma-separated component names or release ids.
                   Example: --only php,apache,mysql-11.4.13
  --keep           Reuse archives that already match the catalog checksum.
  -h, --help       Show this message.
''');
}

Future<void> _download(
  HttpClient client,
  Uri uri,
  File destination,
  ComponentRelease release,
) async {
  if (uri.scheme != 'https') {
    throw StateError('catalog URL is not HTTPS');
  }

  final request = await client.getUrl(uri);
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'StackPilot payload builder',
  );
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    throw HttpException(
      'the server returned HTTP ${response.statusCode}',
      uri: uri,
    );
  }

  final partial = File('${destination.path}.part');
  if (partial.existsSync()) {
    partial.deleteSync();
  }

  final total = response.contentLength > 0 ? response.contentLength : null;
  final sink = partial.openWrite();
  var received = 0;
  var lastPercent = -10;
  try {
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      final percent = total == null ? null : (received * 100 ~/ total);
      if (percent != null && percent >= lastPercent + 10) {
        lastPercent = percent;
        stdout.writeln('  $percent%');
      }
    }
    await sink.flush();
  } finally {
    await sink.close();
  }

  if (destination.existsSync()) {
    destination.deleteSync();
  }
  partial.renameSync(destination.path);
  stdout.writeln(
    '  downloaded ${_megabytes(received)} MB '
    'in ${p.basename(destination.path)}',
  );
}

Future<bool> _matches(File file, ComponentRelease release) async {
  if (!file.existsSync()) {
    return false;
  }
  final size = release.sizeBytes;
  if (size != null && file.lengthSync() != size) {
    return false;
  }
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString().toLowerCase() == release.sha256.toLowerCase();
}

String _uniqueFileName(ComponentRelease release, Set<String> used) {
  final fromUrl = p.basename(Uri.parse(release.url).path);
  var name = fromUrl.isEmpty ? '${release.id}.zip' : fromUrl;
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (name.startsWith('.')) {
    name = 'archive$name';
  }
  if (used.add(name)) {
    return name;
  }

  final extension = p.extension(name);
  final stem = p.basenameWithoutExtension(name);
  var candidate = '${stem}_${release.id}$extension';
  var suffix = 2;
  while (!used.add(candidate)) {
    candidate = '${stem}_${release.id}_$suffix$extension';
    suffix++;
  }
  return candidate;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
