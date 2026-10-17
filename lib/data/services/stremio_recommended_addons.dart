/// Addons que la app ofrece instalar con un clic.
///
/// Sólo entran URLs cuyo `manifest.json` se ha comprobado que responde: una
/// lista de recomendados con enlaces muertos es peor que no tener lista. El
/// resto del ecosistema (incluidos los addons de películas en español que
/// piden una URL personal) se instala pegando su URL.
library;

/// Dónde se publica la lista comunitaria de addons, para el botón "buscar más".
const String communityAddonsListUrl = 'https://stremio-addons.net/';

/// Ficha de un addon recomendado.
class RecommendedAddon {
  final String url;
  final String name;
  final String description;

  /// Etiquetas cortas para agrupar en la pantalla (`Anime`, `Español`, …).
  final List<String> tags;

  /// El addon pide pasar por `/configure` antes de aportar catálogos.
  final bool needsConfiguration;

  const RecommendedAddon({
    required this.url,
    required this.name,
    required this.description,
    this.tags = const [],
    this.needsConfiguration = false,
  });
}

/// Orden = orden en pantalla. Verificados el 2026-10-17.
const List<RecommendedAddon> recommendedStremioAddons = [
  RecommendedAddon(
    url: 'https://pigamer37.alwaysdata.net',
    name: 'AnimES (AnimeFLV)',
    description: 'Catálogos de anime en español y streams de AnimeAV1, '
        'TioAnime, Henaojara y JKAnime.',
    tags: ['Anime', 'Español'],
  ),
  RecommendedAddon(
    url: 'https://anime-kitsu.strem.fun',
    name: 'Anime Kitsu',
    description: 'Catálogos de anime (tendencias, en emisión y mejor '
        'valorado) con ficha, episodios y subtítulos.',
    tags: ['Anime', 'Catálogos'],
  ),
  RecommendedAddon(
    url: 'https://1fe84bc728af-stremio-anime-catalogs.baby-beamup.club',
    name: 'Anime Catalogs',
    description: 'Catálogos de anime de varias fuentes. Hay que configurarlo '
        'en su web antes de que traiga contenido.',
    tags: ['Anime', 'Configurar'],
    needsConfiguration: true,
  ),
];

/// Página de configuración del addon. El protocolo la expone en `/configure`.
String configureUrlFor(String addonUrl) {
  final base = addonUrl.endsWith('/')
      ? addonUrl.substring(0, addonUrl.length - 1)
      : addonUrl;
  return '$base/configure';
}
