# Add project specific ProGuard rules here.
# OpenTelemetry's shared Java instrumentation references a compile-time muzzle marker.
-dontwarn io.opentelemetry.javaagent.tooling.muzzle.NoMuzzle

# NDK SIGSEGV demo trigger (Debug tab)
-keep class com.grafana.quickpizza.features.debug.NdkCrashTrigger { *; }

# Demo-only native crash replay (delete with nativecrash package when OTel #764 lands)
# OTelService reflects on these methods to reach the SDK providers used for replay/flush.
-keepclassmembers class io.opentelemetry.sdk.OpenTelemetrySdk$ObfuscatedLoggerProvider {
    public io.opentelemetry.sdk.logs.SdkLoggerProvider unobfuscate();
}
-keepclassmembers class io.opentelemetry.sdk.OpenTelemetrySdk$ObfuscatedTracerProvider {
    public io.opentelemetry.sdk.trace.SdkTracerProvider unobfuscate();
}
-keep class com.grafana.quickpizza.nativecrash.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
