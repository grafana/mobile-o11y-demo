# Add project specific ProGuard rules here.
# Keep OpenTelemetry classes
-keep class io.opentelemetry.** { *; }
-dontwarn io.opentelemetry.**

# NDK SIGSEGV demo trigger (Debug tab)
-keep class com.grafana.quickpizza.features.debug.NdkCrashTrigger { *; }

# Demo-only native crash replay (delete with nativecrash package when OTel #764 lands)
-keep class com.grafana.quickpizza.nativecrash.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
