// Smoke test: verifies QuickPizzaApp mounts without throwing.
//
// This is deliberately minimal. A richer test would need to mock out the
// full provider tree (auth, pizza, Faro, network), which is out of scope
// for a demo app of this size.
//
// We override `sharedPreferencesProvider` (with mock prefs) and
// `runtimeConfigProvider` because tests don't go through bootstrap, which
// normally resolves both. Config + debug providers read prefs synchronously,
// so the override must be a resolved instance.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_mobile_o11y_demo/bootstrap.dart';
import 'package:flutter_mobile_o11y_demo/core/config/runtime_config.dart';
import 'package:flutter_mobile_o11y_demo/core/config/shared_preferences_provider.dart';

void main() {
  testWidgets('QuickPizzaApp mounts', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            backendBaseUrl: 'http://localhost:3333',
            faroCollectorUrl: '',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const QuickPizzaApp(),
      ),
    );

    // Don't settle — downstream HTTP providers would attempt real network
    // calls. A single frame is enough to prove the app mounts.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
