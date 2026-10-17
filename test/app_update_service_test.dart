import 'dart:io';

import 'package:clubtivi/data/services/app_update_service.dart';
import 'package:clubtivi/data/services/release_checksum.dart';
import 'package:flutter_test/flutter_test.dart';

/// A payload shaped like GitHub's `releases/latest`, with the asset names the
/// release workflow actually publishes.
Map<String, dynamic> _payload({String tag = 'v0.5.0'}) => <String, dynamic>{
      'tag_name': tag,
      'html_url': 'https://github.com/clubanderson/clubTivi/releases/tag/$tag',
      'body': 'Release notes',
      'published_at': '2026-10-16T09:30:00Z',
      'assets': <Map<String, String>>[
        {
          'name': 'clubtivi-android.apk',
          'browser_download_url':
              'https://example.test/clubtivi-android.apk',
        },
        {
          'name': 'clubtivi-android.aab',
          'browser_download_url':
              'https://example.test/clubtivi-android.aab',
        },
        {
          'name': 'clubtivi-ios-unsigned.ipa',
          'browser_download_url':
              'https://example.test/clubtivi-ios-unsigned.ipa',
        },
        {
          'name': 'clubtivi-macos.dmg',
          'browser_download_url': 'https://example.test/clubtivi-macos.dmg',
        },
        {
          'name': 'clubTivi-windows-x64-0.5.0.zip',
          'browser_download_url':
              'https://example.test/clubTivi-windows-x64-0.5.0.zip',
        },
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://example.test/SHA256SUMS.txt',
        },
        {
          'name': 'clubtivi-linux-x64.tar.gz',
          'browser_download_url':
              'https://example.test/clubtivi-linux-x64.tar.gz',
        },
      ],
      'assets_url': 'https://api.github.com/repos/x/y/releases/1/assets',
    };

void main() {
  group('parseLatestRelease', () {
    test('picks the portable zip, its manifest and the APK', () {
      final release = AppUpdateService.parseLatestRelease(_payload());

      expect(release, isNotNull);
      expect(release!.tagName, 'v0.5.0');
      expect(release.version, '0.5.0');
      expect(release.apkDownloadUrl, endsWith('clubtivi-android.apk'));
      expect(release.windowsZipName, 'clubTivi-windows-x64-0.5.0.zip');
      expect(release.windowsZipUrl, endsWith('clubTivi-windows-x64-0.5.0.zip'));
      expect(release.checksumUrl, endsWith('SHA256SUMS.txt'));
      expect(release.hasVerifiedWindowsPackage, isTrue);
      expect(release.htmlUrl, contains('/releases/tag/v0.5.0'));
      expect(release.publishedAt, DateTime.utc(2026, 10, 16, 9, 30));
    });

    test('without a manifest the package cannot be verified', () {
      final payload = _payload();
      (payload['assets'] as List)
          .removeWhere((asset) => asset['name'] == 'SHA256SUMS.txt');

      final release = AppUpdateService.parseLatestRelease(payload);

      expect(release!.windowsZipUrl, isNotNull);
      expect(release.hasVerifiedWindowsPackage, isFalse);
    });

    test('ignores zips from other platforms', () {
      final payload = _payload();
      (payload['assets'] as List).insert(4, {
        'name': 'clubtivi-macos-universal.zip',
        'browser_download_url': 'https://example.test/macos.zip',
      });

      final release = AppUpdateService.parseLatestRelease(payload);

      expect(release!.windowsZipName, 'clubTivi-windows-x64-0.5.0.zip');
    });

    test('needs a tag to mean anything', () {
      expect(AppUpdateService.parseLatestRelease(<String, dynamic>{}), isNull);
      expect(
        AppUpdateService.parseLatestRelease({'tag_name': '  '}),
        isNull,
      );
    });

    test('isNewer compares against the running version', () {
      final newer = AppUpdateService.parseLatestRelease(_payload(tag: 'v99.0.0'));
      final older = AppUpdateService.parseLatestRelease(_payload(tag: 'v0.0.1'));
      final same = AppUpdateService.parseLatestRelease(
        _payload(tag: 'v${AppUpdateService.currentVersion}'),
      );

      expect(newer!.isNewer, isTrue);
      expect(older!.isNewer, isFalse);
      expect(same!.isNewer, isFalse);
    });
  });

  group('downloadVerifiedPackage', () {
    late HttpServer server;
    late Directory work;
    late List<int> package;
    late String manifest;
    late List<String> requestedPaths;

    setUp(() async {
      requestedPaths = <String>[];
      package = List<int>.generate(4096, (i) => (i * 31) % 256);
      manifest = '${sha256OfBytes(package)}  clubTivi-windows-x64-0.5.0.zip\n';
      work = await Directory.systemTemp.createTemp('clubtivi-update-test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        final response = request.response;
        switch (request.uri.path) {
          case '/SHA256SUMS.txt':
            response.headers.contentType = ContentType('text', 'plain');
            response.write(manifest);
            break;
          case '/package.zip':
            response.headers.contentType =
                ContentType('application', 'octet-stream');
            response.headers.contentLength = package.length;
            response.add(package);
            break;
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await work.exists()) await work.delete(recursive: true);
    });

    String base() => 'http://127.0.0.1:${server.port}';

    ReleaseInfo release({String? checksum}) => ReleaseInfo(
          tagName: 'v0.5.0',
          version: '0.5.0',
          htmlUrl: '${base()}/release',
          windowsZipUrl: '${base()}/package.zip',
          windowsZipName: 'clubTivi-windows-x64-0.5.0.zip',
          checksumUrl: checksum,
          body: '',
          publishedAt: DateTime(2026, 10, 16),
        );

    test('returns the file once the hash matches the manifest', () async {
      final phases = <DownloadPhase>[];
      final progress = <double>[];

      final verified = await AppUpdateService.downloadVerifiedPackage(
        release(checksum: '${base()}/SHA256SUMS.txt'),
        into: work,
        onPhase: phases.add,
        onProgress: progress.add,
      );

      expect(verified.sha256, sha256OfBytes(package));
      expect(verified.assetName, 'clubTivi-windows-x64-0.5.0.zip');
      expect(await verified.file.exists(), isTrue);
      expect(await verified.file.length(), package.length);
      expect(verified.sizeBytes, package.length);
      expect(phases, [
        DownloadPhase.manifest,
        DownloadPhase.download,
        DownloadPhase.verify,
      ]);
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
    });

    test('discards the download when the bytes do not match', () async {
      manifest = '${sha256OfBytes([0, 1, 2, 3])}  clubTivi-windows-x64-0.5.0.zip\n';

      await expectLater(
        AppUpdateService.downloadVerifiedPackage(
          release(checksum: '${base()}/SHA256SUMS.txt'),
          into: work,
        ),
        throwsA(isA<ChecksumMismatch>()),
      );

      final leftover = File('${work.path}/clubTivi-windows-x64-0.5.0.zip');
      expect(leftover.existsSync(), isFalse,
          reason: 'a package that failed verification must not stay on disk');
    });

    test('fails closed when the manifest does not list the asset', () async {
      manifest = '${sha256OfBytes(package)}  otro-fichero.zip\n';

      await expectLater(
        AppUpdateService.downloadVerifiedPackage(
          release(checksum: '${base()}/SHA256SUMS.txt'),
          into: work,
        ),
        throwsA(isA<ChecksumUnavailable>()),
      );

      expect(requestedPaths, isNot(contains('/package.zip')),
          reason: 'nothing should be downloaded before the hash is known');
    });

    test('refuses a release with no manifest', () {
      expect(
        () => AppUpdateService.downloadVerifiedPackage(
          release(),
          into: work,
        ),
        throwsA(isA<ChecksumUnavailable>()),
      );
      expect(requestedPaths, isEmpty);
    });

    test('refuses a release with no package', () {
      final bare = ReleaseInfo(
        tagName: 'v0.5.0',
        version: '0.5.0',
        htmlUrl: '${base()}/release',
        checksumUrl: '${base()}/SHA256SUMS.txt',
        body: '',
        publishedAt: DateTime(2026, 10, 16),
      );

      expect(
        () => AppUpdateService.downloadVerifiedPackage(bare, into: work),
        throwsA(isA<ChecksumUnavailable>()),
      );
    });
  });
}
