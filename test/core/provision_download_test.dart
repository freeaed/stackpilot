import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackpilot/core/component_catalog.dart';
import 'package:stackpilot/core/download_cache.dart';
import 'package:stackpilot/core/stack_bootstrap.dart';
import 'package:stackpilot/core/stack_layout.dart';
import 'package:stackpilot/core/stack_provisioner.dart';

void main() {
  late Directory temp;
  late StackLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stackpilot_download_');
    layout = StackBootstrap.create(root: p.join(temp.path, 'stack'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  ComponentRelease mirrorRelease() => ComponentRelease(
    component: StackComponent.mailpit,
    version: '1.32.0',
    installName: 'mailpit-1.32.0',
    url: 'https://primary.example/mailpit.zip',
    mirrors: const ['https://mirror.example/mailpit.zip'],
    sha256: List.filled(64, 'a').join(),
  );

  Future<StackInstall> createInstall(
    StackComponent component,
    String installName,
  ) async {
    final directory = p.join(
      layout.root,
      'bin',
      component.directoryName,
      installName,
    );
    final executable = StackLayout.executablePath(component, directory);
    File(executable).createSync(recursive: true);
    return StackInstall(
      component: component,
      version: installName,
      directory: directory,
      executablePath: executable,
    );
  }

  test('falls back to the mirror when the primary URL fails', () async {
    final release = mirrorRelease();
    final attempts = <String>[];

    final provisioner = StackProvisioner(
      layout,
      download: (uri, destination, onProgress) async {
        attempts.add(uri.toString());
        if (uri.host == 'primary.example') {
          throw const ProvisionException('Download failed with HTTP 404.');
        }
        destination.writeAsBytesSync([1, 2, 3]);
        onProgress(3, 3);
      },
      digest: (_) async => release.sha256,
      installArchive: (component, archivePath, installName) =>
          createInstall(component, installName),
    );

    final result = await provisioner.install(release);

    expect(result.install.version, release.installName);
    expect(attempts, [release.url, release.mirrors.single]);
  });

  test('tries the mirror first when the user asks for it', () async {
    final release = mirrorRelease();
    final attempts = <String>[];

    final provisioner = StackProvisioner(
      layout,
      download: (uri, destination, onProgress) async {
        attempts.add(uri.toString());
        destination.writeAsBytesSync([1, 2, 3]);
      },
      digest: (_) async => release.sha256,
      installArchive: (component, archivePath, installName) =>
          createInstall(component, installName),
    );

    await provisioner.install(release, preferMirror: true);

    expect(attempts.single, release.mirrors.single);
  });

  test('reports the expected and actual digest on a mismatch', () async {
    final release = mirrorRelease();
    const actual = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    final report = await StackProvisioner(
      layout,
      download: (uri, destination, onProgress) async {
        destination.writeAsBytesSync([9, 9, 9]);
      },
      digest: (_) async => actual,
      installArchive: (component, archivePath, installName) =>
          createInstall(component, installName),
    ).installAll([release]);

    expect(report.ok, isFalse);
    final failure = report.failures.single;
    expect(failure.isChecksumMismatch, isTrue);
    expect(failure.expectedSha256, release.sha256);
    expect(failure.actualSha256, actual);
    expect(failure.url, release.url);
    expect(failure.message, contains('checksum'));
  });

  test('uses a cached archive instead of downloading again', () async {
    final release = mirrorRelease();
    final cache = DownloadCache(
      directory: Directory(p.join(temp.path, 'cache'))..createSync(),
    );
    final cached = cache.archiveFor(release.sha256)
      ..writeAsBytesSync([4, 5, 6]);
    var downloads = 0;

    final provisioner = StackProvisioner(
      layout,
      cache: cache,
      digest: (_) async => release.sha256,
      installArchive: (component, archivePath, installName) async {
        expect(archivePath, cached.path);
        return createInstall(component, installName);
      },
    );

    final result = await provisioner.install(release);

    expect(result.install.version, release.installName);
    expect(downloads, 0);
    expect(cached.existsSync(), isTrue);
  });

  test('the cache counts, sizes and clears its archives', () {
    final directory = Directory(p.join(temp.path, 'cache'))..createSync();
    final cache = DownloadCache(directory: directory);
    expect(cache.isEmpty, isTrue);

    cache.archiveFor('a' * 64).writeAsBytesSync([1, 2, 3, 4]);
    cache.partFor('b' * 64).writeAsBytesSync([5, 6]);

    expect(cache.count, 1);
    expect(cache.sizeBytes, 6);
    expect(cache.clear(), 2);
    expect(cache.isEmpty, isTrue);
  });
}
