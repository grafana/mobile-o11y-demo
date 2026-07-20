// Verifies the ordering constraint behind `installFaroHttpOverrides()`:
// an `http.Client()` (IOClient) captures its `HttpClient` AT CONSTRUCTION via
// `HttpOverrides.current`, so a client built BEFORE the override is installed
// is never routed through it — while one built AFTER is. This is the exact
// mechanism that makes bootstrap install the Faro overrides before anything
// (e.g. session restore) constructs the cached ApiClient's http.Client.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _CountingHttpOverrides extends HttpOverrides {
  int createCount = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    createCount++;
    return super.createHttpClient(context);
  }
}

void main() {
  test(
    'http.Client() is only routed through HttpOverrides installed BEFORE it',
    () {
      final saved = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = saved);

      final overrides = _CountingHttpOverrides();

      // Build a client with NO custom override installed.
      HttpOverrides.global = null;
      final before = http.Client();
      expect(
        overrides.createCount,
        0,
        reason: 'client constructed before install must not use the override',
      );

      // Install the override, then build another client.
      HttpOverrides.global = overrides;
      final after = http.Client();
      expect(
        overrides.createCount,
        1,
        reason: 'only the post-install client should go through the override',
      );

      before.close();
      after.close();
    },
  );
}
