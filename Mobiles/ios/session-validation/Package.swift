// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Session99Probe",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: "../grafana-opentelemetry-ios"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git",
             revision: "ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a")
  ],
  targets: [.executableTarget(name: "Session99Probe", dependencies: [
    .product(name: "GrafanaOpenTelemetryIOS", package: "grafana-opentelemetry-ios"),
    .product(name: "Sessions", package: "opentelemetry-swift")
  ])]
)
