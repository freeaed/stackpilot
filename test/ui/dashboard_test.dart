import 'dart:io';

import 'package:flutter/material.dart'
    show
        CheckedPopupMenuItem,
        FilledButton,
        Size,
        SizedBox,
        Tab,
        TextButton,
        TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/app.dart';
import 'package:stackpilot/core/app_preferences.dart';
import 'package:stackpilot/core/service_manager.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:path/path.dart' as p;

class _FakeServiceManager extends ServiceManager {
  _FakeServiceManager(super.layout);

  int startAllCalls = 0;
  int stopAllCalls = 0;
  bool running = false;

  @override
  Future<void> refreshExternal() async {}

  @override
  Future<List<ServiceException>> startEnabled() async {
    startAllCalls++;
    running = true;
    return const [];
  }

  @override
  Future<List<ServiceException>> stopEnabled() async {
    stopAllCalls++;
    running = false;
    return const [];
  }

  @override
  bool isRunning(StackComponent component) => running;

  @override
  Iterable<StackComponent> get runningComponents => running
      ? StackLayout.serviceComponents.where(layout.serviceEnabled)
      : const [];

  @override
  bool get hasRunningServices => running;
}

class _FakePreferencesStore extends AppPreferencesStore {
  _FakePreferencesStore()
    : super(file: File(p.join(Directory.systemTemp.path, 'prefs.json')));

  final List<AppPreferences> saved = [];

  @override
  Future<void> save(AppPreferences preferences) async {
    saved.add(preferences);
  }
}

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_ui_');
    root = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void createFile(String relativePath) {
    File(p.join(root, relativePath))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }

  void createStack() {
    createFile(r'bin\apache\httpd-2.4.66\bin\httpd.exe');
    createFile(r'bin\mysql\mysql-8.4.3\bin\mysqld.exe');
    createFile(r'bin\postgresql\postgresql-x64-16\bin\postgres.exe');
    createFile(r'data\postgresql\PG_VERSION');
    createFile(r'data\postgresql\postgresql.conf');
    File(p.join(root, 'data', 'postgresql', 'PG_VERSION'))
        .writeAsStringSync('16');
    File(p.join(root, 'data', 'postgresql', 'postgresql.conf'))
        .writeAsStringSync('port = 5432\n');
    createFile(r'bin\php\php-8.3.30\php.exe');
    createFile(r'etc\ssl\laragon.crt');
    createFile(r'etc\ssl\laragon.key');
    createFile(r'www\blog\index.php');
    createFile(r'www\shop\index.html');

    File(p.join(root, 'usr', 'laragon.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[preferences]
AutoVirtualHosts=-1
DocumentRootList=$root\\www|

[apache]
Use=-1
SSLEnabled=-1
DocumentRoot=$root\\www

[mysql]
Use=-1

[postgresql]
Use=-1
Port=5432

[nginx]
Use=0
''');

    final path = [
      r'bin\apache\httpd-2.4.66\bin',
      r'bin\mysql\mysql-8.4.3\bin',
      r'bin\php\php-8.3.30',
    ].map((entry) => p.join(root, entry)).join(';');

    File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
      ..createSync(recursive: true)
      ..writeAsStringSync('@SET "PATH=$path;%PATH%;"');

    File(p.join(root, 'usr', 'profile', 'default.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[postgresql]
Version=postgresql-x64-16
''');
  }

  testWidgets('shows version controls and the stack switcher', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    expect(find.text('Version'), findsWidgets);
    expect(find.text('Click version to switch'), findsOneWidget);
    expect(find.text('Change stack'), findsOneWidget);
    expect(find.text('Add version'), findsWidgets);
  });

  testWidgets('switches the active PHP version from the card', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    createFile(r'bin\php\php-8.5.11-Win32-vs17-x64\php.exe');
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    await tester.tap(find.text('8.3.30'));
    await tester.pumpAndSettle();
    expect(find.text('8.5.11'), findsOneWidget);

    final item = find.byType(CheckedPopupMenuItem<Object>).last;
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();

    final profile = File(p.join(root, 'usr', 'profile', 'default.ini'))
        .readAsStringSync();
    expect(profile, contains('Version=php-8.5.11-Win32-vs17-x64'));

    final launcher = File(p.join(root, 'bin', 'laragon', 'laragon.cmd'))
        .readAsStringSync();
    expect(launcher, contains('php-8.5.11-Win32-vs17-x64'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saves MySQL port from the settings dialog', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Stack settings'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'MySQL'));
    await tester.pumpAndSettle();

    final portField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'MySQL port',
    );
    expect(portField, findsOneWidget);
    await tester.enterText(portField, '3307');

    await tester.tap(find.widgetWithText(FilledButton, 'Save settings'));
    await tester.pumpAndSettle();

    final ini = File(p.join(root, 'usr', 'laragon.ini')).readAsStringSync();
    expect(ini, contains('Port=3307'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saves the PostgreSQL port from the settings dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, 'PostgreSQL'));
    await tester.pumpAndSettle();

    final portField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'PostgreSQL port',
    );
    expect(portField, findsOneWidget);
    await tester.enterText(portField, '5434');

    await tester.tap(find.widgetWithText(FilledButton, 'Save settings'));
    await tester.pumpAndSettle();

    final ini = File(p.join(root, 'usr', 'laragon.ini')).readAsStringSync();
    expect(ini, contains('Port=5434'));

    final conf = File(p.join(root, 'data', 'postgresql', 'postgresql.conf'))
        .readAsStringSync();
    expect(RegExp(r'port\s*=\s*5434').hasMatch(conf), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offers phpMyAdmin from the database action', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    await tester.tap(find.text('Database'));
    await tester.pumpAndSettle();

    expect(find.text('Database tools'), findsOneWidget);
    expect(find.text('Download and install'), findsOneWidget);
    expect(find.text('Install from ZIP…'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();

    expect(find.text('Database tools'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows detected services and projects', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root);
    expect(layout, isNotNull);
    final services = _FakeServiceManager(layout!);

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => services,
      ),
    );

    expect(find.text('StackPilot'), findsOneWidget);
    expect(find.text('Apache'), findsOneWidget);
    expect(find.text('MySQL'), findsOneWidget);
    expect(find.text('PHP'), findsOneWidget);
    expect(find.text('blog'), findsOneWidget);
    expect(find.text('shop'), findsOneWidget);
    expect(find.text('SSL'), findsNWidgets(2));
    expect(find.textContaining('No donation prompts'), findsOneWidget);
    expect(find.text('All stopped'), findsOneWidget);
    expect(find.byTooltip('Rescan stack folder'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'blog.test'), findsOneWidget);
  });

  testWidgets('starts and stops services from the header', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;
    final services = _FakeServiceManager(layout);

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => services,
      ),
    );

    await tester.tap(find.text('Start All'));
    await tester.pump();
    expect(services.startAllCalls, 1);
    expect(find.text('3 running'), findsOneWidget);

    await tester.tap(find.text('Stop All'));
    await tester.pump();
    expect(services.stopAllCalls, 1);
    expect(find.text('All stopped'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('generates missing virtual hosts after confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    expect(find.text('vhost missing'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Generate 2 missing virtual host configs'));
    await tester.pumpAndSettle();
    expect(find.text('Generate virtual hosts?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();

    final config = File(
      p.join(root, 'etc', 'apache2', 'sites-enabled', 'auto.blog.test.conf'),
    );
    expect(config.existsSync(), isTrue);
    expect(find.textContaining('Created 2 virtual host files'), findsOneWidget);
    expect(find.text('vhost missing'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adopts a Laragon stack in place', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    createStack();
    final layout = StackLayout.detect(root)!;
    expect(layout.flavor, StackFlavor.laragon);

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    expect(find.text('This folder is a Laragon stack'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Adopt stack'));
    await tester.pumpAndSettle();
    expect(find.text('Adopt this Laragon stack?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Adopt'));
    await tester.pumpAndSettle();

    expect(
      find.text('This stack is now managed by StackPilot.'),
      findsOneWidget,
    );
    expect(
      File(p.join(root, 'usr', 'stackpilot.ini')).existsSync(),
      isTrue,
    );
    expect(File(p.join(root, 'bin', 'stackpilot.cmd')).existsSync(), isTrue);
    expect(StackLayout.detect(root)!.flavor, StackFlavor.stackpilot);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offers to create a stack when none is found', (tester) async {
    await tester.pumpWidget(
      const StackPilotApp(layout: null, attemptedRoot: r'C:\missing-stack'),
    );

    expect(find.text('Welcome to StackPilot'), findsOneWidget);
    expect(find.text('Create stack'), findsOneWidget);
    expect(find.text('Open existing stack…'), findsOneWidget);
    expect(
      find.text('No stack was found at C:\\missing-stack'),
      findsOneWidget,
    );
  });

  testWidgets('creates a StackPilot stack from the onboarding screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final target = p.join(temp.path, 'my-stack');
    await tester.pumpWidget(
      StackPilotApp(
        layout: null,
        attemptedRoot: r'C:\missing-stack',
        serviceManagerFactory: _FakeServiceManager.new,
      ),
    );

    await tester.enterText(find.byType(TextField), target);
    await tester.tap(find.widgetWithText(FilledButton, 'Create stack'));
    await tester.pumpAndSettle();

    expect(StackLayout.isStackRoot(target), isTrue);
    final marker = File(p.join(target, 'usr', 'stackpilot.ini'));
    expect(marker.existsSync(), isTrue);
    expect(
      marker.readAsStringSync(),
      contains('DocumentRootList=$target\\www'),
    );
    expect(find.text('Change stack'), findsOneWidget);
    expect(find.text('Created a stack at $target'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lets a fresh stack install its first version', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final target = p.join(temp.path, 'fresh');
    final layout = StackBootstrap.create(root: target);

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: target,
        serviceManagerFactory: _FakeServiceManager.new,
      ),
    );

    expect(find.text('Not installed'), findsWidgets);
    await tester.tap(find.byTooltip('Add a PHP version'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add version…'));
    await tester.pumpAndSettle();

    expect(find.text('Add PHP version'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offers to set up a fresh stack', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final target = p.join(temp.path, 'empty-stack');
    final layout = StackBootstrap.create(root: target);

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: target,
        serviceManagerFactory: _FakeServiceManager.new,
      ),
    );

    expect(find.text('This stack has no components yet'), findsOneWidget);
    expect(find.text('Install a starter stack'), findsOneWidget);

    await tester.tap(find.text('Install a starter stack'));
    await tester.pumpAndSettle();

    expect(find.text('Set up this stack'), findsOneWidget);
    expect(find.text('Install 4 components'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Set up this stack'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lists stacks in the settings folder and switches to one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    root = p.join(temp.path, 'current-stack');
    createStack();

    final other = p.join(temp.path, 'other-stack');
    File(p.join(other, 'usr', 'laragon.ini'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    Directory(p.join(other, 'bin')).createSync(recursive: true);

    final layout = StackLayout.detect(root)!;
    final store = _FakePreferencesStore();

    await tester.pumpWidget(
      StackPilotApp(
        layout: layout,
        attemptedRoot: root,
        preferences: AppPreferences(stacksFolder: temp.path),
        preferencesStore: store,
        serviceManagerFactory: (_) => _FakeServiceManager(layout),
      ),
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Stacks folder'), findsOneWidget);
    expect(find.text('other-stack'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);

    final useButton = find.widgetWithText(TextButton, 'Use');
    expect(useButton, findsOneWidget);
    expect(tester.widget<TextButton>(useButton).onPressed, isNotNull);
    await tester.ensureVisible(useButton);
    await tester.pumpAndSettle();
    await tester.tap(useButton);
    await tester.pumpAndSettle();

    expect(find.text('Stack settings'), findsNothing);

    expect(store.saved, isNotEmpty);
    expect(store.saved.last.activeStack, p.normalize(other));
    expect(store.saved.last.stacksFolder, p.normalize(temp.path));
    expect(find.textContaining('Using ${p.normalize(other)}'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
