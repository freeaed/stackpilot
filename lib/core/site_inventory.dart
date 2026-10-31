import 'dart:io';

import 'package:path/path.dart' as p;

import 'hosts_file.dart';
import 'stack_layout.dart';

/// One project under the stack document root and its virtual-host state.
class ProjectSite {
  const ProjectSite({
    required this.name,
    required this.directory,
    required this.documentRoot,
    required this.host,
    required this.configPath,
    required this.configPresent,
    required this.configDocumentRoot,
    required this.configSslEnabled,
    required this.hostsMapped,
    required this.sslRequested,
    required this.sslAvailable,
  });

  final String name;
  final String directory;
  final String documentRoot;
  final String host;
  final String configPath;
  final bool configPresent;
  final String? configDocumentRoot;
  final bool configSslEnabled;
  final bool hostsMapped;
  final bool sslRequested;
  final bool sslAvailable;

  bool get sslEnabled =>
      configPresent ? configSslEnabled : sslRequested && sslAvailable;

  bool get configOutdated =>
      configPresent &&
      configDocumentRoot != null &&
      p.normalize(configDocumentRoot!).toLowerCase() !=
          p.normalize(documentRoot).toLowerCase();
}

class VhostGenerationResult {
  const VhostGenerationResult({
    required this.created,
    required this.mappedHosts,
    this.hostsError,
  });

  final List<String> created;
  final List<String> mappedHosts;

  /// Set when the config files were written but the hosts file could not be
  /// updated (usually because it needs administrator rights).
  final String? hostsError;

  bool get changed => created.isNotEmpty || mappedHosts.isNotEmpty;
}

/// Reads projects, virtual-host configs, and hosts entries from a stack.
class SiteInventory {
  SiteInventory._({
    required this.layout,
    required this.sitesEnabledDirectory,
    required this.hostsPath,
    required this.sslCertificatePath,
    required this.sslKeyPath,
    required List<ProjectSite> sites,
  }) : sites = List<ProjectSite>.unmodifiable(sites);

  static const defaultHostsPath = HostsFile.defaultPath;

  static SiteInventory load(StackLayout layout, {String? hostsPath}) {
    final resolvedHostsPath = hostsPath ?? defaultHostsPath;
    final hosts = readHostsLines(resolvedHostsPath);
    final sitesDirectory = Directory(
      p.join(layout.root, 'etc', 'apache2', 'sites-enabled'),
    );
    final sslDirectory = p.join(layout.root, 'etc', 'ssl');
    final certificate =
        _firstExisting(sslDirectory, const ['stackpilot.crt', 'laragon.crt']) ??
        p.join(sslDirectory, 'stackpilot.crt');
    final key =
        _firstExisting(sslDirectory, const ['stackpilot.key', 'laragon.key']) ??
        p.join(sslDirectory, 'stackpilot.key');
    final sslAvailable =
        File(certificate).existsSync() && File(key).existsSync();
    final sslRequested = _isEnabled(
      layout.config.value('apache', 'SSLEnabled'),
    );

    final sites = <ProjectSite>[];
    for (final project in _projects(layout.documentRoot)) {
      final host = '${project.name}.test';
      final configPath = p.join(sitesDirectory.path, 'auto.$host.conf');
      final configFile = File(configPath);
      final configExists = configFile.existsSync();
      final configText = configExists ? _readText(configFile) : null;
      sites.add(
        ProjectSite(
          name: project.name,
          directory: project.path,
          documentRoot: _documentRoot(project.path),
          host: host,
          configPath: configPath,
          configPresent: configExists,
          configDocumentRoot: configText == null
              ? null
              : _define(configText, 'ROOT'),
          configSslEnabled:
              configText?.contains(RegExp(r'<VirtualHost\s+\*:443')) ?? false,
          hostsMapped: hostsFileMaps(hosts, host),
          sslRequested: sslRequested,
          sslAvailable: sslAvailable,
        ),
      );
    }

    sites.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SiteInventory._(
      layout: layout,
      sitesEnabledDirectory: sitesDirectory.path,
      hostsPath: resolvedHostsPath,
      sslCertificatePath: certificate,
      sslKeyPath: key,
      sites: sites,
    );
  }

  final StackLayout layout;
  final String sitesEnabledDirectory;
  final String hostsPath;
  final String sslCertificatePath;
  final String sslKeyPath;
  final List<ProjectSite> sites;

  List<ProjectSite> get missingConfigs =>
      sites.where((site) => !site.configPresent).toList();

  List<ProjectSite> get unmappedHosts =>
      sites.where((site) => !site.hostsMapped).toList();

  /// Host names that still have to be added to the hosts file.
  List<String> get pendingHosts =>
      unmappedHosts.map((site) => site.host).toList();

  /// Creates only missing `auto.<host>.conf` files and, when [mapHosts] is
  /// true, adds a managed block of `127.0.0.1` entries to the hosts file.
  ///
  /// Existing config files and unrelated hosts lines are never changed. A
  /// hosts write that fails (normally an access-denied error) is reported in
  /// [VhostGenerationResult.hostsError] so the generated configs still work.
  /// This writes the file directly; use [mapHosts] when the caller can wait for
  /// an administrator prompt.
  VhostGenerationResult generateMissing({bool mapHosts = true}) {
    final directory = Directory(sitesEnabledDirectory);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }

    final created = <String>[];
    for (final site in missingConfigs) {
      File(site.configPath).writeAsStringSync(_render(site));
      created.add(site.configPath);
    }

    final mapped = <String>[];
    String? hostsError;
    if (mapHosts) {
      final pending = unmappedHosts.map((site) => site.host).toList();
      if (pending.isNotEmpty) {
        try {
          mapped.addAll(_mapHosts(pending));
        } on FileSystemException catch (error) {
          hostsError = error.message;
        }
      }
    }

    return VhostGenerationResult(
      created: created,
      mappedHosts: mapped,
      hostsError: hostsError,
    );
  }

  /// Adds [hosts] to the managed block, asking Windows for administrator
  /// rights when the direct write is denied.
  ///
  /// Use this instead of [generateMissing] from the UI: it covers the normal
  /// case where StackPilot runs as a standard user and the hosts file is
  /// writable only by administrators.
  Future<HostsUpdate> mapHosts(Iterable<String> hosts) =>
      HostsFile(hostsPath).add(hosts);

  /// Adds every project host that is still missing.
  Future<HostsUpdate> mapMissingHosts() => mapHosts(pendingHosts);

  /// Adds [hosts] to the managed block in the hosts file.
  ///
  /// Returns the names that were not mapped before. The block is rewritten in
  /// place so repeated runs stay stable and unrelated lines are preserved.
  List<String> _mapHosts(List<String> hosts) {
    final lines = readHostsLines(hostsPath);
    final document = HostsDocument.parse(lines);
    final added = <String>[];
    for (final host in hosts) {
      if (document.hasHost(host) || hostsFileMaps(lines, host)) {
        continue;
      }
      added.add(host);
    }
    if (added.isEmpty && document.hadBlock) {
      return const [];
    }

    File(hostsPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(document.addHosts(added).render());
    return added;
  }

  String _render(ProjectSite site) {
    final root = site.documentRoot.replaceAll('\\', '/');
    final certificate = sslCertificatePath.replaceAll('\\', '/');
    final key = sslKeyPath.replaceAll('\\', '/');
    final buffer = StringBuffer()
      ..writeln('define ROOT "$root"')
      ..writeln('define SITE "${site.host}"')
      ..writeln()
      ..writeln('<VirtualHost *:${layout.apachePort}> ')
      ..writeln('    DocumentRoot "\${ROOT}"')
      ..writeln('    ServerName \${SITE}')
      ..writeln('    ServerAlias *.\${SITE}')
      ..writeln('    <Directory "\${ROOT}">')
      ..writeln('        AllowOverride All')
      ..writeln('        Require all granted')
      ..writeln('    </Directory>')
      ..writeln('</VirtualHost>')
      ..writeln();

    if (site.sslRequested && site.sslAvailable) {
      buffer
        ..writeln('<VirtualHost *:443>')
        ..writeln('    DocumentRoot "\${ROOT}"')
        ..writeln('    ServerName \${SITE}')
        ..writeln('    ServerAlias *.\${SITE}')
        ..writeln('    <Directory "\${ROOT}">')
        ..writeln('        AllowOverride All')
        ..writeln('        Require all granted')
        ..writeln('    </Directory>')
        ..writeln()
        ..writeln('    SSLEngine on')
        ..writeln('    SSLCertificateFile      $certificate')
        ..writeln('    SSLCertificateKeyFile   $key')
        ..writeln(' ')
        ..writeln('</VirtualHost>');
    }

    return buffer.toString();
  }
}

class _Project {
  const _Project(this.name, this.path);

  final String name;
  final String path;
}

/// Folders in the web root that are tools rather than projects.
const _toolDirectories = {'phpmyadmin', 'pma'};

List<_Project> _projects(String documentRoot) {
  final directory = Directory(documentRoot);
  if (!directory.existsSync()) {
    return const [];
  }

  final projects = <_Project>[];
  for (final entry in directory.listSync(followLinks: false)) {
    if (entry is! Directory) {
      continue;
    }
    final name = p.basename(entry.path);
    if (name.startsWith('.') || name.startsWith(r'$')) {
      continue;
    }
    if (_toolDirectories.contains(name.toLowerCase())) {
      continue;
    }
    projects.add(_Project(name, entry.path));
  }
  return projects;
}

String _documentRoot(String projectDirectory) {
  final public = Directory(p.join(projectDirectory, 'public'));
  return public.existsSync() ? public.path : projectDirectory;
}

String? _readText(File file) {
  try {
    return file.readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

String? _define(String text, String name) {
  final match = RegExp(
    'define\\s+$name\\s+"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(1);
}

/// Returns the first file in [directory] that exists under one of [names].
String? _firstExisting(String directory, List<String> names) {
  for (final name in names) {
    final path = p.join(directory, name);
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

bool _isEnabled(String? value) {
  final normalized = value?.trim();
  return normalized != null &&
      normalized.isNotEmpty &&
      normalized != '0' &&
      normalized.toLowerCase() != 'false';
}
