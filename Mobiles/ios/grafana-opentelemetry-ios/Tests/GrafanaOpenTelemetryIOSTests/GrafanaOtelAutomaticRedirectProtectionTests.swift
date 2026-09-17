import ObjectiveC
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// The opt-in redirect protection, which works by adding a method to upstream's own delegate
/// classes.
///
/// Installation is a process-wide, irreversible runtime mutation, so the whole lifecycle is
/// asserted in ONE test method: splitting it would make the assertions depend on XCTest's ordering.
final class GrafanaOtelAutomaticRedirectProtectionTests: XCTestCase {
  private let selector = #selector(
    URLSessionTaskDelegate.urlSession(
      _:task:willPerformHTTPRedirection:newRequest:completionHandler:)
  )

  /// The names are upstream implementation details, so a rename has to surface as a reported miss
  /// rather than as silently absent protection.
  func testInstallPatchesUpstreamDelegatesReportsMissesAndNeverPatchesTwice() {
    // The classes upstream installs on delegate-less tasks must still exist under these names.
    for name in GrafanaOtelAutomaticRedirectProtection.upstreamDelegateClassNames {
      XCTAssertNotNil(
        NSClassFromString(name),
        "upstream renamed \(name); automatic redirect protection now covers nothing"
      )
    }

    let first = GrafanaOtelAutomaticRedirectProtection.install(
      firstPartyHosts: ["quickpizza.example"],
      propagationFields: ["traceparent"]
    )
    XCTAssertTrue(first.notFound.isEmpty, "unexpected missing classes: \(first.notFound)")
    XCTAssertEqual(
      Set(first.patched).union(first.alreadyImplemented),
      Set(GrafanaOtelAutomaticRedirectProtection.upstreamDelegateClassNames),
      "every named class must be accounted for as patched or already implemented"
    )
    for name in first.patched {
      let cls = try? XCTUnwrap(NSClassFromString(name))
      XCTAssertNotNil(
        class_getInstanceMethod(cls, selector),
        "\(name) must carry the redirect method after a successful patch"
      )
    }

    // Idempotent: a second call must add nothing, so an upstream release that starts handling
    // redirects itself keeps ownership rather than being overwritten.
    let second = GrafanaOtelAutomaticRedirectProtection.install(
      firstPartyHosts: ["quickpizza.example"],
      propagationFields: ["traceparent"]
    )
    XCTAssertTrue(second.patched.isEmpty, "install must not replace an existing implementation")
    XCTAssertEqual(
      Set(second.alreadyImplemented),
      Set(GrafanaOtelAutomaticRedirectProtection.upstreamDelegateClassNames)
    )

    // A name the runtime does not know is reported, not ignored.
    let missing = GrafanaOtelAutomaticRedirectProtection.install(
      firstPartyHosts: [],
      propagationFields: [],
      classNames: ["URLSessionInstrumentation.RenamedInSomeFutureRelease"]
    )
    XCTAssertEqual(missing.notFound, ["URLSessionInstrumentation.RenamedInSomeFutureRelease"])
    XCTAssertNotNil(
      GrafanaOtelAutomaticRedirectProtection.diagnosticMessage(for: missing),
      "a miss has to reach the diagnostics handler, or the gap is invisible"
    )
  }

  /// Read from the protocol rather than written out, so it cannot drift from the declaration.
  ///
  /// The redirect callback is an *optional* requirement of `NSURLSessionTaskDelegate`, which is why
  /// the lookup passes `isRequiredMethod: false`; asking for the required table returns nothing and
  /// would silently fall back to the literal.
  func testTypeEncodingComesFromTheProtocol() {
    let encoding = GrafanaOtelAutomaticRedirectProtection.typeEncoding(for: selector)

    XCTAssertNotEqual(
      encoding,
      GrafanaOtelAutomaticRedirectProtection.fallbackTypeEncoding,
      "the runtime knows this selector, so the literal fallback should not be in use"
    )
    XCTAssertTrue(encoding.hasPrefix("v"), "void return")
    XCTAssertTrue(
      encoding.contains("@?"),
      "the last argument is a block; encoding it as a plain object is wrong: \(encoding)"
    )
  }

  /// The fallback still has to describe the same signature, for the case where the protocol lookup
  /// fails.
  func testFallbackEncodingMatchesTheSignature() {
    let fallback = GrafanaOtelAutomaticRedirectProtection.fallbackTypeEncoding

    XCTAssertEqual(fallback, "v@:@@@@@?")
    // void, self, selector, session, task, response, request, completion block.
    XCTAssertEqual(fallback.filter { $0 == "@" }.count, 6)
  }
}
