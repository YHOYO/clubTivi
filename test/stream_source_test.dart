import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/models/stream_source.dart';
import 'package:clubtivi/data/services/debrid_settings.dart';
import 'package:flutter_test/flutter_test.dart';

StreamSource _source({
  String? url,
  String? magnetUrl,
  String? infoHash,
  String? unavailableReason,
  int? sizeBytes,
  Set<String> audio = const {},
  String? referer,
  Map<String, String> headers = const {},
  bool needsProxy = false,
}) {
  return StreamSource(
    id: 'id',
    providerId: 'provider',
    providerName: 'provider',
    kind: SourceKind.addon,
    title: 'Title',
    url: url,
    magnetUrl: magnetUrl,
    infoHash: infoHash,
    unavailableReason: unavailableReason,
    sizeBytes: sizeBytes,
    audioLanguages: audio,
    referer: referer,
    headers: headers,
    needsProxy: needsProxy,
  );
}

void main() {
  test('la localización prioriza URL, luego magnet y luego infoHash', () {
    expect(
      _source(url: 'https://x', magnetUrl: 'magnet:?x', infoHash: 'abc').locator,
      StreamLocator.url,
    );
    expect(
      _source(magnetUrl: 'magnet:?x', infoHash: 'abc').locator,
      StreamLocator.magnet,
    );
    expect(_source(infoHash: 'abc').locator, StreamLocator.infoHash);
    expect(_source().locator, isNull);
  });

  test('disponibilidad: URL directa siempre; magnet solo sin motivo', () {
    expect(_source(url: 'https://x').isAvailable, isTrue);
    expect(
      _source(magnetUrl: 'magnet:?x', unavailableReason: kDebridRequiredReason)
          .isAvailable,
      isFalse,
    );
    expect(_source(magnetUrl: 'magnet:?x').isAvailable, isTrue);
    expect(_source(infoHash: 'abc').isAvailable, isTrue);
    expect(_source().isAvailable, isFalse);
  });

  test('formatea el tamaño legible', () {
    expect(_source(sizeBytes: 4 * 1024 * 1024 * 1024).filesizeDisplay, '4.0 GB');
    expect(_source(sizeBytes: 700 * 1024 * 1024).filesizeDisplay, '700 MB');
    expect(_source().filesizeDisplay, '');
  });

  test('copyWith enriquece con debrid sin perder idiomas ni proxy', () {
    final original = _source(
      magnetUrl: 'magnet:?x',
      infoHash: 'abc',
      sizeBytes: 1024,
      audio: {kLanguageSpanishLatin},
      referer: 'https://site',
      headers: {'User-Agent': 'ua'},
      needsProxy: true,
    );

    final enriched = original.copyWith(
      kind: SourceKind.debrid,
      isCached: true,
      providerName: 'real-debrid ⚡',
    );

    expect(enriched.kind, SourceKind.debrid);
    expect(enriched.isCached, isTrue);
    expect(enriched.providerName, 'real-debrid ⚡');
    expect(enriched.audioLanguages, original.audioLanguages);
    expect(enriched.sizeBytes, original.sizeBytes);
    expect(enriched.referer, 'https://site');
    expect(enriched.headers, {'User-Agent': 'ua'});
    expect(enriched.needsProxy, isTrue);
    expect(enriched.magnetUrl, original.magnetUrl);
  });
}
