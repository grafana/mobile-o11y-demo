import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_version_resolver.dart';
import 'core/config/app_version_provider.dart';
import 'core/config/config_service.dart';
import 'core/config/shared_preferences_provider.dart';
import 'core/localization/app_localizations.dart';
import 'core/o11y/demo_rum/demo_rum_init.dart';
import 'core/o11y/faro/faro_init.dart';
import 'core/o11y/loggers/o11y_logger.dart';
import 'core/router/app_router.dart';
import 'core/widgets/toast_listener.dart';
import 'features/auth/domain/auth_provider.dart';

/// Bootstrap configuration for the app.
class BootstrapConfig {
  const BootstrapConfig({
    required this.appEnv,
    this.enableFlutterDriver = false,
  });

  /// Environment name for Faro telemetry (e.g., 'production', 'development')
  final String appEnv;

  /// Whether Flutter Driver extension should be enabled (for AI/MCP testing)
  final bool enableFlutterDriver;
}

/// Bootstraps and runs the QuickPizza app with the given configuration.
///
/// This is the shared entry point used by both `main.dart` and `driver_main.dart`.
Future<void> bootstrap(BootstrapConfig config) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Install Faro's HttpOverrides FIRST — before anything can construct an
  // http.Client, or that client would permanently bypass Faro's HTTP
  // auto-instrumentation. See installFaroHttpOverrides for the full rationale.
  installFaroHttpOverrides();

  // Root container with SharedPreferences resolved + bound, so config +
  // debug providers can read overrides synchronously (see
  // createAppProviderContainer).
  final container = await createAppProviderContainer();

  // Access the logger via Riverpod
  final logger = container.read(o11yLoggerProvider);
  final driverSuffix = config.enableFlutterDriver
      ? ' (with Flutter Driver)'
      : '';
  logger.debug('App initialization started$driverSuffix');

  final appVersion = await _resolveTelemetryAppVersion(container, logger);

  // Telemetry nesting: DemoRum (outer) -> Faro (inner) -> runApp. DemoRum is a
  // no-op stand-in SDK (see core/o11y/demo_rum/) run alongside Faro purely to
  // demo how a second RUM SDK plugs in; the nesting order is illustrative. The
  // widget tree wraps as wrapWithDemoRum(wrapWithFaro(app)).
  await startDemoRum(
    appEnv: config.appEnv,
    appVersion: appVersion,
    appRunner: () async {
      // Restore the auth session here (inside the app runners, after
      // installFaroHttpOverrides ran). restoreSession pulls in
      // apiClientProvider, which constructs the app's http.Client — it must
      // happen AFTER the Faro HttpOverrides are installed so Faro still sees
      // the traffic. See installFaroHttpOverrides for the full rationale.
      await container.read(authStateProvider.notifier).restoreSession();

      // Explicit await so the Faro startup Future is always awaited end-to-end,
      // even if this closure is later refactored to a block body.
      await startFaro(
        container: container,
        appEnv: config.appEnv,
        appVersion: appVersion,
        appRunner: () {
          runApp(
            // Used by Riverpod to provide providers to the app
            UncontrolledProviderScope(
              container: container,
              child: wrapWithDemoRum(wrapWithFaro(const QuickPizzaApp())),
            ),
          );
        },
      );
    },
  );
}

/// Resolves the app version used across all telemetry SDKs (Faro appVersion,
/// DemoRum release). Warms [packageInfoProvider] for later use.
Future<String> _resolveTelemetryAppVersion(
  ProviderContainer container,
  O11yLogger logger,
) async {
  final packageInfo = await container.read(packageInfoProvider.future);
  final baseAppVersion = packageInfo.version;
  final versionResolver = container.read(appVersionResolverProvider);
  final appVersion = versionResolver.resolveTelemetryAppVersion(
    baseVersion: baseAppVersion,
    enableCiDemoVersioning: ConfigService.ciDemoVersioning,
  );
  logger.debug(
    'App version resolved',
    context: {
      'baseVersion': baseAppVersion,
      'telemetryVersion': appVersion,
      'ciDemoVersioning': ConfigService.ciDemoVersioning.toString(),
    },
  );
  return appVersion;
}

/// The main QuickPizza application widget.
class QuickPizzaApp extends ConsumerWidget {
  const QuickPizzaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'QuickPizza Flutter',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
      // Wrap all routes with ToastListener to enable global toast messages
      builder: (context, child) {
        return ToastListener(child: child ?? const SizedBox.shrink());
      },
    );
  }
}
