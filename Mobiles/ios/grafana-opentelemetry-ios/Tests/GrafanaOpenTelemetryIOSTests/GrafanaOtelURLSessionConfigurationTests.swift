import OpenTelemetrySdk
import URLSessionInstrumentation
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// The Grafana-owned settings on the upstream `URLSession` instrumentation.
///
/// These are asserted against the configuration builder rather than a live
/// `URLSessionInstrumentation`, because constructing one swizzles `URLSession` globally with no way
/// to undo it. Without these tests every re-assertion in `makeURLSessionConfiguration` could be
/// deleted with the suite still green.
final class GrafanaOtelURLSessionConfigurationTests: XCTestCase {
  private let collector = URL(string: "http://localhost:8002/otlp/app-key")!

  private func makeConfiguration(
    endpoint: URL,
    firstPartyHosts: [String] = [],
    experimental: GrafanaOtelExperimentalOptions = GrafanaOtelExperimentalOptions()
  ) throws -> URLSessionInstrumentationConfiguration {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: endpoint,
      firstPartyHosts: firstPartyHosts
    )
    let plan = GrafanaOtelSetup.makePlan(
      configuration: configuration,
      baseResource: Resource(attributes: [:]),
      environmentHeaders: nil
    )
    return GrafanaOtel.makeURLSessionConfiguration(
      configuration: configuration,
      plan: plan,
      experimental: experimental
    )
  }

  private func shouldInstrument(
    _ configuration: URLSessionInstrumentationConfiguration,
    _ url: String
  ) -> Bool? {
    configuration.shouldInstrument?(URLRequest(url: URL(string: url)!))
  }

  private func shouldInject(
    _ configuration: URLSessionInstrumentationConfiguration,
    _ url: String
  ) -> Bool? {
    configuration.shouldInjectTracingHeaders?(URLRequest(url: URL(string: url)!))
  }

  // MARK: - Collector exclusion

  func testCollectorOriginIsNotInstrumented() throws {
    let configuration = try makeConfiguration(endpoint: collector)

    XCTAssertEqual(shouldInstrument(configuration, "http://localhost:8002/otlp/app-key/v1/logs"), false)
  }

  /// The regression that host-only matching caused: the backend shares `localhost` with the
  /// collector during local development and must stay instrumented.
  func testBackendOnADifferentPortIsStillInstrumented() throws {
    let configuration = try makeConfiguration(endpoint: collector)

    XCTAssertEqual(shouldInstrument(configuration, "http://localhost:3333/api/quotes"), true)
  }

  /// A caller predicate composes, but must not be able to re-enable tracing of the collector.
  func testCallerPredicateNarrowsButCannotReEnableTheCollector() throws {
    let experimental = GrafanaOtelExperimentalOptions(
      customizeURLSession: { configuration in
        configuration.shouldInstrument = { _ in true }
      }
    )
    let configuration = try makeConfiguration(endpoint: collector, experimental: experimental)

    XCTAssertEqual(shouldInstrument(configuration, "http://localhost:8002/otlp/app-key/v1/logs"), false)
    XCTAssertEqual(shouldInstrument(configuration, "http://localhost:3333/api/quotes"), true)
  }

  func testCallerPredicateCanExcludeAdditionalHosts() throws {
    let experimental = GrafanaOtelExperimentalOptions(
      customizeURLSession: { configuration in
        configuration.shouldInstrument = { $0.url?.host != "noisy.example" }
      }
    )
    let configuration = try makeConfiguration(endpoint: collector, experimental: experimental)

    XCTAssertEqual(shouldInstrument(configuration, "https://noisy.example/x"), false)
    XCTAssertEqual(shouldInstrument(configuration, "https://api.example/x"), true)
  }

  // MARK: - Trace-context propagation

  func testEveryListedHostIsInjected() throws {
    let configuration = try makeConfiguration(
      endpoint: collector,
      firstPartyHosts: ["api.example", "ads.thirdparty.example"]
    )

    XCTAssertEqual(shouldInject(configuration, "https://api.example/x"), true)
    XCTAssertEqual(shouldInject(configuration, "https://ads.thirdparty.example/x"), true)
  }

  func testOnlyListedHostsAreInjected() throws {
    let configuration = try makeConfiguration(
      endpoint: collector,
      firstPartyHosts: ["api.example"]
    )

    XCTAssertEqual(shouldInject(configuration, "https://api.example/x"), true)
    // Exact matching: a subdomain is not implied by its parent.
    XCTAssertEqual(shouldInject(configuration, "https://eu.api.example/x"), false)
    XCTAssertEqual(shouldInject(configuration, "https://ads.thirdparty.example/x"), false)
  }

  /// A caller may narrow propagation further, but cannot widen it past the policy.
  func testCallerCannotWidenPropagationPastTheList() throws {
    let experimental = GrafanaOtelExperimentalOptions(
      customizeURLSession: { configuration in
        configuration.shouldInjectTracingHeaders = { _ in true }
      }
    )
    let configuration = try makeConfiguration(
      endpoint: collector,
      firstPartyHosts: ["api.example"],
      experimental: experimental
    )

    XCTAssertEqual(shouldInject(configuration, "https://ads.thirdparty.example/x"), false)
    XCTAssertEqual(shouldInject(configuration, "https://api.example/x"), true)
  }

  // MARK: - Semantic convention and span kind

  /// Fixed by the distribution. A caller may not move it back to the deprecated names, because
  /// ingest reads stable-first and a new app should not start on `http.method` / `http.url`.
  func testSemanticConventionIsStableAndCallerCannotOverrideIt() throws {
    XCTAssertEqual(try makeConfiguration(endpoint: collector).semanticConvention, .stable)

    let experimental = GrafanaOtelExperimentalOptions(
      customizeURLSession: { configuration in
        configuration.semanticConvention = .old
      }
    )
    let configuration = try makeConfiguration(endpoint: collector, experimental: experimental)

    XCTAssertEqual(configuration.semanticConvention, .stable)
  }

  func testSpanCustomizationIsInstalled() throws {
    XCTAssertNotNil(try makeConfiguration(endpoint: collector).spanCustomization)
  }
}
