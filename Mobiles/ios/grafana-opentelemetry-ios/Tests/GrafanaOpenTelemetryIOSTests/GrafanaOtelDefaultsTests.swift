import OpenTelemetryApi
import OpenTelemetrySdk
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// Asserts the mapping from ``GrafanaOtelConfiguration`` onto upstream SDK inputs.
///
/// These run against ``GrafanaOtelSetup/makePlan`` rather than ``GrafanaOtel/initialize``, so the
/// Grafana defaults, resource precedence and header policy are covered without registering
/// process-wide providers or swizzling `URLSession`.
final class GrafanaOtelDefaultsTests: XCTestCase {
  private let base = Resource(attributes: [
    "service.name": .string("unknown_service:xctest"),
    "telemetry.sdk.language": .string("swift"),
  ])

  private func plan(
    _ configuration: GrafanaOtelConfiguration,
    environmentHeaders: [(String, String)]? = nil
  ) -> GrafanaOtelPlan {
    GrafanaOtelSetup.makePlan(
      configuration: configuration,
      baseResource: base,
      environmentHeaders: environmentHeaders
    )
  }

  // MARK: - Resource

  func testPackageOwnedAttributesOverrideTheBaseResource() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        serviceVersion: "1.4.0",
        deploymentEnvironment: "production"
      )
    )

    XCTAssertEqual(result.resource.attributes["service.version"], .string("1.4.0"))
    XCTAssertEqual(result.resource.attributes["deployment.environment.name"], .string("production"))
    // Base resource attributes the Grafana defaults do not own survive.
    XCTAssertEqual(result.resource.attributes["telemetry.sdk.language"], .string("swift"))
  }

  func testCallerResourceAttributesAreAdditive() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        resourceAttributes: ["faro.app.bundleId": "com.grafana.QuickPizzaIos"]
      )
    )

    XCTAssertEqual(
      result.resource.attributes["faro.app.bundleId"],
      .string("com.grafana.QuickPizzaIos")
    )
    // Nothing in the package puts a service name back once the bundle-derived one is removed.
    XCTAssertNil(result.resource.attributes["service.name"])
  }

  /// Only covers attributes the upstream default resource does not itself provide.
  /// `service.version` is deliberately absent from this list — see
  /// ``testOmittedServiceVersionFallsBackToTheBaseResourceValue``.
  func testOptionalIdentityAttributesAreOmittedWhenUnset() throws {
    let result = plan(
      try GrafanaOtelConfiguration(otlpEndpoint: URL(string: "https://collector.example/otlp/key")!, firstPartyHosts: [])
    )

    XCTAssertNil(result.resource.attributes["service.namespace"])
    XCTAssertNil(result.resource.attributes["deployment.environment.name"])
  }

  // MARK: - Endpoints

  func testSignalPathsAreAppendedToTheConfiguredBaseEndpoint() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/app-key")!,
        firstPartyHosts: []
      )
    )

    XCTAssertEqual(
      result.tracesEndpoint.absoluteString,
      "https://collector.example/otlp/app-key/v1/traces"
    )
    XCTAssertEqual(
      result.logsEndpoint.absoluteString,
      "https://collector.example/otlp/app-key/v1/logs"
    )
  }

  func testTrailingSlashOnTheConfiguredEndpointDoesNotDoubleTheSeparator() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "http://localhost:4318/")!,
        firstPartyHosts: []
      )
    )

    XCTAssertEqual(result.tracesEndpoint.absoluteString, "http://localhost:4318/v1/traces")
    XCTAssertEqual(result.logsEndpoint.absoluteString, "http://localhost:4318/v1/logs")
  }

  // MARK: - Headers

  func testConfiguredHeadersOverrideEnvironmentHeadersCaseInsensitively() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp")!,
        firstPartyHosts: [],
        headers: ["Authorization": "Basic configured"]
      ),
      environmentHeaders: [("authorization", "Basic from-env"), ("X-Scope-OrgID", "42")]
    )

    XCTAssertEqual(result.exportHeaders.count, 2)
    XCTAssertEqual(result.exportHeaders.first?.name, "X-Scope-OrgID")
    XCTAssertEqual(result.exportHeaders.first?.value, "42")
    XCTAssertEqual(result.exportHeaders.last?.name, "Authorization")
    XCTAssertEqual(result.exportHeaders.last?.value, "Basic configured")
  }

  /// The exporter comma-appends repeated header names, so duplicates must not survive the merge.
  func testDuplicateEnvironmentHeaderNamesAreDeduplicated() throws {
    let result = plan(
      try GrafanaOtelConfiguration(otlpEndpoint: URL(string: "https://collector.example/otlp/key")!, firstPartyHosts: []),
      environmentHeaders: [("X-Scope-OrgID", "first"), ("x-scope-orgid", "second")]
    )

    XCTAssertEqual(result.exportHeaders.map(\.value), ["first"])
  }

  func testEnvironmentHeadersSurviveWhenNoHeadersAreConfigured() throws {
    let result = plan(
      try GrafanaOtelConfiguration(otlpEndpoint: URL(string: "https://collector.example/otlp/key")!, firstPartyHosts: []),
      environmentHeaders: [("Authorization", "Basic from-env")]
    )

    XCTAssertEqual(result.exportHeaders.map(\.name), ["Authorization"])
  }

  func testConfiguredHeadersAreEmittedInStableOrder() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        headers: ["b-header": "2", "a-header": "1", "c-header": "3"]
      )
    )

    XCTAssertEqual(result.exportHeaders.map(\.name), ["a-header", "b-header", "c-header"])
  }

  func testEnvironmentHeaderParsingSplitsAndTrimsEntries() {
    XCTAssertNil(GrafanaOtelSetup.environmentHeaders(from: nil))
    XCTAssertNil(GrafanaOtelSetup.environmentHeaders(from: "no-equals-sign"))

    let parsed = GrafanaOtelSetup.environmentHeaders(
      from: " Authorization = Basic abc , X-Scope-OrgID=42 "
    )
    XCTAssertEqual(parsed?.map(\.0), ["Authorization", "X-Scope-OrgID"])
    XCTAssertEqual(parsed?.map(\.1), ["Basic abc", "42"])
  }

  /// Upstream requires exactly two `=`-separated components, which drops every base64 value with
  /// padding — that is, every `Basic` credential. Splitting on the first `=` accepts them.
  func testEnvironmentHeaderParsingKeepsBase64PaddingInValues() {
    let parsed = GrafanaOtelSetup.environmentHeaders(from: "Authorization=Basic dXNlcjpwYXNz==")

    XCTAssertEqual(parsed?.map(\.0), ["Authorization"])
    XCTAssertEqual(parsed?.map(\.1), ["Basic dXNlcjpwYXNz=="])
  }

  /// `[String: String]` permits two spellings of one header name, and the exporter comma-appends
  /// repeated names into a corrupt value, so configured names must dedupe against each other too.
  func testCaseVariantConfiguredHeaderNamesAreDeduplicated() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        headers: ["Authorization": "first", "authorization": "second"]
      )
    )

    XCTAssertEqual(result.exportHeaders.count, 1)
    // Sorted order makes the survivor deterministic rather than dictionary-order dependent.
    XCTAssertEqual(result.exportHeaders.first?.name, "Authorization")
  }

  /// Upstream's default resource always contributes `service.version` from the bundle, so omitting
  /// the setting does not mean the attribute is absent.
  func testOmittedServiceVersionFallsBackToTheBaseResourceValue() throws {
    let base = Resource(attributes: ["service.version": .string("1.1.0 (1)")])
    let result = GrafanaOtelSetup.makePlan(
      configuration: try GrafanaOtelConfiguration(otlpEndpoint: URL(string: "https://collector.example/otlp/key")!, firstPartyHosts: []),
      baseResource: base,
      environmentHeaders: nil
    )

    XCTAssertEqual(result.resource.attributes["service.version"], .string("1.1.0 (1)"))
  }

  // MARK: - Sessions, conventions and export host

  func testSessionDefaultsMatchTheGrafanaSessionRules() throws {
    let result = plan(try GrafanaOtelConfiguration(otlpEndpoint: URL(string: "https://collector.example/otlp/key")!, firstPartyHosts: []))

    XCTAssertEqual(result.sessionConfig.sessionTimeout, 15 * 60)
    XCTAssertEqual(result.sessionConfig.maxLifetime, 4 * 60 * 60)
    XCTAssertFalse(result.sessionConfig.restorePersistedSession)
  }

  func testSessionOverridesReachTheUpstreamSessionConfig() throws {
    let result = plan(
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        sessionInactivityTimeout: 60,
        sessionMaxLifetime: 120,
        restorePersistedSession: true
      )
    )

    XCTAssertEqual(result.sessionConfig.sessionTimeout, 60)
    XCTAssertEqual(result.sessionConfig.maxLifetime, 120)
    XCTAssertTrue(result.sessionConfig.restorePersistedSession)
  }

  // MARK: - service.name

  /// The package removes the bundle-derived `service.name` upstream always adds, because ingest
  /// backfills the registered app identity only when the attribute is absent or an
  /// `unknown_service*` placeholder.
  func testBundleDerivedServiceNameIsRemoved() throws {
    let base = Resource(attributes: [
      "service.name": .string("MyBundleName"),
      "telemetry.sdk.language": .string("swift"),
    ])
    let result = GrafanaOtelSetup.makePlan(
      configuration: try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: []
      ),
      baseResource: base,
      environmentHeaders: nil
    )

    XCTAssertNil(result.resource.attributes["service.name"])
    XCTAssertEqual(result.resource.attributes["telemetry.sdk.language"], .string("swift"))
  }

  /// `resourceAttributes` is the only route to a service identity now, and an explicit one must
  /// survive the removal above — that is what the OTLP-gateway path depends on.
  func testExplicitServiceNameInResourceAttributesSurvives() throws {
    let base = Resource(attributes: ["service.name": .string("MyBundleName")])
    let result = GrafanaOtelSetup.makePlan(
      configuration: try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: [],
        resourceAttributes: [
          "service.name": "quickpizza-ios",
          "service.namespace": "quickpizza",
        ]
      ),
      baseResource: base,
      environmentHeaders: nil
    )

    XCTAssertEqual(result.resource.attributes["service.name"], .string("quickpizza-ios"))
    XCTAssertEqual(result.resource.attributes["service.namespace"], .string("quickpizza"))
  }

  // MARK: - Disk buffering

  /// On by default. Trace batches get durable retry; log batches are protected only until their
  /// first export attempt because the upstream HTTP log exporter reports success asynchronously.
  func testDiskBufferingIsEnabledByDefault() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: []
    )

    XCTAssertEqual(configuration.diskBuffering, .enabledInDefaultDirectory)
  }

  /// The default location has to survive system cache eviction, so it must not be a caches
  /// directory, and it must be package-scoped rather than the bare container.
  func testDefaultStorageDirectoryIsPackageScopedAndNotACachesDirectory() {
    let path = GrafanaOtelDiskBuffering.defaultStorageURL.path

    XCTAssertTrue(path.hasSuffix("com.grafana.opentelemetry.ios"), path)
    XCTAssertFalse(path.contains("/Caches/"), path)
  }

  /// The backup-exclusion branch keys off this equality, so it has to hold.
  func testDefaultDirectoryCaseEqualsAnExplicitEnabledCaseAtTheSameURL() {
    XCTAssertEqual(
      GrafanaOtelDiskBuffering.enabledInDefaultDirectory,
      .enabled(storageURL: GrafanaOtelDiskBuffering.defaultStorageURL)
    )
  }

  /// Persistence caps a JSON-encoded batch at 256 KiB and oversized writes fail silently, so
  /// buffered batches must be smaller than the straight-to-network default.
  func testBufferedExportsUseSmallerBatchesThanDirectExports() {
    XCTAssertEqual(GrafanaOtelSetup.maxExportBatchSize(bufferingToDisk: true), 128)
    XCTAssertEqual(GrafanaOtelSetup.maxExportBatchSize(bufferingToDisk: false), 512)
  }

  func testDiskBufferingCanBeTurnedOff() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: [],
      diskBuffering: .disabled
    )

    XCTAssertEqual(configuration.diskBuffering, .disabled)
  }

  // MARK: - URL sanitisation

  func testSanitizedURLStringStripsQueryFragmentAndCredentials() {
    XCTAssertEqual(
      GrafanaOtelSetup.sanitizedURLString(
        for: URL(string: "https://user:secret@api.example/v1/pizza?token=abc&q=1#frag")!
      ),
      "https://api.example/v1/pizza"
    )
  }

  func testSanitizedURLStringKeepsPathAndPort() {
    XCTAssertEqual(
      GrafanaOtelSetup.sanitizedURLString(for: URL(string: "http://localhost:3333/api/quotes")!),
      "http://localhost:3333/api/quotes"
    )
  }

  func testSanitizedURLStringHandlesAMissingURL() {
    XCTAssertNil(GrafanaOtelSetup.sanitizedURLString(for: nil))
  }

  /// The convention is fixed at `.stable`, which records the URL as `url.full`. If that key is
  /// wrong the sanitiser rewrites an attribute nothing reads, and the raw URL ships instead.
  func testUrlAttributeKeyMatchesTheStableConvention() {
    XCTAssertEqual(GrafanaOtelSetup.urlAttributeKey, "url.full")
  }

  func testCollectorOriginIsExcludedFromAutomaticHttpTracing() throws {
    let configured = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: []
    )
    let origin = try XCTUnwrap(GrafanaOtelSetup.excludedOrigin(for: configured))

    XCTAssertEqual(origin.host, "collector.example")
    // https with no explicit port normalises to 443, so a sibling request on the same origin matches.
    XCTAssertEqual(origin.port, 443)
    XCTAssertTrue(origin.matches(URL(string: "https://collector.example/otlp/key/v1/traces")))
    XCTAssertTrue(origin.matches(URL(string: "https://collector.example:443/anything")))
    XCTAssertFalse(origin.matches(URL(string: "https://api.collector.example/x")))
    XCTAssertFalse(origin.matches(nil))
  }

  /// The regression this exists for: a host-only exclusion silently suppressed every backend span
  /// during local development, where the collector and the backend share `localhost`.
  func testLocalBackendOnADifferentPortIsStillInstrumented() throws {
    let configured = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "http://localhost:8002/otlp/ios-spike")!,
      firstPartyHosts: []
    )
    let origin = try XCTUnwrap(GrafanaOtelSetup.excludedOrigin(for: configured))

    XCTAssertTrue(origin.matches(URL(string: "http://localhost:8002/otlp/ios-spike/v1/logs")))
    XCTAssertFalse(
      origin.matches(URL(string: "http://localhost:3333/api/quotes")),
      "the application backend must stay instrumented"
    )
  }

  func testInstrumentationTogglesDefaultToOn() {
    let options = GrafanaOtelInstrumentationOptions.default

    XCTAssertTrue(options.urlSession)
    XCTAssertTrue(options.sessionEvents)
    XCTAssertTrue(options.metricKitDiagnostics)
  }
}
