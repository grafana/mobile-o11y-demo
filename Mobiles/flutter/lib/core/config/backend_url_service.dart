import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_service.dart';
import 'debug_settings.dart';
import 'shared_preferences_provider.dart';

final backendUrlServiceProvider = Provider<BackendUrlService>((ref) {
  return BackendUrlService(
    ref.watch(configServiceProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Thin wrapper around the backend base URL source.
///
/// Always prefer [getUrl] over reading [ConfigService.baseUrl]
/// directly, because it transparently applies any runtime override the
/// user saved from the debug Config screen.
class BackendUrlService {
  const BackendUrlService(this._configService, this._prefs);

  final ConfigService _configService;
  final SharedPreferences _prefs;

  /// Returns the effective backend base URL to use for this session.
  ///
  /// Order of precedence:
  /// 1. Override in SharedPreferences (set via debug Config screen)
  /// 2. Build-time env / platform default (via [ConfigService.baseUrl])
  String getUrl() {
    final override = _prefs.getString(DebugSettingsKeys.backendUrl);
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    return _configService.baseUrl;
  }
}
