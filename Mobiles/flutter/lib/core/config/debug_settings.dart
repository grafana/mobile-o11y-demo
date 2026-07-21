import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_provider.dart';

/// SharedPreferences keys used by debug settings. Exposed so other
/// services (e.g. FaroCollectorService) can read the same values.
abstract class DebugSettingsKeys {
  static const backendUrl = 'debug_backend_url';
  static const faroCollectorUrl = 'debug_faro_collector_url';
  static const faroSampleRate = 'debug_faro_sample_rate';
  static const errorRecommendations = 'debug_error_recommendations';
  static const errorIngredients = 'debug_error_ingredients';
  static const slowRecommendations = 'debug_slow_recommendations';
  static const slowIngredients = 'debug_slow_ingredients';
  static const useV2PizzaSchema = 'debug_use_v2_pizza_schema';
  static const skipAuthDepInTools = 'debug_skip_auth_dep_in_tools';
}

final debugSettingsProvider =
    NotifierProvider<DebugSettingsNotifier, DebugSettings>(
      DebugSettingsNotifier.new,
    );

class DebugSettings {
  final String? backendUrlOverride;
  final String? faroCollectorUrlOverride;

  /// Faro session sampling rate override (0.0–1.0). `null` = use the default
  /// ([kDefaultFaroSampleRate]). Applied at Faro init, so it needs a restart.
  final double? faroSampleRateOverride;
  final bool errorOnRecommendations;
  final bool errorOnIngredients;
  final bool slowRecommendations;
  final bool slowIngredients;
  final bool useV2PizzaSchema;
  final bool skipAuthDepInTools;

  const DebugSettings({
    this.backendUrlOverride,
    this.faroCollectorUrlOverride,
    this.faroSampleRateOverride,
    this.errorOnRecommendations = false,
    this.errorOnIngredients = false,
    this.slowRecommendations = false,
    this.slowIngredients = false,
    this.useV2PizzaSchema = false,
    this.skipAuthDepInTools = false,
  });

  DebugSettings copyWith({
    String? Function()? backendUrlOverride,
    String? Function()? faroCollectorUrlOverride,
    double? Function()? faroSampleRateOverride,
    bool? errorOnRecommendations,
    bool? errorOnIngredients,
    bool? slowRecommendations,
    bool? slowIngredients,
    bool? useV2PizzaSchema,
    bool? skipAuthDepInTools,
  }) {
    return DebugSettings(
      backendUrlOverride: backendUrlOverride != null
          ? backendUrlOverride()
          : this.backendUrlOverride,
      faroCollectorUrlOverride: faroCollectorUrlOverride != null
          ? faroCollectorUrlOverride()
          : this.faroCollectorUrlOverride,
      faroSampleRateOverride: faroSampleRateOverride != null
          ? faroSampleRateOverride()
          : this.faroSampleRateOverride,
      errorOnRecommendations:
          errorOnRecommendations ?? this.errorOnRecommendations,
      errorOnIngredients: errorOnIngredients ?? this.errorOnIngredients,
      slowRecommendations: slowRecommendations ?? this.slowRecommendations,
      slowIngredients: slowIngredients ?? this.slowIngredients,
      useV2PizzaSchema: useV2PizzaSchema ?? this.useV2PizzaSchema,
      skipAuthDepInTools: skipAuthDepInTools ?? this.skipAuthDepInTools,
    );
  }

  bool get hasActiveOverrides =>
      backendUrlOverride != null ||
      faroCollectorUrlOverride != null ||
      faroSampleRateOverride != null ||
      errorOnRecommendations ||
      errorOnIngredients ||
      slowRecommendations ||
      slowIngredients ||
      useV2PizzaSchema ||
      skipAuthDepInTools;

  /// Backend expects:
  ///  * `x-error-*` headers — value is the error message (any non-empty string)
  ///  * `x-delay-*` headers — value is a Go duration string (e.g. `3s`, `500ms`)
  ///
  /// We send descriptive messages so they're meaningful in the backend
  /// logs/traces (Loki/Tempo). The mobile UI shows a generic message — the
  /// injected text is for backend-side correlation only.
  ///
  /// Delay values are tuned so both toggles produce ~3s of user-visible
  /// slowness. `record-recommendation` is called once per `POST /api/pizza`,
  /// so 3s → ~3s. `get-ingredients` is called four times per request
  /// (oil, tomato, mozzarella, topping), so 750ms → ~3s total.
  Map<String, String> get errorInjectionHeaders {
    const recommendationDelay = '3s';
    const ingredientsDelay = '750ms';
    final headers = <String, String>{};
    if (errorOnRecommendations) {
      headers['x-error-record-recommendation'] =
          'simulated recommendation service failure';
    }
    if (errorOnIngredients) {
      headers['x-error-get-ingredients'] =
          'simulated ingredient lookup failure';
    }
    if (slowRecommendations) {
      headers['x-delay-record-recommendation'] = recommendationDelay;
    }
    if (slowIngredients) {
      headers['x-delay-get-ingredients'] = ingredientsDelay;
    }
    return headers;
  }
}

class DebugSettingsNotifier extends Notifier<DebugSettings> {
  /// Cached, synchronously-available prefs (resolved at bootstrap and
  /// exposed via [sharedPreferencesProvider]).
  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  DebugSettings build() => _readFromPrefs();

  DebugSettings _readFromPrefs() {
    return DebugSettings(
      backendUrlOverride: _prefs.getString(DebugSettingsKeys.backendUrl),
      faroCollectorUrlOverride: _prefs.getString(
        DebugSettingsKeys.faroCollectorUrl,
      ),
      faroSampleRateOverride: _prefs.getDouble(
        DebugSettingsKeys.faroSampleRate,
      ),
      errorOnRecommendations:
          _prefs.getBool(DebugSettingsKeys.errorRecommendations) ?? false,
      errorOnIngredients:
          _prefs.getBool(DebugSettingsKeys.errorIngredients) ?? false,
      slowRecommendations:
          _prefs.getBool(DebugSettingsKeys.slowRecommendations) ?? false,
      slowIngredients:
          _prefs.getBool(DebugSettingsKeys.slowIngredients) ?? false,
      useV2PizzaSchema:
          _prefs.getBool(DebugSettingsKeys.useV2PizzaSchema) ?? false,
      skipAuthDepInTools:
          _prefs.getBool(DebugSettingsKeys.skipAuthDepInTools) ?? false,
    );
  }

  /// Persists the backend URL, Faro collector URL, and Faro sample-rate
  /// overrides atomically. A `null` value clears the corresponding override
  /// (empty/whitespace URLs are treated as `null`).
  ///
  /// Returns `true` if any override actually changed, so the caller can decide
  /// whether to show the restart banner.
  Future<bool> saveConfigOverrides({
    required String? backendUrl,
    required String? faroCollectorUrl,
    required double? faroSampleRate,
  }) async {
    final normalizedBackend = _normalize(backendUrl);
    final normalizedFaro = _normalize(faroCollectorUrl);

    final prevBackend = state.backendUrlOverride;
    final prevFaro = state.faroCollectorUrlOverride;
    final prevRate = state.faroSampleRateOverride;

    if (normalizedBackend != null) {
      await _prefs.setString(DebugSettingsKeys.backendUrl, normalizedBackend);
    } else {
      await _prefs.remove(DebugSettingsKeys.backendUrl);
    }

    if (normalizedFaro != null) {
      await _prefs.setString(
        DebugSettingsKeys.faroCollectorUrl,
        normalizedFaro,
      );
    } else {
      await _prefs.remove(DebugSettingsKeys.faroCollectorUrl);
    }

    if (faroSampleRate != null) {
      await _prefs.setDouble(DebugSettingsKeys.faroSampleRate, faroSampleRate);
    } else {
      await _prefs.remove(DebugSettingsKeys.faroSampleRate);
    }

    state = state.copyWith(
      backendUrlOverride: () => normalizedBackend,
      faroCollectorUrlOverride: () => normalizedFaro,
      faroSampleRateOverride: () => faroSampleRate,
    );

    return prevBackend != normalizedBackend ||
        prevFaro != normalizedFaro ||
        prevRate != faroSampleRate;
  }

  String? _normalize(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.replaceAll(RegExp(r'/$'), '');
  }

  Future<void> setErrorOnRecommendations(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.errorRecommendations, value);
    state = state.copyWith(errorOnRecommendations: value);
  }

  Future<void> setErrorOnIngredients(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.errorIngredients, value);
    state = state.copyWith(errorOnIngredients: value);
  }

  Future<void> setSlowRecommendations(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.slowRecommendations, value);
    state = state.copyWith(slowRecommendations: value);
  }

  Future<void> setSlowIngredients(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.slowIngredients, value);
    state = state.copyWith(slowIngredients: value);
  }

  Future<void> setUseV2PizzaSchema(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.useV2PizzaSchema, value);
    state = state.copyWith(useV2PizzaSchema: value);
  }

  Future<void> setSkipAuthDepInTools(bool value) async {
    await _prefs.setBool(DebugSettingsKeys.skipAuthDepInTools, value);
    state = state.copyWith(skipAuthDepInTools: value);
  }

  Future<void> resetAll() async {
    await _prefs.remove(DebugSettingsKeys.backendUrl);
    await _prefs.remove(DebugSettingsKeys.faroCollectorUrl);
    await _prefs.remove(DebugSettingsKeys.faroSampleRate);
    await _prefs.remove(DebugSettingsKeys.errorRecommendations);
    await _prefs.remove(DebugSettingsKeys.errorIngredients);
    await _prefs.remove(DebugSettingsKeys.slowRecommendations);
    await _prefs.remove(DebugSettingsKeys.slowIngredients);
    await _prefs.remove(DebugSettingsKeys.useV2PizzaSchema);
    await _prefs.remove(DebugSettingsKeys.skipAuthDepInTools);
    state = const DebugSettings();
  }
}
