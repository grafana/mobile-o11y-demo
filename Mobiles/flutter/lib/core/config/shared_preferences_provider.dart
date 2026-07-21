import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exposes a resolved [SharedPreferences] instance to the provider tree so
/// config services can read overrides *synchronously* instead of each
/// awaiting `SharedPreferences.getInstance()`.
///
/// `bootstrap` awaits `getInstance()` once and overrides this provider with
/// the concrete instance (see [sharedPreferencesProvider] override there).
/// It intentionally throws if read without that override so a missing setup
/// fails loudly rather than silently returning defaults.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw StateError(
    'sharedPreferencesProvider must be overridden with a resolved '
    'SharedPreferences instance (done in bootstrap / tests).',
  );
});

/// Builds the app's root [ProviderContainer] with [SharedPreferences]
/// resolved up front and bound to [sharedPreferencesProvider].
///
/// Resolving prefs here is what lets config services (backend URL, Faro
/// collector) and debug settings read overrides synchronously
/// instead of each awaiting `getInstance()`. Keeping the wiring next to the
/// provider means callers (bootstrap) just do:
///
/// ```dart
/// final container = await createAppProviderContainer();
/// ```
Future<ProviderContainer> createAppProviderContainer() async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}
