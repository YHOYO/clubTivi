import '../../models/show.dart';
// Los clientes debrid viven en su propio fichero; este import trae el
// barrel (Real-Debrid, AllDebrid, Premiumize…) que usa la factoría.
import 'debrid_client.dart';

/// Supported debrid service types
enum DebridType {
  realDebrid('Real-Debrid', 'real-debrid.com/apitoken'),
  allDebrid('AllDebrid', 'alldebrid.com/apikeys'),
  premiumize('Premiumize', 'premiumize.me/account'),
  debridLink('Debrid-Link', 'debrid-link.com/webapp/apikey'),
  offcloud('Offcloud', 'offcloud.com/account/apikeys'),
  putio('put.io', 'app.put.io/settings/account');

  final String displayName;
  final String tokenUrl;
  const DebridType(this.displayName, this.tokenUrl);
}

/// A file within a cached torrent
class DebridFile {
  final int id;
  final String filename;
  final int filesize;

  const DebridFile({
    required this.id,
    required this.filename,
    required this.filesize,
  });

  String get quality {
    final lower = filename.toLowerCase();
    if (lower.contains('2160p') || lower.contains('4k')) return '4K';
    if (lower.contains('1080p')) return '1080p';
    if (lower.contains('720p')) return '720p';
    if (lower.contains('480p')) return '480p';
    return 'Unknown';
  }

  String get filesizeDisplay {
    final gb = filesize / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = filesize / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }
}

/// Abstract interface for all debrid services
abstract class DebridService {
  String get serviceName;

  /// Check if torrent hashes are instantly available (cached)
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  );

  /// Unrestrict/unlock a link to get a direct stream URL
  Future<ResolvedStream> unrestrictLink(String link);

  /// Full flow: magnet → stream URL
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  });

  /// Verify the API token is valid
  Future<bool> verifyToken();
}

/// Factory to create the right debrid client for a given type
DebridService createDebridService(DebridType type, String apiToken) {
  switch (type) {
    case DebridType.realDebrid:
      return RealDebridService(apiToken: apiToken);
    case DebridType.allDebrid:
      return AllDebridService(apiToken: apiToken);
    case DebridType.premiumize:
      return PremiumizeService(apiToken: apiToken);
    case DebridType.debridLink:
      return DebridLinkService(apiToken: apiToken);
    case DebridType.offcloud:
      return OffcloudService(apiToken: apiToken);
    case DebridType.putio:
      return PutioService(apiToken: apiToken);
  }
}
