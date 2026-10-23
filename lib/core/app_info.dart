/// Identity of this StackPilot build.
///
/// The release script passes the version, channel, update URL, and update
/// public key with `--dart-define`, so a build knows what it is without reading
/// a file at runtime. The defaults keep a local development build working.
class AppInfo {
  const AppInfo._();

  static const name = 'StackPilot';

  /// Marketing version, for example `1.2.0`.
  static const version = String.fromEnvironment(
    'STACKPILOT_VERSION',
    defaultValue: '1.0.0',
  );

  /// Build number from `pubspec.yaml` (`1.2.0+7`).
  static const buildNumber = String.fromEnvironment('STACKPILOT_BUILD');

  /// `stable` or `preview`; see [ReleaseChannel].
  static const channelName = String.fromEnvironment(
    'STACKPILOT_CHANNEL',
    defaultValue: 'stable',
  );

  /// HTTPS location of the signed update manifest. Empty disables updates.
  static const updateManifestUrl = String.fromEnvironment(
    'STACKPILOT_UPDATE_URL',
  );

  /// Base64 Ed25519 public key used to verify the update manifest.
  static const updatePublicKey = String.fromEnvironment(
    'STACKPILOT_UPDATE_PUBLIC_KEY',
  );

  static ReleaseChannel get channel => ReleaseChannel.parse(channelName);

  /// `1.2.0` or `1.2.0+7` when a build number is present.
  static String get versionLabel =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

  /// True when this build carries everything needed to check for updates.
  static bool get updatesConfigured =>
      updateManifestUrl.trim().isNotEmpty && updatePublicKey.trim().isNotEmpty;
}

/// Update channel a build follows.
enum ReleaseChannel {
  stable('stable', 'Stable', 'Tested releases only.'),
  preview(
    'preview',
    'Preview',
    'Preview releases plus the newest stable release.',
  );

  const ReleaseChannel(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static ReleaseChannel parse(String? value) {
    final normalized = value?.trim().toLowerCase();
    for (final channel in ReleaseChannel.values) {
      if (channel.id == normalized) {
        return channel;
      }
    }
    return ReleaseChannel.stable;
  }

  /// True when [value] names a channel this build understands.
  static bool isKnown(String? value) {
    final normalized = value?.trim().toLowerCase();
    return ReleaseChannel.values.any((channel) => channel.id == normalized);
  }
}

/// A comparable application version such as `1.4.2` or `2.0.0-beta.1`.
///
/// Build metadata after `+` is ignored, matching semantic versioning. A
/// pre-release sorts before the matching release, so `2.0.0-beta.1` is older
/// than `2.0.0`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion._(this._numbers, this._preRelease);

  final List<int> _numbers;
  final List<String> _preRelease;

  static AppVersion? tryParse(String value) {
    var text = value.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    if (text.isEmpty) {
      return null;
    }

    final plus = text.indexOf('+');
    if (plus >= 0) {
      text = text.substring(0, plus);
    }

    final dash = text.indexOf('-');
    final core = dash >= 0 ? text.substring(0, dash) : text;
    final suffix = dash >= 0 ? text.substring(dash + 1) : '';
    final numbers = <int>[];
    for (final part in core.split('.')) {
      final number = int.tryParse(part);
      if (number == null || number < 0) {
        return null;
      }
      numbers.add(number);
    }
    if (numbers.isEmpty) {
      return null;
    }
    final preRelease = suffix.isEmpty
        ? const <String>[]
        : suffix.split('.').where((part) => part.isNotEmpty).toList();
    return AppVersion._(numbers, preRelease);
  }

  @override
  int compareTo(AppVersion other) {
    final length = _numbers.length > other._numbers.length
        ? _numbers.length
        : other._numbers.length;
    for (var index = 0; index < length; index++) {
      final left = index < _numbers.length ? _numbers[index] : 0;
      final right = index < other._numbers.length ? other._numbers[index] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }

    if (_preRelease.isEmpty && other._preRelease.isEmpty) {
      return 0;
    }
    if (_preRelease.isEmpty) {
      return 1;
    }
    if (other._preRelease.isEmpty) {
      return -1;
    }

    final count = _preRelease.length > other._preRelease.length
        ? _preRelease.length
        : other._preRelease.length;
    for (var index = 0; index < count; index++) {
      if (index >= _preRelease.length) {
        return -1;
      }
      if (index >= other._preRelease.length) {
        return 1;
      }
      final left = _preRelease[index];
      final right = other._preRelease[index];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      final result = (leftNumber != null && rightNumber != null)
          ? leftNumber.compareTo(rightNumber)
          : left.compareTo(right);
      if (result != 0) {
        return result;
      }
    }
    return 0;
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  String toString() {
    final base = _numbers.join('.');
    return _preRelease.isEmpty ? base : '$base-${_preRelease.join('.')}';
  }
}
