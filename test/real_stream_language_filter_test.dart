// Los tres fixtures son respuestas reales: Torrentio y Comet para
// MobLand S01E01, y AnimES/AnimeAV1 para Jujutsu Kaisen Ep. 1. La prueba cruza
// el mapeador y el filtro que usa el selector.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/stremio_stream_mapper.dart';
import 'package:clubtivi/data/services/stream_ranker.dart';
import 'package:flutter_test/flutter_test.dart';

List<StreamSource> _mapFixture(String fixture, String providerName) {
  final raw = File('test/fixtures/stremio/$fixture').readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;
  final streams = data['streams'] as List;
  final sources = <StreamSource>[];
  for (var i = 0; i < streams.length; i++) {
    final entry = streams[i];
    if (entry is! Map) continue;
    final source = stremioStreamToSource(
      Map<String, dynamic>.from(entry),
      providerId: providerName.toLowerCase(),
      providerName: providerName,
      index: i,
    );
    if (source != null) sources.add(source);
  }
  return sources;
}

StreamSource _oneWith(List<StreamSource> sources, String needle) =>
    sources.firstWhere(
      (source) =>
          source.title.contains(needle) ||
          (source.qualityDetail ?? '').contains(needle),
      orElse: () => throw StateError('No hay fuente con "$needle"'),
    );

void main() {
  test('Torrentio real: MULTi y DUAL no son español; Castellano sí', () {
    final sources = _mapFixture('torrentio_mobland_s01e01.json', 'Torrentio');

    final multi = _oneWith(sources, 'MobLand.S01.MULTi.2160p');
    final dual = _oneWith(sources, 'MobLand.S01E01-02-03.1080p.WEB-DL.DUAL');
    final castellano = _oneWith(sources, 'Castellano.1080p.x264');
    final russianSubs = _oneWith(sources, 'Sub (Rus Eng)');

    expect(
      isSpanishSource(multi),
      isFalse,
      reason: 'MULTi con banderas 🇬🇧/🇵🇱 no declara español',
    );
    expect(
      isSpanishSource(dual),
      isFalse,
      reason: 'DUAL con banderas 🇬🇧/🇵🇹 tampoco',
    );
    expect(
      isSpanishSource(russianSubs),
      isFalse,
      reason: 'Sub (Rus Eng) no son subtítulos españoles',
    );
    expect(isSpanishSource(castellano), isTrue);

    final filtered = selectStreams(
      sources,
      preferences: LanguagePreferences.defaults,
      spanishOnly: true,
    );
    expect(filtered, isNotEmpty);
    expect(filtered.map((s) => s.id), contains(castellano.id));
    expect(filtered.map((s) => s.id), isNot(contains(multi.id)));
    expect(filtered.map((s) => s.id), isNot(contains(dual.id)));
    expect(filtered.every(isSpanishSource), isTrue);
  });

  test('Comet real: la fila 🇪🇸 sobrevive y la MULTi no entra', () {
    final sources = _mapFixture('comet_mobland_s01e01.json', 'Comet');

    final multi = _oneWith(sources, 'MobLand.S01E01.Stick.or.Twist.MULTi');
    final spanish = _oneWith(sources, 'Subtitulado.Esp');

    expect(isSpanishSource(multi), isFalse);
    expect(isSpanishSource(spanish), isTrue);
    expect(spanish.subtitleLanguages, {kLanguageSpanish});
    expect(
      spanish.audioLanguages,
      isEmpty,
      reason: 'la bandera 🇪🇸 describe subtítulos, no audio',
    );

    final filtered = selectStreams(
      sources,
      preferences: LanguagePreferences.defaults,
      spanishOnly: true,
    );
    expect(filtered.map((s) => s.id), contains(spanish.id));
    expect(filtered.map((s) => s.id), isNot(contains(multi.id)));
  });

  test('anime real en español: subtítulos y DUB latino entran al filtro', () {
    final sources = _mapFixture(
      'animes_jujutsu_spanish_streams.json',
      'AnimES',
    );

    expect(sources, hasLength(3));
    expect(sources.where(isSpanishSource), hasLength(3));
    expect(
      sources.where(hasSpanishAudio),
      hasLength(1),
      reason: 'solo el DUB 🇲🇽 anuncia audio español',
    );
    expect(
      sources.where(hasSpanishSubtitles),
      hasLength(2),
      reason: 'las dos fuentes 🇯🇵🇪🇸 traen subtítulos españoles',
    );
    expect(sources.first.displayName, 'Jujutsu Kaisen Ep. 1');

    final filtered = selectStreams(
      sources,
      preferences: LanguagePreferences.defaults,
      spanishOnly: true,
    );
    expect(filtered, hasLength(3));
  });
}
