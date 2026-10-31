import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/hosts_file.dart';

void main() {
  late Directory temp;
  late String hostsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_hosts_file_');
    hostsPath = p.join(temp.path, 'hosts');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('finds hosts mapped anywhere in the file', () {
    final lines = [
      '127.0.0.1 localhost',
      '::1 localhost',
      '127.0.0.1 laragon.test #laragon magic!',
      '# 127.0.0.1 commented.test',
      '127.0.0.1 block.test',
    ];

    expect(hostsFileMaps(lines, 'laragon.test'), isTrue);
    expect(hostsFileMaps(lines, 'LARAGON.TEST'), isTrue);
    expect(hostsFileMaps(lines, 'commented.test'), isFalse);
    expect(hostsFileMaps(lines, 'block.test'), isTrue);
    expect(hostsFileMaps(lines, 'missing.test'), isFalse);
  });

  test('rewrites the managed block and keeps unrelated lines', () {
    final document = HostsDocument.parse([
      '127.0.0.1 localhost',
      '# keep this comment',
      '',
      HostsFile.blockStart,
      '127.0.0.1 old.test',
      HostsFile.blockEnd,
      '',
    ]).addHosts(['new.test', 'OLD.test']);

    final rendered = document.render();

    expect(rendered, contains('127.0.0.1 localhost'));
    expect(rendered, contains('# keep this comment'));
    expect(rendered, contains('127.0.0.1 old.test'));
    expect(rendered, contains('127.0.0.1 new.test'));
    expect(RegExp('old\\.test').allMatches(rendered), hasLength(1));
    expect(HostsDocument.parse(rendered.split('\r\n')).hosts, [
      'old.test',
      'new.test',
    ]);
  });

  test('adds missing hosts and stays idempotent', () async {
    File(hostsPath).writeAsStringSync('127.0.0.1 localhost\r\n');
    final hosts = HostsFile(hostsPath);

    final first = await hosts.add(['site.test', 'other.test']);
    final second = await hosts.add(['site.test']);

    expect(first.written, isTrue);
    expect(first.added, ['site.test', 'other.test']);
    expect(second.written, isTrue);
    expect(second.added, isEmpty);
    expect(second.changed, isFalse);

    final contents = File(hostsPath).readAsStringSync();
    expect(contents, contains('127.0.0.1 site.test'));
    expect(contents, contains('127.0.0.1 other.test'));
    expect(RegExp('site\\.test').allMatches(contents), hasLength(1));
  });

  test(
    'does not add a host that is already mapped outside the block',
    () async {
      File(hostsPath).writeAsStringSync(
        '127.0.0.1 localhost\r\n127.0.0.1 laragon.test #laragon magic!\r\n',
      );

      final result = await HostsFile(hostsPath).add(['laragon.test']);

      expect(result.written, isTrue);
      expect(result.added, isEmpty);
      expect(
        RegExp('laragon\\.test').allMatches(File(hostsPath).readAsStringSync()),
        hasLength(1),
      );
    },
  );

  test('reports an error when the hosts file cannot be written', () async {
    Directory(hostsPath).createSync();

    final result = await HostsFile(hostsPath)
        .add(['site.test'], allowElevation: false);

    expect(result.written, isFalse);
    expect(result.added, isEmpty);
    expect(result.error, isNotNull);
  });
}
