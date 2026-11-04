import Foundation
@testable import GrafanaOpenTelemetryIOS
import OpenTelemetryApi
import OpenTelemetrySdk
import Sessions
import XCTest

private let sessionIDKey = SemanticConventions.Session.id.rawValue

final class GrafanaOtelSessionSamplingTests: XCTestCase {
  func testDefaultSamplesEverySessionAndExperimentalSamplerReachesThePlan() throws {
    let config = try configuration()
    let defaults = GrafanaOtelSetup.makePlan(
      configuration: config, baseResource: Resource(), environmentHeaders: nil
    )
    XCTAssertEqual(defaults.sessionConfig.sessionTimeout, 900)
    XCTAssertEqual(defaults.sessionConfig.maxLifetime, 14400)
    XCTAssertFalse(defaults.sessionConfig.restorePersistedSession)
    XCTAssertEqual(defaults.sessionConfig.sampler.samplingDecision(for: "default"), .sampled)
    let options = GrafanaOtelExperimentalOptions(sessionSampler: AlwaysOffSessionSampler())
    let configured = GrafanaOtelSetup.makePlan(
      configuration: config, baseResource: Resource(), environmentHeaders: nil,
      sessionSampler: options.sessionSampler
    )
    XCTAssertEqual(configured.sessionConfig.sampler.samplingDecision(for: "configured"), .notSampled)
  }

  func testOneDecisionFiltersBothPipelinesIncludingAdditionalProcessors() throws {
    for sampled in [true, false] {
      let fixture = try Fixture(sampled: sampled)
      defer { fixture.close() }
      fixture.emit("first")
      fixture.emit("second")
      fixture.flush()
      XCTAssertEqual(fixture.sampler.calls, 1)
      XCTAssertEqual(fixture.spans.records.count, sampled ? 2 : 0)
      XCTAssertEqual(fixture.logs.records.count, sampled ? 2 : 0)
      for record in fixture.spans.records {
        XCTAssertEqual(record.attributes[sessionIDKey], .string(fixture.manager.getSession().id))
      }
      for record in fixture.logs.records {
        XCTAssertEqual(record.attributes[sessionIDKey], .string(fixture.manager.getSession().id))
      }
    }
  }

  func testSpanStartedBeforeResetKeepsItsOriginalSession() throws {
    let fixture = try Fixture(sampled: true)
    defer { fixture.close() }
    let original = fixture.manager.getSession()
    let held = fixture.tracer.spanBuilder(spanName: "held").startSpan()
    fixture.sampler.sampled = false
    fixture.manager.resetSession()
    let replacement = fixture.manager.getSession()
    XCTAssertNotEqual(original.id, replacement.id)
    XCTAssertEqual(replacement.previousId, original.id)
    held.end()
    let dropped = fixture.tracer.spanBuilder(spanName: "new").setParent(held).startSpan()
    XCTAssertFalse(dropped.isRecording)
    XCTAssertFalse(dropped.context.traceFlags.sampled)
    XCTAssertNotEqual(dropped.context.spanId, held.context.spanId)
    dropped.end()
    fixture.flush()
    XCTAssertEqual(fixture.spans.records.map(\.name), ["held"])
    XCTAssertEqual(fixture.spans.records.first?.attributes[sessionIDKey], .string(original.id))
    XCTAssertEqual(fixture.sampler.calls, 2)
  }

  func testDelayedLogsUseSavedDecisionsNotTheReplacementSession() throws {
    for originalSampled in [true, false] {
      let fixture = try Fixture(sampled: originalSampled)
      defer { fixture.close() }
      let original = fixture.manager.getSession()
      fixture.sampler.sampled = !originalSampled
      fixture.manager.resetSession()
      fixture.logger.logRecordBuilder().setBody(.string("delayed"))
        .setAttributes(original.samplingAttributes).emit()
      fixture.logger.logRecordBuilder().setBody(.string("legacy"))
        .setAttributes([sessionIDKey: .string("historical-without-decision")]).emit()
      fixture.flush()
      XCTAssertEqual(fixture.logs.records.count, originalSampled ? 2 : 1)
      let delayed = fixture.logs.records.filter { $0.body == .string("delayed") }
      XCTAssertEqual(delayed.count, originalSampled ? 1 : 0)
      if originalSampled {
        XCTAssertEqual(delayed.first?.attributes[sessionIDKey], .string(original.id))
      }
      XCTAssertEqual(fixture.logs.records.last?.attributes[sessionIDKey],
                     .string("historical-without-decision"))
      XCTAssertEqual(fixture.sampler.calls, 2)
    }
  }

  func testFilteringHappensBeforeDiskAndResetDoesNotRewriteQueuedRecords() throws {
    let fixture = try Fixture(sampled: true, buffering: true)
    defer { fixture.close() }
    let original = fixture.manager.getSession()
    fixture.emit("accepted")
    fixture.sampler.sampled = false
    fixture.manager.resetSession()
    fixture.emit("rejected")
    fixture.flush()
    // Provider flush only enqueues writes. Drain the writer before inspecting its files;
    // the unavailable receiver leaves the accepted batches on disk.
    fixture.buffer.flush(timeout: 0.1)
    let spans: [SpanData] = try fixture.readBuffered("traces")
    let logs: [ReadableLogRecord] = try fixture.readBuffered("logs")
    XCTAssertEqual(spans.map(\.name), ["accepted"])
    XCTAssertEqual(logs.map(\.body), [.string("accepted")])
    XCTAssertEqual(spans.first?.attributes[sessionIDKey], .string(original.id))
    XCTAssertEqual(logs.first?.attributes[sessionIDKey], .string(original.id))
  }

  func testRestoredDecisionSurvivesOppositeConfigurationAndColdStartLinks() throws {
    let name = "net.local.varanha.session99.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let persistence = UserDefaultsSessionPersistence(userDefaults: defaults)
    var first: SessionManager? = try SessionManager(
      configuration: SessionConfig(sampler: AlwaysOffSessionSampler()), persistence: persistence
    )
    let saved = try XCTUnwrap(first).getSession()
    first = nil
    var restored: SessionManager? = try SessionManager(
      configuration: SessionConfig(sampler: AlwaysOnSessionSampler()), persistence: persistence
    )
    XCTAssertEqual(restored?.getSession().id, saved.id)
    XCTAssertEqual(restored?.getSession().samplingDecision, .notSampled)
    restored = nil
    let restarted = try SessionManager(
      configuration: SessionConfig(restorePersistedSession: false, sampler: AlwaysOnSessionSampler()),
      persistence: persistence
    )
    XCTAssertNotEqual(restarted.getSession().id, saved.id)
    XCTAssertEqual(restarted.getSession().previousId, saved.id)
    XCTAssertEqual(restarted.getSession().samplingDecision, .sampled)
  }

  func testLogLifecycleOperationsStillReachAdditionalProcessors() throws {
    let fixture = try Fixture(sampled: false)
    fixture.emit("discarded")
    XCTAssertEqual(fixture.logProcessor.forceFlush(explicitTimeout: 1), .success)
    XCTAssertEqual(fixture.logs.flushes, 1)
    fixture.close()
    XCTAssertEqual(fixture.logs.shutdowns, 1)
    XCTAssertTrue(fixture.logs.records.isEmpty)
  }

  func testMetricMeasurementsUseCapturedSessionBeforeAggregation() throws {
    let fixture = try Fixture(sampled: true)
    defer { fixture.close() }
    let exporter = CollectedMetrics()
    let provider = MeterProviderSdk.builder().registerMetricReader(
      reader: PeriodicMetricReaderBuilder(exporter: exporter).setInterval(timeInterval: 3600).build()
    ).registerView(
      selector: InstrumentSelector.builder().setInstrument(name: "operations").build(),
      view: View.builder().withAggregation(aggregation: Aggregations.sum()).build()
    ).build()
    defer { _ = provider.shutdown() }
    let counter = provider.get(name: "session99").counterBuilder(name: "operations").build()
    let accepted = fixture.manager.getSession()
    fixture.sampler.sampled = false
    let rejected = fixture.manager.resetSession()
    XCTAssertTrue(accepted.recordIfSampled { counter.add(value: 2, attributes: $0) })
    XCTAssertFalse(rejected.recordIfSampled { counter.add(value: 100, attributes: $0) })
    fixture.sampler.sampled = true
    let replacement = fixture.manager.resetSession()
    XCTAssertTrue(replacement.recordIfSampled { counter.add(value: 3, attributes: $0) })
    XCTAssertEqual(provider.forceFlush(), .success)
    let points = exporter.records.flatMap(\.data.points).compactMap { $0 as? LongPointData }
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points.first { $0.attributes[sessionIDKey] == .string(accepted.id) }?.value, 2)
    XCTAssertEqual(points.first { $0.attributes[sessionIDKey] == .string(replacement.id) }?.value, 3)
    XCTAssertFalse(points.contains { $0.attributes[sessionIDKey] == .string(rejected.id) })
  }

  func testSeparateNamespacesKeepIndependentChainsAndRejectSharedWriters() throws {
    let name = "net.local.varanha.session99.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let appStorage = UserDefaultsSessionPersistence(userDefaults: defaults, namespace: "app")
    let extensionStorage = UserDefaultsSessionPersistence(userDefaults: defaults, namespace: "extension")
    let config = SessionConfig(sampler: AlwaysOffSessionSampler())
    var app: SessionManager? = try SessionManager(configuration: config, persistence: appStorage)
    var other: SessionManager? = try SessionManager(configuration: config, persistence: extensionStorage)
    let appFirst = try XCTUnwrap(app).getSession()
    let extensionFirst = try XCTUnwrap(other).getSession()
    XCTAssertNotEqual(appFirst.id, extensionFirst.id)
    let appReset = try XCTUnwrap(app).resetSession()
    let extensionReset = try XCTUnwrap(other).resetSession()
    XCTAssertEqual(appReset.previousId, appFirst.id)
    XCTAssertEqual(extensionReset.previousId, extensionFirst.id)
    app = nil
    other = nil
    let restoredApp = try SessionManager(configuration: config, persistence: appStorage)
    let restoredExtension = try SessionManager(configuration: config, persistence: extensionStorage)
    XCTAssertEqual(restoredApp.getSession().id, appReset.id)
    XCTAssertEqual(restoredExtension.getSession().id, extensionReset.id)
    let saved = appStorage.read()
    XCTAssertThrowsError(try SessionManager(configuration: config, persistence: appStorage, persistenceAccess: .shared)) {
      XCTAssertEqual($0 as? SessionPersistenceConfigurationError, .concurrentWritersUnsupported)
    }
    XCTAssertEqual(appStorage.read(), saved)
  }

  func testConcurrentResetsDoNotReattributeHistoricalLogs() throws {
    let fixture = try Fixture(sampled: true)
    defer { fixture.close() }
    let accepted = fixture.manager.getSession()
    fixture.sampler.sampled = false
    let rejected = fixture.manager.resetSession()
    DispatchQueue.concurrentPerform(iterations: 200) { index in
      if index.isMultiple(of: 3) {
        fixture.manager.resetSession()
      }
      let session = index.isMultiple(of: 2) ? accepted : rejected
      fixture.logger.logRecordBuilder().setBody(.string("historical-\(index)"))
        .setAttributes(session.samplingAttributes).emit()
    }
    fixture.flush()
    XCTAssertEqual(fixture.logs.records.count, 100)
    XCTAssertTrue(fixture.logs.records.allSatisfy { $0.attributes[sessionIDKey] == .string(accepted.id) })
  }
}

private func configuration() throws -> GrafanaOtelConfiguration {
  try GrafanaOtelConfiguration(
    otlpEndpoint: URL(string: "http://127.0.0.1:1")!, firstPartyHosts: [],
    diskBuffering: .disabled,
    instrumentation: .init(urlSession: false, sessionEvents: false, metricKitDiagnostics: false)
  )
}

private final class Fixture: @unchecked Sendable {
  let sampler: ToggleSampler
  let manager: SessionManager
  let spans = CollectedSpans()
  let logs = CollectedLogs()
  let provider: TracerProviderSdk
  let logProcessor: LogRecordProcessor
  let loggerProvider: LoggerProviderSdk
  let buffer = GrafanaOtelDiskBuffer()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let suite = "net.local.varanha.session99.\(UUID().uuidString)"
  var tracer: Tracer {
    provider.get(instrumentationName: "session99")
  }

  var logger: Logger {
    loggerProvider.get(instrumentationScopeName: "session99")
  }

  init(sampled: Bool, buffering: Bool = false) throws {
    sampler = ToggleSampler(sampled)
    let plan = try GrafanaOtelSetup.makePlan(
      configuration: configuration(), baseResource: Resource(), environmentHeaders: nil,
      sessionSampler: sampler
    )
    manager = try SessionManager(
      configuration: plan.sessionConfig,
      persistence: UserDefaultsSessionPersistence(userDefaults: UserDefaults(suiteName: suite)!)
    )
    for signal in ["traces", "logs"] {
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(signal), withIntermediateDirectories: true
      )
    }
    // Retain bytes for inspection; no background delivery can race the assertions.
    buffer.stopExporting()
    let options = GrafanaOtelExperimentalOptions(
      additionalSpanProcessors: [SimpleSpanProcessor(spanExporter: spans)],
      additionalLogRecordProcessors: [logs], sessionSampler: sampler
    )
    provider = try GrafanaOtel.makeTracerProvider(
      plan: plan, headers: [], tracesStorageURL: buffering ? directory.appendingPathComponent("traces") : nil,
      diskBuffer: buffer, experimental: options, sessionManager: manager
    )
    logProcessor = try GrafanaOtel.makeLogPipeline(
      plan: plan, headers: [], logsStorageURL: buffering ? directory.appendingPathComponent("logs") : nil,
      diskBuffer: buffer, experimental: options, sessionManager: manager
    )
    loggerProvider = LoggerProviderBuilder().with(processors: [logProcessor]).build()
  }

  func emit(_ name: String) {
    tracer.spanBuilder(spanName: name).startSpan().end()
    logger.logRecordBuilder().setBody(.string(name)).emit()
  }

  func flush() {
    provider.forceFlush(timeout: 0.1)
    _ = logProcessor.forceFlush(explicitTimeout: 0.1)
  }

  func close() {
    buffer.stopExporting()
    provider.shutdown()
    _ = logProcessor.shutdown(explicitTimeout: 0.1)
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  func readBuffered<T: Decodable>(_ signal: String) throws -> [T] {
    try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent(signal), includingPropertiesForKeys: nil
    ).flatMap { file in
      let bytes = try Data(contentsOf: file)
      // Upstream's append-only format is a stream of JSON batches, each followed by a comma.
      let batches = try JSONDecoder().decode([[T]?].self, from: Data("[".utf8) + bytes + Data("null]".utf8))
      return batches.compactMap(\.self).flatMap(\.self)
    }
  }
}

private final class ToggleSampler: SessionSampler, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool
  private var count = 0
  init(_ sampled: Bool) {
    value = sampled
  }

  var sampled: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }

  var calls: Int {
    lock.withLock { count }
  }

  func samplingDecision(for _: String) -> SessionSamplingDecision {
    lock.withLock {
      count += 1
      return value ? .sampled : .notSampled
    }
  }
}

private final class CollectedSpans: SpanExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [SpanData] = []
  var records: [SpanData] {
    lock.withLock { stored }
  }

  func export(spans: [SpanData], explicitTimeout _: TimeInterval?) -> SpanExporterResultCode {
    lock.withLock { stored.append(contentsOf: spans) }
    return .success
  }

  func flush(explicitTimeout _: TimeInterval?) -> SpanExporterResultCode {
    .success
  }

  func shutdown(explicitTimeout _: TimeInterval?) {}
}

private final class CollectedLogs: LogRecordProcessor, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ReadableLogRecord] = []
  private var flushCount = 0
  private var shutdownCount = 0
  var records: [ReadableLogRecord] {
    lock.withLock { stored }
  }

  var flushes: Int {
    lock.withLock { flushCount }
  }

  var shutdowns: Int {
    lock.withLock { shutdownCount }
  }

  func onEmit(logRecord: ReadableLogRecord) {
    lock.withLock { stored.append(logRecord) }
  }

  func forceFlush(explicitTimeout _: TimeInterval?) -> ExportResult {
    lock.withLock { flushCount += 1 }
    return .success
  }

  func shutdown(explicitTimeout _: TimeInterval?) -> ExportResult {
    lock.withLock { shutdownCount += 1 }
    return .success
  }
}

private final class CollectedMetrics: MetricExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [MetricData] = []
  var records: [MetricData] {
    lock.withLock { stored }
  }

  func export(metrics: [MetricData]) -> ExportResult {
    lock.withLock { stored.append(contentsOf: metrics) }
    return .success
  }

  func flush() -> ExportResult {
    .success
  }

  func shutdown() -> ExportResult {
    .success
  }

  func getAggregationTemporality(for _: InstrumentType) -> AggregationTemporality {
    .cumulative
  }
}
