import OpenTelemetryApi
import OpenTelemetrySdk
import Sessions
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// End-to-end coverage of `GrafanaOtel.initialize` against real upstream providers.
///
/// `initialize` registers process-wide global providers and swizzles `URLSession`, and neither can
/// be undone, so the whole installation is exercised in ONE test method. Splitting it would make
/// the assertions depend on XCTest's method ordering.
final class GrafanaOtelInstallationTests: XCTestCase {
  /// Upstream persists session state to `UserDefaults`, so a previous run on the same host would
  /// otherwise decide what this test observes.
  private static let sessionDefaultsKeys = [
    "otel-session-id",
    "otel-session-previous-id",
    "otel-session-expire-time",
    "otel-session-start-time",
    "otel-session-timeout",
    "otel-session-max-lifetime",
  ]

  private func clearPersistedSession() {
    for key in Self.sessionDefaultsKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  override func setUp() {
    super.setUp()
    clearPersistedSession()
  }

  override func tearDown() {
    clearPersistedSession()
    super.tearDown()
  }

  func testInitializeWiresUpstreamProvidersSessionsAndResource() throws {
    let spans = SpanCollector()
    let logs = LogRecordCollector()
    let diagnostics = DiagnosticsCollector()
    // A distinctive timeout so the registered manager is identifiable, rather than inferring it
    // from a side effect a lazily created default manager would also produce.
    let inactivityTimeout: TimeInterval = 123
    let maxLifetime: TimeInterval = 4567

    let configuration = try GrafanaOtelConfiguration(
      // Unreachable on purpose: this asserts the assembly, not the network.
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: ["backend.test"],
      serviceVersion: "9.9.9",
      deploymentEnvironment: "test",
      resourceAttributes: [
        "service.build": "42",
        // Service identity travels through resourceAttributes now.
        "service.name": "grafana-otel-installation-test",
        "service.namespace": "quickpizza",
      ],
      sessionInactivityTimeout: inactivityTimeout,
      sessionMaxLifetime: maxLifetime
    )
    let runtime = try GrafanaOtel.initialize(
      configuration: configuration,
      experimental: GrafanaOtelExperimentalOptions(
        additionalSpanProcessors: [SimpleSpanProcessor(spanExporter: spans)],
        additionalLogRecordProcessors: [logs],
        // On, so that the flag is asserted to *do* something. Turning the branch that reads it into
        // a no-op otherwise leaves the suite green while the demo app's only redirect protection
        // disappears.
        automaticRedirectProtection: true,
        diagnosticsHandler: { diagnostics.append($0) }
      )
    )

    // The flag has to reach upstream's delegate classes during `initialize`.
    //
    // Asserted through the recorded outcome rather than by inspecting the classes: another test
    // class sorts ahead of this one and patches them, so their state proves nothing about whether
    // *this* startup installed anything. The outcome is only set by a call to `install`.
    let outcome = try XCTUnwrap(
      GrafanaOtelAutomaticRedirectProtection.lastOutcome,
      "initialize did not install automatic redirect protection despite the flag being on"
    )
    XCTAssertTrue(outcome.notFound.isEmpty, "upstream renamed \(outcome.notFound)")
    XCTAssertEqual(
      Set(outcome.patched).union(outcome.alreadyImplemented),
      Set(GrafanaOtelAutomaticRedirectProtection.upstreamDelegateClassNames)
    )
    XCTAssertEqual(
      outcome.firstPartyHosts,
      ["backend.test"],
      "the automatic path must get the configured hosts, or it strips context from all redirects "
        + "or from none"
    )

    // The providers this package built are the ones registered globally.
    XCTAssertTrue(OpenTelemetry.instance.tracerProvider is TracerProviderSdk)
    XCTAssertIdentical(GrafanaOtel.runtime, runtime)

    // The diagnostics handler must be installed, because it is the only signal an app gets that
    // OTLP export is failing.
    OpenTelemetry.instance.feedbackHandler?("probe diagnostic")
    XCTAssertTrue(diagnostics.messages().contains("probe diagnostic"))

    // XCTest runs this on the main thread, so no thread warning should have been emitted.
    XCTAssertFalse(
      diagnostics.messages().contains { $0.contains("off the main thread") },
      "initialize was called on the main thread, so it must not warn"
    )

    // A span created through the standard API carries the Grafana resource and a session id.
    let tracer = runtime.openTelemetry.tracerProvider.get(
      instrumentationName: "installation-test",
      instrumentationVersion: "1.0.0"
    )
    tracer.spanBuilder(spanName: "probe").startSpan().end()

    // `SimpleSpanProcessor` exports on its own serial queue with `async`, so drain it before
    // asserting. `forceFlush` issues a `sync` on that same queue, which orders behind the export.
    runtime.forceFlush(timeout: 1)

    let exported = try XCTUnwrap(spans.collected().first, "the span reached the exporter")
    XCTAssertEqual(exported.name, "probe")
    XCTAssertEqual(
      exported.resource.attributes["service.name"],
      .string("grafana-otel-installation-test")
    )
    XCTAssertEqual(exported.resource.attributes["service.namespace"], .string("quickpizza"))
    XCTAssertEqual(exported.resource.attributes["service.version"], .string("9.9.9"))
    XCTAssertEqual(exported.resource.attributes["deployment.environment.name"], .string("test"))
    XCTAssertEqual(exported.resource.attributes["service.build"], .string("42"))
    // The upstream default resource is merged in underneath the Grafana attributes.
    XCTAssertEqual(exported.resource.attributes["telemetry.sdk.language"], .string("swift"))
    XCTAssertNotNil(
      exported.attributes["session.id"],
      "SessionSpanProcessor must stamp every span"
    )

    // Step 2 of the documented install order: the session processors must have captured the
    // configured manager. A lazily created default would carry upstream's 30-minute timeout.
    let session = try XCTUnwrap(
      SessionManagerProvider.getInstance().peekSession(),
      "a session must exist once a span has started"
    )
    XCTAssertEqual(
      session.sessionTimeout,
      inactivityTimeout,
      "the processors captured a default SessionManager instead of the configured one"
    )
    XCTAssertEqual(session.maxLifetime, maxLifetime)

    // A log record reaches an additional processor with session enrichment already applied, which
    // is the ordering this package promises: one session processor in front of everything.
    runtime.openTelemetry.loggerProvider
      .loggerBuilder(instrumentationScopeName: "installation-test")
      .build()
      .logRecordBuilder()
      .setBody(.string("probe log"))
      .emit()

    // The collector also receives the upstream `session.start` / `session.end` events, so select
    // the probe record by body rather than assuming it arrived first.
    let collected = logs.collected()
    let record = try XCTUnwrap(
      collected.first { $0.body == .string("probe log") },
      "the log record reached the processor"
    )
    XCTAssertNotNil(
      record.attributes["session.id"],
      "SessionLogRecordProcessor must run before downstream processors"
    )
    // Session lifecycle events are emitted as log records with an event name and no body.
    XCTAssertTrue(
      collected.contains { $0.attributes["session.id"] != nil && $0.body == nil },
      "SessionEventInstrumentation must emit a session lifecycle record"
    )
    XCTAssertEqual(
      record.resource.attributes["service.name"],
      .string("grafana-otel-installation-test")
    )

    // The span and the log record belong to the same session.
    XCTAssertEqual(exported.attributes["session.id"], record.attributes["session.id"])

    // The redirect guard is bound to the configured first-party hosts, so an app that installs it
    // gets the same policy as injection without restating the host list.
    var redirect = URLRequest(url: URL(string: "https://ads.thirdparty.test/pixel")!)
    redirect.setValue("00-\(String(repeating: "a", count: 32))-\(String(repeating: "b", count: 16))-01",
                      forHTTPHeaderField: "traceparent")
    XCTAssertNil(
      runtime.redirectGuard.sanitizedRedirect(redirect).value(forHTTPHeaderField: "traceparent")
    )
    var firstPartyRedirect = URLRequest(url: URL(string: "https://backend.test/moved")!)
    firstPartyRedirect.setValue("00-\(String(repeating: "a", count: 32))-\(String(repeating: "b", count: 16))-01",
                                forHTTPHeaderField: "traceparent")
    XCTAssertNotNil(
      runtime.redirectGuard.sanitizedRedirect(firstPartyRedirect)
        .value(forHTTPHeaderField: "traceparent"),
      "backend.test is the configured first-party host, so its redirects stay connected"
    )

    // A second call must not register a second set of providers, exporters and swizzles.
    let repeated = try GrafanaOtel.initialize(
      configuration: try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
        firstPartyHosts: []
      )
    )
    XCTAssertIdentical(repeated, runtime)

    // The runtime must flush through the processors BEHIND the session decorator. Flushing through
    // the decorator itself silently exports nothing, which is the defect this split exists for.
    let flushesBefore = logs.forceFlushCount()
    runtime.forceFlush(timeout: 7)
    XCTAssertEqual(logs.forceFlushCount(), flushesBefore + 1)
    XCTAssertEqual(logs.lastForceFlushTimeout(), 7)

    // Shutdown is process-terminal for telemetry, so it must come last.
    runtime.shutdown(timeout: 3)
    XCTAssertEqual(logs.shutdownCount(), 1)
    XCTAssertEqual(logs.lastShutdownTimeout(), 3)
  }
}

// MARK: - Collectors

private final class SpanCollector: SpanExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var spans: [SpanData] = []

  func collected() -> [SpanData] { lock.withLock { spans } }

  func export(spans newSpans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    lock.withLock { spans.append(contentsOf: newSpans) }
    return .success
  }

  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func shutdown(explicitTimeout: TimeInterval?) {}
}

private final class LogRecordCollector: LogRecordProcessor, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [ReadableLogRecord] = []
  private var flushes: [TimeInterval?] = []
  private var shutdowns: [TimeInterval?] = []

  func collected() -> [ReadableLogRecord] { lock.withLock { records } }
  func forceFlushCount() -> Int { lock.withLock { flushes.count } }
  func lastForceFlushTimeout() -> TimeInterval? { lock.withLock { flushes.last ?? nil } }
  func shutdownCount() -> Int { lock.withLock { shutdowns.count } }
  func lastShutdownTimeout() -> TimeInterval? { lock.withLock { shutdowns.last ?? nil } }

  func onEmit(logRecord: ReadableLogRecord) {
    lock.withLock { records.append(logRecord) }
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock { flushes.append(explicitTimeout) }
    return .success
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock { shutdowns.append(explicitTimeout) }
    return .success
  }
}

private final class DiagnosticsCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [String] = []

  func append(_ message: String) { lock.withLock { received.append(message) } }
  func messages() -> [String] { lock.withLock { received } }
}
