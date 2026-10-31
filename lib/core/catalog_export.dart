import 'app_catalog.dart';
import 'component_catalog.dart';

/// Builds the signed-catalog body from the compiled-in catalog.
///
/// The same JSON is what `tool/export_catalog.dart` writes and what
/// `CatalogSnapshot.parse` accepts, so a round-trip test can guard the schema.
Map<String, Object?> buildCatalogManifest({DateTime? now}) {
  return {
    'schema': 1,
    'generated': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'components': [
      for (final release in ComponentCatalog.releases)
        {
          'component': release.component.directoryName,
          'version': release.version,
          'installName': release.installName,
          'urls': release.urls,
          'sha256': release.sha256,
          if (release.sizeBytes != null) 'size': release.sizeBytes,
          if (release.product != null) 'product': release.product,
          if (release.notes != null) 'notes': release.notes,
          if (release.resolver != null) 'resolver': release.resolver,
        },
    ],
    'apps': [
      for (final app in AppCatalog.apps)
        {
          'id': app.id,
          'name': app.name,
          'version': app.version,
          'installName': app.installName,
          'urls': app.urls,
          'sha256': app.sha256,
          if (app.sizeBytes != null) 'size': app.sizeBytes,
          if (app.notes != null) 'notes': app.notes,
        },
    ],
  };
}
