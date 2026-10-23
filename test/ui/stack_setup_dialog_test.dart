import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_provisioner.dart';
import 'package:stackpilot/ui/widgets/stack_setup_dialog.dart';

class _FakeProvisioner extends StackProvisioner {
  _FakeProvisioner(super.layout);

  int calls = 0;
  List<ComponentRelease> requested = const [];

  @override
  Future<ProvisionReport> installAll(
    Iterable<ComponentRelease> releases, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
  }) async {
    calls++;
    requested = releases.toList();
    final installed = <ProvisionedComponent>[];
    for (final release in requested) {
      onProgress?.call(
        ProvisionProgress(
          release: release,
          phase: ProvisionPhase.done,
          index: installed.length + 1,
          count: requested.length,
        ),
      );
      installed.add(
        ProvisionedComponent(
          release: release,
          install: StackInstall(
            component: release.component,
            version: release.installName,
            directory: p.join(
              layout.root,
              'bin',
              release.component.directoryName,
              release.installName,
            ),
            executablePath: '',
          ),
          activated: true,
          alreadyInstalled: false,
        ),
      );
    }
    return ProvisionReport(installed: installed, failures: const []);
  }
}

void main() {
  late Directory temp;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_setup_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  Future<void> openDialog(
    WidgetTester tester, {
    required StackProvisioner Function(StackLayout) factory,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showStackSetupDialog(
                context,
                layout: layout,
                provisionerFactory: factory,
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

  testWidgets('lists the starter stack and installs the selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = _FakeProvisioner(layout);
    await openDialog(tester, factory: (_) => fake);

    expect(find.text('Set up this stack'), findsOneWidget);
    expect(find.text('PHP 8.5.12'), findsOneWidget);
    expect(find.text('Apache 2.4.69'), findsOneWidget);
    expect(find.text('MariaDB 11.4.13'), findsOneWidget);
    expect(find.text('Mailpit 1.32.0'), findsOneWidget);
    expect(find.text('Recommended'), findsWidgets);
    expect(find.text('Install 4 components'), findsOneWidget);

    await tester.tap(find.text('Install 4 components'));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    expect(
      fake.requested.map((release) => release.component),
      containsAll([
        StackComponent.php,
        StackComponent.apache,
        StackComponent.mysql,
        StackComponent.mailpit,
      ]),
    );
    expect(find.textContaining('Installed 4 components'), findsOneWidget);
    expect(find.text('Install 4 components'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('Set up this stack'), findsNothing);
  });

  testWidgets('marks installed components and keeps them unchecked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final php = ComponentCatalog.php;
    File(
      p.join(
        layout.root,
        'bin',
        php.component.directoryName,
        php.installName,
        'php.exe',
      ),
    ).createSync(recursive: true);
    layout = StackLayout.detect(layout.root)!;

    await openDialog(tester, factory: (_) => _FakeProvisioner(layout));

    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Install 3 components'), findsOneWidget);

    final tile = find.ancestor(
      of: find.text('PHP 8.5.12'),
      matching: find.byType(CheckboxListTile),
    );
    expect(tester.widget<CheckboxListTile>(tile).onChanged, isNull);
  });

  testWidgets('clearing the selection disables the install button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openDialog(tester, factory: (_) => _FakeProvisioner(layout));

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();

    final install = find.widgetWithText(FilledButton, 'Install');
    expect(install, findsOneWidget);
    expect(tester.widget<FilledButton>(install).onPressed, isNull);
  });

  testWidgets('shows a failure without hiding successful installs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = _FailingProvisioner(layout);
    await openDialog(tester, factory: (_) => fake);

    await tester.tap(find.text('Install 4 components'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Installed 1 component'), findsOneWidget);
    expect(find.textContaining('Mailpit 1.32.0'), findsWidgets);
    expect(find.textContaining('mail server is unavailable'), findsOneWidget);
  });
}

class _FailingProvisioner extends StackProvisioner {
  _FailingProvisioner(super.layout);

  @override
  Future<ProvisionReport> installAll(
    Iterable<ComponentRelease> releases, {
    void Function(ProvisionProgress)? onProgress,
    bool activate = true,
  }) async {
    final list = releases.toList();
    return ProvisionReport(
      installed: [
        ProvisionedComponent(
          release: list.first,
          install: StackInstall(
            component: list.first.component,
            version: list.first.installName,
            directory: p.join(
              layout.root,
              'bin',
              list.first.component.directoryName,
              list.first.installName,
            ),
            executablePath: '',
          ),
          activated: true,
          alreadyInstalled: false,
        ),
      ],
      failures: [
        ProvisionFailure(
          list.last,
          '${list.last.label}: the mail server is unavailable',
        ),
      ],
    );
  }
}
