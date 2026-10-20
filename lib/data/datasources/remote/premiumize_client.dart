import 'package:dio/dio.dart';

import '../../models/show.dart';
import 'debrid_service.dart';

class PremiumizeService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://www.premiumize.me';

  PremiumizeService({required this.apiToken, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  Map<String, String> get _params => {'apikey': apiToken};

  @override
  String get serviceName => 'Premiumize';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.get(
      '/api/cache/check',
      queryParameters: {..._params, 'items[]': hashes},
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final statuses = data['response'] as List? ?? [];
    final result = <String, List<DebridFile>>{};
    for (var i = 0; i < hashes.length && i < statuses.length; i++) {
      if (statuses[i] == true) {
        result[hashes[i].toLowerCase()] = [
          DebridFile(id: 0, filename: 'cached', filesize: 0),
        ];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    // Premiumize uses directdl for magnet/torrent links
    final response = await _dio.post(
      '/api/transfer/directdl',
      data: FormData.fromMap({..._params, 'src': link}),
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final content = data['content'] as List? ?? [];
    if (content.isEmpty) throw Exception('Premiumize: no content returned');
    final first = content[0] as Map<String, dynamic>;
    return ResolvedStream(
      url: first['link'] as String? ?? '',
      filename: first['path'] as String? ?? 'unknown',
      filesize: (first['size'] as num?)?.toInt(),
      source: 'premiumize',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    // Try direct download first (instant if cached)
    try {
      return await unrestrictLink(magnetLink);
    } catch (_) {}

    // Fall back to transfer creation + polling
    final createResp = await _dio.post(
      '/api/transfer/create',
      data: FormData.fromMap({..._params, 'src': magnetLink}),
    );
    final data = createResp.data as Map<String, dynamic>? ?? {};
    final transferId = data['id'] as String? ?? '';

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final listResp = await _dio.get(
        '/api/transfer/list',
        queryParameters: _params,
      );
      final transfers = (listResp.data['transfers'] as List?) ?? [];
      final transfer = transfers.firstWhere(
        (t) => t['id'] == transferId,
        orElse: () => null,
      );
      if (transfer == null) throw Exception('Premiumize: transfer not found');
      final status = transfer['status'] as String? ?? '';
      final progress = ((transfer['progress'] as num?) ?? 0) * 100;
      onProgress?.call(status, progress.toInt());
      if (status == 'finished') {
        final folderId = transfer['folder_id'] as String?;
        if (folderId != null) {
          final browseResp = await _dio.get(
            '/api/folder/list',
            queryParameters: {..._params, 'id': folderId},
          );
          final content = (browseResp.data['content'] as List?) ?? [];
          if (content.isNotEmpty) {
            final first = content[0] as Map<String, dynamic>;
            return ResolvedStream(
              url: first['link'] as String? ?? '',
              filename: first['name'] as String? ?? 'unknown',
              filesize: (first['size'] as num?)?.toInt(),
              source: 'premiumize',
            );
          }
        }
      }
      if (status == 'error' || status == 'deleted') {
        throw Exception('Premiumize status: $status');
      }
    }
    throw Exception('Timed out waiting for Premiumize (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      final resp = await _dio.get(
        '/api/account/info',
        queryParameters: _params,
      );
      return resp.data['status'] == 'success';
    } catch (_) {
      return false;
    }
  }
}
