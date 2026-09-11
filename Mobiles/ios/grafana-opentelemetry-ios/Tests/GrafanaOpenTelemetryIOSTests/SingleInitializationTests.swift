import XCTest
@testable import GrafanaOpenTelemetryIOS

private final class Box {
  let label: String
  init(label: String) { self.label = label }
}

private struct SetupFailure: Error {}

/// The startup guard behind ``GrafanaOtel/initialize(configuration:)``.
///
/// Registering the Swift SDK twice replaces the global providers and installs a second set of
/// exporters and swizzled instrumentations, so these guarantees are what keep a repeated
/// `initialize` call harmless.
final class SingleInitializationTests: XCTestCase {
  func testFirstCallOwnsInitialization() throws {
    let initialization = SingleInitialization<Box>()
    var invocations = 0

    let first = try initialization.getOrInitialize {
      invocations += 1
      return Box(label: "first")
    }
    let second = try initialization.getOrInitialize {
      invocations += 1
      return Box(label: "second")
    }

    XCTAssertEqual(invocations, 1)
    XCTAssertIdentical(first, second)
    XCTAssertEqual(second.label, "first")
  }

  func testValueIsUnavailableBeforeInitialization() {
    XCTAssertNil(SingleInitialization<Box>().getOrNull())
  }

  func testValueIsAvailableAfterInitialization() throws {
    let initialization = SingleInitialization<Box>()
    let value = try initialization.getOrInitialize { Box(label: "ready") }

    XCTAssertIdentical(initialization.getOrNull(), value)
  }

  func testFailurePropagatesToTheCaller() {
    let initialization = SingleInitialization<Box>()

    XCTAssertThrowsError(try initialization.getOrInitialize { throw SetupFailure() }) { error in
      XCTAssertTrue(error is SetupFailure)
    }
    XCTAssertNil(initialization.getOrNull())
  }

  /// Upstream setup may already have registered global state, so a retry in the same process is
  /// refused rather than allowed to build on a half-installed SDK.
  func testFailureIsRememberedAndBlocksRetryInTheSameProcess() {
    let initialization = SingleInitialization<Box>()
    var invocations = 0

    XCTAssertThrowsError(
      try initialization.getOrInitialize {
        invocations += 1
        throw SetupFailure()
      }
    )
    XCTAssertThrowsError(
      try initialization.getOrInitialize {
        invocations += 1
        return Box(label: "retry")
      }
    ) { error in
      guard case .previousAttemptFailed = error as? GrafanaOtelInitializationError else {
        return XCTFail("expected previousAttemptFailed, got \(error)")
      }
    }

    XCTAssertEqual(invocations, 1)
  }

  func testReentrantInitializationIsRejected() {
    let initialization = SingleInitialization<Box>()

    XCTAssertThrowsError(
      try initialization.getOrInitialize {
        _ = try initialization.getOrInitialize { Box(label: "inner") }
        return Box(label: "outer")
      }
    ) { error in
      guard case .reentrantInitialization = error as? GrafanaOtelInitializationError else {
        return XCTFail("expected reentrantInitialization, got \(error)")
      }
    }
  }

  func testConcurrentCallersShareOneValue() throws {
    let initialization = SingleInitialization<Box>()
    let invocations = Counter()
    let results = ResultsBox()

    DispatchQueue.concurrentPerform(iterations: 32) { iteration in
      let value = try? initialization.getOrInitialize {
        invocations.increment()
        return Box(label: "value-\(iteration)")
      }
      if let value { results.append(value) }
    }

    XCTAssertEqual(invocations.value, 1)
    XCTAssertEqual(results.values.count, 32)
    let unique = Set(results.values.map { ObjectIdentifier($0) })
    XCTAssertEqual(unique.count, 1)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private final class ResultsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Box] = []

  func append(_ box: Box) { lock.withLock { storage.append(box) } }
  var values: [Box] { lock.withLock { storage } }
}
