import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';
import 'package:archive/archive.dart';

import '../../models/epg.dart';

/// Parses XMLTV format EPG data from a URL, file, or string.
///
/// Supports:
/// - Standard XMLTV format (http://wiki.xmltv.org/index.php/XMLTVFormat)
/// - Gzip compressed files (.xml.gz)
/// - Multiple display-name elements per channel
/// - XMLTV date format: "20260221120000 +0000"
class XmltvParser {
  /// Parse XMLTV content from a raw XML string.
  XmltvResult parse(String xmlContent, {required String sourceId}) {
    final document = XmlDocument.parse(xmlContent);
    final tv = document.rootElement;

    final channels = <EpgChannel>[];
    final programmes = <EpgProgramme>[];

    // Parse channels
    for (final element in tv.findElements('channel')) {
      final channel = _parseChannel(element, sourceId);
      if (channel != null) channels.add(channel);
    }

    // Parse programmes
    for (final element in tv.findElements('programme')) {
      final programme = _parseProgramme(element, sourceId);
      if (programme != null) programmes.add(programme);
    }

    return XmltvResult(channels: channels, programmes: programmes);
  }

  /// Parse XMLTV from bytes (handles gzip decompression automatically).
  XmltvResult parseBytes(List<int> bytes, {required String sourceId}) {
    List<int> decompressed;
    try {
      decompressed = GZipDecoder().decodeBytes(bytes);
    } catch (_) {
      // Not gzipped, use as-is
      decompressed = bytes;
    }
    final xmlContent = utf8.decode(decompressed, allowMalformed: true);
    return parse(xmlContent, sourceId: sourceId);
  }

  /// Parse XMLTV from a local file.
  Future<XmltvResult> parseFile(File file, {required String sourceId}) async {
    final bytes = await file.readAsBytes();
    return parseBytes(bytes, sourceId: sourceId);
  }

  /// Parse a possibly gzipped XMLTV byte buffer incrementally.
  ///
  /// Shorthand for [parseStreaming] that detects the gzip magic bytes, which is
  /// what a downloaded feed looks like.
  Future<XmltvStreamStats> parseBytesStreaming(
    List<int> bytes, {
    required String sourceId,
    int batchSize = 2000,
    DateTime? keepFrom,
    DateTime? keepUntil,
    void Function(List<EpgChannel> channels)? onChannels,
    Future<void> Function(List<EpgProgramme> programmes)? onProgrammes,
  }) {
    final gzipped =
        bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    return parseStreaming(
      Stream<List<int>>.value(bytes),
      sourceId: sourceId,
      gzipped: gzipped,
      batchSize: batchSize,
      keepFrom: keepFrom,
      keepUntil: keepUntil,
      onChannels: onChannels,
      onProgrammes: onProgrammes,
    );
  }

  /// Parse an XMLTV feed as a stream of events, one element at a time.
  ///
  /// [parse] materializes the decompressed XML *and* a full document tree *and*
  /// every model object at once: an 8 MB gzip feed with ~180k programmes needs
  /// several hundred MB of headroom that way. This path keeps a single element
  /// in memory, hands [batchSize]-sized batches to [onProgrammes] (so the caller
  /// can persist them and let the garbage collector reclaim them) and drops
  /// programmes outside the [keepFrom]/[keepUntil] window — the guide only ever
  /// reads a few days around now, and keeping the rest is what makes both the
  /// database and the app grow without bound.
  Future<XmltvStreamStats> parseStreaming(
    Stream<List<int>> bytes, {
    required String sourceId,
    int batchSize = 2000,
    DateTime? keepFrom,
    DateTime? keepUntil,
    bool gzipped = false,
    void Function(List<EpgChannel> channels)? onChannels,
    Future<void> Function(List<EpgProgramme> programmes)? onProgrammes,
  }) async {
    assert(batchSize > 0, 'batchSize debe ser positivo');

    final stats = XmltvStreamStats();
    final decoded = gzipped ? bytes.transform(gzip.decoder) : bytes;
    final events = decoded
        .transform(utf8.decoder)
        .toXmlEvents()
        .normalizeEvents()
        .flatten();

    final buffer = StringBuffer();
    var capturing = false;
    var depth = 0;
    var channelBatch = <EpgChannel>[];
    var programmeBatch = <EpgProgramme>[];

    Future<void> flushChannels() async {
      if (channelBatch.isEmpty) return;
      final batch = channelBatch;
      channelBatch = <EpgChannel>[];
      onChannels?.call(batch);
    }

    Future<void> flushProgrammes() async {
      if (programmeBatch.isEmpty) return;
      final batch = programmeBatch;
      programmeBatch = <EpgProgramme>[];
      stats.batches++;
      if (onProgrammes != null) await onProgrammes(batch);
    }

    Future<void> finishElement(String fragment) async {
      capturing = false;
      depth = 0;
      buffer.clear();

      final XmlElement element;
      try {
        element = XmlDocument.parse(fragment).rootElement;
      } catch (_) {
        stats.malformed++;
        return;
      }

      if (element.localName == 'channel') {
        final channel = _parseChannel(element, sourceId);
        if (channel != null) {
          channelBatch.add(channel);
          stats.channels++;
        }
        return;
      }

      final programme = _parseProgramme(element, sourceId);
      if (programme == null) {
        stats.malformed++;
        return;
      }

      final startsBeforeEnd =
          keepUntil == null || !programme.start.isAfter(keepUntil);
      final endsAfterStart =
          keepFrom == null || !programme.stop.isBefore(keepFrom);
      if (!startsBeforeEnd || !endsAfterStart) {
        stats.skipped++;
        return;
      }

      // The guide channels always arrive before the first programme: hand them
      // over before the data that depends on them.
      await flushChannels();
      programmeBatch.add(programme);
      stats.programmes++;
      if (programmeBatch.length >= batchSize) await flushProgrammes();
    }

    await for (final event in events) {
      if (!capturing) {
        if (event is XmlStartElementEvent &&
            (event.localName == 'channel' ||
                event.localName == 'programme')) {
          capturing = true;
          depth = 1;
          buffer.write(event.toString());
          if (event.isSelfClosing) {
            await finishElement(buffer.toString());
          }
        }
        continue;
      }

      buffer.write(event.toString());
      if (event is XmlStartElementEvent) {
        if (!event.isSelfClosing) depth++;
      } else if (event is XmlEndElementEvent) {
        depth--;
        if (depth <= 0) await finishElement(buffer.toString());
      }
    }

    await flushChannels();
    await flushProgrammes();
    return stats;
  }

  EpgChannel? _parseChannel(XmlElement element, String sourceId) {
    final id = element.getAttribute('id');
    if (id == null || id.isEmpty) return null;

    final displayNames = element
        .findElements('display-name')
        .map((e) => e.innerText.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    final iconElement = element.findElements('icon').firstOrNull;
    final iconUrl = iconElement?.getAttribute('src');

    // Some XMLTV sources include channel number in display-name
    String? number;
    for (final name in displayNames) {
      if (RegExp(r'^\d+$').hasMatch(name)) {
        number = name;
        break;
      }
    }

    return EpgChannel(
      id: id,
      sourceId: sourceId,
      displayNames: displayNames,
      iconUrl: iconUrl,
      number: number,
    );
  }

  EpgProgramme? _parseProgramme(XmlElement element, String sourceId) {
    final channelId = element.getAttribute('channel');
    final startStr = element.getAttribute('start');
    final stopStr = element.getAttribute('stop');

    if (channelId == null || startStr == null || stopStr == null) return null;

    final start = _parseXmltvDate(startStr);
    final stop = _parseXmltvDate(stopStr);
    if (start == null || stop == null) return null;

    final title = element.findElements('title').firstOrNull?.innerText.trim();
    if (title == null || title.isEmpty) return null;

    final subtitle =
        element.findElements('sub-title').firstOrNull?.innerText.trim();
    final description =
        element.findElements('desc').firstOrNull?.innerText.trim();
    final category =
        element.findElements('category').firstOrNull?.innerText.trim();

    final iconElement = element.findElements('icon').firstOrNull;
    final iconUrl = iconElement?.getAttribute('src');

    final episodeNum =
        element.findElements('episode-num').firstOrNull?.innerText.trim();

    final rating = element
        .findElements('rating')
        .firstOrNull
        ?.findElements('value')
        .firstOrNull
        ?.innerText
        .trim();

    final isNew = element.findElements('new').isNotEmpty;

    return EpgProgramme(
      channelId: channelId,
      sourceId: sourceId,
      start: start,
      stop: stop,
      title: title,
      subtitle: subtitle,
      description: description,
      category: category,
      iconUrl: iconUrl,
      episodeNum: episodeNum,
      rating: rating,
      isNew: isNew,
    );
  }

  /// Parse XMLTV date format: "20260221120000 +0000" or "20260221120000"
  DateTime? _parseXmltvDate(String dateStr) {
    try {
      dateStr = dateStr.trim();

      // Extract timezone offset if present
      Duration tzOffset = Duration.zero;
      final tzMatch = RegExp(r'([+-]\d{4})$').firstMatch(dateStr);
      if (tzMatch != null) {
        final tz = tzMatch.group(1)!;
        final sign = tz[0] == '+' ? 1 : -1;
        final hours = int.parse(tz.substring(1, 3));
        final minutes = int.parse(tz.substring(3, 5));
        tzOffset = Duration(hours: hours * sign, minutes: minutes * sign);
        dateStr = dateStr.substring(0, tzMatch.start).trim();
      }

      // Parse the date part: "20260221120000"
      if (dateStr.length < 14) {
        dateStr = dateStr.padRight(14, '0');
      }

      final year = int.parse(dateStr.substring(0, 4));
      final month = int.parse(dateStr.substring(4, 6));
      final day = int.parse(dateStr.substring(6, 8));
      final hour = int.parse(dateStr.substring(8, 10));
      final minute = int.parse(dateStr.substring(10, 12));
      final second = int.parse(dateStr.substring(12, 14));

      return DateTime.utc(year, month, day, hour, minute, second)
          .subtract(tzOffset);
    } catch (_) {
      return null;
    }
  }
}

/// Outcome of a streaming XMLTV parse.
class XmltvStreamStats {
  /// Channels handed to the caller.
  int channels = 0;

  /// Programmes kept (inside the retention window).
  int programmes = 0;

  /// Programmes dropped because they fall outside the window.
  int skipped = 0;

  /// Elements that could not be parsed.
  int malformed = 0;

  /// Number of programme batches passed to the caller.
  int batches = 0;

  @override
  String toString() =>
      'XmltvStreamStats(channels: $channels, programmes: $programmes, '
      'skipped: $skipped, malformed: $malformed, batches: $batches)';
}

/// Result of parsing an XMLTV document.
class XmltvResult {
  final List<EpgChannel> channels;
  final List<EpgProgramme> programmes;

  const XmltvResult({
    required this.channels,
    required this.programmes,
  });
}
