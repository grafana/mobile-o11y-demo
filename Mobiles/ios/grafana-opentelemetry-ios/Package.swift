// swift-tools-version:6.0

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
    .iOS(.v13),
    .macOS(.v12)
  ],
  products: [
    .library(
      name: "GrafanaOpenTelemetryIOS",
      targets: ["GrafanaOpenTelemetryIOS"]
    )
  ],
  dependencies: [
    // Pinned to the minor line, not the major, matching the operator the Frontend Observability
    // app page hands to customers. Upstream has shipped breaking work in minor releases — a
    // session-recording refactor, the `SessionConfig` API this package calls, and a Swift 6
    // toolchain requirement — while patches have been bug fixes only.
    //
    // `2.6.0` is a floor rather than a preference: the package relies on
    // `OtlpHttpLogExporter.export` returning the upload result, so disk buffering keeps a failed
    // log batch, and on `SessionLogRecordProcessor` forwarding `forceFlush` and `shutdown`.
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift.git",
      .upToNextMinor(from: "2.6.0")
    ),
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
      .upToNextMinor(from: "2.6.0")
    )
  ],
  targets: [
    .target(
      name: "GrafanaOpenTelemetryIOS",
      dependencies: [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
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
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
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
