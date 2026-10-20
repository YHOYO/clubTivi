// La ficha de un catálogo debe aprovechar lo que ya trae el catálogo, pedir
// los episodios al addon y resolver las fuentes con el id propio del título.
import 'dart:async';

import 'package:clubtivi/data/models/playback_request.dart';
import 'package:clubtivi/data/models/stremio_addon.dart';
import 'package:clubtivi/data/models/stream_search_result.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/repositories/shows_repository.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/shows/shows_providers.dart';
import 'package:clubtivi/features/shows/stremio_meta_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _initial = StremioMeta(
  id: 'kitsu:7442',
  type: 'series',
  name: 'Attack on Titan',
  poster: 'https://img.test/poster.jpg',
  releaseInfo: '2013',
  description: 'Centuries ago, mankind was slaughtered.',
);

const _detail = StremioMeta(
  id: 'kitsu:7442',
  type: 'series',
  name: 'Attack on Titan',
  poster: 'https://img.test/poster.jpg',
  releaseInfo: '2013',
  imdbRating: '8.4',
  imdbId: 'tt2560140',
  genres: ['Action', 'Fantasy'],
  description: 'Centuries ago, mankind was slaughtered.',
  videos: [
    StremioVideo(
      id: 'kitsu:7442:1',
      season: 1,
      episode: 1,
      title: 'To You Two Thousand Years Later',
    ),
    StremioVideo(
      id: 'kitsu:7442:2',
      season: 1,
      episode: 2,
      title: 'That Day',
    ),
  ],
);

const _source = StreamSource(
  id: 'kitsu:url:0',
  providerId: 'community.anime.kitsu',
  providerName: 'Anime Kitsu',
  kind: SourceKind.addon,
  title: 'Direct source',
  url: 'https://cdn.test/episode.mp4',
);

class _RecordingPlayerService extends PlayerService {
  int stops = 0;

  @override
  Future<void> stop() async {
    stops++;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  Object? metaError,
  StreamSearchResult? streams,
  Future<StreamSearchResult>? pendingStreams,
  PlayerService? player,
  void Function(Map<String, dynamic>? extra)? onPlayerExtra,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const StremioMetaScreen(
          initialMeta: _initial,
          addonUrl: 'https://anime-kitsu.strem.fun',
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (context, state) {
          onPlayerExtra?.call(state.extra as Map<String, dynamic>?);
          return const Scaffold(body: Text('PLAYER'));
        },
      ),
      GoRoute(
        path: '/debrid-services',
        builder: (context, state) =>
            const Scaffold(body: Text('DEBRID SETTINGS')),
      ),
      GoRoute(
        path: '/stremio-addons',
        builder: (context, state) => const Scaffold(body: Text('ADDONS')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (player != null) playerServiceProvider.overrideWithValue(player),
        stremioMetaProvider.overrideWith((ref, params) async {
          if (metaError != null) throw metaError;
          return _detail;
        }),
        addonStreamsProvider.overrideWith(
          (ref, params) =>
              pendingStreams ??
              Future.value(
                streams ?? const StreamSearchResult(sources: [_source]),
              ),
        ),
        showsRepositoryProvider.overrideWith((ref) async => ShowsRepository()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  if (pendingStreams == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('muestra la ficha completa con temporadas y episodios',
      (tester) async {
    await _pump(tester);

    expect(find.text('Attack on Titan'), findsOneWidget);
    expect(find.textContaining('2013'), findsOneWidget);
    expect(find.textContaining('Action'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.textContaining('To You Two Thousand Years Later'),
        findsOneWidget);
    expect(find.textContaining('S01E02'), findsOneWidget);
  });

  testWidgets('reproducir un episodio abre el selector y luego el reproductor',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.textContaining('To You Two Thousand Years Later'));
    await tester.pumpAndSettle();

    expect(find.text('Select Stream'), findsOneWidget);
    expect(find.textContaining('Attack on Titan S01E01'), findsOneWidget);

    await tester.tap(find.text('Direct source'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
  });

  testWidgets('reproducir suelta el canal antes de resolver las fuentes',
      (tester) async {
    final player = _RecordingPlayerService();
    final pending = Completer<StreamSearchResult>();
    await _pump(tester, player: player, pendingStreams: pending.future);

    await tester.tap(find.textContaining('To You Two Thousand Years Later'));
    await tester.pump();
    await tester.pump();

    expect(
      player.stops,
      1,
      reason: 'el canal no puede seguir sonando mientras se buscan fuentes',
    );
    expect(find.text('Select Stream'), findsNothing);

    pending.complete(const StreamSearchResult(sources: [_source]));
    await tester.pumpAndSettle();
  });

  testWidgets('las cabeceras del addon viajan al reproductor', (tester) async {
    Map<String, dynamic>? extra;
    const protectedSource = StreamSource(
      id: 'anime:url:0',
      providerId: 'com.animeflv.stremio.addon',
      providerName: 'AnimES',
      kind: SourceKind.addon,
      title: 'AnimeAV1 MP4Upload',
      url: 'https://a4.mp4upload.com/video.mp4',
      headers: {'Referer': 'https://a1.mp4upload.com'},
    );

    await _pump(
      tester,
      streams: const StreamSearchResult(sources: [protectedSource]),
      onPlayerExtra: (value) => extra = value,
    );

    await tester.tap(find.textContaining('To You Two Thousand Years Later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AnimeAV1 MP4Upload'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    expect(extra?['httpHeaders'], {'Referer': 'https://a1.mp4upload.com'});
  });

  testWidgets('el episodio llega al reproductor con la identidad de la ficha',
      (tester) async {
    Map<String, dynamic>? extra;
    await _pump(tester, onPlayerExtra: (value) => extra = value);

    await tester.tap(find.textContaining('To You Two Thousand Years Later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct source'));
    await tester.pumpAndSettle();

    expect(find.text('PLAYER'), findsOneWidget);
    final request = extra?['playback'];
    expect(request, isA<PlaybackRequest>());
    final playback = request as PlaybackRequest;
    expect(playback.kind, PlaybackKind.series);
    expect(
      playback.mediaKey,
      'imdb:tt2560140',
      reason: 'con IMDB la clave coincide con la ficha de Trakt del mismo título',
    );
    expect(playback.season, 1);
    expect(playback.episode, 1);
    expect(playback.title, 'Attack on Titan S01E01');
    expect(playback.sourceId, _source.id);
  });

  testWidgets('si el addon no publica ficha, se queda con el catálogo',
      (tester) async {
    await _pump(
      tester,
      metaError: const StremioAddonException('El addon respondió HTTP 500'),
    );

    expect(find.text('Attack on Titan'), findsOneWidget);
    expect(find.textContaining('No se pudo cargar la ficha completa'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget,
        reason: 'sin episodios se ofrece reproducir el título del catálogo');
  });
}
