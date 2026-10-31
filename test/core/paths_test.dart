import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/paths.dart';

void main() {
  test('keeps a capital S in a folder name', () {
    const path = r'D:\StackPilot_stacks\www';

    expect(normalizeWindowsPath(path), path);
    expect(normalizeWindowsPath('  $path  '), path);
    expect(normalizeWindowsPath('"$path"'), path);
  });

  test('keeps the capital S when the value was written with slashes', () {
    expect(
      normalizeWindowsPath('D:/StackPilot_stacks/www'),
      r'D:\StackPilot_stacks\www',
    );
  });

  test('drops trailing separators but keeps a drive root', () {
    expect(normalizeWindowsPath(r'D:\dev\stacks\'), r'D:\dev\stacks');
    expect(normalizeWindowsPath(r'C:\'), r'C:\');
  });

  test('resolves dot segments without touching names', () {
    expect(
      normalizeWindowsPath(r'D:\dev\stacks\..\other\.\www'),
      r'D:\dev\other\www',
    );
  });

  test('leaves an empty value empty', () {
    expect(normalizeWindowsPath('   '), '');
    expect(normalizeWindowsPath('""'), '');
  });

  test('compares Windows paths without case or separator differences', () {
    expect(
      sameWindowsPath(r'D:\StackPilot_stacks\www', 'D:/stackpilot_STACKS/www'),
      isTrue,
    );
    expect(sameWindowsPath(r'D:\a', r'D:\b'), isFalse);
  });

  test('recognises a path inside another one', () {
    expect(
      isWithinWindowsPath(r'D:\StackPilot_stacks', r'D:\StackPilot_stacks\www'),
      isTrue,
    );
    expect(
      isWithinWindowsPath(r'D:\StackPilot_stacks', r'D:\StackPilot_stacks2'),
      isFalse,
    );
  });
}
