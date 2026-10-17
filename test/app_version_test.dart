import 'package:clubtivi/data/services/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppVersion.parse', () {
    test('reads the numeric core and ignores the build number', () {
      final version = AppVersion.parse('0.4.0+5');

      expect(version.major, 0);
      expect(version.minor, 4);
      expect(version.patch, 0);
      expect(version.isPreRelease, isFalse);
      expect(version.toString(), '0.4.0');
    });

    test('accepts a leading v and pre-release identifiers', () {
      final version = AppVersion.parse('v1.2.3-rc1');

      expect(version.toString(), '1.2.3-rc1');
      expect(version.isPreRelease, isTrue);
      expect(version.preRelease, ['rc1']);
    });

    test('missing parts count as zero', () {
      expect(AppVersion.parse('1.2').toString(), '1.2.0');
    });

    test('garbage does not pretend to be a version', () {
      expect(AppVersion.parse('nightly').toString(), '0.0.0');
      expect(AppVersion.parse('').toString(), '0.0.0');
    });
  });

  group('compareAppVersions', () {
    test('orders the numeric parts', () {
      expect(compareAppVersions('0.5.0', '0.4.0'), greaterThan(0));
      expect(compareAppVersions('0.4.1', '0.4.0'), greaterThan(0));
      expect(compareAppVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareAppVersions('0.4.0', '0.4.0'), 0);
      expect(compareAppVersions('0.3.9', '0.4.0'), lessThan(0));
    });

    test('ignores the build number', () {
      expect(compareAppVersions('0.4.0+7', '0.4.0+5'), 0);
    });

    test('a pre-release comes before its release', () {
      expect(compareAppVersions('0.5.0', '0.5.0-rc1'), greaterThan(0));
      expect(compareAppVersions('0.5.0-rc1', '0.5.0'), lessThan(0));
      expect(compareAppVersions('0.5.0-rc2', '0.5.0-rc1'), greaterThan(0));
      expect(compareAppVersions('0.5.0-beta', '0.5.0-alpha'), greaterThan(0));
    });

    test('numeric identifiers rank below alphanumeric ones', () {
      expect(compareAppVersions('1.0.0-2', '1.0.0-alpha'), lessThan(0));
    });

    test('an unknown tag never looks newer than a real version', () {
      expect(compareAppVersions('nightly', '0.4.0'), lessThan(0));
      expect(AppVersion.parse('nightly').isNewerThan('0.4.0'), isFalse);
      expect(AppVersion.parse('').isNewerThan('0.0.1'), isFalse);
    });
  });

  group('isNewerThan', () {
    test('a stable release is newer than the release candidate running', () {
      expect(AppVersion.parse('0.5.0').isNewerThan('0.5.0-rc1'), isTrue);
      expect(AppVersion.parse('0.5.0-rc1').isNewerThan('0.5.0'), isFalse);
    });

    test('the same version is not an update', () {
      expect(AppVersion.parse('0.4.0').isNewerThan('0.4.0+5'), isFalse);
    });
  });
}
