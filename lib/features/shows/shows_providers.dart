import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../data/datasources/remote/trakt_client.dart';
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/datasources/remote/debrid_service.dart';
import '../../data/datasources/remote/torrent_search_client.dart';
import '../../data/repositories/shows_repository.dart';
import '../../data/models/show.dart';
import '../../data/models/stream_source.dart';
import '../../data/services/debrid_settings.dart';
import '../../data/services/language_preferences_store.dart';
import '../../data/services/stream_ranker.dart';

// SharedPreferences keys for API credentials
const _kTraktClientId = 'shows_trakt_client_id';
const _kTmdbApiKey = 'shows_tmdb_api_key';

/// Provider for the shows repository (rebuilds when keys or debrid settings
/// change). Los servicios debrid se construyen en el orden de prioridad que
/// fija [debridSettingsProvider]; sin ninguno habilitado, el repositorio
/// funciona en modo sin debrid.
final showsRepositoryProvider = FutureProvider<ShowsRepository>((ref) async {
  final keys = ref.watch(showsApiKeysProvider);
  final debridSettings = ref.watch(debridSettingsProvider);

  return ShowsRepository(
    trakt: keys.hasTraktKey
        ? TraktClient(clientId: keys.traktClientId)
        : null,
    tmdb: keys.hasTmdbKey
        ? TmdbClient(apiKey: keys.tmdbApiKey)
        : null,
    debridServices: [
      for (final config in debridSettings.enabledServices)
        createDebridService(config.type, config.token),
    ],
    torrentSearch: TorrentSearchClient(),
  );
});

/// Trending shows
final trendingShowsProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getTrendingShows();
});

/// Popular shows
final popularShowsProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getPopularShows();
});

/// Trending movies
final trendingMoviesProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getTrendingMovies();
});

/// Popular movies
final popularMoviesProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getPopularMovies();
});

/// Search results
final showSearchQueryProvider = StateProvider<String>((ref) => '');

final showSearchResultsProvider = FutureProvider<List<Show>>((ref) async {
  final query = ref.watch(showSearchQueryProvider);
  if (query.isEmpty) return [];
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.search(query);
});

/// Show detail provider (family — parameterized by trakt ID + type)
final showDetailProvider =
    FutureProvider.family<ShowDetail?, ShowDetailParams>((ref, params) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getShowDetail(params.traktId, type: params.type);
});

class ShowDetailParams {
  final int traktId;
  final ShowType type;
  const ShowDetailParams(this.traktId, {this.type = ShowType.show});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShowDetailParams && traktId == other.traktId && type == other.type;

  @override
  int get hashCode => traktId.hashCode ^ type.hashCode;
}

/// Episodes for a season
final episodesProvider =
    FutureProvider.family<List<Episode>, EpisodeParams>((ref, params) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getEpisodes(params.traktId, params.season);
});

class EpisodeParams {
  final int traktId;
  final int season;
  const EpisodeParams(this.traktId, this.season);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpisodeParams && traktId == other.traktId && season == other.season;

  @override
  int get hashCode => traktId.hashCode ^ season.hashCode;
}

/// Fuentes para reproducción, ya rankeadas por las preferencias de idioma
/// persistidas. El ranking es puro; el provider solo lo compone con el
/// repositorio y recorta a las 10 mejores para la pantalla actual.
final resolveStreamProvider =
    FutureProvider.family<List<StreamSource>, StreamResolveParams>((ref, params) async {
  final preferences = ref.watch(languagePreferencesProvider);
  final repo = await ref.watch(showsRepositoryProvider.future);
  final sources = await repo.resolveStreams(
    imdbId: params.imdbId,
    season: params.season,
    episode: params.episode,
  );
  return rankStreams(sources, preferences).take(10).toList(growable: false);
});

class StreamResolveParams {
  final String imdbId;
  final int? season;
  final int? episode;
  const StreamResolveParams(this.imdbId, {this.season, this.episode});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamResolveParams &&
          imdbId == other.imdbId &&
          season == other.season &&
          episode == other.episode;

  @override
  int get hashCode => imdbId.hashCode ^ (season ?? 0).hashCode ^ (episode ?? 0).hashCode;
}

/// API keys configuration state
class ShowsApiKeysNotifier extends StateNotifier<ShowsApiKeys> {
  ShowsApiKeysNotifier() : super(const ShowsApiKeys());

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ShowsApiKeys(
      traktClientId: prefs.getString(_kTraktClientId) ?? '',
      tmdbApiKey: prefs.getString(_kTmdbApiKey) ?? '',
    );
  }

  Future<void> save({
    required String traktClientId,
    required String tmdbApiKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTraktClientId, traktClientId);
    await prefs.setString(_kTmdbApiKey, tmdbApiKey);
    state = ShowsApiKeys(
      traktClientId: traktClientId,
      tmdbApiKey: tmdbApiKey,
    );
  }
}

/// Credenciales de metadatos. Debrid vive aparte, en [debridSettingsProvider].
class ShowsApiKeys {
  final String traktClientId;
  final String tmdbApiKey;

  const ShowsApiKeys({
    this.traktClientId = '',
    this.tmdbApiKey = '',
  });

  bool get isConfigured => traktClientId.isNotEmpty && tmdbApiKey.isNotEmpty;
  bool get hasTraktKey => traktClientId.isNotEmpty;
  bool get hasTmdbKey => tmdbApiKey.isNotEmpty;
}

final showsApiKeysProvider =
    StateNotifierProvider<ShowsApiKeysNotifier, ShowsApiKeys>((ref) {
  final notifier = ShowsApiKeysNotifier();
  notifier.load();
  return notifier;
});

// --- Favorites ---

const _kFavorites = 'shows_favorites';

/// Manages a list of favorite shows persisted to SharedPreferences as JSON
class FavoritesNotifier extends StateNotifier<List<Show>> {
  FavoritesNotifier() : super(const []);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavorites);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      state = list.map((e) => _showFromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      // Corrupted data — start fresh
    }
  }

  Future<void> toggle(Show show) async {
    final exists = state.any((s) => s.traktId == show.traktId);
    if (exists) {
      state = state.where((s) => s.traktId != show.traktId).toList();
    } else {
      state = [...state, show];
    }
    await _persist();
  }

  bool isFavorite(int traktId) => state.any((s) => s.traktId == traktId);

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final json = state.map(_showToJson).toList();
    await prefs.setString(_kFavorites, jsonEncode(json));
  }

  static Map<String, dynamic> _showToJson(Show s) => {
        'traktId': s.traktId,
        'imdbId': s.imdbId,
        'tmdbId': s.tmdbId,
        'title': s.title,
        'year': s.year,
        'overview': s.overview,
        'rating': s.rating,
        'posterUrl': s.posterUrl,
        'backdropUrl': s.backdropUrl,
        'type': s.type == ShowType.movie ? 'movie' : 'show',
        'genres': s.genres,
        'network': s.network,
        'status': s.status,
        'runtime': s.runtime,
      };

  static Show _showFromJson(Map<String, dynamic> j) => Show(
        traktId: j['traktId'] as int,
        imdbId: j['imdbId'] as String?,
        tmdbId: j['tmdbId'] as int?,
        title: j['title'] as String? ?? '',
        year: j['year'] as int?,
        overview: j['overview'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        posterUrl: j['posterUrl'] as String?,
        backdropUrl: j['backdropUrl'] as String?,
        type: j['type'] == 'movie' ? ShowType.movie : ShowType.show,
        genres: (j['genres'] as List?)?.cast<String>() ?? const [],
        network: j['network'] as String?,
        status: j['status'] as String?,
        runtime: j['runtime'] as int?,
      );
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, List<Show>>((ref) {
  final notifier = FavoritesNotifier();
  notifier.load();
  return notifier;
});
