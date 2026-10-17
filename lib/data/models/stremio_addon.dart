/// Modelos del protocolo de addons de Stremio (manifest y addon instalado).
///
/// Lógica pura: sin Flutter, sin red y sin almacenamiento. La validación del
/// manifest vive aquí para que la UI pueda explicar por qué una URL no sirve
/// antes de aceptarla.
library;

/// Error con mensaje apto para el usuario sobre un addon o su manifest.
class StremioAddonException implements Exception {
  final String message;
  final Uri? url;

  const StremioAddonException(this.message, {this.url});

  @override
  String toString() => message;
}

/// Un catálogo declarado en el manifest.
class StremioCatalog {
  final String type;
  final String id;
  final String? name;

  const StremioCatalog({required this.type, required this.id, this.name});

  static StremioCatalog? fromJson(Object? value) {
    if (value is! Map) return null;
    final type = value['type'];
    final id = value['id'];
    if (type is! String || id is! String || type.isEmpty || id.isEmpty) {
      return null;
    }
    final name = value['name'];
    return StremioCatalog(type: type, id: id, name: name is String ? name : null);
  }

  @override
  String toString() => 'StremioCatalog($type/$id)';
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
  });

  /// `true` si el addon declara el recurso `stream`, que es lo único que este
  /// pase sabe consumir.
  bool get supportsStreams => resources.contains('stream');

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
    );

    if (!manifest.supportsStreams) {
      throw StremioAddonException(
        'El addon "${manifest.name}" no ofrece streams '
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

  const InstalledAddon({
    required this.url,
    required this.name,
    required this.manifestId,
    this.version,
    this.enabled = true,
  });

  InstalledAddon copyWith({String? name, String? version, bool? enabled}) {
    return InstalledAddon(
      url: url,
      name: name ?? this.name,
      manifestId: manifestId,
      version: version ?? this.version,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'manifestId': manifestId,
        if (version != null) 'version': version,
        'enabled': enabled,
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
    return InstalledAddon(
      url: normalized,
      name: name.trim(),
      manifestId: manifestId is String && manifestId.isNotEmpty
          ? manifestId
          : normalized,
      version: version is String && version.isNotEmpty ? version : null,
      enabled: enabled is bool ? enabled : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InstalledAddon &&
      other.url == url &&
      other.name == name &&
      other.manifestId == manifestId &&
      other.version == version &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(url, name, manifestId, version, enabled);

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
