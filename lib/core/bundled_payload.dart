import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'component_catalog.dart';

/// One archive shipped inside the installer for offline setup.
class BundledComponent {
  const BundledComponent({
    required this.id,
    required this.fileName,
    required this.sha256,
    this.sizeBytes,
  });

  final String id;
  final String fileName;
  final String sha256;
  final int? sizeBytes;
}

/// Optional offline payload installed next to `stackpilot.exe`.
///
/// A release can ship `payload/` with the archives from the component catalog
/// plus a `payload.json` index. The setup wizard then installs those files
/// instead of downloading them. The catalog checksum still decides whether an
/// archive is trusted, so an outdated payload is ignored rather than used.
class BundledPayload {
  BundledPayload._(this.directory, this._components);

  final Directory directory;
  final Map<String, BundledComponent> _components;

  static const manifestName = 'payload.json';

  int get count => _components.length;

  Iterable<BundledComponent> get components => _components.values;

  bool get isEmpty => _components.isEmpty;

  /// Finds a payload next to the running executable, or in
  /// `STACKPILOT_PAYLOAD` when set.
  static BundledPayload? locate({Directory? root}) {
    final candidates = <Directory>[
      ?root,
      if (root == null)
        Directory(p.join(p.dirname(Platform.resolvedExecutable), 'payload')),
      if (root == null &&
          (Platform.environment['STACKPILOT_PAYLOAD'] ?? '').trim().isNotEmpty)
        Directory(Platform.environment['STACKPILOT_PAYLOAD']!.trim()),
    ];
    for (final directory in candidates) {
      final payload = load(directory);
      if (payload != null) {
        return payload;
      }
    }
    return null;
  }

  /// Reads `payload.json` from [directory], or null when it is absent or
  /// malformed.
  static BundledPayload? load(Directory directory) {
    final manifest = File(p.join(directory.path, manifestName));
    if (!manifest.existsSync()) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(manifest.readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      AppLog.warn('Ignoring malformed ${manifest.path}');
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['schema'] != 1) {
      AppLog.warn('Ignoring unsupported payload manifest ${manifest.path}');
      return null;
    }
    final raw = decoded['components'];
    if (raw is! List<Object?>) {
      return null;
    }

    final components = <String, BundledComponent>{};
    for (final entry in raw) {
      if (entry is! Map<String, Object?>) {
        continue;
      }
      final id = entry['id'];
      final file = entry['file'];
      final sha256 = entry['sha256'];
      if (id is! String ||
          file is! String ||
          sha256 is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
        continue;
      }
      // Never follow a path out of the payload folder.
      if (p.basename(file) != file || file.contains('..')) {
        continue;
      }
      final archive = File(p.join(directory.path, file));
      if (!archive.existsSync()) {
        continue;
      }
      components[id] = BundledComponent(
        id: id,
        fileName: file,
        sha256: sha256.toLowerCase(),
        sizeBytes: entry['size'] is int ? entry['size'] as int : null,
      );
    }

    if (components.isEmpty) {
      return null;
    }
    AppLog.info(
      'Bundled payload found at ${directory.path} (${components.length} '
      'components)',
    );
    return BundledPayload._(directory, components);
  }

  /// Archive for [release], when the payload carries the exact pinned build.
  File? archiveFor(ComponentRelease release) {
    final component = _components[release.id];
    if (component == null) {
      return null;
    }
    if (component.sha256.toLowerCase() != release.sha256.toLowerCase()) {
      AppLog.warn(
        'Ignoring bundled ${release.id}: its checksum does not match the '
        'catalog.',
      );
      return null;
    }
    final file = File(p.join(directory.path, component.fileName));
    return file.existsSync() ? file : null;
  }
}
