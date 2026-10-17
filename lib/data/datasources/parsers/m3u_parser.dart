import '../../models/channel.dart';

/// Parses M3U and M3U Plus playlist formats.
///
/// Supports:
/// - Standard M3U (#EXTM3U / #EXTINF)
/// - M3U Plus extended attributes (tvg-id, tvg-name, tvg-logo, group-title, etc.)
/// - Xtream Codes style attributes (tvg-chno, tvg-shift)
/// - `#EXTVLCOPT` per-entry HTTP headers (http-referrer, http-user-agent, …)
/// - Multiple URL formats (HTTP, HTTPS, RTMP, RTSP, UDP)
class M3uParser {
  /// Parse M3U content from a string.
  M3uResult parse(String content, {required String providerId}) {
    final lines = content.split(RegExp(r'\r?\n'));
    final channels = <Channel>[];
    final errors = <String>[];

    if (lines.isEmpty || !lines.first.trim().startsWith('#EXTM3U')) {
      errors.add('Missing #EXTM3U header');
    }

    // Plenty of playlists announce their own XMLTV feed in the header; without
    // it the guide stays empty until the user adds the source by hand.
    final urlTvg = _parseUrlTvg(lines);

    // Same-content duplicates: the first entry stays visible and the rest are
    // stored hidden as failover alternatives. Otherwise the last URL of each
    // channel overwrote the previous one and the working stream was lost.
    final seenIds = <String>{};

    String? currentExtInf;
    var currentHeaders = <String, String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.isEmpty || line == '#EXTM3U') continue;

      // Skip global EXTM3U attributes line
      if (line.startsWith('#EXTM3U ')) continue;

      if (line.startsWith('#EXTINF:')) {
        currentExtInf = line;
        currentHeaders = <String, String>{};
        continue;
      }

      // Per-entry playback options. VLC and friends honour these; the streams
      // they guard (referrer-locked CDNs) reject a plain GET with 403, so they
      // have to travel with the channel.
      if (line.startsWith('#EXTVLCOPT:')) {
        final header = _parseVlcOpt(line.substring('#EXTVLCOPT:'.length));
        if (header != null) currentHeaders[header.$1] = header.$2;
        continue;
      }

      // Skip other directives
      if (line.startsWith('#')) continue;

      // This should be a URL
      if (currentExtInf != null) {
        try {
          final channel =
              _parseEntry(currentExtInf, line, providerId, currentHeaders);
          if (channel != null) {
            if (seenIds.add(channel.id)) {
              channels.add(channel);
            } else {
              // Segunda y siguientes apariciones del mismo canal: se guardan
              // como alternativa oculta con id propio hasta que uno libre.
              var occurrence = 1;
              var alternative = channel.asAlternative(providerId);
              while (!seenIds.add(alternative.id)) {
                alternative =
                    channel.asAlternative(providerId, occurrence: ++occurrence);
              }
              channels.add(alternative);
            }
          }
        } catch (e) {
          errors.add('Line $i: $e');
        }
        currentExtInf = null;
        currentHeaders = <String, String>{};
      }
    }

    return M3uResult(channels: channels, errors: errors, urlTvg: urlTvg);
  }

  /// XMLTV feed announced in a playlist header, if any.
  ///
  /// Public so an already-added provider can have its guide registered without
  /// re-downloading the whole playlist (see ProviderManager).
  static String? urlTvgFromHeader(String header) =>
      _parseUrlTvg(header.split(RegExp(r'\r?\n')));

  /// Read the XMLTV guide URL announced in the `#EXTM3U` header.
  ///
  /// Accepted spellings: `url-tvg`, `x-tvg-url` (Kodi) and `tvg-url`.
  static String? _parseUrlTvg(List<String> lines) {
    for (final line in lines.take(4)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXTM3U')) continue;
      final match = RegExp(
        r'''(?:url-tvg|x-tvg-url|tvg-url)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(trimmed);
      final url = match?.group(1)?.trim();
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  /// Translate one `#EXTVLCOPT:` directive into an HTTP header.
  ///
  /// VLC's option names are mapped to the wire header they produce; anything
  /// unrecognised is passed through with its last dash-separated word
  /// capitalised, so `http-origin` becomes `Origin` without needing a case for
  /// every option a playlist might invent.
  static (String, String)? _parseVlcOpt(String directive) {
    final separator = directive.indexOf('=');
    if (separator <= 0) return null;
    final key = directive.substring(0, separator).trim().toLowerCase();
    final value = directive.substring(separator + 1).trim();
    if (value.isEmpty) return null;

    const knownKeys = <String, String>{
      'http-referrer': 'Referer',
      'http-referer': 'Referer',
      'http-user-agent': 'User-Agent',
      'http-origin': 'Origin',
      'http-cookies': 'Cookie',
      'http-cookie': 'Cookie',
      'http-forward-cookies': '',
    };
    if (knownKeys.containsKey(key)) {
      final name = knownKeys[key]!;
      // A flag-style option with no header of its own.
      if (name.isEmpty) return null;
      return (name, value);
    }

    if (!key.startsWith('http-')) return null;
    final words = key.substring('http-'.length).split('-');
    final name = words
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join('-');
    return (name, value);
  }

  Channel? _parseEntry(
    String extInf,
    String url,
    String providerId, [
    Map<String, String> httpHeaders = const {},
  ]) {
    if (url.isEmpty) return null;

    // Parse #EXTINF:-1 tvg-id="..." tvg-name="..." ... , Channel Name
    final attrs = _parseAttributes(extInf);
    final displayName = _parseDisplayName(extInf);

    if (displayName.isEmpty && attrs['tvg-name'] == null) return null;

    final name = displayName.isNotEmpty ? displayName : attrs['tvg-name']!;

    // Generate a stable ID from provider + tvg-id, or from URL *and* name.
    // The name is part of the fallback on purpose: the same stream URL is often
    // listed under several names/groups, and an URL-only ID made those entries
    // collide (the later one silently overwrote the earlier in the database).
    final tvgId = attrs['tvg-id'];
    final channelId = tvgId != null && tvgId.isNotEmpty
        ? '${providerId}_$tvgId'
        : '${providerId}_${'$url|$name'.hashCode}';

    // Parse channel number
    int? channelNumber;
    final chnoStr = attrs['tvg-chno'];
    if (chnoStr != null && chnoStr.isNotEmpty) {
      channelNumber = int.tryParse(chnoStr);
    }

    return Channel(
      id: channelId,
      providerId: providerId,
      name: name,
      tvgId: _emptyToNull(attrs['tvg-id']),
      tvgName: _emptyToNull(attrs['tvg-name']),
      tvgLogo: _emptyToNull(attrs['tvg-logo']),
      groupTitle: _emptyToNull(attrs['group-title']),
      channelNumber: channelNumber,
      streamUrl: url,
      streamType: _inferStreamType(attrs, url),
      httpHeaders: httpHeaders,
    );
  }

  /// Parse M3U Plus extended attributes from an #EXTINF line.
  /// Example: #EXTINF:-1 tvg-id="ESPN.us" tvg-name="ESPN HD" group-title="Sports",ESPN HD
  Map<String, String> _parseAttributes(String extInf) {
    final attrs = <String, String>{};

    // Match key="value" pairs
    final regex = RegExp(r'([\w-]+)="([^"]*)"');
    for (final match in regex.allMatches(extInf)) {
      attrs[match.group(1)!.toLowerCase()] = match.group(2)!;
    }

    return attrs;
  }

  /// Extract the display name (after the last comma in #EXTINF line).
  String _parseDisplayName(String extInf) {
    final commaIndex = extInf.lastIndexOf(',');
    if (commaIndex == -1) return '';
    return extInf.substring(commaIndex + 1).trim();
  }

  StreamType _inferStreamType(Map<String, String> attrs, String url) {
    final groupTitle = (attrs['group-title'] ?? '').toLowerCase();
    if (groupTitle.contains('vod') || groupTitle.contains('movie')) {
      return StreamType.vod;
    }
    if (groupTitle.contains('series')) {
      return StreamType.series;
    }
    // Xtream Codes URL patterns
    if (url.contains('/movie/')) return StreamType.vod;
    if (url.contains('/series/')) return StreamType.series;
    return StreamType.live;
  }

  String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}

/// Result of parsing an M3U playlist.
class M3uResult {
  final List<Channel> channels;
  final List<String> errors;

  /// XMLTV feed the playlist announces in its header, when it does.
  final String? urlTvg;

  const M3uResult({
    required this.channels,
    this.errors = const [],
    this.urlTvg,
  });

  bool get hasErrors => errors.isNotEmpty;
  int get channelCount => channels.length;
}
