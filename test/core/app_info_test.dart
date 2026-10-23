import 'package:flutter_test/flutter_test.dart';
import 'package:stackpilot/core/app_info.dart';

void main() {
  group('AppVersion', () {
    test('parses plain and prefixed versions', () {
      expect(AppVersion.tryParse('1.2.3')?.toString(), '1.2.3');
      expect(AppVersion.tryParse(' v2.0 ')?.toString(), '2.0');
      expect(AppVersion.tryParse('1.0.0-beta.1')?.toString(), '1.0.0-beta.1');
    });

    test('ignores build metadata', () {
      final version = AppVersion.tryParse('1.4.2+31');

      expect(version?.toString(), '1.4.2');
      expect(version?.compareTo(AppVersion.tryParse('1.4.2')!), 0);
    });

    test('rejects values that are not versions', () {
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.x.0'), isNull);
      expect(AppVersion.tryParse('-1.0.0'), isNull);
    });

    test('compares numeric segments, not strings', () {
      final older = AppVersion.tryParse('1.2.9')!;
      final newer = AppVersion.tryParse('1.2.10')!;

      expect(newer.isNewerThan(older), isTrue);
      expect(older.isNewerThan(newer), isFalse);
    });

    test('treats a pre-release as older than its release', () {
      final beta = AppVersion.tryParse('2.0.0-beta.2')!;
      final release = AppVersion.tryParse('2.0.0')!;

      expect(release.isNewerThan(beta), isTrue);
      expect(beta.isNewerThan(release), isFalse);
      expect(
        AppVersion.tryParse('2.0.0-beta.10')!
            .isNewerThan(AppVersion.tryParse('2.0.0-beta.9')!),
        isTrue,
      );
    });

    test('compares versions with different segment counts', () {
      expect(
        AppVersion.tryParse('1.2')!.compareTo(AppVersion.tryParse('1.2.0')!),
        0,
      );
      expect(
        AppVersion.tryParse('1.3')!.isNewerThan(AppVersion.tryParse('1.2.9')!),
        isTrue,
      );
    });
  });

  group('ReleaseChannel', () {
    test('parses the known channels', () {
      expect(ReleaseChannel.parse('preview'), ReleaseChannel.preview);
      expect(ReleaseChannel.parse('STABLE'), ReleaseChannel.stable);
    });

    test('falls back to stable for unknown or missing values', () {
      expect(ReleaseChannel.parse(null), ReleaseChannel.stable);
      expect(ReleaseChannel.parse('nightly'), ReleaseChannel.stable);
    });

    test('recognizes only the supported channel names', () {
      expect(ReleaseChannel.isKnown('stable'), isTrue);
      expect(ReleaseChannel.isKnown(' Preview '), isTrue);
      expect(ReleaseChannel.isKnown('nightly'), isFalse);
      expect(ReleaseChannel.isKnown(null), isFalse);
    });
  });
}
