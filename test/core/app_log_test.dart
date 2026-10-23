import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_log.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_log_');
  });

  tearDown(() {
    AppLog.close();
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('writes each entry with a timestamp and a level', () {
    AppLog.initialize(directory: temp);
    AppLog.info('starting up');
    AppLog.warn('a warning');
    AppLog.error('something broke', error: StateError('boom'));

    final contents = File(p.join(temp.path, 'stackpilot.log'))
        .readAsStringSync();

    expect(contents, contains('INFO  starting up'));
    expect(contents, contains('WARN  a warning'));
    expect(contents, contains('ERROR something broke'));
    expect(contents, contains('error: Bad state: boom'));
    expect(contents, matches(RegExp(r'\[\d{4}-\d{2}-\d{2}T')));
  });

  test('is a no-op before initialization', () {
    AppLog.info('nobody is listening');
    expect(AppLog.directoryPath, isNull);
    expect(AppLog.currentFile, isNull);
  });

  test('flushes every entry so it survives a crash', () {
    final log = AppLog.initialize(directory: temp);
    AppLog.info('written before a crash');

    // Read through a second handle while the log is still open.
    final contents = log!.file.readAsStringSync();
    expect(contents, contains('written before a crash'));
  });

  test('rotates a log that grew past its limit and keeps old files', () {
    AppLog.initialize(directory: temp, maxBytes: 64, keepFiles: 2);
    AppLog.info('x' * 200);
    AppLog.close();

    AppLog.initialize(directory: temp, maxBytes: 64, keepFiles: 2);
    expect(File(p.join(temp.path, 'stackpilot.log.1')).existsSync(), isTrue);
    expect(File(p.join(temp.path, 'stackpilot.log.2')).existsSync(), isFalse);

    AppLog.info('y' * 200);
    AppLog.close();

    AppLog.initialize(directory: temp, maxBytes: 64, keepFiles: 2);
    expect(File(p.join(temp.path, 'stackpilot.log.1')).existsSync(), isTrue);
    expect(File(p.join(temp.path, 'stackpilot.log.2')).existsSync(), isTrue);
    expect(File(p.join(temp.path, 'stackpilot.log.3')).existsSync(), isFalse);

    // The oldest entry has been dropped by now.
    final oldest = File(p.join(temp.path, 'stackpilot.log.2'))
        .readAsStringSync();
    expect(oldest, contains('x' * 200));
  });

  test('rotates while the log is still open', () {
    AppLog.initialize(directory: temp, maxBytes: 64, keepFiles: 3);
    AppLog.info('first entry ${'a' * 100}');
    AppLog.info('second entry');

    final current = File(p.join(temp.path, 'stackpilot.log'))
        .readAsStringSync();
    final rotated = File(p.join(temp.path, 'stackpilot.log.1'))
        .readAsStringSync();

    expect(rotated, contains('first entry'));
    expect(current, contains('second entry'));
    expect(current, isNot(contains('first entry')));
  });

  test('never throws when the log folder cannot be created', () {
    final blocker = File(p.join(temp.path, 'blocker'))..writeAsStringSync('x');

    final log = AppLog.initialize(directory: Directory(blocker.path));

    expect(log, isNull);
    expect(() => AppLog.info('still safe'), returnsNormally);
  });
}
