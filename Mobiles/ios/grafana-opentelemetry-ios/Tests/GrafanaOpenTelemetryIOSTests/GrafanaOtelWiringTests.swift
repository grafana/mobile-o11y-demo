import OpenTelemetryApi
import OpenTelemetrySdk
import PersistenceExporter
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// That the pieces are *connected*, not just that each piece works.
///
/// Added after a mutation pass: breaking `GrafanaOtelRuntime.forceFlush`, `shutdown`, or the
/// `exportCondition` handed to the persistence exporters left the whole suite green, because every
/// other test drives those units directly. Each defect below was reproduced by hand against a live
/// collector before this file existed, which is not a thing CI can do.
final class GrafanaOtelWiringTests: XCTestCase {
  /// Ordering is the substance of the fix, not an implementation detail.
  ///
  /// The providers are what put records *on disk* under persistence; draining first would flush an
  /// empty queue and leave the batch behind. So the disk flush has to come last.
  func testForceFlushDrainsTheDiskQueueAfterTheProviders() {
    let events = EventLog()
    let buffer = SpyDiskBuffer(events: events)
    let runtime = makeRuntime(buffer: buffer, events: events)

    runtime.forceFlush(timeout: 4)

    XCTAssertEqual(
      events.recorded(),
      ["trace.flush", "log.flush", "disk.flush"],
      "the disk queue must be drained, and only after the providers have written to it"
    )
    XCTAssertEqual(buffer.flushTimeouts(), [4], "the caller's timeout must reach the disk queue")
  }

  /// The gate has to close *before* the providers shut down.
  ///
  /// Shutting a provider down drains its queue through the persistence exporter, and that final
  /// drain must not be followed by a scheduled retry. Closing afterwards leaves a window in which
  /// the worker can pick the batch back up.
  func testShutdownClosesTheGateBeforeTheProvidersStop() {
    let events = EventLog()
    let buffer = SpyDiskBuffer(events: events)
    let runtime = makeRuntime(buffer: buffer, events: events)

    runtime.shutdown(timeout: 2)

    XCTAssertEqual(
      events.recorded(),
      ["disk.stopExporting", "trace.shutdown", "log.shutdown"],
      "export must be gated off before anything is shut down"
    )
  }

  /// Flushing must not gate export off as a side effect: the runtime stays usable after a flush.
  func testForceFlushDoesNotStopExporting() {
    let events = EventLog()
    let buffer = SpyDiskBuffer(events: events)

    makeRuntime(buffer: buffer, events: events).forceFlush(timeout: 1)

    XCTAssertFalse(events.recorded().contains("disk.stopExporting"))
  }

  /// Both persistence exporters must be built with the package's own export condition.
  ///
  /// Without it the decorators default to `{ true }` and `shutdown()` can no longer stop the
  /// periodic workers — the defect returns with no other visible change.
  func testBothPipelinesAdoptTheDiskQueueAndItsExportCondition() throws {
    let storage = FileManager.default.temporaryDirectory
      .appendingPathComponent("grafana-otel-wiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: storage.appendingPathComponent("traces"), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: storage.appendingPathComponent("logs"), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: storage) }

    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: ["backend.test"]
    )
    let plan = GrafanaOtelSetup.makePlan(
      configuration: configuration,
      baseResource: Resource(attributes: [:]),
      environmentHeaders: nil
    )
    let buffer = SpyDiskBuffer(events: EventLog())

    _ = try GrafanaOtel.makeTracerProvider(
      plan: plan,
      headers: [],
      tracesStorageURL: storage.appendingPathComponent("traces"),
      diskBuffer: buffer,
      experimental: GrafanaOtelExperimentalOptions()
    )
    XCTAssertTrue(buffer.adoptedSpanQueue, "the trace queue must be handed to the runtime")

    _ = try GrafanaOtel.makeLogPipeline(
      plan: plan,
      headers: [],
      logsStorageURL: storage.appendingPathComponent("logs"),
      diskBuffer: buffer,
      experimental: GrafanaOtelExperimentalOptions()
    )
    XCTAssertTrue(buffer.adoptedLogQueue, "the log queue must be handed to the runtime")

    XCTAssertEqual(
      buffer.exportConditionRequests, 2,
      "each persistence exporter must be constructed with the package's export condition"
    )
  }

  /// Without disk buffering there is no queue to adopt, and the lifecycle calls still have to work.
  func testNoQueueIsAdoptedWhenBufferingIsOff() throws {
    let configuration = try GrafanaOtelConfiguration(
      otlpEndpoint: URL(string: "https://collector.example/otlp/key")!,
      firstPartyHosts: [],
      diskBuffering: .disabled
    )
    let plan = GrafanaOtelSetup.makePlan(
      configuration: configuration,
      baseResource: Resource(attributes: [:]),
      environmentHeaders: nil
    )
    let buffer = SpyDiskBuffer(events: EventLog())

    _ = try GrafanaOtel.makeTracerProvider(
      plan: plan,
      headers: [],
      tracesStorageURL: nil,
      diskBuffer: buffer,
      experimental: GrafanaOtelExperimentalOptions()
    )

    XCTAssertFalse(buffer.adoptedSpanQueue)
    XCTAssertEqual(buffer.exportConditionRequests, 0)
  }

  // MARK: - Helpers

  /// A runtime over recording doubles, so the order of its lifecycle calls is observable.
  @discardableResult
  private func makeRuntime(buffer: SpyDiskBuffer, events: EventLog) -> GrafanaOtelRuntime {
    let tracerProvider = TracerProviderBuilder()
      .add(spanProcessors: [RecordingSpanProcessor(events: events)])
      .build()
    return GrafanaOtelRuntime(
      tracerProvider: tracerProvider,
      loggerProvider: LoggerProviderBuilder().build(),
      flushableLogRecordProcessors: [RecordingLogRecordProcessor(events: events)],
      retainedInstrumentations: [],
      diskBuffer: buffer,
      redirectGuard: GrafanaOtelRedirectGuard(firstPartyHosts: [], propagationFields: [])
    )
  }
}

// MARK: - Doubles

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  func append(_ event: String) { lock.withLock { events.append(event) } }
  func recorded() -> [String] { lock.withLock { events } }
}

private final class SpyDiskBuffer: GrafanaOtelDiskBuffer, @unchecked Sendable {
  private let events: EventLog
  private let lock = NSLock()
  private var timeouts: [TimeInterval?] = []
  private(set) var adoptedSpanQueue = false
  private(set) var adoptedLogQueue = false
  private(set) var exportConditionRequests = 0

  init(events: EventLog) {
    self.events = events
    super.init()
  }

  override var exportCondition: @Sendable () -> Bool {
    exportConditionRequests += 1
    return super.exportCondition
  }

  override func adopt(spanQueue: PersistenceSpanExporterDecorator) {
    adoptedSpanQueue = true
    super.adopt(spanQueue: spanQueue)
  }

  override func adopt(logQueue: PersistenceLogExporterDecorator) {
    adoptedLogQueue = true
    super.adopt(logQueue: logQueue)
  }

  override func flush(timeout: TimeInterval?) {
    lock.withLock { timeouts.append(timeout) }
    events.append("disk.flush")
    super.flush(timeout: timeout)
  }

  override func stopExporting() {
    events.append("disk.stopExporting")
    super.stopExporting()
  }

  func flushTimeouts() -> [TimeInterval?] { lock.withLock { timeouts } }
}

private final class RecordingSpanProcessor: SpanProcessor, @unchecked Sendable {
  let isStartRequired = false
  let isEndRequired = false
  private let events: EventLog

  init(events: EventLog) { self.events = events }

  func onStart(parentContext: SpanContext?, span: any ReadableSpan) {}
  func onEnd(span: any ReadableSpan) {}
  func forceFlush(timeout: TimeInterval?) { events.append("trace.flush") }
  func shutdown(explicitTimeout: TimeInterval?) { events.append("trace.shutdown") }
}

private final class RecordingLogRecordProcessor: LogRecordProcessor, @unchecked Sendable {
  private let events: EventLog

  init(events: EventLog) { self.events = events }

  func onEmit(logRecord: ReadableLogRecord) {}

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    events.append("log.flush")
    return .success
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    events.append("log.shutdown")
    return .success
  }
}
