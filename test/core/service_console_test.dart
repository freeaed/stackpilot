import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/service_console.dart';
import 'package:stackpilot/core/stack_layout.dart';

void main() {
  late Directory temp;
  late ServiceConsole console;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_console_');
    console = ServiceConsole(temp.path);
  });

  tearDown(() async {
    await console.dispose();
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('writes a timestamped line and keeps it in the ring buffer', () {
    console.append(StackComponent.mailpit, 'listening on :8025');

    final file = ServiceConsole.fileFor(temp.path, StackComponent.mailpit);
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(
      RegExp(r'^\[\d{2}:\d{2}:\d{2}\] listening on :8025\r\n$').hasMatch(text),
      isTrue,
      reason: text,
    );
    expect(console.recentLines(StackComponent.mailpit).single, endsWith(
      'listening on :8025',
    ));
  });

  test('keeps only the newest ring buffer lines', () {
    final console = ServiceConsole(temp.path, ringLines: 3);
    addTearDown(console.dispose);
    for (var index = 0; index < 10; index++) {
      console.append(StackComponent.redis, 'line $index');
    }

    final lines = console.recentLines(StackComponent.redis, 10);
    expect(lines, hasLength(3));
    expect(lines.last, endsWith('line 9'));
  });

  test('rotates the console file at the size limit', () {
    final console = ServiceConsole(temp.path, maxBytes: 30);
    addTearDown(console.dispose);

    for (var index = 0; index < 8; index++) {
      console.append(StackComponent.apache, 'a long line $index');
    }

    final file = ServiceConsole.fileFor(temp.path, StackComponent.apache);
    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.1').existsSync(), isTrue);
    expect(file.lengthSync(), lessThan(120));
  });

  test('decodes stdout chunks that split a line', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    console.attach(StackComponent.apache, stdout: controller.stream);

    controller.add(utf8.encode('first line\nsec'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.add(utf8.encode('ond line\n'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final lines = console.recentLines(StackComponent.apache);
    expect(lines, hasLength(2));
    expect(lines.first, endsWith('first line'));
    expect(lines.last, endsWith('second line'));
  });

  test('detach stops capturing output', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    console.attach(StackComponent.nginx, stdout: controller.stream);
    await console.detach(StackComponent.nginx);

    controller.add(utf8.encode('ignored\n'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(console.recentLines(StackComponent.nginx), isEmpty);
  });

  test('console files live in the stack logs folder', () {
    final file = ServiceConsole.fileFor(
      temp.path,
      StackComponent.postgresql,
    );

    expect(file.path, p.join(temp.path, 'logs', 'postgresql-console.log'));
  });
}
