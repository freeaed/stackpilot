import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_settings.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late StackInstall apache;
  late String vendorConfig;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_apache_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));

    final directory = p.join(
      layout.root,
      'bin',
      'apache',
      'httpd-2.4.69-261002-Win64-VS18',
    );
    vendorConfig =
        'ServerRoot "C:/Apache24"\n'
        'Listen 80\n'
        'DocumentRoot "C:/Apache24/htdocs"\n';
    File(p.join(directory, 'bin', 'httpd.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(directory, 'conf', 'httpd.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync(vendorConfig);
    File(p.join(directory, 'conf', 'mime.types'))
      ..createSync(recursive: true)
      ..writeAsStringSync('text/html html\n');
    for (final module in [
      'mod_mpm_winnt.so',
      'mod_authn_core.so',
      'mod_authz_core.so',
      'mod_dir.so',
      'mod_mime.so',
      'mod_rewrite.so',
      'mod_socache_shmcb.so',
      'mod_ssl.so',
    ]) {
      File(p.join(directory, 'modules', module))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }

    layout = StackLayout.detect(layout.root)!;
    apache = layout.installedVersions(StackComponent.apache).single;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('writes a template and keeps the vendor config', () {
    final config = File(p.join(apache.directory, 'conf', 'httpd.conf'));

    StackEditor(layout).prepareApacheConfig(apache);

    final contents = config.readAsStringSync();
    final installPath = apache.directory.replaceAll('\\', '/');
    expect(
      contents,
      startsWith('# StackPilot Apache configuration - generated'),
    );
    expect(contents, contains('ServerRoot "$installPath"'));
    expect(contents, contains('Listen 80'));
    expect(contents, contains('ServerName localhost'));
    expect(
      contents,
      contains('LoadModule mpm_winnt_module "modules/mod_mpm_winnt.so"'),
    );
    expect(
      contents,
      contains('LoadModule rewrite_module "modules/mod_rewrite.so"'),
    );
    expect(contents, isNot(contains('mod_expires.so')));
    expect(contents, isNot(contains('mod_headers.so')));
    expect(
      contents,
      contains('DocumentRoot "${layout.documentRoot.replaceAll('\\', '/')}"'),
    );
    expect(contents, contains('AllowOverride All'));
    expect(contents, contains('Require all granted'));
    expect(contents, contains('ErrorLog "logs/error.log"'));
    expect(contents, contains('CustomLog "logs/access.log" combined'));
    expect(contents, contains('sites-enabled/*.conf'));
    expect(contents, contains('TypesConfig conf/mime.types'));
    expect(Directory(p.join(apache.directory, 'logs')).existsSync(), isTrue);

    final vendor = File('${config.path}.vendor');
    expect(vendor.existsSync(), isTrue);
    expect(vendor.readAsStringSync(), vendorConfig);
  });

  test('supports builds with a compiled-in MPM', () {
    File(
      p.join(apache.directory, 'modules', 'mod_mpm_winnt.so'),
    ).deleteSync();

    StackEditor(layout).prepareApacheConfig(apache);

    final contents = File(
      p.join(apache.directory, 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(contents, isNot(contains('LoadModule mpm_winnt_module')));
    expect(contents, contains('<IfModule mpm_winnt_module>'));
    expect(contents, contains('ThreadsPerChild 150'));
  });

  test('regenerates the document root and SSL from the stack marker', () {
    StackEditor(layout).selectVersion(StackComponent.apache, apache);

    final newRoot = p.join(layout.root, 'public');
    Directory(newRoot).createSync();
    File(p.join(layout.root, 'etc', 'ssl', 'stackpilot.crt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('certificate');
    File(p.join(layout.root, 'etc', 'ssl', 'stackpilot.key'))
      ..createSync(recursive: true)
      ..writeAsStringSync('key');

    final settings = StackSettings.load(
      StackLayout.detect(layout.root)!,
    ).copyWith(documentRoot: newRoot, apacheSsl: true);
    StackEditor(StackLayout.detect(layout.root)!).applySettings(settings);

    final contents = File(
      p.join(apache.directory, 'conf', 'httpd.conf'),
    ).readAsStringSync();
    final rootPath = newRoot.replaceAll('\\', '/');
    expect(contents, contains('DocumentRoot "$rootPath"'));
    expect(contents, contains('<Directory "$rootPath">'));
    expect(contents, contains('Listen 443'));
    expect(contents, contains('SSLEngine on'));
    expect(
      contents,
      contains(
        'SSLCertificateFile "${p.join(layout.root, 'etc', 'ssl', 'stackpilot.crt').replaceAll('\\', '/')}"',
      ),
    );
  });

  test('omits SSL when the certificate is missing', () {
    StackEditor(layout).selectVersion(StackComponent.apache, apache);
    final settings = StackSettings.load(
      StackLayout.detect(layout.root)!,
    ).copyWith(apacheSsl: true);
    StackEditor(StackLayout.detect(layout.root)!).applySettings(settings);

    final contents = File(
      p.join(apache.directory, 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(contents, isNot(contains('Listen 443')));
    expect(contents, isNot(contains('SSLEngine on')));
  });
}
