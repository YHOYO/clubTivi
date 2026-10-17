/// Modelos del protocolo de addons de Stremio (manifest y addon instalado).
///
/// Lógica pura: sin Flutter, sin red y sin almacenamiento. La validación del
/// manifest vive aquí para que la UI pueda explicar por qué una URL no sirve
/// antes de aceptarla.
library;

import 'show.dart';

/// Error con mensaje apto para el usuario sobre un addon o su manifest.
class StremioAddonException implements Exception {
  final String message;
  final Uri? url;

  const StremioAddonException(this.message, {this.url});

  @override
  String toString() => message;
}

/// Un parámetro `extra` de un catálogo (`skip`, `genre`, `search`, …).
///
/// `genre` trae sus opciones en el manifest; `search` es obligatorio en los
/// catálogos que sólo responden a una búsqueda y por eso no se pueden pintar
/// como fila.
class StremioCatalogExtra {
  final String name;
  final bool isRequired;
  final List<String> options;
  final int? optionsLimit;

  const StremioCatalogExtra({
    required this.name,
    this.isRequired = false,
    this.options = const [],
    this.optionsLimit,
  });

  static StremioCatalogExtra? fromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawOptions = value['options'];
    final options = rawOptions is List
        ? [
            for (final option in rawOptions)
              if (option is String && option.trim().isNotEmpty) option.trim(),
          ]
        : const <String>[];
    final limit = value['optionsLimit'];
    return StremioCatalogExtra(
      name: name.trim(),
      isRequired: value['isRequired'] == true,
      options: options,
      optionsLimit: limit is num ? limit.toInt() : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (isRequired) 'isRequired': true,
        if (options.isNotEmpty) 'options': options,
        if (optionsLimit != null) 'optionsLimit': optionsLimit,
      };

  @override
  String toString() => 'StremioCatalogExtra($name)';
}

/// Un catálogo declarado en el manifest.
class StremioCatalog {
  final String type;
  final String id;
  final String? name;
  final List<StremioCatalogExtra> extra;

  const StremioCatalog({
    required this.type,
    required this.id,
    this.name,
    this.extra = const [],
  });

  /// `true` cuando el catálogo sólo responde a `search`: no se puede mostrar
  /// como fila del descubrimiento, pero sí consultarse desde la búsqueda.
  bool get needsSearch =>
      extra.any((e) => e.name == 'search' && e.isRequired);

  /// `true` cuando la fila se puede pedir sin más datos que un género. Un
  /// `extra` obligatorio que no sabemos rellenar (`calendarVideosIds`, …) deja
  /// el catálogo fuera del descubrimiento en vez de pintar un error.
  bool get canBrowse =>
      extra.every((e) => !e.isRequired || e.name == 'genre');

  /// Género con opciones declaradas, si el addon lo admite.
  StremioCatalogExtra? get genreExtra {
    for (final entry in extra) {
      if (entry.name == 'genre' && entry.options.isNotEmpty) return entry;
    }
    return null;
  }

  static StremioCatalog? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = value['type'];
    final id = value['id'];
    if (type is! String || id is! String || type.isEmpty || id.isEmpty) {
      return null;
    }
    final name = value['name'];
    final rawExtra = value['extra'];
    return StremioCatalog(
      type: type,
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      extra: rawExtra is List
          ? [
              for (final entry in rawExtra) ?StremioCatalogExtra.fromJson(entry),
            ]
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        if (name != null) 'name': name,
        if (extra.isNotEmpty)
          'extra': [for (final entry in extra) entry.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is StremioCatalog &&
      other.type == type &&
      other.id == id &&
      other.name == name &&
      _sameSize(other.extra, extra) &&
      Iterable.generate(extra.length).every(
        (i) =>
            other.extra[i].name == extra[i].name &&
            other.extra[i].isRequired == extra[i].isRequired,
      );

  @override
  int get hashCode => Object.hash(
        type,
        id,
        name,
        Object.hashAll(extra.map((e) => '${e.name}/${e.isRequired}')),
      );

  @override
  String toString() => 'StremioCatalog($type/$id)';
}

bool _sameSize(List<Object?> a, List<Object?> b) => a.length == b.length;

/// Un vídeo (episodio) de la ficha de un addon.
class StremioVideo {
  final String id;
  final int? season;
  final int? episode;
  final String? title;
  final String? thumbnail;
  final DateTime? released;

  const StremioVideo({
    required this.id,
    this.season,
    this.episode,
    this.title,
    this.thumbnail,
    this.released,
  });

  String get code {
    if (season == null || episode == null) return 'Episode';
    return 'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}';
  }

  static StremioVideo? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.trim().isEmpty) return null;
    return StremioVideo(
      id: id.trim(),
      season: _int(value['season']),
      episode: _int(value['episode']),
      title: _string(value['title']),
      thumbnail: _string(value['thumbnail']),
      released: DateTime.tryParse(_string(value['released']) ?? ''),
    );
  }

  @override
  String toString() => 'StremioVideo($id)';
}

/// Ficha de un título tal y como la entrega un addon (catálogo o `/meta`).
///
/// Un catálogo sólo trae la carátula y los datos básicos; `/meta` añade los
/// episodios. El modelo acepta ambas formas y la pantalla usa lo que haya.
class StremioMeta {
  final String id;
  final String type;
  final String name;
  final String? poster;
  final String? background;
  final String? description;
  final String? releaseInfo;
  final String? imdbRating;
  final String? imdbId;
  final String? logo;
  final List<String> genres;
  final List<StremioVideo> videos;
  final int? runtimeMinutes;

  const StremioMeta({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.background,
    this.description,
    this.releaseInfo,
    this.imdbRating,
    this.imdbId,
    this.logo,
    this.genres = const [],
    this.videos = const [],
    this.runtimeMinutes,
  });

  /// Null cuando el addon no devuelve un título legible; la fila puede
  /// ignorarlo sin romper el resto del catálogo.
  static StremioMeta? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final type = value['type'];
    if (id is! String || id.trim().isEmpty) return null;
    if (type is! String || type.trim().isEmpty) return null;
    final rawVideos = value['videos'];
    final rawGenres = value['genres'];
    final imdbId = _string(value['imdb_id']);
    return StremioMeta(
      id: id.trim(),
      type: type.trim(),
      name: _string(value['name']) ?? id.trim(),
      poster: _string(value['poster']),
      background: _string(value['background']),
      description: _string(value['description']),
      releaseInfo: _string(value['releaseInfo']),
      imdbRating: _string(value['imdbRating']),
      imdbId: imdbId ?? (id.trim().startsWith('tt') ? id.trim() : null),
      logo: _string(value['logo']),
      genres: rawGenres is List
          ? [
              for (final genre in rawGenres)
                if (genre is String && genre.trim().isNotEmpty) genre.trim(),
            ]
          : const [],
      videos: rawVideos is List
          ? [for (final video in rawVideos) ?StremioVideo.fromJson(video)]
          : const [],
      runtimeMinutes: _durationMinutes(value['runtime']),
    );
  }

  /// Los catálogos de anime usan `anime` como tipo aunque tengan episodios.
  bool get isSeries =>
      type == 'series' || type == 'anime' || type == 'tv' || videos.isNotEmpty;

  int? get year {
    final match = RegExp(r'\d{4}').firstMatch(releaseInfo ?? '');
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  double? get rating => double.tryParse(imdbRating ?? '');

  /// Temporadas distintas presentes en `videos`, ordenadas.
  List<int> get seasons {
    final numbers = <int>{
      for (final video in videos)
        if (video.season != null) video.season!,
    }.toList()..sort();
    return numbers;
  }

  List<StremioVideo> videosOfSeason(int season) =>
      videos.where((v) => v.season == season).toList(growable: false);

  /// Vista de [Show] para reutilizar carátulas y metadatos donde haga falta.
  Show toShow() {
    return Show(
      traktId: -((id.hashCode & 0x7fffffff) + 1),
      imdbId: imdbId,
      title: name,
      year: year,
      overview: description,
      rating: rating,
      genres: genres,
      posterUrl: poster,
      backdropUrl: background,
      runtime: runtimeMinutes,
      type: isSeries ? ShowType.show : ShowType.movie,
    );
  }

  @override
  String toString() => 'StremioMeta($type/$id, $name)';
}

String? _string(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

int? _int(Object? value) => value is num ? value.toInt() : null;

/// `runtime` llega como "24 min" o como minutos en algunos addons.
int? _durationMinutes(Object? value) {
  if (value is num) return value.toInt();
  if (value is! String) return null;
  final match = RegExp(r'\d+').firstMatch(value);
  return match == null ? null : int.tryParse(match.group(0)!);
}

/// Manifest ya validado de un addon.
class StremioManifest {
  final String id;
  final String name;
  final String version;
  final String? description;
  final String? logo;
  final List<String> types;
  final List<String> resources;
  final List<String> idPrefixes;
  final List<StremioCatalog> catalogs;

  /// El addon se configura en una página web (`/configure`) antes de servir
  /// catálogos útiles.
  final bool configurable;

  /// Sin configurar todavía: se puede instalar, pero no tiene catálogos.
  final bool configurationRequired;

  const StremioManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description,
    this.logo,
    this.types = const [],
    this.resources = const [],
    this.idPrefixes = const [],
    this.catalogs = const [],
    this.configurable = false,
    this.configurationRequired = false,
  });

  /// `true` si el addon declara el recurso `stream` o `catalog`: cualquier
  /// addon que no aporte fuentes ni contenido no sirve en esta app.
  bool get supportsStreams => resources.contains('stream');

  bool get supportsCatalogs => resources.contains('catalog');
  bool get supportsMeta => resources.contains('meta');
  bool get isUsable => supportsStreams || supportsCatalogs;

  bool supportsType(String type) => types.contains(type);

  /// Valida y traduce el JSON del manifest. Lanza [StremioAddonException] con
  /// un motivo legible cuando algo falta o tiene la forma equivocada.
  factory StremioManifest.fromJson(Object? json) {
    if (json is! Map) {
      throw const StremioAddonException(
        'La respuesta no es un manifest de addon (no es un objeto JSON).',
      );
    }

    final id = _requiredString(json, 'id');
    final name = _requiredString(json, 'name');
    final version = _requiredString(json, 'version');

    final types = _stringList(json['types']);
    final resources = _resourceNames(json['resources']);
    final idPrefixes = _stringList(json['idPrefixes']);

    if (types.isEmpty) {
      throw const StremioAddonException(
        'El manifest no declara "types" (movie, series, …): no es un addon válido.',
      );
    }
    if (resources.isEmpty) {
      throw const StremioAddonException(
        'El manifest no declara "resources": no es un addon válido.',
      );
    }

    List<StremioCatalog> catalogs = const [];
    final rawCatalogs = json['catalogs'];
    if (rawCatalogs is List) {
      catalogs = [
        for (final entry in rawCatalogs) ?StremioCatalog.fromJson(entry),
      ];
    }

    final hints = json['behaviorHints'];
    final behaviorHints = hints is Map ? hints : const {};
    final manifest = StremioManifest(
      id: id,
      name: name,
      version: version,
      description: _optionalString(json['description']),
      logo: _optionalString(json['logo']),
      types: types,
      resources: resources,
      idPrefixes: idPrefixes,
      catalogs: catalogs,
      configurable: behaviorHints['configurable'] == true,
      configurationRequired:
          behaviorHints['configurationRequired'] == true ||
              json['configurationRequired'] == true,
    );

    if (!manifest.isUsable) {
      throw StremioAddonException(
        'El addon "${manifest.name}" no ofrece streams ni catálogos '
        '(recursos: ${resources.join(', ')}).',
      );
    }
    return manifest;
  }

  static String _requiredString(Map<dynamic, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw StremioAddonException(
        'El manifest no trae un "$key" válido: la URL no parece de un addon Stremio.',
      );
    }
    return value.trim();
  }

  static String? _optionalString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    ];
  }

  /// `resources` admite strings (`"stream"`) o mapas
  /// (`{"name": "stream", "types": [...]}`).
  static List<String> _resourceNames(Object? value) {
    if (value is! List) return const [];
    final names = <String>[];
    for (final entry in value) {
      if (entry is String && entry.trim().isNotEmpty) {
        names.add(entry.trim());
      } else if (entry is Map) {
        final name = entry['name'];
        if (name is String && name.trim().isNotEmpty) names.add(name.trim());
      }
    }
    return names;
  }

  @override
  String toString() => 'StremioManifest($id, $name, $version)';
}

/// Addon instalado: URL base, nombre visible, estado y posición.
///
/// El orden de la lista es la prioridad, igual que en los servicios debrid.
class InstalledAddon {
  /// URL base normalizada (sin barra final, sin `/manifest.json`).
  final String url;

  /// Nombre del manifest; se guarda para poder pintar la lista antes de
  /// volver a pedir el manifest.
  final String name;

  final String manifestId;
  final String? version;
  final bool enabled;

  /// Catálogos que declaró el manifest al instalar. Se guardan para poder
  /// pintar el descubrimiento sin volver a pedir el manifest en cada arranque.
  final List<StremioCatalog> catalogs;

  /// Tipos que acepta el addon (`movie`, `series`, `anime`, …).
  final List<String> types;

  final bool configurable;
  final bool configurationRequired;

  /// `false` en un addon de sólo catálogo (Kitsu): no se le piden streams.
  final bool supportsStreams;

  const InstalledAddon({
    required this.url,
    required this.name,
    required this.manifestId,
    this.version,
    this.enabled = true,
    this.catalogs = const [],
    this.types = const [],
    this.configurable = false,
    this.configurationRequired = false,
    this.supportsStreams = true,
  });

  /// Catálogos que se pueden pintar como fila (los de sólo búsqueda no).
  List<StremioCatalog> get browsableCatalogs =>
      catalogs.where((c) => c.canBrowse).toList(growable: false);

  bool get hasCatalogs => catalogs.isNotEmpty;

  InstalledAddon copyWith({
    String? name,
    String? version,
    bool? enabled,
    List<StremioCatalog>? catalogs,
    List<String>? types,
    bool? configurable,
    bool? configurationRequired,
    bool? supportsStreams,
  }) {
    return InstalledAddon(
      url: url,
      name: name ?? this.name,
      manifestId: manifestId,
      version: version ?? this.version,
      enabled: enabled ?? this.enabled,
      catalogs: catalogs ?? this.catalogs,
      types: types ?? this.types,
      configurable: configurable ?? this.configurable,
      configurationRequired:
          configurationRequired ?? this.configurationRequired,
      supportsStreams: supportsStreams ?? this.supportsStreams,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'manifestId': manifestId,
        if (version != null) 'version': version,
        'enabled': enabled,
        if (catalogs.isNotEmpty)
          'catalogs': [for (final catalog in catalogs) catalog.toJson()],
        if (types.isNotEmpty) 'types': types,
        if (configurable) 'configurable': true,
        if (configurationRequired) 'configurationRequired': true,
        if (!supportsStreams) 'streams': false,
      };

  /// Null para entradas irrecuperables: un JSON corrupto no debe dejar la app
  /// sin addons.
  static InstalledAddon? fromJson(Object? value) {
    if (value is! Map) return null;
    final url = value['url'];
    final name = value['name'];
    if (url is! String || name is! String) return null;
    final normalized = tryNormalizeAddonUrl(url);
    if (normalized == null || name.trim().isEmpty) return null;
    final manifestId = value['manifestId'];
    final version = value['version'];
    final enabled = value['enabled'];
    final rawCatalogs = value['catalogs'];
    final catalogs = rawCatalogs is List
        ? [
            for (final entry in rawCatalogs) ?StremioCatalog.fromJson(entry),
          ]
        : const <StremioCatalog>[];
    final rawTypes = value['types'];
    final types = rawTypes is List
        ? [
            for (final entry in rawTypes)
              if (entry is String && entry.trim().isNotEmpty) entry.trim(),
          ]
        : const <String>[];
    return InstalledAddon(
      url: normalized,
      name: name.trim(),
      manifestId: manifestId is String && manifestId.isNotEmpty
          ? manifestId
          : normalized,
      version: version is String && version.isNotEmpty ? version : null,
      enabled: enabled is bool ? enabled : true,
      catalogs: catalogs,
      types: types,
      configurable: value['configurable'] == true,
      configurationRequired: value['configurationRequired'] == true,
      supportsStreams: value['streams'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InstalledAddon &&
      other.url == url &&
      other.name == name &&
      other.manifestId == manifestId &&
      other.version == version &&
      other.enabled == enabled &&
      _sameSize(other.catalogs, catalogs) &&
      Iterable.generate(catalogs.length)
          .every((i) => other.catalogs[i] == catalogs[i]) &&
      _sameSize(other.types, types) &&
      Iterable.generate(types.length).every((i) => other.types[i] == types[i]) &&
      other.configurable == configurable &&
      other.configurationRequired == configurationRequired &&
      other.supportsStreams == supportsStreams;

  @override
  int get hashCode => Object.hash(
        url,
        name,
        manifestId,
        version,
        enabled,
        Object.hashAll(catalogs.map((c) => c.id)),
        Object.hashAll(types),
        configurable,
        configurationRequired,
        supportsStreams,
      );

  @override
  String toString() => 'InstalledAddon($name, $url, enabled: $enabled)';
}

/// Normaliza la URL pegada por el usuario: añade `https://` si falta, quita
/// `/manifest.json` y la barra final. Devuelve null si no es una URL http(s).
String? tryNormalizeAddonUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'https://$value';

  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;

  var path = uri.path;
  if (path.endsWith('/manifest.json')) {
    path = path.substring(0, path.length - '/manifest.json'.length);
  }
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(path: path, query: uri.query.isEmpty ? null : uri.query).toString();
}
