import 'stack_layout.dart';

/// A pinned, downloadable build of a stack component.
///
/// Every entry names the exact archive StackPilot installs, its SHA-256 digest,
/// and the folder name used under `bin/<component>/`. Pinning the version and
/// the digest keeps a clean install reproducible and makes a tampered or
/// truncated download fail before anything is extracted.
class ComponentRelease {
  const ComponentRelease({
    required this.component,
    required this.version,
    required this.installName,
    required this.url,
    required this.sha256,
    this.mirrors = const [],
    this.resolver,
    this.product,
    this.sizeBytes,
    this.notes,
  });

  final StackComponent component;

  /// Version shown to the user, such as `8.5.12`.
  final String version;

  /// Folder name created under `bin/<component>`.
  final String installName;

  /// Primary HTTPS download location of the ZIP archive.
  final String url;

  /// Extra URLs tried when the primary one fails, such as the vendor's
  /// archive folder or a CDN. Every mirror must serve the exact same bytes.
  final List<String> mirrors;

  /// Optional remote index used to look up newer builds, such as
  /// `php-releases-json` or `node-index-json`.
  final String? resolver;

  /// Lower-case hex SHA-256 of the archive.
  final String sha256;

  /// Product name when it differs from the component, such as MariaDB for the
  /// `mysql` component.
  final String? product;

  /// Archive size in bytes, when known.
  final int? sizeBytes;

  /// Short note shown in the setup dialog.
  final String? notes;

  /// Primary URL followed by every mirror.
  List<String> get urls => [url, ...mirrors];

  /// True when a failed download has somewhere else to go, or when a remote
  /// index can resolve the release again.
  bool get hasFallback => urls.length > 1 || resolver != null;

  String get productName =>
      product ?? ComponentCatalog.productName(component);

  /// A short label such as `PHP 8.5.12` or `MariaDB 11.4.13`.
  String get label => '$productName $version';

  String get id => '${component.directoryName}-$version';

  /// Rough download size for the setup dialog.
  String get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null) {
      return 'Download size varies';
    }
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// True when the release is part of the starter stack offered on a fresh
  /// install.
  bool get isRecommended => ComponentCatalog.recommended.contains(this);

  @override
  String toString() => label;
}

/// Official Windows builds StackPilot can install into its own stack.
///
/// The catalog deliberately lists one known-good version per component. New
/// releases are added by updating the URL, folder name, and digest together;
/// "Add version…" on a service card still accepts any ZIP, folder, or URL.
class ComponentCatalog {
  const ComponentCatalog._();

  static const apache = ComponentRelease(
    component: StackComponent.apache,
    version: '2.4.69',
    installName: 'httpd-2.4.69-261002-Win64-VS18',
    url:
        'https://www.apachelounge.com/download/VS18/binaries/'
        'httpd-2.4.69-261002-Win64-VS18.zip',
    sha256: '77d715d0d9cee731e2251e7ddc2090a7a8e6d41fedef2e9827cd918593c5a652',
    sizeBytes: 14495691,
    resolver: 'apachelounge-page',
    notes: 'Apache Lounge build. Needs the Microsoft Visual C++ runtime.',
  );

  static const php = ComponentRelease(
    component: StackComponent.php,
    version: '8.5.12-1',
    installName: 'php-8.5.12-1-Win32-vs17-x64',
    url:
        'https://windows.php.net/downloads/releases/'
        'php-8.5.12-1-Win32-vs17-x64.zip',
    // PHP moves a build to releases/archives/ after the next release, so the
    // archive folder is the natural mirror for the exact same bytes.
    mirrors: [
      'https://windows.php.net/downloads/releases/archives/'
          'php-8.5.12-1-Win32-vs17-x64.zip',
    ],
    sha256: '0dacd6484b092b5e9ae9fa3d7f96a937caf9d874eee2d980b68ed3129741144a',
    sizeBytes: 36453069,
    resolver: 'php-releases-json',
    notes: 'Thread-safe build, so Apache can load PHP directly.',
  );

  static const mariadb = ComponentRelease(
    component: StackComponent.mysql,
    version: '11.4.13',
    installName: 'mariadb-11.4.13-winx64',
    product: 'MariaDB',
    url:
        'https://archive.mariadb.org/mariadb-11.4.13/winx64-packages/'
        'mariadb-11.4.13-winx64.zip',
    mirrors: [
      'https://downloads.mariadb.org/rest-api/mariadb/11.4.13/'
          'mariadb-11.4.13-winx64.zip',
    ],
    sha256: 'd62986d433eeebfde218560b276103831604a61e929e87f1a17f5aebd80257e2',
    sizeBytes: 95024126,
    resolver: 'mariadb-rest-api',
    notes: 'MySQL-compatible. Its data directory is initialised on install.',
  );

  static const nginx = ComponentRelease(
    component: StackComponent.nginx,
    version: '1.30.6',
    installName: 'nginx-1.30.6',
    url: 'https://nginx.org/download/nginx-1.30.6.zip',
    sha256: 'c6ee35edb0a861063323f709192ae50d1eefaf2ea7d00678bd2b22d8542dc61e',
    sizeBytes: 2773293,
    resolver: 'nginx-download-page',
    notes: 'Static file server with a PHP FastCGI block ready to enable.',
  );

  static const nodejs = ComponentRelease(
    component: StackComponent.nodejs,
    version: '26.13.0',
    installName: 'node-v26.13.0-win-x64',
    url: 'https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip',
    sha256: 'dcc60d59a0746999f99064a01c020445d54d84228c691cdbf25b49ac3b59150a',
    sizeBytes: 41157375,
    resolver: 'node-index-json',
    notes: 'Node.js LTS with npm.',
  );

  static const mailpit = ComponentRelease(
    component: StackComponent.mailpit,
    version: '1.32.0',
    installName: 'mailpit-1.32.0',
    url:
        'https://github.com/axllent/mailpit/releases/download/v1.32.0/'
        'mailpit-windows-amd64.zip',
    sha256: '16915767a6c95dca569336e8f561f91cf355e9a33c57b91deedcc10a4bba7fd4',
    sizeBytes: 10632291,
    resolver: 'github-release',
    notes: 'Catches outgoing mail at localhost:8025.',
  );

  static const redis = ComponentRelease(
    component: StackComponent.redis,
    version: '5.0.14.1',
    installName: 'redis-5.0.14.1',
    url:
        'https://github.com/tporadowski/redis/releases/download/v5.0.14.1/'
        'Redis-x64-5.0.14.1.zip',
    sha256: '018ea18a35876383cbb5f4cd0258adfc87747cf9d619bce1cf73a2e36f720ccf',
    sizeBytes: 12617669,
    resolver: 'github-release',
    notes: 'Community Windows port of Redis 5.0.',
  );

  static const postgresql = ComponentRelease(
    component: StackComponent.postgresql,
    version: '17.6',
    installName: 'postgresql-17.6',
    url:
        'https://get.enterprisedb.com/postgresql/'
        'postgresql-17.6-1-windows-x64-binaries.zip',
    sha256: 'd378882abd001a186735acd6f6ba716bca6ccd192e800412d4fd15ed25376b3e',
    sizeBytes: 329891687,
    resolver: 'edb-index-page',
    notes: 'Binaries only. StackPilot runs initdb for this stack.',
  );

  /// Every pinned build, in the order the setup dialog lists them.
  static const List<ComponentRelease> releases = [
    php,
    apache,
    mariadb,
    mailpit,
    nginx,
    nodejs,
    redis,
    postgresql,
  ];

  /// The starter stack: a web server, PHP, a database, and a mail catcher.
  static const List<ComponentRelease> recommended = [
    php,
    apache,
    mariadb,
    mailpit,
  ];

  /// Order used when several components are installed together.
  ///
  /// PHP goes first so Apache's config can include `mod_php.conf`, and Apache
  /// goes before the database so a failure still leaves a working web server.
  static const List<StackComponent> installOrder = [
    StackComponent.php,
    StackComponent.apache,
    StackComponent.mysql,
    StackComponent.mailpit,
    StackComponent.nginx,
    StackComponent.nodejs,
    StackComponent.redis,
    StackComponent.postgresql,
    StackComponent.memcached,
  ];

  static const Map<StackComponent, String> _productNames = {
    StackComponent.apache: 'Apache',
    StackComponent.nginx: 'Nginx',
    StackComponent.mysql: 'MySQL',
    StackComponent.postgresql: 'PostgreSQL',
    StackComponent.php: 'PHP',
    StackComponent.nodejs: 'Node.js',
    StackComponent.redis: 'Redis',
    StackComponent.memcached: 'Memcached',
    StackComponent.mailpit: 'Mailpit',
  };

  static String productName(StackComponent component) =>
      _productNames[component] ?? component.directoryName;

  static List<ComponentRelease> forComponent(StackComponent component) => [
    for (final release in releases)
      if (release.component == component) release,
  ];

  static ComponentRelease? latest(StackComponent component) {
    final matches = forComponent(component);
    return matches.isEmpty ? null : matches.first;
  }

  /// Finds a release by component and version.
  ///
  /// [version] may be the display version, the install folder name, or the
  /// release id.
  static ComponentRelease? find(String component, String version) {
    final componentNeedle = component.trim().toLowerCase();
    final versionNeedle = version.trim().toLowerCase();
    for (final release in releases) {
      final matchesComponent =
          release.component.directoryName.toLowerCase() == componentNeedle ||
          release.id.toLowerCase() == componentNeedle;
      if (!matchesComponent) {
        continue;
      }
      if (release.version.toLowerCase() == versionNeedle ||
          release.installName.toLowerCase() == versionNeedle ||
          release.id.toLowerCase() == versionNeedle) {
        return release;
      }
    }
    return null;
  }

  static ComponentRelease? byId(String id) {
    final needle = id.trim().toLowerCase();
    for (final release in releases) {
      if (release.id.toLowerCase() == needle) {
        return release;
      }
    }
    return null;
  }

  /// A release that is not installed in [layout], if any.
  static List<ComponentRelease> missingFrom(StackLayout layout) => [
    for (final release in releases)
      if (!isInstalled(layout, release)) release,
  ];

  static bool isInstalled(StackLayout layout, ComponentRelease release) {
    return layout
        .installedVersions(release.component)
        .any(
          (install) =>
              install.version.toLowerCase() ==
              release.installName.toLowerCase(),
        );
  }
}
