/**
 * Temporary demo-only NDK crash replay for the OTel Android app.
 *
 * **TODO:** Remove this package once [opentelemetry-android supports native crash reporting](https://github.com/open-telemetry/opentelemetry-android/issues/764).
 * Tombstone parsing, ApplicationExitInfo replay, and `device.crash` export belong in the SDK
 * (same role as `FaroCrashReporter` in faro-react-native-sdk), not in client/demo apps.
 *
 * Until then, [NativeExitCrashReporter] replays `REASON_CRASH_NATIVE` on launch and emits OTLP
 * `device.crash` logs with a `trace` attribute for collector NDK + R8 retrace.
 *
 * SIGSEGV triggers live in the Debug tab (`NdkCrashTrigger`, separate PR). This package only
 * handles replay/export so it can be deleted when the OTel Android SDK ships native crashes.
 */
package com.grafana.quickpizza.nativecrash
