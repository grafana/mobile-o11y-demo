import 'dart:io';

import 'package:faro/faro.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'core/application_layer/o11y/loggers/o11y_logger.dart';
import 'core/application_layer/o11y/events/o11y_events.dart';
import 'services/api_service.dart';
import 'services/config_service.dart';
import 'screens/home_screen.dart';
import 'utils/faro_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  o11yLogger.debug('App initialization started', context: {});

  // Initialize config service (loads .env file)
  await ConfigService.init();

  // Debug: Print Sentry configuration
  debugPrint('=== Sentry Configuration ===');
  debugPrint('Sentry DSN: ${ConfigService.sentryDsn}');
  debugPrint('Sentry Enabled: ${ConfigService.isSentryEnabled}');
  debugPrint('============================');

  // Initialize Sentry for error tracking (if enabled)
  if (ConfigService.isSentryEnabled) {
    await SentryFlutter.init((options) {
      options.dsn = ConfigService.sentryDsn;
      // Set environment (e.g., 'development', 'staging', 'production')
      options.environment = const String.fromEnvironment(
        'SENTRY_ENVIRONMENT',
        defaultValue: 'development',
      );
      // Enable performance monitoring
      options.tracesSampleRate = 1.0;
      // Enable profiling (requires tracing to be enabled)
      options.profilesSampleRate = 1.0;
      // Capture failed HTTP requests
      options.enableAutoPerformanceTracing = true;
      // Add release info for better error grouping
      options.release = '1.0.0+1';
      // Enable debug mode in development
      options.debug = true;
    });
    debugPrint('Sentry initialized successfully!');
  } else {
    debugPrint('Sentry is DISABLED - DSN not configured');
  }

  // Extract token from collector URL
  final collectorUrl = dotenv.env['FARO_COLLECTOR_URL'];
  final apiKey = extractTokenFromCollectorUrl(collectorUrl);

  // Initialize Faro instance first
  final faro = Faro();

  // Set HttpOverrides AFTER Faro instance is created to ensure HTTP tracing works
  // This must be done before any HTTP calls are made
  HttpOverrides.global = FaroHttpOverrides(HttpOverrides.current);

  faro.transports.add(
    OfflineTransport(maxCacheDuration: const Duration(days: 3)),
  );

  o11yLogger.debug(
    'Faro initialized',
    context: {'collectorUrl': collectorUrl ?? 'not_set'},
  );

  o11yEvents.trackEvent('app_started', attributes: {'app_version': '1.0.0'});

  faro.runApp(
    optionsConfiguration: FaroConfig(
      appName: 'QuickPizza_Flutter',
      appVersion: '1.0.0',
      appEnv: 'production',
      apiKey: apiKey,
      collectorUrl: collectorUrl,
      cpuUsageVitals: true,
      memoryUsageVitals: true,
      anrTracking: true,
      refreshRateVitals: true,
      fetchVitalsInterval: const Duration(seconds: 30),
      enableCrashReporting: true,
    ),
    appRunner: () {
      runApp(
        DefaultAssetBundle(
          bundle: FaroAssetBundle(),
          child: const FaroUserInteractionWidget(child: QuickPizzaApp()),
        ),
      );
    },
  );
}

class QuickPizzaApp extends StatelessWidget {
  const QuickPizzaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService();

    // Note: User must login via LoginScreen to get a valid token.
    // Some APIs (quotes, config) work without auth, but others (ratings, pizza, tools) require authentication.

    return MaterialApp(
      title: 'QuickPizza',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      navigatorObservers: [FaroNavigationObserver()],
      home: HomeScreen(apiService: apiService),
    );
  }
}
