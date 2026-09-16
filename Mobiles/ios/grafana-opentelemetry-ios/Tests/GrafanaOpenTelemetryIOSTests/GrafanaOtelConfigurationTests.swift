import XCTest
@testable import GrafanaOpenTelemetryIOS

final class GrafanaOtelConfigurationTests: XCTestCase {
  private let endpoint = URL(string: "https://collector.example/otlp/app-key")!

  func testAcceptsMinimalConfiguration() throws {
    // Truly minimal: endpoint plus the propagation decision, nothing else.
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: endpoint,
      firstPartyHosts: []
    )

    XCTAssertEqual(configuration.otlpEndpoint, endpoint)
    XCTAssertEqual(configuration.sessionInactivityTimeout, 15 * 60)
    XCTAssertEqual(configuration.sessionMaxLifetime, 4 * 60 * 60)
    XCTAssertFalse(configuration.restorePersistedSession)
    XCTAssertEqual(configuration.diskBuffering, .enabledInDefaultDirectory)
    XCTAssertEqual(configuration.instrumentation, .default)
    XCTAssertTrue(configuration.headers.isEmpty)
    XCTAssertTrue(configuration.resourceAttributes.isEmpty)
  }

  func testRejectsNonHttpEndpointScheme() {
    assertRejects(
      .invalidEndpoint(reason: "must be an absolute http:// or https:// URL")
    ) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "ftp://collector.example/otlp")!,
        firstPartyHosts: []
      )
    }
  }

  func testRejectsRelativeEndpoint() {
    assertRejects(
      .invalidEndpoint(reason: "must be an absolute http:// or https:// URL")
    ) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "otlp/app-key")!,
        firstPartyHosts: []
      )
    }
  }

  func testRejectsEndpointQueryString() {
    assertRejects(.invalidEndpoint(reason: "must not contain a query string")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp?token=abc")!,
        firstPartyHosts: []
      )
    }
  }

  func testRejectsEndpointFragment() {
    assertRejects(.invalidEndpoint(reason: "must not contain a fragment")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp#part")!,
        firstPartyHosts: []
      )
    }
  }

  /// RFC 3986 defines the scheme as case-insensitive, and the package lowercases hosts elsewhere.
  func testAcceptsUppercaseEndpointScheme() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "HTTPS://collector.example/otlp")!,
      firstPartyHosts: []
    )

    XCTAssertEqual(configuration.otlpEndpoint.scheme, "HTTPS")
  }

  /// The endpoint is a base URL. Pasting a full signal URL would otherwise produce
  /// `/v1/traces/v1/traces` and 404s that nothing in the SDK reports.
  func testRejectsEndpointThatAlreadyNamesASignalPath() {
    for path in ["v1/traces", "v1/logs", "v1/metrics"] {
      assertRejects(
        .invalidEndpoint(
          reason: "must be the OTLP base URL, not a signal URL ending in /\(path)"
        )
      ) {
        try GrafanaOtelConfiguration(
          otlpEndpoint: URL(string: "https://collector.example/otlp/\(path)")!,
          firstPartyHosts: []
        )
      }
    }
  }

  func testRejectsEndpointNamingASignalPathWithATrailingSlash() {
    assertRejects(
      .invalidEndpoint(reason: "must be the OTLP base URL, not a signal URL ending in /v1/traces")
    ) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/v1/traces/")!,
        firstPartyHosts: []
      )
    }
  }

  /// A base path that merely *contains* a signal segment is legitimate.
  func testAcceptsEndpointWhoseSignalSegmentIsNotTheSuffix() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/v1/traces/otlp/app-key")!,
      firstPartyHosts: []
    )

  }

  /// A malformed entry matches no host, so it silently disables injection — indistinguishable from
  /// a deliberately narrow allowlist.
  func testRejectsPropagationHostsThatAreNotBareHosts() {
    let malformed = [
      "https://api.example.com",
      "api.example.com/",
      "api.example.com:443",
      "user@api.example.com",
      "*.example.com",
      ".example.com",
      "example.com.",
      "api.example.com ",
      "two hosts",
    ]
    for host in malformed {
      assertRejects(.invalidFirstPartyHost(host)) {
        try GrafanaOtelConfiguration(
          otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
          firstPartyHosts: [host]
        )
      }
    }
  }

  func testAcceptsBareHostsIncludingAddressesAndSingleLabels() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: ["localhost", "api.example.com", "192.168.1.10"]
    )

    XCTAssertEqual(
      configuration.firstPartyHosts,
      ["localhost", "api.example.com", "192.168.1.10"]
    )
  }

  func testRejectsBlankOptionalIdentityValues() {
    assertRejects(.blankValue(field: "serviceVersion")) {
      try GrafanaOtelConfiguration(otlpEndpoint: endpoint, firstPartyHosts: [], serviceVersion: "")
    }
    assertRejects(.blankValue(field: "deploymentEnvironment")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        deploymentEnvironment: "\t"
      )
    }
  }

  /// `Resource(attributes:)` drops every attribute when one key is invalid, so this must fail loudly.
  func testRejectsUnprintableResourceAttributeKey() {
    assertRejects(.invalidResourceAttributeKey("bad\nkey")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        resourceAttributes: ["bad\nkey": "value"]
      )
    }
  }

  func testRejectsOverlongResourceAttributeKey() {
    let key = String(repeating: "k", count: 256)
    assertRejects(.invalidResourceAttributeKey(key)) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        resourceAttributes: [key: "value"]
      )
    }
  }

  func testRejectsInvalidHeaderName() {
    assertRejects(.invalidHeaderName("Bad Header")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        headers: ["Bad Header": "value"]
      )
    }
  }

  func testRejectsInvalidHeaderValue() {
    assertRejects(.invalidHeaderValue(name: "Authorization")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        headers: ["Authorization": "Basic abc\n"]
      )
    }
  }

  func testAcceptsTabsInHeaderValues() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: endpoint,
      firstPartyHosts: [],
      headers: ["X-Scope": "a\tb"]
    )

    XCTAssertEqual(configuration.headers["X-Scope"], "a\tb")
  }

  func testRejectsNonPositiveSessionTimeouts() {
    assertRejects(.notPositive(field: "sessionInactivityTimeout")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        sessionInactivityTimeout: 0
      )
    }
    assertRejects(.notPositive(field: "sessionMaxLifetime")) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        sessionMaxLifetime: -1
      )
    }
  }

  func testRejectsMaxLifetimeShorterThanInactivityTimeout() {
    assertRejects(.sessionMaxLifetimeTooShort) {
      try GrafanaOtelConfiguration(
        otlpEndpoint: endpoint,
        firstPartyHosts: [],
        sessionInactivityTimeout: 600,
        sessionMaxLifetime: 300
      )
    }
  }

  // MARK: - Helpers

  private func assertRejects(
    _ expected: GrafanaOtelConfigurationError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> GrafanaOtelConfiguration
  ) {
    do {
      _ = try body()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as GrafanaOtelConfigurationError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("unexpected error \(error)", file: file, line: line)
    }
  }
}
