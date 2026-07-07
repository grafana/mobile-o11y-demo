# Add project specific ProGuard rules here.
# Keep OpenTelemetry classes
-keep class io.opentelemetry.** { *; }
-dontwarn io.opentelemetry.**

# Demo-only native crash replay (delete with nativecrash package when OTel #764 lands)
-keep class com.grafana.quickpizza.nativecrash.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
