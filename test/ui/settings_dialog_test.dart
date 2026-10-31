import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/app_preferences.dart';
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

  Future<void> openDialog(
    WidgetTester tester,
    int tab, {
    AppPreferencesStore? store,
  }) async {
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
                preferencesStore: store,
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

  testWidgets('saves the stacks folder to preferences.json', (tester) async {
    final file = File(p.join(temp.path, 'prefs', 'preferences.json'));
    final store = AppPreferencesStore(file: file);
    final stacks = Directory(p.join(temp.path, 'my_stacks'))..createSync();
    await openDialog(tester, 0, store: store);

    await tester.enterText(
      find.widgetWithText(TextField, 'Stacks folder'),
      p.join(stacks.path, 'nested'),
    );
    await tester.tap(find.text('Save settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(file.existsSync(), isTrue, reason: 'preferences were not saved');
    final loaded = AppPreferencesStore(file: file).load();
    expect(loaded.stacksFolder, p.join(stacks.path, 'nested'));
    expect(loaded.onboardingCompleted, isTrue);
  });

  testWidgets('saves the terminal choice', (tester) async {
    final file = File(p.join(temp.path, 'prefs-terminal', 'preferences.json'));
    final store = AppPreferencesStore(file: file);
    await openDialog(tester, 1, store: store);

    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows Terminal').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      AppPreferencesStore(file: file).load().terminalShell,
      'windowsTerminal',
    );
  });
}
