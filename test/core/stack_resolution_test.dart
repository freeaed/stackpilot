import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_preferences.dart';
import 'package:stackpilot/core/stack_resolution.dart';

void main() {
  late Directory temp;
  late String root;
  late String sibling;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_resolution_');
    root = p.join(temp.path, 'laragon');
    sibling = p.join(temp.path, 'laragon-wamp');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void createStack(String path) {
    File(p.join(path, 'usr', 'laragon.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    Directory(p.join(path, 'bin')).createSync(recursive: true);
  }

  test('an explicit requested root wins over saved preferences', () {
    createStack(root);
    createStack(sibling);

    final startup = resolveStartupStack(
      requestedRoot: root,
      preferences: AppPreferences(
        stacksFolder: temp.path,
        activeStack: sibling,
      ),
    );

    expect(startup.layout?.root, p.normalize(root));
    expect(startup.attemptedRoot, root);
  });

  test('uses the saved active stack', () {
    createStack(root);

    final startup = resolveStartupStack(
      preferences: AppPreferences(stacksFolder: temp.path, activeStack: root),
    );

    expect(startup.layout?.root, p.normalize(root));
  });

  test('falls back to the first stack in the stacks folder', () {
    createStack(sibling);

    final startup = resolveStartupStack(
      preferences: AppPreferences(stacksFolder: temp.path),
    );

    expect(startup.layout?.root, p.normalize(sibling));
  });

  test('skips a saved stack that no longer exists', () {
    createStack(sibling);

    final startup = resolveStartupStack(
      preferences: AppPreferences(
        stacksFolder: temp.path,
        activeStack: root,
      ),
    );

    expect(startup.layout?.root, p.normalize(sibling));
  });

  test('reports the last known location when nothing is found', () {
    final startup = resolveStartupStack(
      preferences: AppPreferences(activeStack: root),
      fallbackCandidates: const [],
    );

    expect(startup.layout, isNull);
    expect(startup.attemptedRoot, root);
  });

  test('reports a requested root that is not a stack', () {
    final startup = resolveStartupStack(requestedRoot: root);

    expect(startup.layout, isNull);
    expect(startup.attemptedRoot, root);
  });
}
