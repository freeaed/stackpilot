import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/ini.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_editor_');
    root = temp.path;

    void createFile(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    createFile(r'bin\php\php-8.3.30-Win32-vs16-x64\php.exe');
    createFile(
      r'bin\php\php-8.3.30-Win32-vs16-x64\php.ini',
      '[PHP]\n'
          'memory_limit=128M\n'
          'upload_max_filesize=2M\n'
          'post_max_size=8M\n'
          'max_execution_time=30\n'
          'display_errors=On\n'
          'extension_dir = "C:/old/php-8.3.30/ext"\n',
    );
    createFile(r'bin\php\php-8.5.11-Win32-vs17-x64\php.exe');
    createFile(
      r'bin\php\php-8.5.11-Win32-vs17-x64\php.ini',
      '[PHP]\nmemory_limit=256M\nextension_dir = "ext"\n',
    );

    createFile(r'bin\php\php-7.4.33\php.exe');
    createFile(r'bin\php\php-7.4.33\php7apache2_4.dll');
    createFile(r'bin\php\php-7.4.33\libcrypto-1_1-x64.dll');
    createFile(r'bin\php\php-7.4.33\libssl-1_1-x64.dll');

    createFile(r'bin\mysql\mysql-8.4.3-winx64\bin\mysqld.exe');
    createFile(r'bin\mysql\mysql-9.1.0-winx64\bin\mysqld.exe');
    createFile(
      r'bin\mysql\mysql-8.4.3-winx64\my.ini',
      '[client]\nport=3306\n\n'
          '[mysqld]\nport= 3306\ndatadir="C:/laragon-wamp/data/mysql-8.4"\n',
    );

    createFile(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    createFile(r'bin\apache\httpd-2.4.66\conf\openssl.cnf');
    createFile(
      r'bin\apache\httpd-2.4.66\conf\httpd.conf',
      'ServerRoot "C:/stack/bin/apache/httpd-2.4.66"\n'
          'Listen 80\n'
          'DocumentRoot "$root\\www"\n'
          '<Directory "$root\\www">\n'
          '    AllowOverride All\n'
          '</Directory>\n',
    );

    createFile(
      r'etc\apache2\mod_php.conf',
      '# auto-generated\n'
          'LoadFile "$root/bin/php/php-8.3.30-Win32-vs16-x64/libcrypto-3-x64.dll"\n'
          'LoadFile "$root/bin/php/php-8.3.30-Win32-vs16-x64/libssl-3-x64.dll"\n'
          'LoadModule php_module "$root/bin/php/php-8.3.30-Win32-vs16-x64/php8apache2_4.dll"\n'
          'PHPIniDir "$root/bin/php/php-8.3.30-Win32-vs16-x64"\n',
    );
    createFile(r'etc\apache2\httpd-ssl.conf', 'Listen 443\n');
    createFile(
      r'etc\apache2\sites-enabled\00-default.conf',
      '<VirtualHost _default_:80>\n'
          '    <Directory "$root\\www">\n'
          '        AllowOverride All\n'
          '    </Directory>\n'
          '</VirtualHost>\n',
    );

    createFile(
      r'usr\laragon.ini',
      '[preferences]\n'
          'AutoVirtualHosts=-1\n'
          'DataDir=$root\\data\n'
          'DocumentRootList=$root\\www|\n'
          '\n'
          '[apache]\n'
          'Use=-1\n'
          'SSLEnabled=-1\n'
          'DocumentRoot=$root\\www\n'
          '\n'
          '[mysql]\n'
          'Use=-1\n'
          'Port=3306\n'
          '\n'
          '[nginx]\n'
          'Use=0\n'
          '\n'
          '[php]\n'
          'Version=php-8.3.30-Win32-vs16-x64\n'
          '\n'
          '[mailpit]\n'
          'Use=-1\n',
    );

    createFile(
      r'usr\profile\default.ini',
      '[php]\nVersion=php-8.3.30-Win32-vs16-x64\n'
          '\n[apache]\nVersion=httpd-2.4.66\n'
          '\n[mysql]\nVersion=mysql-8.4.3-winx64\n',
    );

    final path = [
      r'bin\mysql\mysql-8.4.3-winx64\bin',
      r'bin\php\php-8.3.30-Win32-vs16-x64',
      r'bin\apache\httpd-2.4.66\bin',
    ].map((entry) => p.join(root, entry)).join(';');

    createFile(
      r'bin\laragon\laragon.cmd',
      '@SET "LARAGON_ROOT=$root\\\\" && '
          'SET "OPENSSL_CONF=$root\\bin\\apache\\httpd-2.4.66\\conf\\openssl.cnf" && '
          'SET "PATH=$path;%PATH%;"',
    );

    Directory(p.join(root, 'www')).createSync(recursive: true);
    layout = StackLayout.detect(root)!;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('switching PHP updates every place Laragon reads the version', () async {
    final install = layout
        .installedVersions(StackComponent.php)
        .firstWhere((install) => install.version.contains('8.5'));

    StackEditor(layout).selectVersion(StackComponent.php, install);

    final profile = IniDocument.parse(
      File(p.join(root, 'usr', 'profile', 'default.ini')).readAsStringSync(),
    );
    expect(profile.value('php', 'Version'), install.version);

    final laragonIni = IniDocument.parse(
      File(p.join(root, 'usr', 'laragon.ini')).readAsStringSync(),
    );
    expect(laragonIni.value('php', 'Version'), install.version);

    final launcher = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
        .readAsStringSync();
    expect(launcher, contains(install.directory));
    expect(launcher, isNot(contains('php-8.3.30-Win32-vs16-x64')));

    final apachePhp = File(p.join(root, 'etc', 'apache2', 'mod_php.conf'))
        .readAsStringSync();
    final normalizedDirectory = install.directory.replaceAll('\\', '/');
    expect(apachePhp, contains('$normalizedDirectory/libcrypto-3-x64.dll'));
    expect(apachePhp, contains('$normalizedDirectory/php8apache2_4.dll'));
    expect(apachePhp, contains('PHPIniDir "$normalizedDirectory"'));

    final phpIni = File(p.join(install.directory, 'php.ini'))
        .readAsStringSync();
    expect(phpIni, contains('"$normalizedDirectory/ext"'));

    final updated = StackLayout.detect(root)!;
    expect(updated.activeVersion(StackComponent.php)?.version, install.version);

    expect(
      File(p.join(root, 'usr', 'profile', 'default.ini.stackpilot.bak'))
          .existsSync(),
      isTrue,
    );
  });

  test('switching Apache updates OPENSSL_CONF in the launcher', () {
    final install = layout.activeVersion(StackComponent.apache)!;

    StackEditor(layout).selectVersion(StackComponent.apache, install);

    final launcher = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
        .readAsStringSync();
    expect(
      launcher,
      contains(
        p.join(install.directory, 'conf', 'openssl.cnf').replaceAll('\\', '/'),
      ),
    );
    expect(launcher, contains(p.join(install.directory, 'bin')));
  });

  test('switching PHP picks the module libraries of that version', () {
    final install = layout
        .installedVersions(StackComponent.php)
        .firstWhere((install) => install.version.contains('7.4'));

    StackEditor(layout).selectVersion(StackComponent.php, install);

    final apachePhp = File(p.join(root, 'etc', 'apache2', 'mod_php.conf'))
        .readAsStringSync();
    final normalizedDirectory = install.directory.replaceAll('\\', '/');
    expect(apachePhp, contains('$normalizedDirectory/libcrypto-1_1-x64.dll'));
    expect(apachePhp, contains('$normalizedDirectory/libssl-1_1-x64.dll'));
    expect(apachePhp, contains('$normalizedDirectory/php7apache2_4.dll'));
    expect(apachePhp, isNot(contains('libcrypto-3-x64.dll')));
    expect(apachePhp, isNot(contains('php8apache2_4.dll')));
  });

  test('switching MySQL keeps the trailing bin folder on PATH', () {
    final install = layout
        .installedVersions(StackComponent.mysql)
        .firstWhere((install) => install.version.contains('9.1'));

    StackEditor(layout).selectVersion(StackComponent.mysql, install);

    final launcher = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
        .readAsStringSync();
    expect(launcher, contains(p.join(install.directory, 'bin')));
    expect(launcher, isNot(contains(r'mysql-8.4.3-winx64\bin')));

    final profile = IniDocument.parse(
      File(p.join(root, 'usr', 'profile', 'default.ini')).readAsStringSync(),
    );
    expect(profile.value('mysql', 'Version'), install.version);

    final copiedIni = File(p.join(install.directory, 'my.ini'));
    expect(copiedIni.existsSync(), isTrue);
    expect(copiedIni.readAsStringSync(), contains('port=3306'));
  });

  test('switching MySQL applies the configured port', () {
    final iniFile = File(p.join(root, 'usr', 'laragon.ini'));
    iniFile.writeAsStringSync(
      iniFile.readAsStringSync().replaceFirst('Port=3306', 'Port=3307'),
    );
    layout = StackLayout.detect(root)!;
    final install = layout
        .installedVersions(StackComponent.mysql)
        .firstWhere((install) => install.version.contains('9.1'));

    StackEditor(layout).selectVersion(StackComponent.mysql, install);

    final myIni = File(p.join(install.directory, 'my.ini')).readAsStringSync();
    expect(RegExp(r'port\s*=\s*3307').allMatches(myIni), hasLength(2));
  });

  test('applySettings writes ini, Apache, MySQL, and PHP settings', () async {
    final newDocumentRoot = p.join(root, 'www2');
    Directory(newDocumentRoot).createSync(recursive: true);
    final settings = StackSettings.load(layout).copyWith(
      documentRoot: newDocumentRoot,
      dataDirectory: p.join(root, 'data2'),
      mysqlPort: 3307,
      autoVirtualHosts: false,
      apacheSsl: false,
      enabledServices: {
        StackComponent.apache,
        StackComponent.mysql,
        StackComponent.redis,
      },
      php: StackSettings.load(layout).php.copyWith(
        memoryLimit: '1G',
        uploadMaxFilesize: '4G',
        postMaxSize: '4G',
        maxExecutionTime: '120',
        displayErrors: false,
      ),
    );

    StackEditor(layout).applySettings(settings);

    final ini = IniDocument.parse(
      File(p.join(root, 'usr', 'laragon.ini')).readAsStringSync(),
    );
    expect(ini.value('preferences', 'DataDir'), p.join(root, 'data2'));
    expect(ini.value('preferences', 'AutoVirtualHosts'), '0');
    expect(ini.value('preferences', 'DocumentRootList'), '$newDocumentRoot|');
    expect(ini.value('apache', 'DocumentRoot'), newDocumentRoot);
    expect(ini.value('apache', 'SSLEnabled'), '0');
    expect(ini.value('mysql', 'Port'), '3307');
    expect(ini.value('apache', 'Use'), '-1');
    expect(ini.value('mysql', 'Use'), '-1');
    expect(ini.value('redis', 'Use'), '-1');
    expect(ini.value('nginx', 'Use'), '0');
    expect(ini.value('mailpit', 'Use'), '0');

    final httpd = File(
      p.join(root, 'bin', 'apache', 'httpd-2.4.66', 'conf', 'httpd.conf'),
    ).readAsStringSync();
    expect(httpd, contains(newDocumentRoot));

    final defaultVhost = File(
      p.join(root, 'etc', 'apache2', 'sites-enabled', '00-default.conf'),
    ).readAsStringSync();
    expect(defaultVhost, contains(newDocumentRoot));

    final myIni = File(
      p.join(root, 'bin', 'mysql', 'mysql-8.4.3-winx64', 'my.ini'),
    ).readAsStringSync();
    expect(RegExp(r'port\s*=\s*3307').allMatches(myIni), hasLength(2));

    final phpIni = File(
      p.join(root, 'bin', 'php', 'php-8.3.30-Win32-vs16-x64', 'php.ini'),
    ).readAsStringSync();
    expect(phpIni, contains('memory_limit=1G'));
    expect(phpIni, contains('upload_max_filesize=4G'));
    expect(phpIni, contains('post_max_size=4G'));
    expect(phpIni, contains('max_execution_time=120'));
    expect(phpIni, contains('display_errors=Off'));
  });

  test('importFolder copies a version and prepares php.ini', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'php-8.4.26'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'php.exe')).writeAsStringSync('');
    File(p.join(source.path, 'php.ini-development'))
        .writeAsStringSync('[PHP]\nextension_dir = "ext"\n');

    final install = await StackEditor(layout)
        .importFolder(StackComponent.php, source.path);

    final expected = p.join(root, 'bin', 'php', 'php-8.4.26');
    expect(install.directory, expected);
    expect(File(p.join(expected, 'php.exe')).existsSync(), isTrue);
    final phpIni = File(p.join(expected, 'php.ini')).readAsStringSync();
    expect(phpIni, contains('"${expected.replaceAll('\\', '/')}/ext"'));

    final updated = StackLayout.detect(root)!;
    expect(
      updated
          .installedVersions(StackComponent.php)
          .map((install) => install.version),
      contains('php-8.4.26'),
    );
  });

  test('imported Apache is pointed at this stack and its includes', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'httpd-2.4.70'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'bin', 'httpd.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    File(p.join(source.path, 'conf', 'openssl.cnf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    for (final module in [
      'mod_rewrite.so',
      'mod_ssl.so',
      'mod_socache_shmcb.so',
      'mod_headers.so',
    ]) {
      File(p.join(source.path, 'modules', module))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }
    File(p.join(source.path, 'conf', 'httpd.conf')).writeAsStringSync(
      '# vendor config\n'
      'Define SRVROOT "c:/Apache24"\n'
      'ServerRoot "\${SRVROOT}"\n'
      'Listen 80\n'
      'DocumentRoot "c:/Apache24/htdocs"\n'
      '<Directory "c:/Apache24/htdocs">\n'
      '    AllowOverride None\n'
      '</Directory>\n'
      'ScriptAlias /cgi-bin/ "c:/Apache24/cgi-bin/"\n'
      '<Directory "c:/Apache24/cgi-bin">\n'
      '    AllowOverride None\n'
      '</Directory>\n'
      '#LoadModule rewrite_module modules/mod_rewrite.so\n'
      '#LoadModule ssl_module modules/mod_ssl.so\n'
      '#LoadModule socache_shmcb_module modules/mod_socache_shmcb.so\n'
      '#LoadModule headers_module modules/mod_headers.so\n'
      'IncludeOptional "C:/old-stack/etc/apache2/alias/*.conf"\n'
      'Include "C:/old-stack/etc/apache2/mod_php.conf"\n',
    );

    final install = await StackEditor(layout)
        .importFolder(StackComponent.apache, source.path);

    final httpd = File(p.join(install.directory, 'conf', 'httpd.conf'))
        .readAsStringSync();
    final installPath = install.directory.replaceAll('\\', '/');
    final documentRoot = p.join(root, 'www').replaceAll('\\', '/');
    final etcPath = p.join(root, 'etc', 'apache2').replaceAll('\\', '/');

    expect(httpd, contains('Define SRVROOT "$installPath"'));
    expect(httpd, contains('ServerRoot "$installPath"'));
    expect(httpd, contains('DocumentRoot "$documentRoot"'));
    expect(httpd, contains('<Directory "$documentRoot">'));
    expect(httpd, contains('ScriptAlias /cgi-bin/ "$installPath/cgi-bin/"'));
    expect(httpd, contains('<Directory "$installPath/cgi-bin">'));
    expect(httpd, isNot(contains('c:/Apache24')));
    expect(httpd, isNot(contains('C:/old-stack')));
    expect(httpd, contains('\nLoadModule rewrite_module '));
    expect(httpd, contains('\nLoadModule ssl_module '));
    expect(httpd, contains('\nLoadModule socache_shmcb_module '));
    expect(httpd, contains('IncludeOptional "$etcPath/alias/*.conf"'));
    expect(httpd, contains('IncludeOptional "$etcPath/sites-enabled/*.conf"'));
    expect(httpd, contains('Include "$etcPath/httpd-ssl.conf"'));
    expect(httpd, contains('Include "$etcPath/mod_php.conf"'));

    StackEditor(layout).selectVersion(StackComponent.apache, install);
    expect(
      File(p.join(install.directory, 'conf', 'httpd.conf')).readAsStringSync(),
      httpd,
    );
  });

  test(
    'imported PHP reuses the active php.ini and repairs its paths',
    () async {
      final source = Directory(p.join(temp.path, 'downloads', 'php-8.4.26'))
        ..createSync(recursive: true);
      File(p.join(source.path, 'php.exe')).writeAsStringSync('');
      File(p.join(source.path, 'php.ini-development'))
          .writeAsStringSync('[PHP]\n;extension_dir = "ext"\n');

      final install = await StackEditor(layout)
          .importFolder(StackComponent.php, source.path);

      final phpIni = File(p.join(install.directory, 'php.ini'))
          .readAsStringSync();
      final normalized = install.directory.replaceAll('\\', '/');
      final temporary = p.join(root, 'tmp').replaceAll('\\', '/');
      expect(phpIni, contains('memory_limit=128M'));
      expect(phpIni, contains('extension_dir = "$normalized/ext"'));
      expect(phpIni, contains('error_log="$temporary/php_errors.log"'));
      expect(phpIni, contains('session.save_path="$temporary"'));
    },
  );

  test('PHP fallback ini enables the extensions Laragon uses', () async {
    final active = layout.activeVersion(StackComponent.php)!;
    File(p.join(active.directory, 'php.ini')).deleteSync();

    final source = Directory(p.join(temp.path, 'downloads', 'php-8.4.26'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'php.exe')).writeAsStringSync('');
    for (final name in ['curl', 'gd', 'exif', 'ldap', 'mysqli']) {
      File(p.join(source.path, 'ext', 'php_$name.dll'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }
    File(p.join(source.path, 'php.ini-development')).writeAsStringSync(
      '[PHP]\n'
      ';extension_dir = "ext"\n'
      ';extension=curl\n'
      ';extension=gd\n'
      ';extension=exif      ; Must be after mbstring as it depends on it\n'
      ';extension=ldap\n'
      ';extension=mysqli\n',
    );

    final install = await StackEditor(layout)
        .importFolder(StackComponent.php, source.path);

    final phpIni = File(p.join(install.directory, 'php.ini'))
        .readAsStringSync();
    final normalized = install.directory.replaceAll('\\', '/');
    expect(phpIni, contains('\nextension=curl\n'));
    expect(phpIni, contains('\nextension=gd\n'));
    expect(phpIni, contains('\nextension=exif      ; Must be after mbstring'));
    expect(phpIni, contains('\nextension=mysqli\n'));
    expect(phpIni, contains('\n;extension=ldap\n'));
    expect(phpIni, contains('extension_dir = "$normalized/ext"'));
  });

  test('installArchive extracts a ZIP and registers the version', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'php-8.4.26'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'php.exe')).writeAsStringSync('');
    File(p.join(source.path, 'php.ini-development'))
        .writeAsStringSync('[PHP]\nextension_dir = "ext"\n');

    final archive = p.join(temp.path, 'php-8.4.26.zip');
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -LiteralPath '
          "'${source.path.replaceAll("'", "''")}' "
          "-DestinationPath '$archive' -Force",
    ]);
    expect(compress.exitCode, 0, reason: compress.stderr.toString());

    final install = await StackEditor(layout)
        .installArchive(StackComponent.php, archive);

    expect(install.version, 'php-8.4.26');
    expect(install.directory, p.join(root, 'bin', 'php', 'php-8.4.26'));
    expect(File(p.join(install.directory, 'php.exe')).existsSync(), isTrue);
    expect(File(p.join(install.directory, 'php.ini')).existsSync(), isTrue);
  });

  test('importFolder rejects folders that are not a version', () async {
    final source = Directory(p.join(temp.path, 'downloads', 'php-broken'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'readme.txt')).writeAsStringSync('nothing here');

    expect(
      StackEditor(layout).importFolder(StackComponent.php, source.path),
      throwsA(isA<StackEditException>()),
    );
  });

  test('importFolder refuses to overwrite an existing version', () async {
    final source = Directory(
      p.join(temp.path, 'downloads', 'php-8.3.30-Win32-vs16-x64'),
    )..createSync(recursive: true);
    File(p.join(source.path, 'php.exe')).writeAsStringSync('');

    expect(
      StackEditor(layout).importFolder(StackComponent.php, source.path),
      throwsA(isA<StackEditException>()),
    );
  });
}
