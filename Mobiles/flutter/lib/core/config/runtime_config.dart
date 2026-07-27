import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_url_service.dart';
import 'faro_collector_service.dart';
import 'faro_sample_rate_service.dart';

/// Immutable snapshot of configuration values captured once at app
/// bootstrap and held for the lifetime of the session.
///
/// This is intentionally *not* reactive: these are the URLs that Faro
/// initialized with and that [ApiClient] is using. Changing a saved
/// override in [DebugSettings] will NOT change these values — the user
/// must restart the app for the override to take effect.
///
/// Why: keeping backend + collector stable per session makes correlated
/// traces/logs/metrics much easier to reason about when demoing.
class RuntimeConfig {
  const RuntimeConfig({
    required this.backendBaseUrl,
    required this.faroCollectorUrl,
    required this.faroSampleRate,
  });

  final String backendBaseUrl;
  final String faroCollectorUrl;

  /// Faro session sampling rate (0.0–1.0) that Faro actually initialized with
  /// this session.
  final double faroSampleRate;
}

/// Resolves the effective backend + Faro values once, via the service
/// providers. These reads are synchronous because the underlying
/// [SharedPreferences] instance is resolved once at bootstrap and exposed
/// via [sharedPreferencesProvider], so consumers can read
/// `ref.watch(runtimeConfigProvider)` directly without a loading state.
final runtimeConfigProvider = Provider<RuntimeConfig>((ref) {
  final backendBaseUrl = ref.watch(backendUrlServiceProvider).getUrl();
  final faroCollectorUrl = ref.watch(faroCollectorServiceProvider).getUrl();
  final faroSampleRate = ref.watch(faroSampleRateServiceProvider).getRate();
  return RuntimeConfig(
    backendBaseUrl: backendBaseUrl,
    faroCollectorUrl: faroCollectorUrl,
    faroSampleRate: faroSampleRate,
  );
});
