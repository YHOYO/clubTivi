import 'package:dio/dio.dart';

import '../../models/show.dart';
import 'debrid_service.dart';

class DebridLinkService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://debrid-link.com/api/v2';

  DebridLinkService({required this.apiToken, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': 'Bearer $apiToken'};
  }

  @override
  String get serviceName => 'Debrid-Link';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.get(
      '/seedbox/cached',
      queryParameters: {'url': hashes.join(',')},
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    final result = <String, List<DebridFile>>{};
    for (final hash in hashes) {
      final lower = hash.toLowerCase();
      if (value.containsKey(lower) && value[lower] != null) {
        result[lower] = [DebridFile(id: 0, filename: 'cached', filesize: 0)];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.post(
      '/downloader/add',
      data: FormData.fromMap({'url': link}),
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    return ResolvedStream(
      url: value['downloadUrl'] as String? ?? '',
      filename: value['filename'] as String? ?? 'unknown',
      filesize: (value['filesize'] as num?)?.toInt(),
      source: 'debrid-link',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post(
      '/seedbox/add',
      data: FormData.fromMap({'url': magnetLink, 'async': true}),
    );
    final data = addResp.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    final torrentId = value['id'] as String? ?? '';

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final infoResp = await _dio.get('/seedbox/list');
      final list = (infoResp.data['value'] as List?) ?? [];
      final torrent = list.firstWhere(
        (t) => t['id'] == torrentId,
        orElse: () => null,
      );
      if (torrent == null) throw Exception('Debrid-Link: torrent not found');
      final status = torrent['status'] as int? ?? 0;
      onProgress?.call('status:$status', status == 100 ? 100 : 50);
      // status 100 = ready
      if (status == 100) {
        final files = torrent['files'] as List? ?? [];
        if (files.isNotEmpty) {
          final first = files[0] as Map<String, dynamic>;
          final dlUrl = first['downloadUrl'] as String? ?? '';
          if (dlUrl.isNotEmpty) {
            return ResolvedStream(
              url: dlUrl,
              filename: first['name'] as String? ?? 'unknown',
              filesize: (first['size'] as num?)?.toInt(),
              source: 'debrid-link',
            );
          }
        }
      }
      if (status < 0) {
        throw Exception('Debrid-Link error status: $status');
      }
    }
    throw Exception('Timed out waiting for Debrid-Link (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/infos');
      return true;
    } catch (_) {
      return false;
    }
  }
}
