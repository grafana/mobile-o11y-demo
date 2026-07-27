import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/config_service.dart';
import '../../../core/config/debug_settings.dart';
import '../../../core/config/faro_sample_rate_service.dart';
import '../../../core/config/runtime_config.dart';
import '../../../core/utils/faro_utils.dart';

// =============================================================================
// UI State
// =============================================================================

/// Represents the UI state for the debug Config screen.
class ConfigScreenUiState extends Equatable {
  const ConfigScreenUiState({
    required this.backendInUse,
    required this.faroCollectorInUse,
    required this.faroCollectorInUseDisplay,
    required this.faroSampleRateInUse,
    required this.defaultBackend,
    required this.defaultFaroCollector,
    required this.defaultFaroCollectorDisplay,
    required this.defaultFaroSampleRate,
    required this.savedBackendOverride,
    required this.savedFaroCollectorOverride,
    required this.savedFaroSampleRateOverride,
    required this.saving,
    required this.statusMessage,
  });

  /// Backend URL currently used by [ApiClient] for this session.
  final String backendInUse;

  /// Raw Faro collector URL currently used by Faro for this session.
  final String faroCollectorInUse;

  /// Faro collector URL with the API key partially masked, safe to render.
  final String faroCollectorInUseDisplay;

  /// Faro session sampling rate Faro initialized with this session (0.0–1.0).
  final double faroSampleRateInUse;

  /// Build-time default backend URL.
  final String defaultBackend;

  /// Build-time default Faro collector URL (null if not configured).
  final String? defaultFaroCollector;

  /// Masked build-time default, safe to render (null if not configured).
  final String? defaultFaroCollectorDisplay;

  /// Default Faro sampling rate when no override is saved.
  final double defaultFaroSampleRate;

  /// Saved override in SharedPreferences — empty string means "no override".
  final String? savedBackendOverride;
  final String? savedFaroCollectorOverride;

  /// Saved sampling-rate override — `null` means "no override".
  final double? savedFaroSampleRateOverride;

  /// Whether a save/clear is in-flight.
  final bool saving;

  /// Transient status message shown to the user after a save/clear.
  final String? statusMessage;

  ConfigScreenUiState copyWith({
    bool? saving,
    String? Function()? statusMessage,
  }) {
    return ConfigScreenUiState(
      backendInUse: backendInUse,
      faroCollectorInUse: faroCollectorInUse,
      faroCollectorInUseDisplay: faroCollectorInUseDisplay,
      faroSampleRateInUse: faroSampleRateInUse,
      defaultBackend: defaultBackend,
      defaultFaroCollector: defaultFaroCollector,
      defaultFaroCollectorDisplay: defaultFaroCollectorDisplay,
      defaultFaroSampleRate: defaultFaroSampleRate,
      savedBackendOverride: savedBackendOverride,
      savedFaroCollectorOverride: savedFaroCollectorOverride,
      savedFaroSampleRateOverride: savedFaroSampleRateOverride,
      saving: saving ?? this.saving,
      statusMessage: statusMessage != null
          ? statusMessage()
          : this.statusMessage,
    );
  }

  @override
  List<Object?> get props => [
    backendInUse,
    faroCollectorInUse,
    faroCollectorInUseDisplay,
    faroSampleRateInUse,
    defaultBackend,
    defaultFaroCollector,
    defaultFaroCollectorDisplay,
    defaultFaroSampleRate,
    savedBackendOverride,
    savedFaroCollectorOverride,
    savedFaroSampleRateOverride,
    saving,
    statusMessage,
  ];
}

// =============================================================================
// Actions Interface
// =============================================================================

/// Defines the actions available on the Config screen.
abstract interface class ConfigScreenActions {
  /// Persist all overrides atomically. Empty/whitespace URL values clear the
  /// corresponding override; an empty [faroSampleRateText] clears the rate
  /// override. Returns silently after setting an error status if the sample
  /// rate is present but invalid.
  Future<void> save({
    required String? backendUrl,
    required String? faroCollectorUrl,
    required String? faroSampleRateText,
  });

  /// Clear all overrides and fall back to build-time defaults on the
  /// next app launch.
  Future<void> clear();
}

// =============================================================================
// ViewModel Implementation
// =============================================================================

class _ConfigScreenViewModel extends Notifier<ConfigScreenUiState>
    implements ConfigScreenActions {
  @override
  ConfigScreenUiState build() {
    final settings = ref.watch(debugSettingsProvider);
    final runtime = ref.watch(runtimeConfigProvider);
    final configService = ref.watch(configServiceProvider);

    final defaultFaroCollector = _safeDefaultFaroCollectorUrl();

    return ConfigScreenUiState(
      backendInUse: runtime.backendBaseUrl,
      faroCollectorInUse: runtime.faroCollectorUrl,
      faroCollectorInUseDisplay: maskCollectorUrl(runtime.faroCollectorUrl),
      faroSampleRateInUse: runtime.faroSampleRate,
      defaultBackend: configService.baseUrl,
      defaultFaroCollector: defaultFaroCollector,
      defaultFaroCollectorDisplay: defaultFaroCollector == null
          ? null
          : maskCollectorUrl(defaultFaroCollector),
      defaultFaroSampleRate: kDefaultFaroSampleRate,
      savedBackendOverride: settings.backendUrlOverride,
      savedFaroCollectorOverride: settings.faroCollectorUrlOverride,
      savedFaroSampleRateOverride: settings.faroSampleRateOverride,
      saving: false,
      statusMessage: null,
    );
  }

  @override
  Future<void> save({
    required String? backendUrl,
    required String? faroCollectorUrl,
    required String? faroSampleRateText,
  }) async {
    final (sampleRate, sampleRateError) = _parseSampleRate(faroSampleRateText);
    if (sampleRateError != null) {
      state = state.copyWith(statusMessage: () => sampleRateError);
      return;
    }

    state = state.copyWith(saving: true, statusMessage: () => null);
    await ref
        .read(debugSettingsProvider.notifier)
        .saveConfigOverrides(
          backendUrl: backendUrl,
          faroCollectorUrl: faroCollectorUrl,
          faroSampleRate: sampleRate,
        );
    // State is re-derived automatically via ref.watch(debugSettingsProvider)
    // in build(), so we only need to update the transient fields here.
    state = state.copyWith(
      saving: false,
      statusMessage: () =>
          'Saved. Kill and relaunch the app for changes to take effect.',
    );
  }

  @override
  Future<void> clear() async {
    state = state.copyWith(saving: true, statusMessage: () => null);
    await ref
        .read(debugSettingsProvider.notifier)
        .saveConfigOverrides(
          backendUrl: null,
          faroCollectorUrl: null,
          faroSampleRate: null,
        );
    state = state.copyWith(
      saving: false,
      statusMessage: () =>
          'Overrides cleared. Kill and relaunch to use defaults.',
    );
  }

  /// Parses the sample-rate text field. Returns `(rate, error)`:
  /// - empty → `(null, null)` (clear the override)
  /// - a number in [0.0, 1.0] → `(value, null)`
  /// - anything else → `(null, <message>)`
  (double?, String?) _parseSampleRate(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return (null, null);
    final value = double.tryParse(trimmed);
    if (value == null || value < 0.0 || value > 1.0) {
      return (null, 'Faro sample rate must be a number between 0.0 and 1.0.');
    }
    return (value, null);
  }

  /// [ConfigService.faroCollectorUrl] throws if `FARO_COLLECTOR_URL` isn't
  /// configured. Swallow that here so the Config screen is still usable.
  String? _safeDefaultFaroCollectorUrl() {
    try {
      return ConfigService.faroCollectorUrl;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// Providers
// =============================================================================

final _configScreenViewModelProvider =
    NotifierProvider<_ConfigScreenViewModel, ConfigScreenUiState>(
      _ConfigScreenViewModel.new,
    );

final configScreenUiStateProvider = Provider<ConfigScreenUiState>((ref) {
  return ref.watch(_configScreenViewModelProvider);
});

final configScreenActionsProvider = Provider<ConfigScreenActions>((ref) {
  return ref.read(_configScreenViewModelProvider.notifier);
});
