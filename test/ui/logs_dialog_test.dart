import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/ui/logs_dialog.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_logs_dialog_');
    root = temp.path;

    void file(String relativePath, [String contents = '']) {
      File(p.join(root, relativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    file(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    file(r'usr\laragon.ini', '[preferences]\nDataDir=$root\\data\n');
    file('usr/profile/default.ini', '[apache]\nVersion=httpd-2.4.66\n');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  Widget harness(StackLayout layout) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showServiceLogsDialog(context, layout: layout),
              child: const Text('Open logs'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester, StackLayout layout) async {
    await tester.pumpWidget(harness(layout));
    await tester.tap(find.text('Open logs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> closeDialog(WidgetTester tester) async {
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows the newest lines of the active service log', (
    tester,
  ) async {
    File(
      p.join(root, r'bin\apache\httpd-2.4.66\logs\error.log'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('[mpm] Apache started\n[core] ready\n');

    await openDialog(tester, StackLayout.detect(root)!);

    expect(find.text('Service logs'), findsOneWidget);
    expect(find.text('error.log'), findsNWidgets(2));

    final viewer = tester.widget<SelectableText>(
      find.byKey(const ValueKey('service-log-text')),
    );
    expect(viewer.data, contains('Apache started'));
    expect(viewer.data, contains('[core] ready'));

    await closeDialog(tester);
    expect(find.text('Service logs'), findsNothing);
  });

  testWidgets('explains when a service has not written a log yet', (
    tester,
  ) async {
    await openDialog(tester, StackLayout.detect(root)!);

    expect(find.text('No service logs found yet'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);

    await closeDialog(tester);
    expect(find.text('No service logs found yet'), findsNothing);
  });
}
