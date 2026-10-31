import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'app_catalog.dart';
import 'app_info.dart';
import 'component_catalog.dart';
import 'stack_layout.dart';

/// Raised when the remote catalog cannot be trusted or parsed.
class RemoteCatalogException implements Exception {
  const RemoteCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Component and app versions from a signed JSON manifest.
///
/// The manifest is fetched as bytes and verified with a detached Ed25519
/// signature (`<manifest-url>.sig`), using the same key that signs update
/// manifests. That lets a release fix a moved URL or a new checksum without
/// shipping a new application build.
class CatalogSnapshot {
  const CatalogSnapshot({
    required this.components,
    required this.apps,
    this.generated,
  });

  final List<ComponentRelease> components;
  final List<CatalogApp> apps;
  final DateTime? generated;

  static CatalogSnapshot parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const RemoteCatalogException(
        'The component catalog is not valid JSON.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const RemoteCatalogException(
        'The component catalog has an unexpected shape.',
      );
    }
    if (decoded['schema'] != 1) {
      throw RemoteCatalogException(
        'Unsupported component catalog schema ${decoded['schema']}.',
      );
    }

    final components = <ComponentRelease>[];
    final rawComponents = decoded['components'];
    if (rawComponents is List<Object?>) {
      for (final entry in rawComponents) {
        components.add(_component(entry));
      }
    }

    final apps = <CatalogApp>[];
    final rawApps = decoded['apps'];
    if (rawApps is List<Object?>) {
      for (final entry in rawApps) {
        apps.add(_app(entry));
      }
    }

    if (components.isEmpty && apps.isEmpty) {
      throw const RemoteCatalogException(
        'The component catalog lists nothing.',
      );
    }

    DateTime? generated;
    final rawGenerated = decoded['generated'];
    if (rawGenerated is String) {
      generated = DateTime.tryParse(rawGenerated);
    }

    return CatalogSnapshot(
      components: components,
      apps: apps,
      generated: generated,
    );
  }

  static ComponentRelease _component(Object? entry) {
    if (entry is! Map<String, Object?>) {
      throw const RemoteCatalogException('A component entry is not an object.');
    }
    final name = _text(entry['component'], 'component');
    StackComponent? component;
    for (final value in StackComponent.values) {
      if (value.directoryName == name) {
        component = value;
        break;
      }
    }
    if (component == null) {
      throw RemoteCatalogException('Unknown component "$name".');
    }
    final urls = _urls(entry['urls']);
    return ComponentRelease(
      component: component,
      version: _text(entry['version'], 'version'),
      installName: _text(entry['installName'], 'installName'),
      url: urls.first,
      mirrors: urls.sublist(1),
      sha256: _sha256(entry['sha256']),
      sizeBytes: _size(entry['size']),
      product: _optionalText(entry['product']),
      notes: _optionalText(entry['notes']),
      resolver: _optionalText(entry['resolver']),
    );
  }

  static CatalogApp _app(Object? entry) {
    if (entry is! Map<String, Object?>) {
      throw const RemoteCatalogException('An app entry is not an object.');
    }
    final urls = _urls(entry['urls']);
    return CatalogApp(
      id: _text(entry['id'], 'id'),
      name: _text(entry['name'], 'name'),
      version: _text(entry['version'], 'version'),
      installName: _text(entry['installName'], 'installName'),
      url: urls.first,
      mirrors: urls.sublist(1),
      sha256: _sha256(entry['sha256']),
      sizeBytes: _size(entry['size']),
      notes: _optionalText(entry['notes']),
    );
  }

  static List<String> _urls(Object? value) {
    final raw = value is List
        ? value
        : value is String
        ? [value]
        : const [];
    final urls = <String>[];
    for (final entry in raw) {
      if (entry is! String) {
        continue;
      }
      final uri = Uri.tryParse(entry.trim());
      if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
        throw RemoteCatalogException(
          'Only HTTPS download URLs are accepted (got "$entry").',
        );
      }
      urls.add(entry.trim());
    }
    if (urls.isEmpty) {
      throw const RemoteCatalogException(
        'A catalog entry has no HTTPS download URL.',
      );
    }
    return urls;
  }

  static String _text(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw RemoteCatalogException('A catalog entry has no $field.');
    }
    return value.trim();
  }

  static String? _optionalText(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String _sha256(Object? value) {
    if (value is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
      throw const RemoteCatalogException(
        'A catalog entry has an invalid SHA-256 digest.',
      );
    }
    return value.toLowerCase();
  }

  static int? _size(Object? value) =>
      value is int && value > 0 ? value : null;
}

typedef RemoteBytesFetcher = Future<List<int>> Function(Uri uri);
typedef RemoteTextFetcher = Future<String> Function(Uri uri);

/// Fetches and verifies [CatalogSnapshot] manifests.
class RemoteCatalog {
  RemoteCatalog({
    required this.manifestUri,
    required this.publicKey,
    RemoteBytesFetcher? fetchBytes,
    RemoteTextFetcher? fetchText,
  }) : _fetchBytes = fetchBytes ?? _httpBytes,
       _fetchText = fetchText ?? _httpText;

  final Uri manifestUri;

  /// Base64 Ed25519 public key from the build.
  final String publicKey;

  final RemoteBytesFetcher _fetchBytes;
  final RemoteTextFetcher _fetchText;

  /// Builds a client from the build's defines, or null when none is configured.
  static RemoteCatalog? fromConfig({
    String manifestUrl = AppInfo.componentManifestUrl,
    String publicKey = AppInfo.updatePublicKey,
  }) {
    final url = manifestUrl.trim();
    final key = publicKey.trim();
    if (url.isEmpty || key.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
      return null;
    }
    return RemoteCatalog(manifestUri: uri, publicKey: key);
  }

  /// Fetches the manifest, verifies its signature, and parses it.
  Future<CatalogSnapshot> fetch() async {
    if (manifestUri.scheme != 'https' || !manifestUri.hasAuthority) {
      throw const RemoteCatalogException(
        'The component catalog must be served over HTTPS.',
      );
    }
    final bytes = await _fetchBytes(manifestUri);
    if (bytes.length > 1024 * 1024) {
      throw const RemoteCatalogException('The component catalog is too large.');
    }

    final signatureUri = manifestUri.replace(
      path: '${manifestUri.path}.sig',
    );
    final encoded = (await _fetchText(signatureUri)).trim();
    if (encoded.isEmpty) {
      throw const RemoteCatalogException(
        'The component catalog has no signature.',
      );
    }

    final List<int> signatureBytes;
    try {
      signatureBytes = base64Decode(encoded.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const RemoteCatalogException(
        'The component catalog signature is not valid base64.',
      );
    }
    if (signatureBytes.length != 64) {
      throw const RemoteCatalogException(
        'The component catalog signature is not valid.',
      );
    }

    final List<int> keyBytes;
    try {
      keyBytes = base64Decode(publicKey.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw const RemoteCatalogException(
        'The update public key configured in this build is invalid.',
      );
    }
    if (keyBytes.length != 32) {
      throw const RemoteCatalogException(
        'The update public key configured in this build is invalid.',
      );
    }

    final algorithm = Ed25519();
    final bool valid;
    try {
      valid = await algorithm.verify(
        bytes,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on ArgumentError {
      throw const RemoteCatalogException(
        'The component catalog signature could not be checked.',
      );
    }
    if (!valid) {
      throw const RemoteCatalogException(
        'The component catalog signature is not valid. It was not used.',
      );
    }

    return CatalogSnapshot.parse(utf8.decode(bytes));
  }

  static Future<List<int>> _httpBytes(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'StackPilot');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw RemoteCatalogException(
          'The catalog server returned HTTP ${response.statusCode}.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const RemoteCatalogException(
            'The component catalog is too large.',
          );
        }
      }
      return bytes;
    } on SocketException catch (error) {
      throw RemoteCatalogException('Could not reach the catalog: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _httpText(Uri uri) async =>
      utf8.decode(await _httpBytes(uri));
}
