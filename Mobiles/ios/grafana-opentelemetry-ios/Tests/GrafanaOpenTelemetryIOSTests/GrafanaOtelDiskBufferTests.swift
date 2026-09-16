import OpenTelemetryApi
import OpenTelemetrySdk
import PersistenceExporter
import XCTest
@testable import GrafanaOpenTelemetryIOS

/// The two things disk buffering does not do on its own: deliver on flush, and stop on shutdown.
///
/// Both are invisible from the provider APIs, which is why they are asserted against real upstream
/// persistence exporters over a temporary directory rather than against a stub.
final class GrafanaOtelDiskBufferTests: XCTestCase {
  private var storageURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    storageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("grafana-otel-disk-buffer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: storageURL)
    storageURL = nil
    try super.tearDownWithError()
  }

  /// Flushing the provider is not enough, and the buffer's own flush is what delivers.
  ///
  /// `BatchSpanProcessor.forceFlush` reaches `export`, which under persistence writes to disk and
  /// returns. Nothing on that path calls the exporter's `flush`, so without the second step the
  /// span sits on disk until the periodic worker wakes up.
  func testProviderFlushOnlyReachesDiskAndTheBufferFlushDelivers() throws {
    let network = RecordingSpanExporter()
    let buffer = GrafanaOtelDiskBuffer()
    let queue = PersistenceSpanExporterDecorator(
      spanExporter: network,
      storageURL: storageURL,
      exportCondition: buffer.exportCondition
    )
    buffer.adopt(spanQueue: queue)

    let provider = TracerProviderBuilder()
      .add(spanProcessors: [BatchSpanProcessor(spanExporter: queue)])
      .build()
    provider.get(instrumentationName: "disk-buffer-test", instrumentationVersion: "1.0.0")
      .spanBuilder(spanName: "queued")
      .startSpan()
      .end()

    provider.forceFlush(timeout: 5)
    XCTAssertTrue(
      network.exported().isEmpty,
      "the batch processor's flush only writes to disk; reaching the network here would mean "
        + "upstream started calling the exporter's own flush and this indirection is obsolete"
    )

    buffer.flush(timeout: 5)
    XCTAssertEqual(network.exported().map(\.name), ["queued"])
  }

  /// The same, for the log pipeline.
  func testLogProviderFlushOnlyReachesDiskAndTheBufferFlushDelivers() throws {
    let network = RecordingLogRecordExporter()
    let buffer = GrafanaOtelDiskBuffer()
    let queue = PersistenceLogExporterDecorator(
      logRecordExporter: network,
      storageURL: storageURL,
      exportCondition: buffer.exportCondition
    )
    buffer.adopt(logQueue: queue)

    let processor = BatchLogRecordProcessor(logRecordExporter: queue)
    let provider = LoggerProviderBuilder().with(processors: [processor]).build()
    provider.loggerBuilder(instrumentationScopeName: "disk-buffer-test")
      .build()
      .logRecordBuilder()
      .setBody(.string("queued"))
      .emit()

    _ = processor.forceFlush(explicitTimeout: 5)
    XCTAssertTrue(network.exported().isEmpty, "the batch processor's flush only writes to disk")

    buffer.flush(timeout: 5)
    XCTAssertEqual(network.exported().map(\.body), [.string("queued")])
  }

  /// `stopExporting` closes the condition the periodic worker reads on every tick.
  ///
  /// The worker's `DispatchWorkItem` cannot be cancelled from outside upstream —
  /// `DataExportWorkerProtocol` exposes only `flush()` — so this condition is what stops a failed
  /// batch being retried for the rest of the process.
  func testStopExportingClosesTheWorkersExportCondition() {
    let buffer = GrafanaOtelDiskBuffer()
    let condition = buffer.exportCondition

    XCTAssertTrue(condition(), "buffering must export while the runtime is live")
    buffer.stopExporting()
    XCTAssertFalse(condition())
  }

  /// Shutdown still has to deliver its final batch, so the flush path must ignore the gate.
  ///
  /// It does, because `DataExportWorker.flush` never consults `exportCondition` — only its
  /// scheduled work does. A change to that upstream would silently turn shutdown into data loss.
  func testFlushStillDeliversAfterExportIsStopped() throws {
    let network = RecordingSpanExporter()
    let buffer = GrafanaOtelDiskBuffer()
    let queue = PersistenceSpanExporterDecorator(
      spanExporter: network,
      storageURL: storageURL,
      exportCondition: buffer.exportCondition
    )
    buffer.adopt(spanQueue: queue)

    let provider = TracerProviderBuilder()
      .add(spanProcessors: [BatchSpanProcessor(spanExporter: queue)])
      .build()
    provider.get(instrumentationName: "disk-buffer-test", instrumentationVersion: "1.0.0")
      .spanBuilder(spanName: "last")
      .startSpan()
      .end()
    provider.forceFlush(timeout: 5)

    buffer.stopExporting()
    buffer.flush(timeout: 5)

    XCTAssertEqual(network.exported().map(\.name), ["last"])
  }
}

// MARK: - Recorders

private final class RecordingSpanExporter: SpanExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var spans: [SpanData] = []

  func exported() -> [SpanData] { lock.withLock { spans } }

  func export(spans newSpans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    lock.withLock { spans.append(contentsOf: newSpans) }
    return .success
  }

  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func shutdown(explicitTimeout: TimeInterval?) {}
}

private final class RecordingLogRecordExporter: LogRecordExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [ReadableLogRecord] = []

  func exported() -> [ReadableLogRecord] { lock.withLock { records } }

  func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock { records.append(contentsOf: logRecords) }
    return .success
  }

  func shutdown(explicitTimeout: TimeInterval?) {}
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
}
