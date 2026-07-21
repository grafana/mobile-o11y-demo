import 'dart:async';

import 'package:flutter/widgets.dart';

import 'sdk/demo_rum.dart';

/// Owns startup + configuration for the made-up [DemoRum] SDK.
///
/// DemoRum runs *alongside* Grafana Faro to demo two mobile RUM SDKs coexisting
/// in one app. It's a no-op stand-in (see `sdk/demo_rum.dart`), so unlike Faro
/// it has no endpoint/credentials to configure and can't fail — it always
/// "initializes" and runs the app.
///
/// [startDemoRum] runs as the OUTER half of the telemetry nesting
/// (`startFaro` is the inner half). DemoRum installs *chained*
/// `FlutterError.onError` / `PlatformDispatcher.onError` handlers (echo-only,
/// see `sdk/demo_rum.dart`), exactly as a real cooperating SDK would. Because
/// both DemoRum and Faro chain (save + call the previous handler), init order
/// only decides who runs first, not who captures — both observe every error.
Future<void> startDemoRum({
  required String appEnv,
  required String appVersion,
  required FutureOr<void> Function() appRunner,
}) async {
  await DemoRum.init((options) {
    options.environment = appEnv;
    options.release = 'quickpizza-flutter@$appVersion';

    // Echo every signal to the console so the demo can *show* the second SDK
    // receiving the same telemetry as Faro. A real SDK would send to a backend.
    options.echoToConsole = true;
  }, appRunner: appRunner);
}

/// Wraps the app root with DemoRum's widget. Composed by `bootstrap` as
/// `wrapWithDemoRum(wrapWithFaro(app))`, mirroring where a real SDK's root
/// widget would sit above `MaterialApp`.
Widget wrapWithDemoRum(Widget child) => DemoRumWidget(child: child);
