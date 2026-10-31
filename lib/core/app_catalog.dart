/// A web application StackPilot installs into a stack, as opposed to a
/// service or runtime from [ComponentCatalog].
///
/// Apps live in `<stack>/etc/apps/<installName>` — the same place Laragon
/// keeps them — and are served through an Apache alias, so they never appear
/// inside the user's document root.
class CatalogApp {
  const CatalogApp({
    required this.id,
    required this.name,
    required this.version,
    required this.installName,
    required this.url,
    required this.sha256,
    this.mirrors = const [],
    this.sizeBytes,
    this.notes,
  });

  /// Stable key used by preferences and the payload manifest.
  final String id;

  /// Product name shown to the user.
  final String name;

  final String version;

  /// Folder name under `etc/apps`.
  final String installName;

  /// Primary HTTPS download location.
  final String url;

  /// Additional URLs serving the exact same archive.
  final List<String> mirrors;

  /// Lower-case hex SHA-256 of the archive.
  final String sha256;

  final int? sizeBytes;

  final String? notes;

  List<String> get urls => [url, ...mirrors];

  String get label => '$name $version';

  String get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null) {
      return 'Download size varies';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  String toString() => label;
}

/// Applications StackPilot can download and serve for a stack.
class AppCatalog {
  const AppCatalog._();

  static const phpMyAdmin = CatalogApp(
    id: 'phpmyadmin',
    name: 'phpMyAdmin',
    version: '5.2.3',
    installName: 'phpmyadmin',
    url:
        'https://files.phpmyadmin.net/phpMyAdmin/5.2.3/'
        'phpMyAdmin-5.2.3-all-languages.zip',
    sha256: '2d2e13c735366d318425c78e4ee2cc8fc648d77faba3ddea2cd516e43885733f',
    sizeBytes: 16431330,
    notes: 'Opens at http://localhost/phpmyadmin/ after Apache restarts.',
  );

  /// Every app, in the order the setup dialog lists them.
  static const List<CatalogApp> apps = [phpMyAdmin];

  static CatalogApp? byId(String id) {
    final needle = id.trim().toLowerCase();
    for (final app in apps) {
      if (app.id == needle) {
        return app;
      }
    }
    return null;
  }
}
