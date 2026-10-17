import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_info.dart';
import '../data/services/p2p/p2p_providers.dart';
import 'router.dart';
import 'theme.dart';

class ClubTiviApp extends ConsumerStatefulWidget {
  const ClubTiviApp({super.key});

  @override
  ConsumerState<ClubTiviApp> createState() => _ClubTiviAppState();
}

class _ClubTiviAppState extends ConsumerState<ClubTiviApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // El motor P2P es un proceso hijo: se mata al cerrar la ventana para no
    // dejar rqbit huérfano. Si nunca se usó, no hay nada que cerrar.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          final engine = ref.read(rqbitEngineProvider).valueOrNull;
          await engine?.dispose();
        } catch (error) {
          debugPrint('[P2P] Could not stop the engine on exit: $error');
        }
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'clubTivi',
      debugShowCheckedModeBanner: false,
      theme: ClubTiviTheme.dark,
      routerConfig: router,
      builder: (context, child) {
        // Detect TV mode from the first MediaQuery context
        PlatformInfo.detectFromContext(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
