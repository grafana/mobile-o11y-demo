import XCTest
@testable import GrafanaOpenTelemetryIOS

/// The allowlist that decides which hosts receive `traceparent`.
///
/// Upstream injects trace context into every instrumented request, so this list is the only thing
/// standing between a connected first-party trace and trace ids leaking to third-party hosts.
final class GrafanaOtelTracePropagationTests: XCTestCase {
  func testListedHostIsTrusted() {
    XCTAssertTrue(propagates(to: "quickpizza.example", hosts: ["quickpizza.example"]))
  }

  func testUnlistedHostIsNotTrusted() {
    XCTAssertFalse(propagates(to: "ads.thirdparty.example", hosts: ["quickpizza.example"]))
  }

  /// Matching is exact, not a suffix match. A host is trusted only because someone listed it, so
  /// each subdomain has to be named — and a look-alike domain can never slip through.
  func testSubdomainsAreNotImpliedByTheirParent() {
    XCTAssertFalse(propagates(to: "api.example.com", hosts: ["example.com"]))
    XCTAssertTrue(propagates(to: "api.example.com", hosts: ["example.com", "api.example.com"]))
    XCTAssertFalse(propagates(to: "notexample.com", hosts: ["example.com"]))
    XCTAssertFalse(propagates(to: "example.com.evil.test", hosts: ["example.com"]))
  }

  func testMatchingIsCaseInsensitive() {
    XCTAssertTrue(propagates(to: "quickpizza.example", hosts: ["QuickPizza.Example"]))
    XCTAssertTrue(propagates(to: "API.EXAMPLE.COM", hosts: ["api.example.com"]))
  }

  func testRequestWithoutAHostIsNeverTrusted() {
    XCTAssertFalse(propagates(to: nil, hosts: ["example.com"]))
    XCTAssertFalse(propagates(to: "", hosts: ["example.com"]))
  }

  /// Valid, and worth a test: it is how an app says "propagate nowhere".
  func testEmptyListTrustsNothing() {
    XCTAssertFalse(propagates(to: "quickpizza.example", hosts: []))
  }

  /// A blank entry would match nothing while looking like an allowlist, so it is rejected up front.
  func testBlankHostEntryIsRejectedByConfiguration() {
    do {
      _ = try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: ["quickpizza.example", "  "]
      )
      XCTFail("expected a blank-value error")
    } catch let error as GrafanaOtelConfigurationError {
      XCTAssertEqual(error, .blankValue(field: "firstPartyHosts entry"))
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  /// There is no default: a caller cannot end up propagating anywhere they did not name.
  func testHostsAreCarriedThroughVerbatim() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: ["api.example", "eu.api.example"]
    )

    XCTAssertEqual(configuration.firstPartyHosts, ["api.example", "eu.api.example"])
  }

  private func propagates(to host: String?, hosts: [String]) -> Bool {
    GrafanaOtelSetup.shouldPropagateTraceContext(
      to: host,
      firstPartyHosts: Set(hosts.map { $0.lowercased() })
    )
  }
}
