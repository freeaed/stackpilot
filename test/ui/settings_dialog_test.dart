import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_editor.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/ui/settings_dialog.dart';

void main() {
  late Directory temp;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_settings_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  Future<void> openDialog(WidgetTester tester, int tab) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showStackSettingsDialog(
                context,
                layout: layout,
                editor: StackEditor(layout),
                initialTabIndex: tab,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens directly on the updates tab', (tester) async {
    await openDialog(tester, 6);

    expect(find.text('Release channel'), findsOneWidget);
    expect(find.text('Check now'), findsOneWidget);
    expect(find.text('Check for updates on startup'), findsOneWidget);
  });

  testWidgets('opens directly on the diagnostics tab', (tester) async {
    await openDialog(tester, 7);

    expect(find.text('Create report bundle'), findsOneWidget);
    expect(find.text('Open logs'), findsOneWidget);
    expect(
      find.textContaining('does not contain database data'),
      findsOneWidget,
    );
  });
}
