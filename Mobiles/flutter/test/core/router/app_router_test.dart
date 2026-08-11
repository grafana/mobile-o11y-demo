import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_mobile_o11y_demo/bootstrap.dart';
import 'package:flutter_mobile_o11y_demo/core/config/runtime_config.dart';
import 'package:flutter_mobile_o11y_demo/core/config/shared_preferences_provider.dart';
import 'package:flutter_mobile_o11y_demo/core/router/app_router.dart';

class _NavigationChange {
  const _NavigationChange(this.kind, this.from, this.to);

  final String kind;
  final String? from;
  final String? to;
}

class _RecordingObserver extends NavigatorObserver {
  final List<_NavigationChange> changes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    changes.add(
      _NavigationChange(
        'push',
        previousRoute?.settings.name,
        route.settings.name,
      ),
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    changes.add(
      _NavigationChange(
        'pop',
        route.settings.name,
        previousRoute?.settings.name,
      ),
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    changes.add(
      _NavigationChange(
        'replace',
        oldRoute?.settings.name,
        newRoute?.settings.name,
      ),
    );
  }
}

void main() {
  testWidgets('reports named shell and root navigation changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final rootObserver = _RecordingObserver();
    final shellObserver = _RecordingObserver();
    final router = createAppRouter(
      rootObservers: [rootObserver],
      shellObservers: [shellObserver],
    );
    addTearDown(router.dispose);

    final container = ProviderContainer(
      overrides: [
        appRouterProvider.overrideWithValue(router),
        sharedPreferencesProvider.overrideWithValue(prefs),
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            backendBaseUrl: 'http://localhost:3333',
            faroCollectorUrl: '',
            faroSampleRate: 1.0,
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
    await tester.pump();

    rootObserver.changes.clear();
    shellObserver.changes.clear();

    router.go(AppRoutes.about);
    await tester.pumpAndSettle();
    expect(shellObserver.changes, hasLength(1));
    expect(shellObserver.changes.single.kind, 'push');
    expect(shellObserver.changes.single.from, AppRoutes.home);
    expect(shellObserver.changes.single.to, AppRoutes.about);
    expect(rootObserver.changes, isEmpty);

    shellObserver.changes.clear();
    router.go(AppRoutes.debug);
    await tester.pumpAndSettle();
    expect(shellObserver.changes, hasLength(1));
    expect(shellObserver.changes.single.kind, 'push');
    expect(shellObserver.changes.single.from, AppRoutes.about);
    expect(shellObserver.changes.single.to, AppRoutes.debug);

    rootObserver.changes.clear();
    router.push(AppRoutes.debugConfig);
    await tester.pumpAndSettle();
    expect(rootObserver.changes, hasLength(1));
    expect(rootObserver.changes.single.kind, 'push');
    expect(rootObserver.changes.single.from, AppRoutes.debug);
    expect(rootObserver.changes.single.to, AppRoutes.debugConfig);

    rootObserver.changes.clear();
    router.pop();
    await tester.pumpAndSettle();
    expect(rootObserver.changes, hasLength(1));
    expect(rootObserver.changes.single.kind, 'pop');
    expect(rootObserver.changes.single.from, AppRoutes.debugConfig);
    expect(rootObserver.changes.single.to, AppRoutes.debug);
  });
}
