import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../data/datasources/remote/trakt_client.dart';
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/datasources/remote/debrid_service.dart';
import '../../data/datasources/remote/stremio_addon_client.dart';
import '../../data/datasources/remote/torrent_search_client.dart';
import '../../data/repositories/shows_repository.dart';
import '../../data/models/show.dart';
import '../../data/models/stremio_addon.dart';
import '../../data/models/stream_search_result.dart';
import '../../data/services/debrid_settings.dart';
import '../../data/services/language_preferences_store.dart';
import '../../data/services/stremio_addon_settings.dart';
import '../../data/services/stream_ranker.dart';
import '../../data/services/tmdb_language_store.dart';

// SharedPreferences keys for API credentials
const _kTraktClientId = 'shows_trakt_client_id';
const _kTmdbApiKey = 'shows_tmdb_api_key';

/// Cliente compartido del protocolo Stremio: lo usan tanto la búsqueda de
/// fuentes como la pantalla de instalación, y en tests se sustituye por un
/// doble sin tocar la red.
final stremioAddonClientProvider = Provider<StremioAddonClient>(
  (ref) => StremioAddonClient(),
);

/// Addons que se van a consultar, en orden de prioridad: un addon deshabilitado
/// no llega nunca al repositorio.
final enabledStremioAddonsProvider = Provider<List<InstalledAddon>>(
  (ref) => ref.watch(stremioAddonSettingsProvider).enabledAddons,
);

/// Addons a los que sí se les pide streams. Un addon de sólo catálogo (Kitsu)
/// se instala para descubrir, pero no se consulta al reproducir.
final enabledStreamAddonsProvider = Provider<List<InstalledAddon>>(
  (ref) => ref
      .watch(stremioAddonSettingsProvider)
      .enabledAddons
      .where((addon) => addon.supportsStreams)
      .toList(growable: false),
);

/// Provider for the shows repository (rebuilds when keys, debrid settings or
/// addons change). Los servicios debrid se construyen en el orden de prioridad
/// que fija [debridSettingsProvider] y los addons en el que fija
/// [stremioAddonSettingsProvider]; sin nada habilitado, el repositorio sigue
/// funcionando exactamente como antes.
final showsRepositoryProvider = FutureProvider<ShowsRepository>((ref) async {
  final keys = ref.watch(showsApiKeysProvider);
  final debridSettings = ref.watch(debridSettingsProvider);
  final addons = ref.watch(enabledStreamAddonsProvider);
  final stremioClient = ref.watch(stremioAddonClientProvider);
  // Cambiar el idioma reconstruye el repositorio y, con él, todos los
  // catálogos y fichas que dependen de TMDB.
  final tmdbLanguage = ref.watch(tmdbLanguageProvider);

  return ShowsRepository(
    trakt: keys.hasTraktKey ? TraktClient(clientId: keys.traktClientId) : null,
    tmdb: keys.hasTmdbKey
        ? TmdbClient(apiKey: keys.tmdbApiKey, language: tmdbLanguage)
        : null,
    debridServices: [
      for (final config in debridSettings.enabledServices)
        createDebridService(config.type, config.token),
    ],
    torrentSearch: TorrentSearchClient(),
    stremioAddons: addons,
    stremioClient: stremioClient,
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
final showDetailProvider = FutureProvider.family<ShowDetail?, ShowDetailParams>(
  (ref, params) async {
    final repo = await ref.watch(showsRepositoryProvider.future);
    return repo.getShowDetail(params.traktId, type: params.type);
  },
);

class ShowDetailParams {
  final int traktId;
  final ShowType type;
  const ShowDetailParams(this.traktId, {this.type = ShowType.show});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShowDetailParams &&
          traktId == other.traktId &&
          type == other.type;

  @override
  int get hashCode => traktId.hashCode ^ type.hashCode;
}

/// Episodes for a season
final episodesProvider = FutureProvider.family<List<Episode>, EpisodeParams>((
  ref,
  params,
) async {
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
      other is EpisodeParams &&
          traktId == other.traktId &&
          season == other.season;

  @override
  int get hashCode => traktId.hashCode ^ season.hashCode;
}

/// Fuentes para reproducción, ya rankeadas por las preferencias de idioma
/// persistidas, junto con los addons que no pudieron responder. El ranking es
/// puro; el provider solo lo compone con el repositorio. No recorta: el
/// selector necesita la lista completa para poder filtrar por español.
final resolveStreamProvider =
    FutureProvider.family<StreamSearchResult, StreamResolveParams>((
      ref,
      params,
    ) async {
      final preferences = ref.watch(languagePreferencesProvider);
      final repo = await ref.watch(showsRepositoryProvider.future);
      final result = await repo.resolveStreams(
        imdbId: params.imdbId,
        season: params.season,
        episode: params.episode,
      );
      return result.copyWith(
        sources: rankStreams(result.sources, preferences),
      );
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
  int get hashCode =>
      imdbId.hashCode ^ (season ?? 0).hashCode ^ (episode ?? 0).hashCode;
}

/// Un catálogo que se va a pintar en el descubrimiento.
class AddonCatalogSpec {
  final InstalledAddon addon;
  final StremioCatalog catalog;

  const AddonCatalogSpec({required this.addon, required this.catalog});

  String get title {
    final name = catalog.name?.trim();
    return name == null || name.isEmpty ? catalog.id : name;
  }

  /// Género con el que abre la fila: el primero si es obligatorio.
  String? get defaultGenre {
    final extra = catalog.genreExtra;
    if (extra == null || !extra.isRequired || extra.options.isEmpty) {
      return null;
    }
    return extra.options.first;
  }

  @override
  String toString() => 'AddonCatalogSpec(${addon.name}/$title)';
}

/// Una fila de descubrimiento: un catálogo de un addon con su primera página.
///
/// Un catálogo que falla no tumba la sección: la fila conserva el motivo para
/// que la pantalla lo explique y el resto sigue pintándose.
class AddonCatalogRow {
  final InstalledAddon addon;
  final StremioCatalog catalog;
  final List<StremioMeta> metas;
  final String? error;

  const AddonCatalogRow({
    required this.addon,
    required this.catalog,
    this.metas = const [],
    this.error,
  });

  String get title {
    final name = catalog.name?.trim();
    return name == null || name.isEmpty ? catalog.id : name;
  }

  bool get hasError => error != null;
  bool get isEmpty => metas.isEmpty && error == null;

  @override
  String toString() => 'AddonCatalogRow(${addon.name}/$title, ${metas.length})';
}

/// Catálogos que se pintan en el descubrimiento, en el orden de los addons.
///
/// Los catálogos que sólo responden a `search` o que exigen un extra que no
/// sabemos rellenar se omiten; como mucho se pintan 12 filas.
final stremioCatalogSpecsProvider = Provider<List<AddonCatalogSpec>>((ref) {
  final addons = ref
      .watch(enabledStremioAddonsProvider)
      .where((addon) => addon.hasCatalogs)
      .toList(growable: false);
  const maxRows = 12;
  const maxPerAddon = 4;

  final specs = <AddonCatalogSpec>[];
  for (final addon in addons) {
    for (final catalog in addon.browsableCatalogs.take(maxPerAddon)) {
      if (specs.length >= maxRows) break;
      specs.add(AddonCatalogSpec(addon: addon, catalog: catalog));
    }
  }
  return specs;
});

/// Primera página de una fila. El género viaja en los parámetros para que la
/// propia fila pueda cambiarlo sin recargar las demás.
final addonCatalogRowProvider =
    FutureProvider.family<AddonCatalogRow, AddonCatalogParams>((
      ref,
      params,
    ) async {
      final addon = ref
          .watch(stremioAddonSettingsProvider)
          .byUrl(params.addonUrl);
      if (addon == null) {
        throw const StremioAddonException(
          'Ese addon ya no está instalado. Vuelve a instalarlo para ver su catálogo.',
        );
      }
      StremioCatalog? catalog;
      for (final candidate in addon.catalogs) {
        if (candidate.type == params.catalogType &&
            candidate.id == params.catalogId) {
          catalog = candidate;
          break;
        }
      }
      if (catalog == null) {
        throw const StremioAddonException(
          'El addon ya no publica ese catálogo. Actualízalo desde Stremio Addons.',
        );
      }
      return _loadRow(
        ref.watch(stremioAddonClientProvider),
        addon,
        catalog,
        params.genre,
      );
    });

class AddonCatalogParams {
  final String addonUrl;
  final String catalogType;
  final String catalogId;
  final String? genre;

  const AddonCatalogParams({
    required this.addonUrl,
    required this.catalogType,
    required this.catalogId,
    this.genre,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AddonCatalogParams &&
          addonUrl == other.addonUrl &&
          catalogType == other.catalogType &&
          catalogId == other.catalogId &&
          genre == other.genre;

  @override
  int get hashCode => Object.hash(addonUrl, catalogType, catalogId, genre);
}

Future<AddonCatalogRow> _loadRow(
  StremioAddonClient client,
  InstalledAddon addon,
  StremioCatalog catalog,
  String? genre,
) async {
  try {
    final metas = await client.fetchCatalog(
      addon: addon,
      catalog: catalog,
      genre: genre,
    );
    return AddonCatalogRow(addon: addon, catalog: catalog, metas: metas);
  } on StremioAddonException catch (e) {
    return AddonCatalogRow(addon: addon, catalog: catalog, error: e.message);
  } catch (_) {
    return AddonCatalogRow(
      addon: addon,
      catalog: catalog,
      error: 'El addon no pudo responder',
    );
  }
}

/// Ficha completa desde el addon del catálogo. Null = el addon no publica
/// `meta`; la pantalla mantiene entonces los datos del catálogo.
final stremioMetaProvider = FutureProvider.family<StremioMeta?, StremioMetaParams>((
  ref,
  params,
) async {
  final addon = ref.watch(stremioAddonSettingsProvider).byUrl(params.addonUrl);
  if (addon == null) {
    throw const StremioAddonException(
      'Ese addon ya no está instalado. Vuelve a instalarlo para abrir su ficha.',
    );
  }
  return ref
      .watch(stremioAddonClientProvider)
      .fetchMeta(addon: addon, type: params.type, id: params.id);
});

class StremioMetaParams {
  final String addonUrl;
  final String type;
  final String id;

  const StremioMetaParams({
    required this.addonUrl,
    required this.type,
    required this.id,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StremioMetaParams &&
          addonUrl == other.addonUrl &&
          type == other.type &&
          id == other.id;

  @override
  int get hashCode => Object.hash(addonUrl, type, id);
}

/// Fuentes de un título de catálogo, consultadas a los addons con su id propio
/// (`kitsu:7442:1`) y a Torrentio cuando la ficha trae un id IMDB.
final addonStreamsProvider =
    FutureProvider.family<StreamSearchResult, AddonStreamParams>((
      ref,
      params,
    ) async {
      final preferences = ref.watch(languagePreferencesProvider);
      final repo = await ref.watch(showsRepositoryProvider.future);
      final result = await repo.resolveStreams(
        imdbId: params.imdbId,
        season: params.season,
        episode: params.episode,
        addonType: params.addonType,
        addonId: params.addonId,
      );
      return result.copyWith(
        sources: rankStreams(result.sources, preferences),
      );
    });

class AddonStreamParams {
  final String addonType;
  final String addonId;
  final String imdbId;
  final int? season;
  final int? episode;

  const AddonStreamParams({
    required this.addonType,
    required this.addonId,
    required this.imdbId,
    this.season,
    this.episode,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AddonStreamParams &&
          addonType == other.addonType &&
          addonId == other.addonId &&
          imdbId == other.imdbId &&
          season == other.season &&
          episode == other.episode;

  @override
  int get hashCode => Object.hash(addonType, addonId, imdbId, season, episode);
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
    state = ShowsApiKeys(traktClientId: traktClientId, tmdbApiKey: tmdbApiKey);
  }
}

/// Credenciales de metadatos. Debrid vive aparte, en [debridSettingsProvider].
class ShowsApiKeys {
  final String traktClientId;
  final String tmdbApiKey;

  const ShowsApiKeys({this.traktClientId = '', this.tmdbApiKey = ''});

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
      state = list
          .map((e) => _showFromJson(e as Map<String, dynamic>))
          .toList();
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

final favoritesProvider = StateNotifierProvider<FavoritesNotifier, List<Show>>((
  ref,
) {
  final notifier = FavoritesNotifier();
  notifier.load();
  return notifier;
});
