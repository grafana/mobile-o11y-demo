import 'package:faro/faro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/about/presentation/about_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/debug/presentation/config_screen.dart';
import '../../features/debug/presentation/debug_screen.dart';
import '../../features/pizza/presentation/home_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/shell/presentation/main_shell.dart';
import '../o11y/demo_rum/sdk/demo_rum.dart';

/// Route paths as constants for type-safe navigation
abstract class AppRoutes {
  static const home = '/';
  static const about = '/about';
  static const debug = '/debug';
  static const debugConfig = '/debug/config';
  static const login = '/login';
  static const profile = '/profile';
}

/// Navigator key for the root navigator
final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Navigator key for the shell (bottom nav) navigator
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// Provider for the GoRouter instance
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: AppRoutes.home,
    // Both RUM SDKs derive screen names from `route.settings.name`. The
    // pageBuilder routes below set an explicit `name:` so Faro view meta and
    // DemoRum screen views are both populated (builder routes get their name
    // from go_router automatically).
    observers: [FaroNavigationObserver(), DemoRumNavigatorObserver()],
    routes: [
      // ShellRoute wraps the bottom navigation bar
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (_, _, child) {
          return MainShell(child: child);
        },
        routes: [
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (_, _) => const NoTransitionPage(
              name: AppRoutes.home,
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.about,
            pageBuilder: (_, _) => const NoTransitionPage(
              name: AppRoutes.about,
              child: AboutScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.debug,
            pageBuilder: (_, _) => const NoTransitionPage(
              name: AppRoutes.debug,
              child: DebugScreen(),
            ),
          ),
        ],
      ),
      // /debug/config is pushed on top of the shell (hides bottom nav)
      GoRoute(
        path: AppRoutes.debugConfig,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, _) => const ConfigScreen(),
      ),
      // Routes outside the shell (full-screen, no bottom nav)
      GoRoute(
        path: AppRoutes.login,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, _) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, _) => const ProfileScreen(),
      ),
    ],
  );
});
