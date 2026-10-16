// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "grafana-opentelemetry-ios",
  // iOS is the supported platform. macOS is declared only so that `swift build` and `swift test`
  // can resolve on a developer machine: upstream's exporter, resource, session and instrumentation
  // products all require macOS 12, so without it the `swift` CLI has no host platform to build for.
  //
  // Both values are the floors declared by opentelemetry-swift, the binding upstream dependency, so
  // the package adds no requirement of its own beyond upstream's. Nothing else is declared —
  // upstream also supports tvOS, watchOS and visionOS, but this package is not built or tested for
  // them.
  platforms: [
    .iOS(.v15),
    .macOS(.v12)
  ],
  products: [
    .library(
      name: "GrafanaOpenTelemetryIOS",
      targets: ["GrafanaOpenTelemetryIOS"]
    )
  ],
  dependencies: [
    // Local #99 validation pin: merged #1218, not a released SDK dependency.
    // Core products now live in the consolidated Swift repository.
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift.git",
      revision: "ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a"
    )
  ],
  targets: [
    .target(
      name: "GrafanaOpenTelemetryIOS",
      dependencies: [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift"),
        .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
        .product(name: "ResourceExtension", package: "opentelemetry-swift"),
        .product(name: "Sessions", package: "opentelemetry-swift"),
        .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift"),
        .product(name: "MetricKitInstrumentation", package: "opentelemetry-swift")
      ]
    ),
    .testTarget(
      name: "GrafanaOpenTelemetryIOSTests",
      dependencies: [
        "GrafanaOpenTelemetryIOS",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift"),
        // The disk-buffering behaviour this package works around is only observable against the
        // real persistence exporters, so they are exercised over a temporary directory.
        .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
        // Asserted against directly: the session manager the processors captured is the only way to
        // prove the install order registered the configured manager and not a lazy default.
        .product(name: "Sessions", package: "opentelemetry-swift"),
        .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift")
      ]
    )
  ]
)
