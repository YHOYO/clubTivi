import 'dart:io';

import 'package:clubtivi/data/services/release_checksum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sha256OfBytes', () {
    test('matches the published vector for "abc"', () {
      expect(
        sha256OfBytes('abc'.codeUnits),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('hashFromManifest', () {
    const hash =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    test('reads the two-space format sha256sum writes', () {
      final manifest = '$hash  clubTivi-windows-x64-0.5.0.zip\n';
      expect(
        hashFromManifest(manifest, 'clubTivi-windows-x64-0.5.0.zip'),
        hash,
      );
    });

    test('reads the binary-mode star and single spaces', () {
      expect(hashFromManifest('$hash *pkg.zip\n', 'pkg.zip'), hash);
      expect(hashFromManifest('$hash pkg.zip\n', 'pkg.zip'), hash);
    });

    test('handles CRLF, blank lines and comments', () {
      final manifest = '\r\n# generated on CI\r\n'
          '$hash  clubtivi-windows-x64-1.0.0.zip\r\n\r\n';

      expect(
        hashFromManifest(manifest, 'clubtivi-windows-x64-1.0.0.zip'),
        hash,
      );
    });

    test('compares by file name, not by the whole path', () {
      final manifest = '$hash  /tmp/release/clubTivi-windows-x64-0.5.0.zip\n';

      expect(
        hashFromManifest(manifest, 'clubTivi-windows-x64-0.5.0.zip'),
        hash,
      );
    });

    test('is case-insensitive for the file name and lowercases the hash', () {
      final upper = hash.toUpperCase();
      expect(
        hashFromManifest('$upper  CLUBTIVI-WINDOWS-X64-0.5.0.ZIP\n',
            'clubtivi-windows-x64-0.5.0.zip'),
        hash,
      );
    });

    test('returns null when the asset is not listed', () {
      final manifest = '$hash  other.zip\n';
      expect(hashFromManifest(manifest, 'pkg.zip'), isNull);
    });

    test('ignores lines that are not checksums', () {
      const manifest = 'not a manifest\n0000\n$hash  pkg.zip\n';
      expect(hashFromManifest(manifest, 'pkg.zip'), hash);
      expect(hashFromManifest(manifest, 'not a manifest'), isNull);
    });

    test('does not match a truncated hash', () {
      expect(hashFromManifest('${hash.substring(0, 40)}  pkg.zip\n', 'pkg.zip'),
          isNull);
    });
  });

  group('verifyFileChecksum', () {
    late Directory work;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('clubtivi-checksum-test');
    });

    tearDown(() async {
      if (await work.exists()) await work.delete(recursive: true);
    });

    test('returns the hash of a file that matches', () async {
      final file = File('${work.path}/payload.bin');
      await file.writeAsBytes('abc'.codeUnits);

      final actual = await verifyFileChecksum(
        file,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );

      expect(
        actual,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('throws when a single byte changes', () async {
      final file = File('${work.path}/payload.bin');
      await file.writeAsBytes('abd'.codeUnits);

      expect(
        () => verifyFileChecksum(
          file,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
        throwsA(
          isA<ChecksumMismatch>()
              .having((e) => e.fileName, 'fileName', 'payload.bin')
              .having((e) => e.actual,
                  'actual', sha256OfBytes('abd'.codeUnits)),
        ),
      );
    });

    test('the message names the file without dumping the hashes', () {
      final mismatch = ChecksumMismatch(
        fileName: 'pkg.zip',
        expected: 'a' * 64,
        actual: 'b' * 64,
      );

      expect(mismatch.message, contains('pkg.zip'));
      expect(mismatch.message, isNot(contains('a' * 64)));
    });
  });
}
