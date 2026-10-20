import 'package:logger/logger.dart';
import '../datasources/remote/trakt_client.dart';
import '../datasources/remote/tmdb_client.dart';
import '../datasources/remote/debrid_service.dart';
import '../datasources/remote/stremio_addon_client.dart';
import '../datasources/remote/torrent_hash_resolver.dart';
import '../datasources/remote/torrent_search_client.dart';
import '../models/show.dart';
import '../models/stremio_addon.dart';
import '../models/stream_search_result.dart';
import '../models/stream_source.dart';
import '../services/debrid_settings.dart';

/// Combines Trakt, TMDB, debrid, and torrent search into a unified shows data source
class ShowsRepository {
  final TraktClient? _trakt;
  final TmdbClient? _tmdb;

  /// Servicios habilitados en orden de prioridad. Vacío = modo sin debrid.
  final List<DebridService> _debridServices;
  final TorrentSearchClient _torrentSearch;

  /// Addons Stremio habilitados, en orden de prioridad. Vacío = ruta actual
  /// intacta: solo Torrentio.
  final List<InstalledAddon> _stremioAddons;
  final StremioAddonClient _stremioClient;
  final _log = Logger(printer: SimplePrinter());

  ShowsRepository({
    TraktClient? trakt,
    TmdbClient? tmdb,
    List<DebridService> debridServices = const [],
    TorrentSearchClient? torrentSearch,
    List<InstalledAddon> stremioAddons = const [],
    StremioAddonClient? stremioClient,
  }) : _trakt = trakt,
       _tmdb = tmdb,
       _debridServices = List<DebridService>.unmodifiable(debridServices),
       _torrentSearch = torrentSearch ?? TorrentSearchClient(),
       _stremioAddons = List<InstalledAddon>.unmodifiable(stremioAddons),
       _stremioClient = stremioClient ?? StremioAddonClient();

  bool get hasTrakt => _trakt != null;
  bool get hasTmdb => _tmdb != null;
  bool get hasDebrid => _debridServices.isNotEmpty;
  bool get hasStremioAddons => _stremioAddons.isNotEmpty;

  /// Nombres de los servicios que resolverán, en orden de prioridad.
  List<String> get debridServiceNames => [
    for (final service in _debridServices) service.serviceName,
  ];

  /// URLs de los addons que se consultarán, en orden de prioridad.
  List<String> get stremioAddonUrls => [
    for (final addon in _stremioAddons) addon.url,
  ];

  /// Get trending shows, enriched with TMDB posters
  Future<List<Show>> getTrendingShows({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getTrendingShows(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(
        await _tmdb.getTrendingTv(page: page),
        ShowType.show,
      );
    }
    return [];
  }

  /// Get popular shows, enriched with TMDB posters
  Future<List<Show>> getPopularShows({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getPopularShows(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(
        await _tmdb.getPopularTv(page: page),
        ShowType.show,
      );
    }
    return [];
  }

  /// Get trending movies, enriched with TMDB posters
  Future<List<Show>> getTrendingMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getTrendingMovies(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(
        await _tmdb.getTrendingMovie(page: page),
        ShowType.movie,
      );
    }
    return [];
  }

  /// Get popular movies, enriched with TMDB posters
  Future<List<Show>> getPopularMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getPopularMovies(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(
        await _tmdb.getPopularMovie(page: page),
        ShowType.movie,
      );
    }
    return [];
  }

  /// Search shows and movies
  Future<List<Show>> search(String query) async {
    if (_trakt != null) {
      final results = await _trakt.search(query);
      return _enrichWithTmdb(results);
    }
    if (_tmdb != null) {
      final tvResults = await _tmdb.searchTv(query);
      final movieResults = await _tmdb.searchMovie(query);
      return [
        ..._tmdbResultsToShows(tvResults, ShowType.show),
        ..._tmdbResultsToShows(movieResults, ShowType.movie),
      ];
    }
    return [];
  }

  /// Get full show detail with seasons
  Future<ShowDetail?> getShowDetail(
    int traktId, {
    ShowType type = ShowType.show,
  }) async {
    // Trakt-based detail
    if (_trakt != null) {
      final show = type == ShowType.movie
          ? await _trakt.getMovie(traktId)
          : await _trakt.getShow(traktId);
      final enriched = await _enrichSingle(show);

      List<Season> seasons = [];
      if (type == ShowType.show) {
        seasons = await _trakt.getSeasons(traktId);
        seasons = seasons.where((s) => s.number > 0).toList();
        if (_tmdb != null && enriched.tmdbId != null) {
          seasons = await _enrichSeasons(enriched.tmdbId!, seasons);
        }
      }
      return ShowDetail(show: enriched, seasons: seasons);
    }

    // TMDB-only fallback — traktId is actually tmdbId in this case
    if (_tmdb != null) {
      return _getShowDetailFromTmdb(traktId, type: type);
    }

    return null;
  }

  /// TMDB-only show detail
  Future<ShowDetail?> _getShowDetailFromTmdb(
    int tmdbId, {
    ShowType type = ShowType.show,
  }) async {
    if (_tmdb == null) return null;
    try {
      final detail = type == ShowType.movie
          ? await _tmdb.getMovie(tmdbId)
          : await _tmdb.getTvShow(tmdbId);

      _log.i(
        'TMDB detail for $tmdbId: title=${detail.title}, imdb=${detail.imdbId}, seasons=${detail.numberOfSeasons}',
      );

      final show = Show(
        traktId: tmdbId,
        tmdbId: tmdbId,
        imdbId: detail.imdbId,
        title: detail.title,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: detail.overview,
        rating: detail.voteAverage,
        votes: detail.voteCount,
        year: detail.year,
        genres: detail.genres,
        videos: detail.videos,
        type: type,
      );

      // For TV shows, build seasons list from TMDB
      List<Season> seasons = [];
      if (type == ShowType.show) {
        final numSeasons = detail.numberOfSeasons ?? 0;
        _log.i('Fetching $numSeasons seasons for ${detail.title}');
        for (int i = 1; i <= numSeasons; i++) {
          try {
            final tmdbSeason = await _tmdb.getTvSeason(tmdbId, i);
            seasons.add(
              Season(
                number: i,
                overview: tmdbSeason.overview,
                episodeCount: tmdbSeason.episodes.length,
                airedEpisodes: tmdbSeason.episodes.length,
                posterUrl: tmdbSeason.posterPath != null
                    ? TmdbClient.posterUrl(tmdbSeason.posterPath)
                    : null,
              ),
            );
          } catch (e) {
            _log.w('Failed to fetch season $i for $tmdbId: $e');
            seasons.add(Season(number: i));
          }
        }
      }

      return ShowDetail(show: show, seasons: seasons);
    } catch (e) {
      _log.e('TMDB detail failed for $tmdbId: $e');
      return null;
    }
  }

  /// Get episodes for a season
  Future<List<Episode>> getEpisodes(int traktId, int seasonNumber) async {
    // Trakt-based
    if (_trakt != null) {
      final episodes = await _trakt.getEpisodes(traktId, seasonNumber);
      if (_tmdb != null) {
        try {
          final show = await _trakt.getShow(traktId);
          if (show.tmdbId != null) {
            return await _enrichEpisodesWithTmdb(
              episodes,
              show.tmdbId!,
              seasonNumber,
            );
          }
        } catch (_) {}
      }
      return episodes;
    }

    // TMDB-only fallback — traktId is actually tmdbId
    if (_tmdb != null) {
      return _getEpisodesFromTmdb(traktId, seasonNumber);
    }

    return [];
  }

  /// Get episodes directly from TMDB
  Future<List<Episode>> _getEpisodesFromTmdb(
    int tmdbId,
    int seasonNumber,
  ) async {
    if (_tmdb == null) return [];
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      return tmdbSeason.episodes
          .map(
            (e) => Episode(
              season: seasonNumber,
              number: e.episodeNumber,
              title: e.name,
              overview: e.overview,
              rating: e.voteAverage,
              stillUrl: e.stillUrl.isNotEmpty ? e.stillUrl : null,
              tmdbId: e.episodeNumber,
            ),
          )
          .toList();
    } catch (e) {
      _log.e('TMDB episodes failed for $tmdbId S$seasonNumber: $e');
      return [];
    }
  }

  /// Find sources for a show/movie as the app-wide [StreamSource] type.
  ///
  /// Torrentio y los addons habilitados devuelven ese tipo; aquí se mezclan, se
  /// enriquecen con la disponibilidad del debrid habilitado y se marca el motivo
  /// cuando no hay ninguno. Los addons se consultan en paralelo y un addon caído
  /// o lento solo se reporta como fallo con su motivo: nunca tumba ni bloquea a
  /// los demás. El orden final lo decide `rankStreams` en la capa de providers,
  /// para que este repositorio no dependa de preferencias de UI.
  /// [addonType]/[addonId] permiten pedir a los addons el id propio de su
  /// catálogo (`kitsu:7442:1`, `animeav1:…:2`) en vez del id IMDB. Torrentio
  /// sólo se consulta cuando hay un id `tt` real.
  Future<StreamSearchResult> resolveStreams({
    required String imdbId,
    int? season,
    int? episode,
    String? addonType,
    String? addonId,
  }) async {
    final isEpisode = season != null && episode != null;

    // Step 1: Torrentio y addons Stremio en paralelo.
    final hasImdbId = imdbId.startsWith('tt');
    final torrentFuture = !hasImdbId
        ? Future<List<StreamSource>>.value(const [])
        : isEpisode
        ? _torrentSearch.searchEpisode(imdbId, season: season, episode: episode)
        : _torrentSearch.searchMovie(imdbId);
    final streamId =
        addonId ?? (isEpisode ? '$imdbId:$season:$episode' : imdbId);
    final streamType = addonType ?? (isEpisode ? 'series' : 'movie');

    final addonFutures = [
      for (final addon in _stremioAddons)
        _fetchFromAddon(addon, type: streamType, id: streamId),
    ];

    final sources = <StreamSource>[...await torrentFuture];
    final failures = <StreamProviderFailure>[];
    for (final result in await Future.wait(addonFutures)) {
      sources.addAll(result.sources);
      if (result.failure != null) failures.add(result.failure!);
    }

    if (sources.isEmpty) {
      _log.w('No sources found for $imdbId');
      return StreamSearchResult(failures: failures);
    }

    // Step 2: Check debrid instant availability. Se prueba en orden de
    // prioridad y se para en el primer servicio que devuelva algo: un servicio
    // sin consulta de caché (AllDebrid retiró `/magnet/instant`) contesta vacío
    // y no debe impedir que el siguiente marque sus hashes.
    Set<String> cachedHashes = {};
    String? cachedSource;
    for (final service in _debridServices) {
      try {
        final hashes = [
          for (final source in sources)
            if (source.infoHash != null && source.infoHash!.isNotEmpty)
              source.infoHash!,
        ];
        final available = await service.checkInstantAvailability(hashes);
        cachedHashes = available.keys.toSet();
        if (cachedHashes.isEmpty) continue;
        cachedSource = service.serviceName;
        break;
      } catch (e) {
        _log.w('${service.serviceName} availability check failed: $e');
      }
    }

    // Step 3: Enrich with debrid state. Sin ningún servicio habilitado los
    // torrents siguen visibles, pero marcados como no disponibles con el
    // motivo, en vez de fallar al pulsar.
    final debridEnabled = hasDebrid;
    final results = <StreamSource>[];
    for (final source in sources) {
      final hash = source.infoHash?.toLowerCase() ?? '';
      final cached = hash.isNotEmpty && cachedHashes.contains(hash);

      var enriched = source;
      if (cached) {
        enriched = enriched.copyWith(
          kind: SourceKind.debrid,
          isCached: true,
          cachedBy: cachedSource,
        );
      }
      if (!debridEnabled) {
        enriched = enriched.copyWith(unavailableReason: kDebridRequiredReason);
      }
      results.add(enriched);
    }

    return StreamSearchResult(sources: results, failures: failures);
  }

  /// Consulta un addon y traduce cualquier fallo a un motivo visible. El addon
  /// caído queda fuera de la lista, pero los demás siguen respondiendo.
  Future<({List<StreamSource> sources, StreamProviderFailure? failure})>
  _fetchFromAddon(
    InstalledAddon addon, {
    required String type,
    required String id,
  }) async {
    try {
      final sources = await _stremioClient.fetchStreams(
        addon: addon,
        type: type,
        id: id,
      );
      return (sources: sources, failure: null);
    } on StremioAddonException catch (e) {
      _log.w('Addon ${addon.name} failed: ${e.message}');
      return (
        sources: const <StreamSource>[],
        failure: StreamProviderFailure(
          providerId: addon.manifestId,
          providerName: addon.name,
          reason: e.message,
        ),
      );
    } catch (e) {
      _log.w('Addon ${addon.name} failed: $e');
      return (
        sources: const <StreamSource>[],
        failure: StreamProviderFailure(
          providerId: addon.manifestId,
          providerName: addon.name,
          reason: 'El addon no pudo responder',
        ),
      );
    }
  }

  /// Resolve a specific torrent through the enabled debrid services, in
  /// priority order. Throws [DebridUnavailableException] when there is none.
  Future<ResolvedStream?> resolveMagnet(
    String magnetUrl, {
    void Function(String status, int progress)? onProgress,
  }) async {
    if (_debridServices.isEmpty) {
      throw const DebridUnavailableException();
    }

    Object? lastError;
    for (final service in _debridServices) {
      try {
        final resolved = await service.resolveFromMagnet(
          magnetUrl,
          onProgress: onProgress,
        );
        if (resolved != null && resolved.url.isNotEmpty) return resolved;
      } catch (e) {
        lastError = e;
        _log.w('${service.serviceName} could not resolve magnet: $e');
      }
    }

    if (lastError != null) {
      throw Exception(
        'Ningún servicio debrid pudo resolver el enlace: $lastError',
      );
    }
    return null;
  }

  /// Reabre un release ya conocido por su `infoHash`, sin volver a buscarlo en
  /// los addons.
  ///
  /// Es el camino corto de «seguir con esta fuente»: cuando el debrid tiene el
  /// torrent, pedirlo por hash evita la búsqueda entera. [fileIdx], [season] y
  /// [episode] son pistas para elegir el fichero del pack; el servicio que no
  /// sepa usarlas cae al magnet de siempre.
  Future<ResolvedStream?> resolveTorrentHash(
    String infoHash, {
    int? fileIdx,
    int? season,
    int? episode,
    void Function(String status, int progress)? onProgress,
  }) async {
    if (_debridServices.isEmpty) {
      throw const DebridUnavailableException();
    }
    final magnet = magnetForTorrentHash(infoHash);
    Object? lastError;
    for (final service in _debridServices) {
      try {
        final resolver = service is TorrentHashResolver
            ? service as TorrentHashResolver
            : null;
        final resolved = resolver != null
            ? await resolver.resolveTorrentHash(
                infoHash,
                fileIdx: fileIdx,
                season: season,
                episode: episode,
                onProgress: onProgress,
              )
            : await service.resolveFromMagnet(
                magnet,
                onProgress: onProgress,
              );
        if (resolved != null && resolved.url.isNotEmpty) return resolved;
      } catch (e) {
        lastError = e;
        _log.w('${service.serviceName} could not reopen the release: $e');
      }
    }
    if (lastError != null) {
      throw Exception(
        'Ningún servicio debrid pudo reabrir el release: $lastError',
      );
    }
    return null;
  }

  /// Enrich a list of shows with TMDB poster/backdrop URLs
  Future<List<Show>> _enrichWithTmdb(List<Show> shows) async {
    if (_tmdb == null) return shows;

    final enriched = <Show>[];
    for (final show in shows) {
      enriched.add(await _enrichSingle(show));
    }
    return enriched;
  }

  /// Enrich seasons with TMDB posters/overviews
  Future<List<Season>> _enrichSeasons(int tmdbId, List<Season> seasons) async {
    if (_tmdb == null) return seasons;
    final result = <Season>[];
    for (final season in seasons) {
      try {
        final tmdbSeason = await _tmdb.getTvSeason(tmdbId, season.number);
        result.add(
          Season(
            number: season.number,
            title: season.title,
            overview: tmdbSeason.overview ?? season.overview,
            episodeCount: season.episodeCount,
            airedEpisodes: season.airedEpisodes,
            rating: season.rating,
            posterUrl: tmdbSeason.posterPath != null
                ? TmdbClient.posterUrl(tmdbSeason.posterPath)
                : null,
            firstAired: season.firstAired,
            traktId: season.traktId,
            tmdbId: season.tmdbId,
          ),
        );
      } catch (_) {
        result.add(season);
      }
    }
    return result;
  }

  /// Enrich Trakt episodes with TMDB stills
  Future<List<Episode>> _enrichEpisodesWithTmdb(
    List<Episode> episodes,
    int tmdbId,
    int seasonNumber,
  ) async {
    if (_tmdb == null) return episodes;
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      final tmdbEpMap = {
        for (final e in tmdbSeason.episodes) e.episodeNumber: e,
      };
      return episodes.map((ep) {
        final tmdbEp = tmdbEpMap[ep.number];
        if (tmdbEp == null) return ep;
        return Episode(
          season: ep.season,
          number: ep.number,
          title: ep.title ?? tmdbEp.name,
          overview: ep.overview ?? tmdbEp.overview,
          rating: ep.rating,
          votes: ep.votes,
          runtime: ep.runtime,
          firstAired: ep.firstAired,
          stillUrl: tmdbEp.stillUrl.isNotEmpty ? tmdbEp.stillUrl : null,
          traktId: ep.traktId,
          tmdbId: ep.tmdbId,
        );
      }).toList();
    } catch (_) {
      return episodes;
    }
  }

  /// Enrich a single show with TMDB images and IMDB ID
  Future<Show> _enrichSingle(Show show) async {
    if (_tmdb == null || show.tmdbId == null) return show;
    try {
      final detail = show.type == ShowType.movie
          ? await _tmdb.getMovie(show.tmdbId!)
          : await _tmdb.getTvShow(show.tmdbId!);
      // Trakt devuelve títulos y sinopsis en inglés; TMDB los da en el idioma
      // elegido en Shows & Movies. Se prefiere TMDB y se cae a Trakt si falta.
      // El tráiler de Trakt queda como respaldo para cuando TMDB no publica
      // ningún vídeo (sin clave de TMDB, o títulos que no los tienen).
      return show.copyWith(
        imdbId: detail.imdbId,
        title: detail.title.isNotEmpty ? detail.title : null,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: (detail.overview?.isNotEmpty ?? false)
            ? detail.overview
            : show.overview,
        videos: detail.videos.isNotEmpty ? detail.videos : null,
      );
    } catch (e) {
      _log.w('TMDB enrichment failed for ${show.title}: $e');
      return show;
    }
  }

  /// Convert TMDB search results to Show objects (fallback when Trakt unavailable)
  List<Show> _tmdbResultsToShows(
    List<TmdbSearchResult> results,
    ShowType type,
  ) {
    return results
        .map(
          (r) => Show(
            traktId: r.id,
            tmdbId: r.id,
            title: r.displayName,
            year: r.year,
            overview: r.overview,
            rating: r.voteAverage,
            posterUrl: r.posterUrl.isNotEmpty ? r.posterUrl : null,
            backdropUrl: r.backdropUrl.isNotEmpty ? r.backdropUrl : null,
            type: type,
          ),
        )
        .toList();
  }
}
