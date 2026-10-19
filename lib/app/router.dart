import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/platform_info.dart';
import '../features/channels/channels_screen.dart';
import '../features/guide/guide_screen.dart';
import '../features/player/player_screen.dart';
import '../features/providers/providers_screen.dart';
import '../features/epg_mapping/epg_mapping_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/debrid_services_screen.dart';
import '../features/settings/stremio_addons_screen.dart';
import '../features/shows/shows_screen.dart';
import '../features/shows/show_detail_screen.dart';
import '../features/shows/stremio_meta_screen.dart';
import '../features/shows/trailer_player_screen.dart';
import '../features/splash/splash_screen.dart';
import '../platform/tv/tv_shell.dart';
import '../data/models/show.dart';
import '../data/models/stremio_addon.dart';

GoRouter createRouter() {
  // Routes that live inside the TV sidebar shell
  final sidebarRoutes = [
    GoRoute(path: '/', builder: (context, state) => const ChannelsScreen()),
    GoRoute(path: '/guide', builder: (context, state) => const GuideScreen()),
    GoRoute(
      path: '/providers',
      builder: (context, state) => const ProvidersScreen(),
    ),
    GoRoute(
      path: '/epg-mapping',
      builder: (context, state) => const EpgMappingScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/debrid-services',
      builder: (context, state) => const DebridServicesScreen(),
    ),
    GoRoute(
      path: '/stremio-addons',
      builder: (context, state) => const StremioAddonsScreen(),
    ),
  ];

  // Routes outside the shell (player, shows detail, splash, etc.)
  final standaloneRoutes = [
    GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
    GoRoute(
      path: '/player',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return PlayerScreen(
          streamUrl: extra['streamUrl'] as String? ?? '',
          channelName: extra['channelName'] as String? ?? '',
          channelLogo: extra['channelLogo'] as String?,
          alternativeUrls:
              (extra['alternativeUrls'] as List<String>?) ?? const [],
          channels:
              (extra['channels'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              const [],
          currentIndex: extra['currentIndex'] as int? ?? 0,
        );
      },
    ),
    GoRoute(path: '/shows', builder: (context, state) => const ShowsScreen()),
    GoRoute(
      path: '/trailer',
      builder: (context, state) {
        final args = state.extra;
        if (args is! TrailerRouteArgs) return const _UnavailableScreen();
        return TrailerPlayerScreen(
          video: args.video,
          videos: args.videos,
          title: args.title,
        );
      },
    ),
    GoRoute(
      path: '/shows/:id',
      builder: (context, state) {
        final traktId = int.tryParse(state.pathParameters['id'] ?? '') ?? 0;
        final show = state.extra as Show?;
        return ShowDetailScreen(traktId: traktId, initialShow: show);
      },
    ),
    GoRoute(
      path: '/stremio-meta',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is Map && extra['meta'] is StremioMeta) {
          return StremioMetaScreen(
            initialMeta: extra['meta'] as StremioMeta,
            addonUrl: extra['addonUrl'] as String? ?? '',
          );
        }
        return const _UnavailableScreen();
      },
    ),
  ];

  if (PlatformInfo.isTV) {
    return GoRouter(
      initialLocation: '/splash',
      routes: [
        ShellRoute(
          builder: (context, state, child) => TvShell(child: child),
          routes: sidebarRoutes,
        ),
        ...standaloneRoutes,
      ],
    );
  }

  // Non-TV: flat routes (original behavior)
  return GoRouter(
    initialLocation: '/splash',
    routes: [...sidebarRoutes, ...standaloneRoutes],
  );
}

/// Lo que se enseña cuando la ruta recibe datos que ya no valen (una ficha
/// recargada, un vídeo que se quedó sin identificador).
class _UnavailableScreen extends StatelessWidget {
  const _UnavailableScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0A0A1A),
      body: Center(
        child: Text(
          'Este contenido ya no está disponible',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}

/// Global router instance — initialized lazily.
final GoRouter router = createRouter();
