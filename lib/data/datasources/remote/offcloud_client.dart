import 'package:dio/dio.dart';

import '../../models/show.dart';
import 'debrid_service.dart';

class OffcloudService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://offcloud.com/api';

  OffcloudService({required this.apiToken, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': apiToken};
  }

  @override
  String get serviceName => 'Offcloud';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.post('/cache', data: {'hashes': hashes});
    final data = response.data as Map<String, dynamic>? ?? {};
    final cachedItems = data['cachedItems'] as List? ?? [];
    final result = <String, List<DebridFile>>{};
    for (final hash in cachedItems) {
      if (hash is String) {
        result[hash.toLowerCase()] = [
          DebridFile(id: 0, filename: 'cached', filesize: 0),
        ];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.post('/cloud', data: {'url': link});
    final data = response.data as Map<String, dynamic>? ?? {};
    return ResolvedStream(
      url: data['url'] as String? ?? '',
      filename: data['fileName'] as String? ?? 'unknown',
      source: 'offcloud',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post('/cloud', data: {'url': magnetLink});
    final data = addResp.data as Map<String, dynamic>? ?? {};
    final requestId = data['requestId'] as String? ?? '';
    final directUrl = data['url'] as String?;
    if (directUrl != null && directUrl.isNotEmpty) {
      return ResolvedStream(
        url: directUrl,
        filename: data['fileName'] as String? ?? 'unknown',
        source: 'offcloud',
      );
    }

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final statusResp = await _dio.get(
        '/cloud/status',
        queryParameters: {'requestId': requestId},
      );
      final sData = statusResp.data as Map<String, dynamic>? ?? {};
      final status = sData['status'] as String? ?? '';
      onProgress?.call(status, 50);
      if (status == 'downloaded') {
        final url = sData['url'] as String? ?? '';
        return ResolvedStream(
          url: url,
          filename: sData['fileName'] as String? ?? 'unknown',
          source: 'offcloud',
        );
      }
      if (status == 'error') {
        throw Exception('Offcloud error');
      }
    }
    throw Exception('Timed out waiting for Offcloud (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/stats');
      return true;
    } catch (_) {
      return false;
    }
  }
}
