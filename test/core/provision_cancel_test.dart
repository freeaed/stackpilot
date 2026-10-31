import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_provisioner.dart';

void main() {
  late Directory temp;
  late StackLayout layout;
  late int installedCount;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_cancel_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
    installedCount = 0;
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  StackProvisioner provisioner({ProvisionCancellation? cancellation}) {
    return StackProvisioner(
      layout,
      cancellation: cancellation,
      download: (uri, destination, onProgress) async {
        destination.writeAsBytesSync([1, 2, 3]);
        onProgress(3, 3);
      },
      digest: (file) async => ComponentCatalog.mailpit.sha256,
      installArchive: (component, archivePath, installName) async {
        installedCount++;
        final directory = Directory(
          p.join(layout.root, 'bin', component.directoryName, installName),
        )..createSync(recursive: true);
        final executable = File(
          StackLayout.executablePath(component, directory.path),
        )..createSync(recursive: true);
        return StackInstall(
          component: component,
          version: installName,
          directory: directory.path,
          executablePath: executable.path,
        );
      },
    );
  }

  test('a cancelled install stops before downloading anything', () async {
    final cancellation = ProvisionCancellation()..cancel();

    final report = await provisioner(
      cancellation: cancellation,
    ).installAll([ComponentCatalog.mailpit]);

    expect(report.cancelled, isTrue);
    expect(report.installed, isEmpty);
    expect(installedCount, 0);
  });

  test('re-download replaces an installed copy', () async {
    File(
      p.join(
        layout.root,
        'bin',
        'mailpit',
        ComponentCatalog.mailpit.installName,
        'mailpit.exe',
      ),
    ).createSync(recursive: true);
    layout = StackLayout.detect(layout.root)!;

    final report = await provisioner().installAll(
      [ComponentCatalog.mailpit],
      reinstall: true,
    );

    expect(report.failures, isEmpty);
    expect(report.installed.single.alreadyInstalled, isFalse);
    expect(installedCount, 1);
    expect(
      Directory(
        p.join(
          layout.root,
          'bin',
          'mailpit',
          ComponentCatalog.mailpit.installName,
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(
        p.join(
          layout.root,
          'bin',
          'mailpit',
          '${ComponentCatalog.mailpit.installName}.stackpilot-previous',
        ),
      ).existsSync(),
      isFalse,
    );
  });

  test('an existing install is reused without re-downloading', () async {
    File(
      p.join(
        layout.root,
        'bin',
        'mailpit',
        ComponentCatalog.mailpit.installName,
        'mailpit.exe',
      ),
    ).createSync(recursive: true);
    layout = StackLayout.detect(layout.root)!;

    final report = await provisioner().installAll([ComponentCatalog.mailpit]);

    expect(report.installed.single.alreadyInstalled, isTrue);
    expect(installedCount, 0);
  });
}
