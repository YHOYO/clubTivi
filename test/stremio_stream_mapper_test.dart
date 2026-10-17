// El mapeo es la frontera entre el protocolo de Stremio y el tipo único de la
// app: si pierde `fileIdx`, los `sources` o las cabeceras, el usuario lo nota
// como un stream que no arranca. Se prueba con payloads reales grabados.
import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/stremio_stream_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

const _providerId = 'com.stremio.torrentio.addon';
const _providerName = 'Torrentio';

List<Map<String, dynamic>> _streamsOf(String fixture) {
  final raw = File('test/fixtures/stremio/$fixture').readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final entry in data['streams'] as List)
      Map<String, dynamic>.from(entry as Map),
  ];
}

StreamSource? _map(String fixture, int index) {
  final streams = _streamsOf(fixture);
  return stremioStreamToSource(
    streams[index],
    providerId: _providerId,
    providerName: _providerName,
    index: index,
  );
}

void main() {
  test('un torrent real de Torrentio conserva hash, fileIdx, seeds y tamaño',
      () {
    final source = _map('torrentio_streams.json', 0)!;

    expect(source.kind, SourceKind.torrent);
    expect(source.providerId, _providerId);
    expect(source.providerName, _providerName);
    expect(source.infoHash, 'f181e166e440b355ce73cc8b988f47ad7e8ea6ab');
    expect(source.fileIdx, 0);
    expect(source.quality, '4K', reason: 'el nombre del addon dice "4k"');
    expect(source.seeds, 1);
    expect(source.sizeBytes, closeTo(7.1 * 1024 * 1024 * 1024, 1));
    expect(source.title, contains('Big Buck Bunny'));
    expect(source.locator, StreamLocator.magnet);
    expect(source.magnetUrl, contains('f181e166e440b355ce73cc8b988f47ad7e8ea6ab'));
  });

  test('los sources del addon se traducen a trackers y el dht se ignora', () {
    final streams = _streamsOf('torrentio_streams.json');
    final raw = streams[1];
    final source = _map('torrentio_streams.json', 1)!;

    final trackers = (raw['sources'] as List)
        .where((s) => (s as String).startsWith('tracker:'))
        .map((s) => (s as String).substring('tracker:'.length))
        .toList();
    final dht = (raw['sources'] as List)
        .where((s) => (s as String).startsWith('dht:'))
        .length;

    expect(trackers, isNotEmpty);
    expect('&tr='.allMatches(source.magnetUrl!).length, trackers.length);
    expect(source.magnetUrl, contains(Uri.encodeComponent(trackers.first)));
    expect(source.magnetUrl, isNot(contains('dht')));
    expect((raw['sources'] as List).length, trackers.length + dht);
    expect(source.fileIdx, 3);
    expect(source.quality, '1080p');
    expect(source.audioLanguages, containsAll(<String>['en', 'ru']),
        reason: 'los idiomas del payload real vienen como banderas');
  });

  test('un infoHash sin sources genera un magnet válido', () {
    final source = _map('helloworld_streams.json', 0)!;

    expect(source.magnetUrl,
        'magnet:?xt=urn:btih:24c8802e2624e17d46cd555f364debd949f2c81e'
        '&dn=The%20Wizard%20of%20Oz');
    expect(source.fileIdx, 0);
    expect(source.seeds, isNull, reason: 'el payload no publica seeds');
    expect(source.sizeBytes, isNull);
    expect(source.isAvailable, isTrue);
  });

  test('los trackers del magnet vienen de sources, incluido el dht aparte', () {
    final source = _map('helloworld_streams.json', 1)!;

    expect('&tr='.allMatches(source.magnetUrl!).length, 3);
    expect(
      source.magnetUrl,
      contains(Uri.encodeComponent('udp://tracker.publicbt.com/announce')),
    );
    expect(source.quality, '1080p', reason: 'el title del addon lo declara');
  });

  test('un stream con url directa y sin cabeceras es reproducible sin proxy',
      () {
    final source = _map('helloworld_streams.json', 2)!;

    expect(source.kind, SourceKind.addon);
    expect(source.isDirect, isTrue);
    expect(source.url, 'http://clips.vorwaerts-gmbh.de/big_buck_bunny.mp4');
    expect(source.needsProxy, isFalse);
    expect(source.headers, isEmpty);
    expect(source.referer, isNull);
    expect(source.isAvailable, isTrue);
  });

  test('behaviorHints.proxyHeaders y notWebReady llegan intactos al tipo', () {
    final source = _map('direct_url_proxy_headers.json', 0)!;

    expect(source.isDirect, isTrue);
    expect(source.needsProxy, isTrue);
    expect(source.headers['Referer'], 'https://example-cdn.net/');
    expect(source.headers['User-Agent'], contains('Mozilla/5.0'));
    expect(source.referer, 'https://example-cdn.net/');
    expect(source.sizeBytes, 2254857830, reason: 'behaviorHints.videoSize');
    expect(source.seeds, 87);
    expect(source.quality, '1080p');
    expect(source.audioLanguages, {kLanguageSpanishLatin});
    expect(source.subtitles, hasLength(2));
    expect(source.subtitles.map((s) => s.language).toSet(), {'es', 'en'});
    expect(source.subtitles.first.url, contains('.srt'));
  });

  test('el segundo stream del addon directo conserva su propio referer', () {
    final source = _map('direct_url_proxy_headers.json', 1)!;

    expect(source.headers, {'Referer': 'https://example-cdn.net/streaming'});
    expect(source.referer, 'https://example-cdn.net/streaming');
    expect(source.quality, '4K');
    expect(source.sizeBytes, closeTo(14.3 * 1024 * 1024 * 1024, 1));
    expect(source.subtitles, isEmpty);
  });

  test('ytId y externalUrl se descartan: no son reproducibles', () {
    expect(_map('helloworld_streams.json', 3), isNull, reason: 'ytId');
    expect(_map('helloworld_streams.json', 4), isNull, reason: 'externalUrl');
  });

  test('un stream sin url ni infoHash devuelve null', () {
    expect(
      stremioStreamToSource(
        const {'name': 'vacío'},
        providerId: 'x',
        providerName: 'X',
        index: 0,
      ),
      isNull,
    );
  });

  test('la entrada vacía de url no cuenta como directa', () {
    expect(
      stremioStreamToSource(
        const {'url': '', 'name': 'roto'},
        providerId: 'x',
        providerName: 'X',
        index: 0,
      ),
      isNull,
    );
  });
}
