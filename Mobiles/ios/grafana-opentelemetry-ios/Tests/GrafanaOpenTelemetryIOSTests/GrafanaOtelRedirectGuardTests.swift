import OpenTelemetryApi
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// The redirect hole in upstream's injection policy.
///
/// `shouldInjectTracingHeaders` is consulted once, for the original request, and `URLSession`
/// carries that request's custom headers onto the request it builds for a 3xx. Upstream swizzles no
/// redirect method, so without this guard a first-party request that redirects to a third party
/// takes `traceparent` with it.
final class GrafanaOtelRedirectGuardTests: XCTestCase {
  private let fields: Set<String> = ["traceparent", "tracestate", "baggage"]

  func testRedirectOffTheListLosesTraceContext() {
    let sanitized = sanitize(
      redirectTo: "https://ads.thirdparty.example/pixel",
      hosts: ["quickpizza.example"]
    )

    XCTAssertNil(sanitized.value(forHTTPHeaderField: "traceparent"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "tracestate"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "baggage"))
  }

  /// A first-party redirect must stay connected, or the guard would break the traces it protects.
  func testRedirectStayingOnTheListKeepsTraceContext() {
    let sanitized = sanitize(
      redirectTo: "https://quickpizza.example/moved",
      hosts: ["quickpizza.example"]
    )

    XCTAssertEqual(sanitized.value(forHTTPHeaderField: "traceparent"), Self.traceparent)
    XCTAssertEqual(sanitized.value(forHTTPHeaderField: "tracestate"), "vendor=state")
  }

  /// Same host policy as injection: exact and case-insensitive, never a suffix match.
  func testRedirectPolicyMatchesTheInjectionPolicy() {
    XCTAssertNil(
      sanitize(redirectTo: "https://api.example.com/x", hosts: ["example.com"])
        .value(forHTTPHeaderField: "traceparent"),
      "a subdomain is not implied by its parent"
    )
    XCTAssertEqual(
      sanitize(redirectTo: "https://QuickPizza.Example/x", hosts: ["quickpizza.example"])
        .value(forHTTPHeaderField: "traceparent"),
      Self.traceparent
    )
  }

  /// Everything else about the request has to survive: the guard removes trace context, not auth,
  /// method or body.
  func testOnlyTraceContextIsRemoved() {
    let sanitized = sanitize(
      redirectTo: "https://ads.thirdparty.example/pixel",
      hosts: ["quickpizza.example"]
    )

    XCTAssertEqual(sanitized.httpMethod, "POST")
    XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Authorization"), "Token secret")
    XCTAssertEqual(sanitized.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(sanitized.httpBody, Data("{}".utf8))
  }

  /// A redirect without a usable host is treated as third party, not waved through.
  func testUnknownDestinationIsTreatedAsThirdParty() {
    var request = URLRequest(url: URL(string: "data:text/plain,hello")!)
    request.setValue(Self.traceparent, forHTTPHeaderField: "traceparent")

    let sanitized = GrafanaOtelSetup.sanitizedRedirect(
      request,
      firstPartyHosts: ["quickpizza.example"],
      propagationFields: fields
    )

    XCTAssertNil(sanitized.value(forHTTPHeaderField: "traceparent"))
  }

  /// The guard strips whatever the installed propagators declare, so replacing them keeps it
  /// correct, and the W3C names are always included because those are what the defaults inject.
  func testPropagationFieldsCoverTheDefaultPropagators() {
    let resolved = GrafanaOtelSetup.tracePropagationFields()

    XCTAssertTrue(resolved.isSuperset(of: ["traceparent", "tracestate", "baggage"]))
    XCTAssertTrue(
      resolved.isSuperset(of: OpenTelemetry.instance.propagators.textMapPropagator.fields)
    )
    XCTAssertTrue(
      resolved.isSuperset(of: OpenTelemetry.instance.propagators.textMapBaggagePropagator.fields)
    )
  }

  /// The W3C names are included unconditionally, not just taken from the propagators.
  ///
  /// `TextMapPropagator.fields` is advisory rather than exhaustive — `ZipkinBaggagePropagator`
  /// declares an empty set while writing a header per baggage entry — so a propagator that
  /// under-declares must not be able to leave `traceparent` on a third-party redirect. Reading the
  /// propagators alone passes every other test in this file, because the defaults happen to
  /// declare exactly those three names.
  func testW3CNamesAreStrippedEvenWhenThePropagatorsDeclareNothing() {
    let silent = GrafanaOtelSetup.tracePropagationFields(propagators: SilentPropagators())

    XCTAssertTrue(
      silent.isSuperset(of: ["traceparent", "tracestate", "baggage"]),
      "a propagator that declares no fields must not disable the guard: \(silent)"
    )
  }

  /// The delegate method is what `URLSession` actually calls, so exercise it rather than only the
  /// policy behind it.
  func testDelegateReturnsTheSanitizedRequest() {
    let guardObject = GrafanaOtelRedirectGuard(
      firstPartyHosts: ["quickpizza.example"],
      propagationFields: fields
    )
    var redirect = URLRequest(url: URL(string: "https://ads.thirdparty.example/pixel")!)
    redirect.setValue(Self.traceparent, forHTTPHeaderField: "traceparent")

    var delivered: URLRequest?
    guardObject.urlSession(
      .shared,
      task: URLSession.shared.dataTask(with: URL(string: "https://quickpizza.example/a")!),
      willPerformHTTPRedirection: HTTPURLResponse(
        url: URL(string: "https://quickpizza.example/a")!,
        statusCode: 302,
        httpVersion: nil,
        headerFields: nil
      )!,
      newRequest: redirect,
      completionHandler: { delivered = $0 }
    )

    XCTAssertNil(try? XCTUnwrap(delivered).value(forHTTPHeaderField: "traceparent"))
    XCTAssertEqual(delivered?.url, redirect.url, "the redirect must still be followed")
  }

  /// Load-bearing, and easy to delete by mistake.
  ///
  /// Giving a task a delegate makes upstream skip its own `AsyncTaskDelegate`, and
  /// `urlSession(_:task:didCompleteWithError:)` is one of the selectors `URLSessionInstrumentation`
  /// scans delegate classes for. Without it this class is never swizzled and every HTTP span of
  /// every request using the guard is silently dropped.
  func testGuardImplementsTheSelectorUpstreamSwizzlesToEndSpans() {
    let guardObject = GrafanaOtelRedirectGuard(firstPartyHosts: [], propagationFields: fields)
    let selector = #selector(
      URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)
    )

    XCTAssertTrue(
      guardObject.responds(to: selector),
      "removing didCompleteWithError drops the spans of every request using this guard"
    )
  }

  // MARK: - Helpers

  /// Propagators that inject headers without declaring any, like `ZipkinBaggagePropagator`.
  private struct SilentPropagators: ContextPropagators {
    struct Silent: TextMapPropagator, TextMapBaggagePropagator {
      let fields: Set<String> = []
      func inject<S>(spanContext: SpanContext, carrier: inout [String: String], setter: S)
        where S: Setter {}
      func inject<S>(baggage: Baggage, carrier: inout [String: String], setter: S)
        where S: Setter {}
      func extract<G>(carrier: [String: String], getter: G) -> SpanContext?
        where G: Getter { nil }
      func extract<G>(carrier: [String: String], getter: G) -> Baggage?
        where G: Getter { nil }
    }

    let textMapPropagator: TextMapPropagator = Silent()
    let textMapBaggagePropagator: TextMapBaggagePropagator = Silent()
  }

  private static let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  private func sanitize(redirectTo url: String, hosts: Set<String>) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue(Self.traceparent, forHTTPHeaderField: "traceparent")
    request.setValue("vendor=state", forHTTPHeaderField: "tracestate")
    request.setValue("key=value", forHTTPHeaderField: "baggage")
    request.setValue("Token secret", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    return GrafanaOtelSetup.sanitizedRedirect(
      request,
      firstPartyHosts: hosts,
      propagationFields: fields
    )
  }
}
