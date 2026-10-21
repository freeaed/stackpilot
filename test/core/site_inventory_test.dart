import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/site_inventory.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;
  late String hostsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_sites_');
    root = temp.path;
    hostsPath = p.join(root, 'hosts');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void createFile(String relativePath, [String contents = '']) {
    File(p.join(root, relativePath))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void createStack({bool ssl = true}) {
    Directory(p.join(root, 'bin')).createSync();
    createFile(r'usr\laragon.ini', '''
[apache]
Use=-1
SSLEnabled=-1
DocumentRoot=$root\\www
''');
    createFile(r'www\blog\public\index.php');
    createFile(r'www\shop\index.html');
    if (ssl) {
      createFile(r'etc\ssl\laragon.crt');
      createFile(r'etc\ssl\laragon.key');
    }
  }

  test('discovers projects, document roots, configs, and hosts entries', () {
    createStack();
    File(hostsPath).writeAsStringSync('''
127.0.0.1 blog.test #laragon magic!
# 127.0.0.1 shop.test
''');

    final inventory = SiteInventory.load(
      StackLayout.detect(root)!,
      hostsPath: hostsPath,
    );

    expect(inventory.sites.map((site) => site.name), ['blog', 'shop']);
    final blog = inventory.sites.first;
    final shop = inventory.sites.last;
    expect(blog.documentRoot, p.join(root, 'www', 'blog', 'public'));
    expect(shop.documentRoot, p.join(root, 'www', 'shop'));
    expect(blog.host, 'blog.test');
    expect(blog.hostsMapped, isTrue);
    expect(shop.hostsMapped, isFalse);
    expect(inventory.missingConfigs, hasLength(2));
  });

  test('generates missing vhosts once and leaves existing files alone', () {
    createStack();
    File(hostsPath).writeAsStringSync('');
    final layout = StackLayout.detect(root)!;
    final inventory = SiteInventory.load(layout, hostsPath: hostsPath);

    final result = inventory.generateMissing();
    final second = SiteInventory.load(
      layout,
      hostsPath: hostsPath,
    ).generateMissing();

    expect(result.created, hasLength(2));
    expect(second.created, isEmpty);
    final normalizedRoot = root.replaceAll('\\', '/');
    final blogConfig = File(
      p.join(root, 'etc', 'apache2', 'sites-enabled', 'auto.blog.test.conf'),
    ).readAsStringSync();
    expect(
      blogConfig,
      contains('define ROOT "$normalizedRoot/www/blog/public"'),
    );
    expect(blogConfig, contains('<VirtualHost *:443>'));
    expect(blogConfig, contains('laragon.crt'));
  });

  test('omits SSL when certificates are missing', () {
    createStack(ssl: false);
    File(hostsPath).writeAsStringSync('');
    final inventory = SiteInventory.load(
      StackLayout.detect(root)!,
      hostsPath: hostsPath,
    );

    inventory.generateMissing();

    final config = File(
      p.join(root, 'etc', 'apache2', 'sites-enabled', 'auto.blog.test.conf'),
    ).readAsStringSync();
    expect(config, isNot(contains('<VirtualHost *:443>')));
  });

  test('reads an existing config and detects an outdated root', () {
    createStack();
    createFile(r'etc\apache2\sites-enabled\auto.blog.test.conf', '''
define ROOT "C:/old/blog/public"
define SITE "blog.test"
<VirtualHost *:80>
</VirtualHost>
''');
    File(hostsPath).writeAsStringSync('');

    final inventory = SiteInventory.load(
      StackLayout.detect(root)!,
      hostsPath: hostsPath,
    );
    final blog = inventory.sites.first;

    expect(blog.configPresent, isTrue);
    expect(blog.configDocumentRoot, 'C:/old/blog/public');
    expect(blog.configOutdated, isTrue);
    expect(blog.sslEnabled, isFalse);
    expect(inventory.missingConfigs.map((site) => site.name), ['shop']);
  });
}
