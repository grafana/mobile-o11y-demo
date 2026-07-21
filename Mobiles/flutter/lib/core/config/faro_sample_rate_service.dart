import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_settings.dart';
import 'shared_preferences_provider.dart';

/// Default Faro session sampling rate when no override is saved: sample every
/// session (100%). Matches Faro's own default of `SamplingRate(1.0)`.
const double kDefaultFaroSampleRate = 1.0;

final faroSampleRateServiceProvider = Provider<FaroSampleRateService>((ref) {
  return FaroSampleRateService(ref.watch(sharedPreferencesProvider));
});

/// Thin wrapper around the Faro session sampling-rate source.
///
/// The value only takes effect when Faro initializes (the sampling decision is
/// made once per session at startup), so changing the override requires an app
/// restart — same as the collector URL.
class FaroSampleRateService {
  const FaroSampleRateService(this._prefs);

  final SharedPreferences _prefs;

  /// Returns the effective sampling rate (0.0–1.0) to use for this session.
  ///
  /// Order of precedence:
  /// 1. Override in SharedPreferences (set via debug Config screen)
  /// 2. [kDefaultFaroSampleRate]
  ///
  /// Any out-of-range persisted value is clamped defensively.
  double getRate() {
    final override = _prefs.getDouble(DebugSettingsKeys.faroSampleRate);
    if (override == null) return kDefaultFaroSampleRate;
    return override.clamp(0.0, 1.0);
  }
}
