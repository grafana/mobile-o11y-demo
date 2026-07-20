import 'dart:async';
import 'dart:io';

import 'package:faro/faro.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/runtime_config.dart';
import '../../utils/faro_utils.dart';
import 'faro.dart';

/// Installs Faro's [HttpOverrides] so the SDK can auto-instrument HTTP.
///
/// IMPORTANT: call this BEFORE anything constructs an `http.Client`! The http
/// package uses `IOClient` on mobile, which creates its `HttpClient` at
/// construction time — if the override is installed afterwards, that client
/// (and, since [apiClientProvider] is a cached singleton, the whole app) will
/// bypass Faro's HTTP interception. `bootstrap` therefore calls this right
/// after `WidgetsFlutterBinding.ensureInitialized()` — before the provider
/// container, provider reads, and session restore — not inside [startFaro]
/// (which runs much later, wrapping the app runner).
void installFaroHttpOverrides() {
  HttpOverrides.global = FaroHttpOverrides(HttpOverrides.current);
}

/// Owns all Grafana Faro SDK startup and configuration for QuickPizza.
///
/// Runs as the INNER half of the telemetry nesting (`startDemoRum` is the
/// outer half) — a convention, not a requirement. [Faro.runApp] installs
/// Faro's chained `FlutterError.onError` / `PlatformDispatcher.onError`
/// handlers; because both SDKs chain (save + call the previously-installed
/// handler), either init order lets both observe the same Dart errors. See
/// [startDemoRum] for the full rationale.
Future<void> startFaro({
  required ProviderContainer container,
  required String appEnv,
  required String appVersion,
  required FutureOr<void> Function() appRunner,
}) async {
  final faroCollectorUrl = container
      .read(runtimeConfigProvider)
      .faroCollectorUrl;
  final apiKey = extractTokenFromCollectorUrl(faroCollectorUrl);
  final faro = container.read(faroProvider);

  faro.transports.add(
    OfflineTransport(maxCacheDuration: const Duration(days: 3)),
  );

  await faro.runApp(
    optionsConfiguration: FaroConfig(
      appName: 'QuickPizza_Flutter',
      appVersion: appVersion,
      appEnv: appEnv,
      apiKey: apiKey,
      collectorUrl: faroCollectorUrl,
      cpuUsageVitals: true,
      memoryUsageVitals: true,
      anrTracking: true,
      refreshRateVitals: true,
      fetchVitalsInterval: const Duration(seconds: 30),
      enableCrashReporting: true,
    ),
    appRunner: appRunner,
  );
}

/// Wraps the app root with Faro's tracking widgets. Composed by `bootstrap`
/// as `wrapWithDemoRum(wrapWithFaro(app))`.
Widget wrapWithFaro(Widget child) =>
    FaroAssetTracking(child: FaroUserInteractionWidget(child: child));
