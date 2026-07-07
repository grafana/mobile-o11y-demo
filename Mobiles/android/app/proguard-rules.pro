# Add project specific ProGuard rules here.
# Keep OpenTelemetry classes
-keep class io.opentelemetry.** { *; }
-dontwarn io.opentelemetry.**

# NDK SIGSEGV demo trigger (Debug tab)
-keep class com.grafana.quickpizza.features.debug.NdkCrashTrigger { *; }
