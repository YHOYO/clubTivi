import 'package:dio/dio.dart';

import '../../models/show.dart';
import 'debrid_service.dart';

class PutioService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://api.put.io/v2';

  PutioService({required this.apiToken, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': 'Bearer $apiToken'};
  }

  @override
  String get serviceName => 'put.io';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    // put.io doesn't have a direct cache check — return empty
    return {};
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    // put.io uses transfers, not link unrestriction
    final result = await resolveFromMagnet(link);
    if (result == null) throw Exception('put.io: could not resolve link');
    return result;
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post(
      '/transfers/add',
      data: FormData.fromMap({'url': magnetLink}),
    );
    final transfer = addResp.data['transfer'] as Map<String, dynamic>? ?? {};
    final transferId = transfer['id'] as int? ?? 0;

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final infoResp = await _dio.get('/transfers/$transferId');
      final data = infoResp.data['transfer'] as Map<String, dynamic>? ?? {};
      final status = data['status'] as String? ?? '';
      final pct = data['percent_done'] as int? ?? 0;
      onProgress?.call(status, pct);
      if (status == 'COMPLETED' || status == 'SEEDING') {
        final fileId = data['file_id'] as int? ?? 0;
        final url = '$_baseUrl/files/$fileId/download?oauth_token=$apiToken';
        return ResolvedStream(
          url: url,
          filename: data['name'] as String? ?? 'unknown',
          source: 'put.io',
        );
      }
      if (status == 'ERROR') {
        throw Exception('put.io error: ${data['error_message']}');
      }
    }
    throw Exception('Timed out waiting for put.io (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/info');
      return true;
    } catch (_) {
      return false;
    }
  }
}
