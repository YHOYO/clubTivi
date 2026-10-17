import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';
import 'package:clubtivi/data/models/epg.dart';
import 'package:flutter_test/flutter_test.dart';

const _sample = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="clubTivi-test">
  <channel id="one.tv"><display-name>One</display-name><icon src="http://x/1.png"/></channel>
  <channel id="two.tv"><display-name>Two</display-name><display-name>2</display-name></channel>
  <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="one.tv">
    <title>Show A</title>
    <desc>Description A</desc>
    <category>News</category>
  </programme>
  <programme start="20260102120000 +0000" stop="20260102130000 +0000" channel="one.tv">
    <title>Show B</title>
  </programme>
  <!-- un programa roto: sin stop -->
  <programme start="20260103120000 +0000" channel="two.tv"><title>Broken</title></programme>
  <programme start="20270101120000 +0000" stop="20270101130000 +0000" channel="two.tv">
    <title>Far future</title>
  </programme>
</tv>
''';

void main() {
  late XmltvParser parser;

  setUp(() {
    parser = XmltvParser();
  });

  Stream<List<int>> bytesOf(String xml) =>
      Stream<List<int>>.value(utf8.encode(xml));

  test('emite canales y programas por lotes sin materializar el documento',
      () async {
    final channels = <EpgChannel>[];
    final programmes = <EpgProgramme>[];
    final batches = <int>[];

    final stats = await parser.parseStreaming(
      bytesOf(_sample),
      sourceId: 'src',
      batchSize: 2,
      onChannels: channels.addAll,
      onProgrammes: (batch) async {
        batches.add(batch.length);
        programmes.addAll(batch);
      },
    );

    expect(stats.channels, 2);
    expect(stats.programmes, 3);
    expect(stats.skipped, 0);
    // Un programa roto (sin stop) y ninguno más: se cuenta, no revienta.
    expect(stats.malformed, 1);

    expect(channels.map((c) => c.id), ['one.tv', 'two.tv']);
    expect(channels.first.primaryName, 'One');
    expect(channels.first.iconUrl, 'http://x/1.png');

    // 3 programas con lotes de 2 => 2 llamadas.
    expect(batches, [2, 1]);
    expect(stats.batches, 2);

    final showA = programmes.first;
    expect(showA.title, 'Show A');
    expect(showA.description, 'Description A');
    expect(showA.category, 'News');
    expect(showA.start.toUtc(), DateTime.utc(2026, 1, 1, 12));
    expect(showA.stop.toUtc(), DateTime.utc(2026, 1, 1, 13));

    // El canal llega antes que sus programas: quien los persiste los necesita.
    expect(channels, isNotEmpty);
  });

  test('descarta los programas fuera de la ventana de retención', () async {
    final programmes = <EpgProgramme>[];
    final stats = await parser.parseStreaming(
      bytesOf(_sample),
      sourceId: 'src',
      keepFrom: DateTime.utc(2026, 1, 1),
      keepUntil: DateTime.utc(2026, 1, 31),
      onProgrammes: (batch) async => programmes.addAll(batch),
    );

    expect(stats.programmes, 2, reason: 'solo los dos programas de enero');
    expect(stats.skipped, 1, reason: 'el del 2027 queda fuera');
    expect(programmes.map((p) => p.title), ['Show A', 'Show B']);
  });

  test('detecta el gzip y lo descomprime en streaming', () async {
    final gzipped = gzip.encode(utf8.encode(_sample));
    expect(gzipped[0], 0x1f);
    expect(gzipped[1], 0x8b);

    final programmes = <EpgProgramme>[];
    final stats = await parser.parseBytesStreaming(
      gzipped,
      sourceId: 'src',
      onProgrammes: (batch) async => programmes.addAll(batch),
    );

    expect(stats.channels, 2);
    expect(stats.programmes, 3);
    expect(programmes.first.title, 'Show A');
  });

  test('acepta entrada sin comprimir', () async {
    final stats = await parser.parseBytesStreaming(
      utf8.encode(_sample),
      sourceId: 'src',
    );

    expect(stats.programmes, 3);
  });

  test('parse() sigue devolviendo el documento completo', () {
    final result = parser.parse(_sample, sourceId: 'src');
    expect(result.channels.length, 2);
    expect(result.programmes.length, 3);
  });
}
