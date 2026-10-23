import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_settings.dart';

/// Verifies the generated Apache template against a real Apache archive.
///
/// Usage: dart run tool/verify_apache_template.dart [--keep] [--ssl] `<Apache24>`
Future<void> main(List<String> args) async {
  final keep = args.contains('--keep');
  final ssl = args.contains('--ssl');
  final paths = args
      .where((arg) => arg != '--keep' && arg != '--ssl')
      .toList();
  if (paths.length != 1) {
    stderr.writeln('Pass the extracted Apache24 folder.');
    exitCode = 2;
    return;
  }

  final source = Directory(paths.single);
  if (!source.existsSync()) {
    stderr.writeln('Not found: ${source.path}');
    exitCode = 2;
    return;
  }

  final temp = Directory.systemTemp.createTempSync('stackpilot_verify_');
  try {
    final layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
    final target = p.join(
      layout.root,
      'bin',
      'apache',
      'httpd-2.4.69-261002-Win64-VS18',
    );
    await _copy(source, Directory(target));

    final detected = StackLayout.detect(layout.root)!;
    final apache = detected.installedVersions(StackComponent.apache).single;
    StackEditor(detected).selectVersion(StackComponent.apache, apache);

    if (ssl) {
      final sslDirectory = Directory(p.join(layout.root, 'etc', 'ssl'))
        ..createSync(recursive: true);
      final certificate = p.join(sslDirectory.path, 'stackpilot.crt');
      final key = p.join(sslDirectory.path, 'stackpilot.key');
      final openssl = p.join(apache.directory, 'bin', 'openssl.exe');
      final opensslConfig = p.join(apache.directory, 'conf', 'openssl.cnf');
      final generated = await Process.run(openssl, [
        'req',
        '-config',
        opensslConfig,
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        certificate,
        '-days',
        '1',
        '-subj',
        '/CN=localhost',
      ], workingDirectory: apache.directory);
      if (generated.exitCode != 0) {
        stderr.writeln(generated.stderr);
        exitCode = generated.exitCode;
        return;
      }
      final current = StackLayout.detect(layout.root)!;
      final settings = StackSettings.load(current).copyWith(apacheSsl: true);
      StackEditor(current).applySettings(settings);
    }

    final config = p.join(apache.directory, 'conf', 'httpd.conf');
    final httpd = p.join(apache.directory, 'bin', 'httpd.exe');
    final check = await Process.run(httpd, [
      '-t',
      '-f',
      config,
    ], workingDirectory: apache.directory);
    stdout.writeln('config: $config');
    stdout.writeln('root: ${layout.root}');
    stdout.writeln('exit: ${check.exitCode}');
    stdout.writeln(check.stdout);
    stderr.writeln(check.stderr);
    exitCode = check.exitCode;
  } finally {
    if (!keep && temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}

Future<void> _copy(Directory source, Directory target) async {
  target.createSync(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final destination = p.join(target.path, name);
    if (entity is Directory) {
      await _copy(entity, Directory(destination));
    } else if (entity is File) {
      await entity.copy(destination);
    }
  }
}
