import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';
import 'release_checksum.dart';

/// Repository the update check reads: el fork que publica los releases de esta
/// build. Se puede apuntar a otro en tiempo de compilación:
///
///     flutter build windows --dart-define=CLUBTIVI_UPDATE_REPO=you/clubTivi
const String _repo = String.fromEnvironment(
  'CLUBTIVI_UPDATE_REPO',
  defaultValue: 'YHOYO/clubTivi',
);

/// Version the running build reports. It has to match `version:` in
/// pubspec.yaml, which is what the release tag is derived from; the release
/// assistant bumps both, and test/version_consistency_test.dart fails if they
/// ever drift apart.
const _currentVersion = '0.5.3';

/// Everything the app needs from a published release: its notes, the APK for
/// Android, and the portable ZIP with the manifest that proves its checksum.
class ReleaseInfo {
  final String tagName;
  final String version;
  final String htmlUrl;
  final String? apkDownloadUrl;
  final String? windowsZipUrl;
  final String? windowsZipName;
  final String? checksumUrl;
  final String body;
  final DateTime publishedAt;

  ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.htmlUrl,
    this.apkDownloadUrl,
    this.windowsZipUrl,
    this.windowsZipName,
    this.checksumUrl,
    required this.body,
    required this.publishedAt,
  });

  bool get isNewer => AppVersion.parse(version).isNewerThan(_currentVersion);

  /// The release publishes both the portable ZIP and the manifest, so the
  /// package can be verified before it is offered.
  bool get hasVerifiedWindowsPackage =>
      windowsZipUrl != null && windowsZipName != null && checksumUrl != null;
}

/// A downloaded package that already matched the release's SHA-256 manifest.
class VerifiedDownload {
  const VerifiedDownload({
    required this.file,
    required this.sha256,
    required this.assetName,
  });

  final File file;
  final String sha256;
  final String assetName;

  int get sizeBytes => file.existsSync() ? file.lengthSync() : 0;
}

/// Progress phases, so the UI can say what is happening during a 30 MB download.
enum DownloadPhase { manifest, download, verify }

class AppUpdateService {
  static final Dio _dio = Dio();
  static const _channel = MethodChannel('io.github.clubanderson.clubtivi/installer');

  static String get currentVersion => _currentVersion;

  /// Repository the app checks, for logging and for the "release page" link.
  static String get repository => _repo;

  /// Check GitHub for the latest release.
  static Future<ReleaseInfo?> checkForUpdate() async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$_repo/releases/latest',
        options: Options(
          headers: {'Accept': 'application/vnd.github.v3+json'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode != 200) return null;
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;
      return parseLatestRelease(data);
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Turns the GitHub `releases/latest` payload into a [ReleaseInfo].
  ///
  /// Kept pure and public so the asset selection can be tested against the
  /// exact JSON GitHub returns, without hitting the network.
  static ReleaseInfo? parseLatestRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    if (tag.isEmpty) return null;

    final version = tag.replaceFirst(RegExp(r'^[vV]'), '');

    String? apkUrl;
    String? zipUrl;
    String? zipName;
    String? checksumUrl;

    for (final raw in (json['assets'] as List<dynamic>? ?? const <dynamic>[])) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String? ?? '').trim();
      final url = raw['browser_download_url'] as String?;
      if (name.isEmpty || url == null || url.isEmpty) continue;

      final lower = name.toLowerCase();
      if (apkUrl == null && lower.endsWith('.apk')) apkUrl = url;
      if (checksumUrl == null && lower == 'sha256sums.txt') checksumUrl = url;
      // Only the Windows portable package; a release may carry other zips later.
      if (zipUrl == null && lower.endsWith('.zip') && lower.contains('windows')) {
        zipUrl = url;
        zipName = name;
      }
    }

    return ReleaseInfo(
      tagName: tag,
      version: version,
      htmlUrl: json['html_url'] as String? ?? '',
      apkDownloadUrl: apkUrl,
      windowsZipUrl: zipUrl,
      windowsZipName: zipName,
      checksumUrl: checksumUrl,
      body: json['body'] as String? ?? '',
      publishedAt:
          DateTime.tryParse(json['published_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }

  /// Downloads the release's portable package and verifies it against the
  /// release's own `SHA256SUMS.txt` before returning it.
  ///
  /// Fails closed: if the manifest is missing, does not list the asset, or the
  /// hash does not match, this throws and deletes the file. Callers must not
  /// offer an update until this returns.
  static Future<VerifiedDownload> downloadVerifiedPackage(
    ReleaseInfo release, {
    void Function(DownloadPhase phase)? onPhase,
    void Function(double progress)? onProgress,
    Directory? into,
  }) {
    final assetUrl = release.windowsZipUrl;
    final assetName = release.windowsZipName;
    final checksumUrl = release.checksumUrl;

    if (assetUrl == null || assetName == null) {
      throw ChecksumUnavailable('this release has no portable Windows package');
    }
    if (checksumUrl == null) {
      throw ChecksumUnavailable('this release has no SHA256SUMS.txt manifest');
    }

    return downloadVerifiedAsset(
      assetUrl: assetUrl,
      assetName: assetName,
      checksumUrl: checksumUrl,
      onPhase: onPhase,
      onProgress: onProgress,
      into: into,
    );
  }

  /// Downloads [assetUrl], checks it against [checksumUrl] and only then
  /// returns it.
  static Future<VerifiedDownload> downloadVerifiedAsset({
    required String assetUrl,
    required String assetName,
    required String checksumUrl,
    void Function(DownloadPhase phase)? onPhase,
    void Function(double progress)? onProgress,
    Directory? into,
  }) async {
    onPhase?.call(DownloadPhase.manifest);
    onProgress?.call(0);

    final manifestResponse = await _dio.get<String>(
      checksumUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final manifest = manifestResponse.data;
    if (manifest == null || manifest.trim().isEmpty) {
      throw ChecksumUnavailable('the release manifest is empty');
    }

    final expected = hashFromManifest(manifest, assetName);
    if (expected == null) {
      throw ChecksumUnavailable('the manifest does not list $assetName');
    }

    final directory = into ??
        Directory('${(await getTemporaryDirectory()).path}/clubtivi-updates');
    await directory.create(recursive: true);
    final file = File('${directory.path}/$assetName');
    if (await file.exists()) await file.delete();

    onPhase?.call(DownloadPhase.download);
    await _dio.download(
      assetUrl,
      file.path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );

    onPhase?.call(DownloadPhase.verify);
    try {
      final actual = await verifyFileChecksum(file, expected);
      onProgress?.call(1);
      return VerifiedDownload(file: file, sha256: actual, assetName: assetName);
    } on ChecksumMismatch {
      // A truncated or tampered file must not be left lying around for
      // somebody else to run.
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  /// Download APK and trigger install via native FileProvider intent.
  static Future<void> downloadAndInstall(
    String apkUrl, {
    required void Function(double progress) onProgress,
    required void Function(String error) onError,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/clubtivi-update.apk';

      await _dio.download(
        apkUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress(received / total);
        },
      );

      if (Platform.isAndroid) {
        await _channel.invokeMethod('installApk', {'filePath': filePath});
      }
    } catch (e) {
      onError('Install failed: $e');
    }
  }
}
