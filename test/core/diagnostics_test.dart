import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_info.dart';
import 'package:stackpilot/core/app_log.dart';
import 'package:stackpilot/core/app_preferences.dart';
import 'package:stackpilot/core/diagnostics.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late Directory logs;
  late Directory reports;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_diag_');
    logs = Directory(p.join(temp.path, 'logs'))..createSync(recursive: true);
    reports = Directory(p.join(temp.path, 'reports'));
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  Archive readBundle(DiagnosticsBundle bundle) {
    return ZipDecoder().decodeBytes(bundle.file.readAsBytesSync());
  }

  test('collects logs, build details, and stack metadata', () {
    File(p.join(logs.path, 'stackpilot.log'))
        .writeAsStringSync('[2026-10-01T00:00:00.000Z] INFO  hello\n');

    final bundle = Diagnostics.create(
      preferences: const AppPreferences(
        stacksFolder: r'D:\dev\stacks',
        updateChannel: ReleaseChannel.preview,
      ),
      layout: layout,
      outputDirectory: reports,
      logDirectory: logs,
      now: DateTime.utc(2026, 10, 23, 9, 30),
    );

    expect(bundle.file.existsSync(), isTrue);
    expect(bundle.file.path, endsWith('StackPilot-report-20261023093000.zip'));

    final archive = readBundle(bundle);
    final names = archive.files.map((file) => file.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'app.txt',
        'preferences.json',
        'stack.txt',
        'README.txt',
        'logs/stackpilot.log',
        'stack/${p.basename(layout.markerPath)}',
      ]),
    );
    expect(
      names.every(
        (name) =>
            name == 'app.txt' ||
            name == 'preferences.json' ||
            name == 'stack.txt' ||
            name == 'README.txt' ||
            name.startsWith('logs/') ||
            name.startsWith('stack/'),
      ),
      isTrue,
    );

    String text(String name) => String.fromCharCodes(
      archive.files.firstWhere((file) => file.name == name).content
          as List<int>,
    );

    expect(text('app.txt'), contains('StackPilot ${AppInfo.versionLabel}'));
    expect(text('app.txt'), contains('Channel: ${AppInfo.channel.id}'));
    expect(text('preferences.json'), contains(r'D:\\dev\\stacks'));
    expect(text('stack.txt'), contains('Root: ${layout.root}'));
    expect(text('README.txt'), contains('does not contain database data'));
    expect(text('logs/stackpilot.log'), contains('hello'));
  });

  test('does not copy project files or database data', () {
    File(p.join(layout.documentRoot, 'index.php'))
        .writeAsStringSync('<?php echo "secret";');
    File(p.join(layout.dataDirectory, 'notes.txt'))
        .writeAsStringSync('private');

    final bundle = Diagnostics.create(
      layout: layout,
      outputDirectory: reports,
      logDirectory: logs,
    );

    final archive = readBundle(bundle);
    expect(
      archive.files.any((file) => file.name.contains('index.php')),
      isFalse,
    );
    expect(
      archive.files.any((file) => file.name.contains('notes.txt')),
      isFalse,
    );
  });

  test('reports when no stack is open', () {
    final bundle = Diagnostics.create(
      outputDirectory: reports,
      logDirectory: logs,
    );

    final archive = readBundle(bundle);
    final stack = String.fromCharCodes(
      archive.files.firstWhere((file) => file.name == 'stack.txt').content
          as List<int>,
    );
    expect(stack, contains('No stack is open.'));
  });

  test('never overwrites an earlier bundle from the same second', () {
    final timestamp = DateTime.utc(2026, 10, 23, 9, 30);
    final first = Diagnostics.create(
      layout: layout,
      outputDirectory: reports,
      logDirectory: logs,
      now: timestamp,
    );
    final second = Diagnostics.create(
      layout: layout,
      outputDirectory: reports,
      logDirectory: logs,
      now: timestamp,
    );

    expect(second.file.path, isNot(first.file.path));
    expect(first.file.existsSync(), isTrue);
    expect(second.file.existsSync(), isTrue);
  });

  test('includes the log that is currently open', () {
    AppLog.initialize(directory: logs);
    addTearDown(AppLog.close);
    AppLog.info('a live entry');

    final bundle = Diagnostics.create(layout: layout, outputDirectory: reports);

    final archive = readBundle(bundle);
    final log = String.fromCharCodes(
      archive.files
              .firstWhere((file) => file.name == 'logs/stackpilot.log')
              .content
          as List<int>,
    );
    expect(log, contains('a live entry'));
  });

  test('includes rotated logs, not just the current file', () {
    File(p.join(logs.path, 'stackpilot.log'))
        .writeAsStringSync('current entry\n');
    File(p.join(logs.path, 'stackpilot.log.1'))
        .writeAsStringSync('crash entry\n');
    File(p.join(logs.path, 'unrelated.txt')).writeAsStringSync('ignored');

    final bundle = Diagnostics.create(
      layout: layout,
      outputDirectory: reports,
      logDirectory: logs,
    );

    final names = readBundle(bundle).files.map((file) => file.name).toSet();
    expect(names, contains('logs/stackpilot.log'));
    expect(names, contains('logs/stackpilot.log.1'));
    expect(names, isNot(contains('logs/unrelated.txt')));
  });

  test('skips a log folder that does not exist', () {
    final bundle = Diagnostics.create(
      outputDirectory: reports,
      logDirectory: Directory(p.join(temp.path, 'missing')),
    );

    expect(bundle.file.existsSync(), isTrue);
    expect(bundle.entries.where((name) => name.startsWith('logs/')), isEmpty);
  });
}
