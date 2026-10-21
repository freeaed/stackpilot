import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_catalog.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_catalog_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void createStack(String parent, String name) {
    final root = p.join(parent, name);
    File(p.join(root, 'usr', 'laragon.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    Directory(p.join(root, 'bin')).createSync(recursive: true);
  }

  test('finds stacks inside a folder and sorts them by name', () {
    createStack(temp.path, 'zeta');
    createStack(temp.path, 'alpha');
    Directory(p.join(temp.path, 'notes')).createSync(recursive: true);
    Directory(p.join(temp.path, 'half-stack', 'bin')).createSync(recursive: true);

    final stacks = StackCatalog.scan(temp.path);

    expect(stacks, [
      p.normalize(p.join(temp.path, 'alpha')),
      p.normalize(p.join(temp.path, 'zeta')),
    ]);
  });

  test('returns the folder itself when it is a stack root', () {
    createStack(temp.path, 'laragon');
    final root = p.join(temp.path, 'laragon');

    expect(StackCatalog.scan(root), [p.normalize(root)]);
  });

  test('returns an empty list for a missing folder', () {
    expect(StackCatalog.scan(p.join(temp.path, 'missing')), isEmpty);
  });

  test('ignores folders without a laragon.ini', () {
    Directory(p.join(temp.path, 'bin')).createSync(recursive: true);

    expect(StackCatalog.scan(temp.path), isEmpty);
  });
}
