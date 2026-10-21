import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_preferences.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_prefs_');
    file = File(p.join(temp.path, 'settings', 'preferences.json'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  test('returns empty preferences when the file does not exist', () {
    final store = AppPreferencesStore(file: file);

    final preferences = store.load();

    expect(preferences.stacksFolder, isNull);
    expect(preferences.activeStack, isNull);
  });

  test('saves and loads the stacks folder and active stack', () async {
    final store = AppPreferencesStore(file: file);
    final preferences = AppPreferences(
      stacksFolder: r'D:\dev\stacks',
      activeStack: r'D:\dev\stacks\laragon',
    );

    await store.save(preferences);

    expect(file.existsSync(), isTrue);
    final loaded = AppPreferencesStore(file: file).load();
    expect(loaded.stacksFolder, p.normalize(r'D:\dev\stacks'));
    expect(loaded.activeStack, p.normalize(r'D:\dev\stacks\laragon'));
  });

  test('treats malformed json as empty preferences', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{ not json');

    final preferences = AppPreferencesStore(file: file).load();

    expect(preferences.stacksFolder, isNull);
    expect(preferences.activeStack, isNull);
  });

  test('treats json that is not an object as empty preferences', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('["C:/laragon"]');

    final preferences = AppPreferencesStore(file: file).load();

    expect(preferences.stacksFolder, isNull);
    expect(preferences.activeStack, isNull);
  });

  test('ignores blank and non-string paths', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{"stacksFolder": "  ", "activeStack": 42}');

    final preferences = AppPreferencesStore(file: file).load();

    expect(preferences.stacksFolder, isNull);
    expect(preferences.activeStack, isNull);
  });

  test('copyWith keeps values that are not replaced', () {
    const preferences = AppPreferences(
      stacksFolder: r'C:\',
      activeStack: r'C:\laragon',
    );

    final updated = preferences.copyWith(activeStack: r'C:\laragon-wamp');

    expect(updated.stacksFolder, r'C:\');
    expect(updated.activeStack, r'C:\laragon-wamp');
  });
}
