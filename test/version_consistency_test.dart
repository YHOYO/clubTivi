import 'dart:io';

import 'package:clubtivi/data/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('version', () {
    test('the app reports the version declared in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match =
          RegExp(r'^\s*version:\s*([^\s#]+)', multiLine: true).firstMatch(pubspec);

      expect(match, isNotNull,
          reason: 'pubspec.yaml should declare a version: X.Y.Z+N line');

      final declared = match!.group(1)!.split('+').first;
      expect(
        AppUpdateService.currentVersion,
        declared,
        reason: 'AppUpdateService.currentVersion is what the update check '
            'compares against the published tag; pubspec.yaml is what the '
            'release is built from. tools/release.ps1 bumps both — if they '
            'disagree, the app either misses updates or claims to be newer '
            'than it is.',
      );
    });
  });
}
