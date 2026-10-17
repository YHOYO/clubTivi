import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/epg_refresh_service.dart';
import '../../data/services/logo_resolver_service.dart';
import '../../core/feature_gate.dart';
import 'package:dio/dio.dart';

/// Manages IPTV providers: adding, refreshing, channel loading.
class ProviderManager {
  final db.AppDatabase _db;
  final M3uParser _m3uParser = M3uParser();

  ProviderManager(this._db);

  /// Check provider count against tier limit.
  Future<void> _checkProviderLimit() async {
    final existing = await _db.getAllProviders();
    if (existing.length >= FeatureGate.maxProviders) {
      throw ProviderLimitException(FeatureGate.maxProviders);
    }
  }

  /// Add an M3U provider.
  Future<void> addM3uProvider({
    required String id,
    required String name,
    required String url,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(db.ProvidersCompanion.insert(
      id: id,
      name: name,
      type: 'm3u',
      url: Value(url),
    ));
    await refreshProvider(id);
  }

  /// Add an Xtream Codes provider.
  Future<void> addXtreamProvider({
    required String id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(db.ProvidersCompanion.insert(
      id: id,
      name: name,
      type: 'xtream',
      url: Value(url),
      username: Value(username),
      password: Value(password),
    ));
    await refreshProvider(id);
  }

  /// Refresh a provider's channels from its source.
  Future<int> refreshProvider(String providerId) async {
    final providers = await _db.getAllProviders();
    final provider = providers.firstWhere((p) => p.id == providerId);

    List<Channel> channels;
    if (provider.type == 'm3u') {
      final result = await _refreshM3u(provider);
      channels = result.channels;
      await _registerPlaylistEpgSource(provider, result.urlTvg);
    } else if (provider.type == 'xtream') {
      channels = await _refreshXtream(provider);
    } else {
      return 0;
    }

    // Save channels to database
    await _db.upsertChannels(channels.map((c) => db.ChannelsCompanion.insert(
      id: c.id,
      providerId: c.providerId,
      name: c.name,
      tvgId: Value(c.tvgId),
      tvgName: Value(c.tvgName),
      tvgLogo: Value(c.tvgLogo),
      groupTitle: Value(c.groupTitle),
      channelNumber: Value(c.channelNumber),
      streamUrl: c.streamUrl,
      streamType: Value(c.streamType.name),
      httpHeaders: Value(Channel.encodeHttpHeaders(c.httpHeaders)),
      hidden: Value(c.hidden),
    )).toList());

    // Resolve missing logos in background
    _resolveChannelLogos(channels).catchError((_) {});

    return channels.length;
  }

  Future<M3uResult> _refreshM3u(db.Provider provider) async {
    final source = provider.url!;
    final content = isLocalPlaylistPath(source)
        ? await _readLocalPlaylist(source)
        : await _downloadPlaylist(source);
    return _m3uParser.parse(content, providerId: provider.id);
  }

  /// Guide sources for the playlists already in the database.
  ///
  /// Providers added before this existed never registered their guide, and the
  /// grid stayed empty until the channel list was refreshed. This reads only
  /// the header of each playlist (a few KB), so it is cheap at startup.
  Future<int> registerPlaylistEpgSources() async {
    final providers = await _db.getAllProviders();
    var added = 0;
    for (final provider in providers) {
      final source = provider.url;
      if (provider.type != 'm3u' || source == null || source.isEmpty) continue;
      try {
        final header = await _readPlaylistHeader(source);
        final urlTvg = M3uParser.urlTvgFromHeader(header);
        if (await _registerPlaylistEpgSource(provider, urlTvg, refresh: false)) {
          added++;
        }
      } catch (e) {
        debugPrint('[EPG] Could not read the header of ${provider.name}: $e');
      }
    }
    return added;
  }

  /// First few kilobytes of a playlist: enough for the `#EXTM3U` header, where
  /// the guide URL lives.
  Future<String> _readPlaylistHeader(String source) async {
    if (isLocalPlaylistPath(source)) {
      final content = await _readLocalPlaylist(source);
      return content.length > 8192 ? content.substring(0, 8192) : content;
    }
    final response = await Dio(BaseOptions(
      validateStatus: (_) => true,
      followRedirects: true,
    )).get<String>(
      source,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Range': 'bytes=0-8191'},
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    return response.data ?? '';
  }

  /// Register the XMLTV feed a playlist announces in its `#EXTM3U` header.
  ///
  /// Playlists like TDTChannels ship their own guide in `url-tvg`; without this
  /// the grid stays empty and looks broken until the source is added by hand.
  Future<bool> _registerPlaylistEpgSource(
    db.Provider provider,
    String? urlTvg, {
    bool refresh = true,
  }) async {
    if (urlTvg == null || urlTvg.trim().isEmpty) return false;
    final sourceId = '${provider.id}-playlist-epg';

    final sources = await _db.getAllEpgSources();
    final current = sources.where((s) => s.id == sourceId).firstOrNull;
    if (current != null && current.url == urlTvg) return false;

    await _db.upsertEpgSource(db.EpgSourcesCompanion.insert(
      id: sourceId,
      name: '${provider.name} (guide from playlist)',
      url: urlTvg.trim(),
    ));

    // A guide can be tens of megabytes: fetch it in the background so adding a
    // provider never waits for the listings.
    if (refresh) {
      unawaited(EpgRefreshService(_db).refreshSource(sourceId).then((_) {
        debugPrint('[EPG] Playlist guide loaded: $urlTvg');
      }).catchError((Object e) {
        debugPrint('[EPG] Could not load $urlTvg: $e');
      }));
    }
    return true;
  }

  /// Whether a provider URL points at a file on this machine rather than a server.
  ///
  /// Local playlists are stored as `file://` URIs, but a plain Windows or Unix
  /// path is accepted too so a path pasted into the dialog just works.
  static bool isLocalPlaylistPath(String url) {
    if (url.startsWith('file://')) return true;
    if (url.startsWith('http://') || url.startsWith('https://')) return false;
    return File(url).existsSync();
  }

  /// Turn a stored local playlist URL into a path.
  static String localPlaylistPath(String url) =>
      url.startsWith('file://') ? File.fromUri(Uri.parse(url)).path : url;

  /// Render a local path as the `file://` URI the provider URL column holds.
  static String toPlaylistUri(String path) => Uri.file(path).toString();

  Future<String> _readLocalPlaylist(String url) async {
    final file = File(localPlaylistPath(url));
    if (!await file.exists()) {
      throw FileSystemException('Playlist file not found', file.path);
    }
    final bytes = await file.readAsBytes();
    // Playlists are usually UTF-8, but plenty of them are still Latin-1; a
    // wrong guess would turn every accented channel name into mojibake.
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  Future<String> _downloadPlaylist(String url) async {
    final dio = Dio();
    try {
      final response = await dio.get<String>(url);
      return response.data ?? '';
    } finally {
      dio.close();
    }
  }

  Future<List<Channel>> _refreshXtream(db.Provider provider) async {
    final client = XtreamClient(
      baseUrl: provider.url!,
      username: provider.username!,
      password: provider.password!,
    );
    try {
      return await client.getLiveStreams(providerId: provider.id);
    } finally {
      client.dispose();
    }
  }

  Future<void> deleteProvider(String id) async {
    await _db.deleteProvider(id);
  }

  /// Limpia los canales que quedaron de versiones anteriores, cuando borrar un
  /// proveedor solo borraba su fila y dejaba los canales sueltos.
  Future<int> purgeOrphanChannels() async {
    final removed = await _db.purgeOrphanChannels();
    if (removed > 0) {
      debugPrint('[Providers] Removed $removed orphan channels');
    }
    return removed;
  }

  /// Resolve missing logos in background after provider refresh.
  Future<void> _resolveChannelLogos(List<Channel> channels) async {
    await resolveLogosForChannels(channels);
  }

  /// Resolve missing logos for a set of channels.
  /// Public so it can be called at startup for existing DB channels.
  Future<void> resolveLogosForChannels(List<Channel> channels) async {
    final needsLogo = channels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) return;
    debugPrint('[Logo] ${needsLogo.length} channels need logos');

    final resolved = <String, String>{};

    // First try EPG icons for channels that have EPG mappings
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      final epgIconMap = <String, String>{};
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          epgIconMap[ec.displayName.toLowerCase()] = ec.iconUrl!;
          epgIconMap[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
      for (final ch in needsLogo.toList()) {
        final stripped = ch.name.toLowerCase()
            .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
            .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
            .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
            .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
        final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
        if (icon != null) {
          resolved[ch.id] = icon;
          needsLogo.removeWhere((c) => c.id == ch.id);
        }
      }
      debugPrint('[Logo] EPG icons resolved ${resolved.length} channels');
    } catch (_) {}

    // Then resolve remaining from tv-logo/tv-logos GitHub repo
    if (needsLogo.isNotEmpty) {
      debugPrint('[Logo] Resolving ${needsLogo.length} via GitHub tv-logos...');
      final ghResolved = await LogoResolverService.resolveLogosForChannels(needsLogo);
      debugPrint('[Logo] GitHub resolved ${ghResolved.length} logos');
      resolved.addAll(ghResolved);
    }

    // Batch-write all resolved logos in a single transaction
    if (resolved.isNotEmpty) {
      await _db.updateChannelLogos(resolved);
    }
  }

  static const _logoResolvedKey = 'logo_last_resolved';
  static const _logoChannelCountKey = 'logo_channel_count';
  static const _logoCooldown = Duration(hours: 6);
  static const _logoBatchSize = 200;

  /// Resolve missing logos progressively: favorites first, then the rest
  /// in small batches so the UI stays responsive.
  /// Skips entirely if resolved recently and channel count hasn't changed.
  Future<void> resolveAllMissingLogos() async {
    final prefs = await SharedPreferences.getInstance();
    final lastResolved = prefs.getInt(_logoResolvedKey) ?? 0;
    final lastCount = prefs.getInt(_logoChannelCountKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - lastResolved;

    final allChannels = await _db.getAllChannels();

    // Skip if resolved recently AND no new channels were added
    if (age < _logoCooldown.inMilliseconds && allChannels.length == lastCount) {
      return;
    }

    final needsLogo = allChannels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) {
      await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(_logoChannelCountKey, allChannels.length);
      return;
    }

    // Build lookup maps once
    final epgIconMap = await _buildEpgIconMap();
    await LogoResolverService.ensureIndex(); // pre-load GitHub index

    // Partition: favorites first, then the rest
    final favIds = await _db.getAllFavoritedChannelIds();
    final favorites = needsLogo.where((c) => favIds.contains(c.id)).toList();
    final rest = needsLogo.where((c) => !favIds.contains(c.id)).toList();

    debugPrint('[Logo] ${needsLogo.length} missing (${favorites.length} favorites, ${rest.length} other)');

    // Resolve favorites immediately
    if (favorites.isNotEmpty) {
      final resolved = await _resolveLogoBatch(favorites, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
        debugPrint('[Logo] Favorites: resolved ${resolved.length} logos');
      }
    }

    // Resolve rest in small batches with yields between
    for (var i = 0; i < rest.length; i += _logoBatchSize) {
      final batch = rest.sublist(i, (i + _logoBatchSize).clamp(0, rest.length));
      final resolved = await _resolveLogoBatch(batch, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
      }
      // Yield to UI between batches
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('[Logo] Resolution complete');
    await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_logoChannelCountKey, allChannels.length);
  }

  /// Build EPG icon lookup map (display name / channel ID → icon URL).
  Future<Map<String, String>> _buildEpgIconMap() async {
    final map = <String, String>{};
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          map[ec.displayName.toLowerCase()] = ec.iconUrl!;
          map[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
    } catch (_) {}
    return map;
  }

  /// Resolve logos for a batch of channels using EPG icons + GitHub tv-logos.
  Future<Map<String, String>> _resolveLogoBatch(
    List<({String id, String name, String? tvgLogo})> channels,
    Map<String, String> epgIconMap,
  ) async {
    final resolved = <String, String>{};
    final remaining = <({String id, String name, String? tvgLogo})>[];

    for (final ch in channels) {
      final stripped = ch.name.toLowerCase()
          .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
          .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
          .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
          .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
      final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
      if (icon != null) {
        resolved[ch.id] = icon;
      } else {
        remaining.add(ch);
      }
    }

    if (remaining.isNotEmpty) {
      final ghResolved = await LogoResolverService.resolveLogosForChannels(remaining);
      resolved.addAll(ghResolved);
    }

    return resolved;
  }
}

class ProviderLimitException implements Exception {
  final int limit;
  const ProviderLimitException(this.limit);

  @override
  String toString() =>
      'Provider limit reached ($limit). Upgrade to Pro for unlimited providers.';
}

/// Riverpod provider for the database.
final databaseProvider = Provider<db.AppDatabase>((ref) {
  final database = db.AppDatabase();
  ref.onDispose(() => database.close());
  return database;
});

/// Riverpod provider for the provider manager.
final providerManagerProvider = Provider<ProviderManager>((ref) {
  return ProviderManager(ref.watch(databaseProvider));
});
