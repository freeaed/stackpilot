// Exports the compiled-in component and app catalog as a signed-manifest
// source file.
//
//   dart run tool/export_catalog.dart
//   dart run tool/export_catalog.dart --output build/components.json
//
// Sign and publish the result, then build the app with
// --dart-define=STACKPILOT_COMPONENT_CATALOG_URL=<url> and the usual update
// public key:
//
//   dart run tool/update_keys.dart sign build/components.json
//
// The app fetches `components.json`, verifies `components.json.sig` with the
// update key, and falls back to its built-in catalog when the fetch fails.

import 'dart:convert';
import 'dart:io';

import 'package:stackpilot/core/catalog_export.dart';

Future<void> main(List<String> args) async {
  var output = 'build/components.json';
  for (var index = 0; index < args.length; index++) {
    if (args[index] == '--output' && index + 1 < args.length) {
      output = args[++index];
    } else if (args[index] == '--help' || args[index] == '-h') {
      stdout.writeln(
        'Usage: dart run tool/export_catalog.dart [--output <path>]',
      );
      return;
    } else {
      stderr.writeln('Unknown argument: ${args[index]}');
      exitCode = 2;
      return;
    }
  }

  final manifest = buildCatalogManifest();

  final file = File(output);
  file.parent.createSync(recursive: true);
  // Write exact bytes: the detached signature covers this file, so no
  // trailing conversion is allowed.
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );

  stdout.writeln('Wrote ${file.path}');
  stdout.writeln('Sign it with:');
  stdout.writeln('  dart run tool/update_keys.dart sign ${file.path}');
}
