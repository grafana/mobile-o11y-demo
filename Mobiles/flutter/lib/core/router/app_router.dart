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

/// Provider for the GoRouter instance
final appRouterProvider = Provider<GoRouter>((ref) {
  return createAppRouter();
});

/// Creates the app router with separate observers for its two navigators.
///
/// A NavigatorObserver can only be attached to one Navigator, so the root and
/// shell navigators need distinct Faro and DemoRum observer instances.
GoRouter createAppRouter({
  List<NavigatorObserver>? rootObservers,
  List<NavigatorObserver>? shellObservers,
}) {
  final rootNavigatorKey = GlobalKey<NavigatorState>();
  final shellNavigatorKey = GlobalKey<NavigatorState>();

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.home,
    // Builder routes get their path as the RouteSettings name from go_router.
    // Custom pages below set the same path explicitly for consistent RUM view
    // names across both navigators.
    observers: rootObservers ?? _createNavigationObservers(),
    routes: [
      // ShellRoute wraps the bottom navigation bar
      ShellRoute(
        navigatorKey: shellNavigatorKey,
        // Avoid forwarding the root observers in addition to the dedicated
        // shell observers, which would report every shell navigation twice.
        notifyRootObserver: false,
        observers: shellObservers ?? _createNavigationObservers(),
        pageBuilder: (_, state, child) => MaterialPage<void>(
          key: state.pageKey,
          // Keep the wrapper route aligned with its visible child. This also
          // gives root-level pushes and pops a non-null previous route name.
          name: state.uri.path,
          child: MainShell(child: child),
        ),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (_, state) => NoTransitionPage<void>(
              key: state.pageKey,
              name: AppRoutes.home,
              child: const HomeScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.about,
            pageBuilder: (_, state) => NoTransitionPage<void>(
              key: state.pageKey,
              name: AppRoutes.about,
              child: const AboutScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.debug,
            pageBuilder: (_, state) => NoTransitionPage<void>(
              key: state.pageKey,
              name: AppRoutes.debug,
              child: const DebugScreen(),
            ),
          ),
        ],
      ),
      // /debug/config is pushed on top of the shell (hides bottom nav)
      GoRoute(
        path: AppRoutes.debugConfig,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const ConfigScreen(),
      ),
      // Routes outside the shell (full-screen, no bottom nav)
      GoRoute(
        path: AppRoutes.login,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const ProfileScreen(),
      ),
    ],
  );
}

List<NavigatorObserver> _createNavigationObservers() => [
  FaroNavigationObserver(),
  DemoRumNavigatorObserver(),
];
