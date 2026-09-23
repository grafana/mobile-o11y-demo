import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_mobile_o11y_demo/core/config/config_service.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('selects the collector for $platform, with legacy fallback', () {
      debugDefaultTargetPlatformOverride = platform;
      const shared = String.fromEnvironment('FARO_COLLECTOR_URL');
      const ios = String.fromEnvironment('FARO_COLLECTOR_URL_IOS');
      const android = String.fromEnvironment('FARO_COLLECTOR_URL_ANDROID');
      final selected = platform == TargetPlatform.android ? android : ios;
      final expected = selected.isEmpty ? shared : selected;
      if (expected.isEmpty) {
        expect(() => ConfigService.faroCollectorUrl, throwsStateError);
      } else {
        expect(ConfigService.faroCollectorUrl, expected);
      }
    });
  }
}
