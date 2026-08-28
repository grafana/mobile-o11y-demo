# Add project specific ProGuard rules here.
# OpenTelemetry's shared Java instrumentation references a compile-time muzzle marker.
-dontwarn io.opentelemetry.javaagent.tooling.muzzle.NoMuzzle

# NDK SIGSEGV demo trigger (Debug tab)
-keep class com.grafana.quickpizza.features.debug.NdkCrashTrigger { *; }

# Demo-only native crash replay (delete with nativecrash package when OTel #764 lands)
-keep class com.grafana.quickpizza.nativecrash.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
