import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The file was published, but not with the bytes the release says it has.
class ChecksumMismatch implements Exception {
  ChecksumMismatch({
    required this.fileName,
    required this.expected,
    required this.actual,
  });

  final String fileName;
  final String expected;
  final String actual;

  @override
  String toString() =>
      'ChecksumMismatch($fileName: expected $expected, got $actual)';

  /// Message for the user: says which file and which hashes, without dumping
  /// the whole manifest.
  String get message =>
      'The checksum of $fileName does not match the release manifest. '
      'The download was discarded and nothing was installed.';
}

/// The release does not say which hash the asset should have, so it cannot be
/// trusted. Verification fails closed: no manifest, no download.
class ChecksumUnavailable implements Exception {
  ChecksumUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'ChecksumUnavailable($reason)';

  String get message => 'Cannot verify the download: $reason';
}

/// Lowercase SHA-256 of a file, read in chunks so a 30 MB package does not have
/// to fit in memory.
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Lowercase SHA-256 of some bytes.
String sha256OfBytes(List<int> bytes) => sha256.convert(bytes).toString();

final RegExp _manifestLine = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');

/// Looks up [assetName] in a `sha256sum` manifest and returns its hash.
///
/// Accepts the formats `sha256sum` and `certutil` produce — `hash  name`,
/// `hash *name`, `hash name` — with CRLF or LF, comments and blank lines, and
/// paths instead of bare names (`/tmp/release/clubTivi-....zip`). Names are
/// compared by file name and case-insensitively; the hash comes back lowercase.
///
/// Returns `null` when the asset is not listed, which callers must treat as
/// "cannot verify", never as "verified".
String? hashFromManifest(String manifest, String assetName) {
  final wanted = _baseName(assetName).toLowerCase();
  if (wanted.isEmpty) return null;

  for (final rawLine in const LineSplitter().convert(manifest)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final match = _manifestLine.firstMatch(line);
    if (match == null) continue;

    final listed = match.group(2)!.trim();
    if (_baseName(listed).toLowerCase() == wanted) {
      return match.group(1)!.toLowerCase();
    }
  }
  return null;
}

/// Throws [ChecksumMismatch] unless [file] hashes to [expected].
///
/// Returns the hash it computed, so the caller can show it to the user.
Future<String> verifyFileChecksum(File file, String expected) async {
  final actual = await sha256OfFile(file);
  if (actual != expected.toLowerCase()) {
    throw ChecksumMismatch(
      fileName: _baseName(file.path),
      expected: expected.toLowerCase(),
      actual: actual,
    );
  }
  return actual;
}

/// Last component of a path, whatever separator it uses.
String _baseName(String path) {
  final parts = path.trim().split(RegExp(r'[\\/]'));
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].trim().isNotEmpty) return parts[i].trim();
  }
  return '';
}
