import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'app_info.dart';
import 'app_log.dart';
import 'app_preferences.dart';

/// One installable release from the update manifest.
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.channel,
    required this.installerUrl,
    required this.sha256,
    this.sizeBytes,
    this.notes = '',
    this.published,
  });

  final String version;
  final ReleaseChannel channel;
  final Uri installerUrl;

  /// Lower-case hex SHA-256 of the installer.
  final String sha256;
  final int? sizeBytes;
  final String notes;
  final DateTime? published;

  String get label => 'StackPilot $version';
}

/// Manifest for all release channels.
///
/// The manifest is fetched as bytes and verified with a detached Ed25519
/// signature (`<manifest-url>.sig`). The signature covers the exact bytes, so
/// the JSON is never re-serialized before verification.
class UpdateManifest {
  const UpdateManifest({required this.channels, this.generated});

  final Map<ReleaseChannel, UpdateRelease> channels;
  final DateTime? generated;

  static UpdateManifest parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const UpdateException('The update manifest is not valid JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const UpdateException(
        'The update manifest has an unexpected shape.',
      );
    }
    if (decoded['schema'] != 1) {
      throw UpdateException(
        'Unsupported update manifest schema ${decoded['schema']}.',
      );
    }
    final rawChannels = decoded['channels'];
    if (rawChannels is! Map<String, Object?>) {
      throw const UpdateException('The update manifest has no channels.');
    }

    final channels = <ReleaseChannel, UpdateRelease>{};
    for (final entry in rawChannels.entries) {
      final channel = ReleaseChannel.parse(entry.key);
      if (channel.id != entry.key.trim().toLowerCase()) {
        throw UpdateException('Unknown update channel "${entry.key}".');
      }
      final value = entry.value;
      if (value is! Map<String, Object?>) {
        throw UpdateException('Channel "${entry.key}" is not an object.');
      }
      channels[channel] = _parseRelease(channel, value);
    }
    if (channels.isEmpty) {
      throw const UpdateException('The update manifest lists no releases.');
    }

    DateTime? generated;
    final rawGenerated = decoded['generated'];
    if (rawGenerated is String) {
      generated = DateTime.tryParse(rawGenerated);
    }
    return UpdateManifest(channels: channels, generated: generated);
  }

  static UpdateRelease _parseRelease(
    ReleaseChannel channel,
    Map<String, Object?> json,
  ) {
    final version = json['version'];
    if (version is! String || AppVersion.tryParse(version) == null) {
      throw UpdateException('Channel "${channel.id}" has an invalid version.');
    }
    final installer = json['installer'];
    if (installer is! Map<String, Object?>) {
      throw UpdateException('Channel "${channel.id}" has no installer.');
    }
    final rawUrl = installer['url'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl.trim()) : null;
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
      throw UpdateException(
        'Channel "${channel.id}" has no valid HTTPS installer URL.',
      );
    }
    final digest = installer['sha256'];
    if (digest is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
      throw UpdateException(
        'Channel "${channel.id}" has an invalid installer checksum.',
      );
    }
    final size = installer['size'];
    final notes = json['notes'];
    final published = json['published'];
    return UpdateRelease(
      version: version.trim(),
      channel: channel,
      installerUrl: uri,
      sha256: digest.toLowerCase(),
      sizeBytes: size is int && size > 0 ? size : null,
      notes: notes is String ? notes : '',
      published: published is String ? DateTime.tryParse(published) : null,
    );
  }

  /// The release [channel] should offer.
  ///
  /// A preview build follows preview releases and falls back to the newest
  /// stable release when it is newer.
  UpdateRelease? releaseFor(ReleaseChannel channel) {
    final stable = channels[ReleaseChannel.stable];
    if (channel == ReleaseChannel.stable) {
      return stable;
    }
    final preview = channels[ReleaseChannel.preview];
    if (preview == null) {
      return stable;
    }
    if (stable == null) {
      return preview;
    }
    final stableVersion = AppVersion.tryParse(stable.version)!;
    final previewVersion = AppVersion.tryParse(preview.version)!;
    return previewVersion.isNewerThan(stableVersion) ? preview : stable;
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of one update check.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.channel,
    this.release,
  });

  final String currentVersion;
  final ReleaseChannel channel;

  /// Newer release, or null when the build is current.
  final UpdateRelease? release;

  bool get hasUpdate => release != null;
}

/// A downloaded installer that can be installed again later.
class CachedInstaller {
  const CachedInstaller({
    required this.version,
    required this.file,
    required this.sizeBytes,
  });

  final String version;
  final File file;
  final int sizeBytes;

  String get label => 'StackPilot $version';
}

typedef UpdateBytesFetcher = Future<List<int>> Function(Uri uri);
typedef UpdateTextFetcher = Future<String> Function(Uri uri);
typedef UpdateDownload = Future<void> Function(
  Uri uri,
  File destination,
  void Function(int received, int? total) onProgress,
);

/// Checks a signed update manifest, downloads installers, and launches them.
///
/// Only HTTPS manifests are accepted. The manifest must carry a detached
/// Ed25519 signature from the public key compiled into the build, and every
/// installer is checked against the SHA-256 in that manifest before it runs.
class UpdateService {
  UpdateService({
    required this.manifestUri,
    required this.publicKey,
    required this.currentVersion,
    required this.channel,
    Directory? cacheDirectory,
    UpdateBytesFetcher? fetchBytes,
    UpdateTextFetcher? fetchText,
    UpdateDownload? download,
  }) : _cacheDirectory = cacheDirectory ?? defaultCacheDirectory(),
       _fetchBytes = fetchBytes ?? _httpBytes,
       _fetchText = fetchText ?? _httpText,
       _download = download ?? _httpDownload;

  final Uri manifestUri;

  /// Base64 Ed25519 public key.
  final String publicKey;
  final String currentVersion;
  final ReleaseChannel channel;

  final Directory _cacheDirectory;
  final UpdateBytesFetcher _fetchBytes;
  final UpdateTextFetcher _fetchText;
  final UpdateDownload _download;

  /// Builds a service from [preferences] and the build's compiled-in values.
  ///
  /// Returns null when this build has no manifest URL or public key, which is
  /// the normal state for local development builds.
  static UpdateService? fromConfig(
    AppPreferences preferences, {
    String currentVersion = AppInfo.version,
  }) {
    final url = (preferences.updateManifestUrl ?? AppInfo.updateManifestUrl)
        .trim();
    final key = AppInfo.updatePublicKey.trim();
    if (url.isEmpty || key.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
      return null;
    }
    return UpdateService(
      manifestUri: uri,
      publicKey: key,
      currentVersion: currentVersion,
      channel: preferences.updateChannel,
    );
  }

  /// `%LOCALAPPDATA%\StackPilot\updates`, with a profile fallback.
  static Directory defaultCacheDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = (localAppData == null || localAppData.trim().isEmpty)
        ? p.join(
            Platform.environment['USERPROFILE'] ?? Directory.current.path,
            'AppData',
            'Local',
          )
        : localAppData;
    return Directory(p.join(base, 'StackPilot', 'updates'));
  }

  /// Fetches and verifies the manifest, then compares versions.
  Future<UpdateCheckResult> check() async {
    if (manifestUri.scheme != 'https' || !manifestUri.hasAuthority) {
      throw const UpdateException(
        'The update manifest must be served over HTTPS.',
      );
    }
    AppLog.info(
      'Checking ${manifestUri.toString()} for ${channel.id} updates '
      '(current $currentVersion)',
    );
    final manifestBytes = await _fetchBytes(manifestUri);
    if (manifestBytes.length > 1024 * 1024) {
      throw const UpdateException('The update manifest is too large.');
    }
    await _verifySignature(manifestBytes);

    final manifest = UpdateManifest.parse(utf8.decode(manifestBytes));
    final release = manifest.releaseFor(channel);
    if (release == null) {
      throw const UpdateException('No release is published for this channel.');
    }

    final current = AppVersion.tryParse(currentVersion);
    final candidate = AppVersion.tryParse(release.version);
    if (current == null || candidate == null) {
      throw const UpdateException(
        'The update manifest has an invalid version.',
      );
    }

    if (!candidate.isNewerThan(current)) {
      AppLog.info('StackPilot is up to date ($currentVersion).');
      return UpdateCheckResult(
        currentVersion: currentVersion,
        channel: channel,
      );
    }

    AppLog.info('Update available: ${release.label}');
    return UpdateCheckResult(
      currentVersion: currentVersion,
      channel: channel,
      release: release,
    );
  }

  Future<void> _verifySignature(List<int> manifestBytes) async {
    final signatureUri = manifestUri.replace(path: '${manifestUri.path}.sig');
    final encoded = (await _fetchText(signatureUri)).trim();
    if (encoded.isEmpty) {
      throw const UpdateException('The update manifest has no signature.');
    }

    final List<int> signatureBytes;
    try {
      signatureBytes = base64Decode(encoded.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const UpdateException('The update signature is not valid base64.');
    }
    if (signatureBytes.length != 64) {
      throw const UpdateException('The update signature is not valid.');
    }

    final List<int> keyBytes;
    try {
      keyBytes = base64Decode(this.publicKey.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const UpdateException(
        'The update public key configured in this build is invalid.',
      );
    }
    if (keyBytes.length != 32) {
      throw const UpdateException(
        'The update public key configured in this build is invalid.',
      );
    }

    final algorithm = Ed25519();
    final publicKey = SimplePublicKey(keyBytes, type: KeyPairType.ed25519);
    final bool valid;
    try {
      valid = await algorithm.verify(
        manifestBytes,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
    } on ArgumentError {
      throw const UpdateException(
        'The update manifest signature could not be checked.',
      );
    }
    if (!valid) {
      throw const UpdateException(
        'The update manifest signature is not valid. The download was not '
        'trusted.',
      );
    }
  }

  /// Downloads [release] into the cache and verifies its checksum.
  Future<File> download(
    UpdateRelease release, {
    void Function(int received, int? total)? onProgress,
  }) async {
    _cacheDirectory.createSync(recursive: true);
    final target = File(
      p.join(_cacheDirectory.path, 'StackPilot-${release.version}-Setup.exe'),
    );

    if (target.existsSync() && await _matches(target, release)) {
      AppLog.info('Using cached installer ${target.path}');
      return target;
    }

    final partial = File('${target.path}.part');
    if (partial.existsSync()) {
      partial.deleteSync();
    }
    AppLog.info('Downloading ${release.installerUrl}');
    try {
      await _download(release.installerUrl, partial, (received, total) {
        onProgress?.call(received, total);
      });
    } on Object {
      try {
        if (partial.existsSync()) {
          partial.deleteSync();
        }
      } on FileSystemException {
        // Ignore; the next attempt replaces the partial file.
      }
      rethrow;
    }

    if (!await _matches(partial, release)) {
      try {
        partial.deleteSync();
      } on FileSystemException {
        // Ignore.
      }
      throw UpdateException(
        'The ${release.label} installer did not match its published checksum, '
        'so it was not installed.',
      );
    }

    if (target.existsSync()) {
      target.deleteSync();
    }
    partial.renameSync(target.path);
    _prune(keep: target);
    AppLog.info('Installer ready at ${target.path}');
    return target;
  }

  Future<bool> _matches(File file, UpdateRelease release) async {
    final size = release.sizeBytes;
    if (size != null && file.lengthSync() != size) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == release.sha256;
  }

  /// Installers already downloaded, newest version first.
  List<CachedInstaller> cachedInstallers() => scanCache(_cacheDirectory);

  /// Scans [directory] (default: the per-user update cache) for installers.
  static List<CachedInstaller> scanCache([Directory? directory]) {
    final target = directory ?? defaultCacheDirectory();
    if (!target.existsSync()) {
      return const [];
    }
    final installers = <CachedInstaller>[];
    try {
      for (final entity in target.listSync(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        final match = RegExp(
          r'^StackPilot-(.+)-Setup\.exe$',
          caseSensitive: false,
        ).firstMatch(p.basename(entity.path));
        if (match == null) {
          continue;
        }
        installers.add(
          CachedInstaller(
            version: match.group(1)!,
            file: entity,
            sizeBytes: entity.lengthSync(),
          ),
        );
      }
    } on FileSystemException {
      return const [];
    }
    installers.sort((a, b) {
      final left = AppVersion.tryParse(a.version);
      final right = AppVersion.tryParse(b.version);
      if (left == null || right == null) {
        return b.version.compareTo(a.version);
      }
      return right.compareTo(left);
    });
    return installers;
  }

  /// Starts the Inno Setup installer and returns immediately.
  ///
  /// The caller should exit StackPilot so the installer can replace its files.
  Future<void> launchInstaller(File installer) => runInstaller(installer);

  /// Starts [installer] silently. Also used for rollback, so it does not
  /// require an update manifest or signing key.
  static Future<void> runInstaller(File installer) async {
    if (!installer.existsSync()) {
      throw UpdateException('The installer at ${installer.path} is missing.');
    }
    AppLog.info('Launching installer ${installer.path}');
    await Process.start(installer.path, const [
      '/SILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/RESTARTAPPLICATIONS',
    ], mode: ProcessStartMode.detached);
  }

  /// Removes older installers, keeping [keep] plus the two newest others.
  void _prune({required File keep}) {
    final installers = cachedInstallers();
    var removed = 0;
    for (final installer in installers) {
      if (p.equals(installer.file.path, keep.path)) {
        continue;
      }
      if (removed >= 2) {
        break;
      }
      try {
        installer.file.deleteSync();
        removed++;
      } on FileSystemException {
        // Ignore.
      }
    }
  }

  static Future<List<int>> _httpBytes(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'StackPilot');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException(
          'The update server returned HTTP ${response.statusCode}.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const UpdateException('The update manifest is too large.');
        }
      }
      return bytes;
    } on SocketException catch (error) {
      throw UpdateException(
        'Could not reach the update server: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _httpText(Uri uri) async {
    final bytes = await _httpBytes(uri);
    return utf8.decode(bytes);
  }

  static Future<void> _httpDownload(
    Uri uri,
    File destination,
    void Function(int received, int? total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'StackPilot');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException(
          'The update server returned HTTP ${response.statusCode}.',
        );
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      final handle = destination.openSync(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response) {
          handle.writeFromSync(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
    } on SocketException catch (error) {
      throw UpdateException('Could not download the update: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}
