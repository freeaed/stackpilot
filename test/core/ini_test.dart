import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/ini.dart';

void main() {
  group('IniDocument', () {
    const source = r'''
; leading comment
# another comment

[preferences]
FirstRun=0
AutoVirtualHosts=-1
DocumentRootList=C:\laragon-wamp\www|

[apache]
Use=-1
SSLEnabled=-1

[mysql]
Port=3306
''';

    test('parses sections and values case-insensitively', () {
      final ini = IniDocument.parse(source);

      expect(ini.value('preferences', 'FirstRun'), '0');
      expect(ini.value('PREFERENCES', 'firstrun'), '0');
      expect(ini.value('apache', 'Use'), '-1');
      expect(ini.value('mysql', 'Port'), '3306');
      expect(ini.value('redis', 'Use'), isNull);
    });

    test('keeps Windows paths intact', () {
      final ini = IniDocument.parse(source);

      expect(
        ini.value('preferences', 'DocumentRootList'),
        r'C:\laragon-wamp\www|',
      );
    });

    test('keeps empty values and the last duplicate key', () {
      final ini = IniDocument.parse('''
[preferences]
Blank=
Key=first
Key=second
''');

      expect(ini.value('preferences', 'Blank'), '');
      expect(ini.value('preferences', 'Key'), 'second');
    });

    test('ignores malformed lines without failing', () {
      final ini = IniDocument.parse('''
not-a-section
=no-key
[services]
apache = enabled
''');

      expect(ini.value('services', 'apache'), 'enabled');
      expect(ini.value('services', 'no-key'), isNull);
    });

    test('serializes to a re-parsable document', () {
      final ini = IniDocument.parse(source);
      final reparsed = IniDocument.parse(ini.serialize());

      expect(reparsed.value('preferences', 'FirstRun'), '0');
      expect(
        reparsed.value('preferences', 'DocumentRootList'),
        r'C:\laragon-wamp\www|',
      );
      expect(reparsed.value('apache', 'SSLEnabled'), '-1');
    });
  });

  group('IniEditor', () {
    test('changes one value and keeps comments and formatting', () {
      const original =
          '; keep this comment\r\n'
          '[php]\r\n'
          'Version=php-8.3.30\r\n'
          '; another comment\r\n'
          'Use=-1\r\n';

      final updated = IniEditor.parse(original)
        ..setValue('PHP', 'Version', 'php-8.5.11');

      expect(
        updated.serialize(),
        '; keep this comment\r\n'
        '[php]\r\n'
        'Version=php-8.5.11\r\n'
        '; another comment\r\n'
        'Use=-1\r\n',
      );
    });

    test('creates a missing section at the end', () {
      final updated = IniEditor.parse('[apache]\nUse=-1\n')
        ..setValue('redis', 'Use', '-1');

      expect(updated.serialize(), '[apache]\nUse=-1\n\n[redis]\nUse=-1\n');
    });

    test('inserts a missing key into an existing section', () {
      final updated = IniEditor.parse('[mysql]\nPort=3306\n')
        ..setValue('mysql', 'Use', '-1');

      expect(updated.serialize(), '[mysql]\nPort=3306\nUse=-1\n');
    });
  });

  group('setIniDirective', () {
    test('replaces a directive and preserves comments', () {
      const source = '; comment\nmemory_limit = 128M\nmax_execution_time=30\n';

      final updated = setIniDirective(source, 'memory_limit', '1G');

      expect(updated, '; comment\nmemory_limit = 1G\nmax_execution_time=30\n');
    });

    test('replaces every occurrence when asked', () {
      const source = '[client]\nport=3306\n[mysqld]\nport = 3306\n';

      final updated = setIniDirective(source, 'port', '3307', all: true);

      expect(updated, '[client]\nport=3307\n[mysqld]\nport = 3307\n');
    });

    test('appends a missing directive without a comment-only match', () {
      final updated = setIniDirective(
        ';extension_dir = "ext"\n',
        'extension_dir',
        '"C:/php/ext"',
      );

      expect(updated, ';extension_dir = "ext"\nextension_dir="C:/php/ext"\n');
    });
  });
}
