import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/stack_conflicts.dart';

void main() {
  test('finds a running Laragon process', () async {
    final conflicts = await findLaragonProcesses(
      run: (executable, arguments) async {
        expect(executable, 'powershell.exe');
        return ProcessResult(
          0,
          0,
          '[{"ProcessId": 7800, "Name": "laragon.exe", '
              '"ExecutablePath": "C:\\\\laragon\\\\Laragon.exe"}]',
          '',
        );
      },
    );

    expect(conflicts, hasLength(1));
    expect(conflicts.single.pid, 7800);
    expect(conflicts.single.name, 'laragon.exe');
    expect(conflicts.single.executablePath, r'C:\laragon\Laragon.exe');
  });

  test('accepts a single JSON object', () async {
    final conflicts = await findLaragonProcesses(
      run: (_, _) async => ProcessResult(
        0,
        0,
        '{"ProcessId": 7801, "Name": "laragon.exe", '
            '"ExecutablePath": "C:\\\\laragon\\\\Laragon.exe"}',
        '',
      ),
    );

    expect(conflicts.single.pid, 7801);
  });

  test('returns an empty list when Laragon is not running', () async {
    expect(
      await findLaragonProcesses(
        run: (_, _) async => ProcessResult(0, 0, '', ''),
      ),
      isEmpty,
    );
  });

  test('ignores malformed output', () async {
    expect(
      await findLaragonProcesses(
        run: (_, _) async => ProcessResult(0, 0, 'not json', ''),
      ),
      isEmpty,
    );
  });
}
