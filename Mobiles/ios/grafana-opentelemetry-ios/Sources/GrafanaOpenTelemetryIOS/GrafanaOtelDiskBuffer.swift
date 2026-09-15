import Foundation
import OpenTelemetrySdk
import PersistenceExporter

/// The on-disk export queues, and the gate that stops them.
///
/// Two upstream facts make this type necessary, and both are invisible from the provider APIs.
///
/// **Flushing a provider does not drain the queue.** `BatchSpanProcessor.forceFlush` and
/// `BatchLogRecordProcessor.forceFlush` hand their in-memory batch to the exporter's `export`,
/// which under persistence only *writes it to disk*. Neither calls the exporter's own
/// `flush`/`forceFlush`, and that is the only method that reads the queue back and sends it. So
/// without this type a completed `forceFlush` means "written to disk", and the batch leaves the
/// device whenever `DataExportWorker` next wakes up — up to `maxExportDelay`, 20 seconds, later.
///
/// **Shutting down does not stop the worker.** `DataExportWorker` has `cancelSynchronously()`, but
/// `DataExportWorkerProtocol` exposes only `flush()`, so `PersistenceExporterDecorator` cannot
/// cancel it and its repeating `DispatchWorkItem` outlives `shutdown()`, still retrying whatever
/// failed to send. `exportCondition` is the one lever upstream leaves reachable: the worker
/// evaluates it on every tick and skips the read entirely when it returns `false`.
///
/// Not `final`: the runtime's calls into this type are the fix for both of those problems, and a
/// test subclass is how that wiring is asserted. Deleting either call is otherwise invisible.
class GrafanaOtelDiskBuffer {
  /// Read by `DataExportWorker` on every tick, from its own queue.
  ///
  /// A separate object from the buffer so that the closure the exporters retain does not retain
  /// the exporters back through it.
  final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    var allowsExport: Bool { lock.withLock { isOpen } }
    func close() { lock.withLock { isOpen = false } }
  }

  private let gate = ExportGate()
  private let lock = NSLock()
  private var spanQueue: PersistenceSpanExporterDecorator?
  private var logQueue: PersistenceLogExporterDecorator?

  /// Pass to every `PersistenceExporterDecorator` this buffer owns.
  var exportCondition: @Sendable () -> Bool {
    let gate = gate
    return { gate.allowsExport }
  }

  func adopt(spanQueue: PersistenceSpanExporterDecorator) {
    lock.withLock { self.spanQueue = spanQueue }
  }

  func adopt(logQueue: PersistenceLogExporterDecorator) {
    lock.withLock { self.logQueue = logQueue }
  }

  /// Sends everything on disk, including a batch written moments ago.
  ///
  /// Call *after* flushing the providers, so their in-memory records are on disk first. The flush
  /// path reads through `FileReader.onRemainingBatches`, which — unlike the worker's periodic
  /// `readNextBatch` — applies no `minFileAgeForRead`, so a just-written file is eligible.
  /// `PersistenceExporterDecorator.flush` also waits on the writer's queue before reading, so the
  /// asynchronous write from the provider flush cannot still be in flight.
  ///
  /// Unaffected by ``stopExporting()``: the worker's flush path never consults
  /// `exportCondition`, which is what lets a shutdown still deliver its final batch.
  func flush(timeout: TimeInterval?) {
    let (spanQueue, logQueue) = lock.withLock { (self.spanQueue, self.logQueue) }
    _ = spanQueue?.flush(explicitTimeout: timeout)
    _ = logQueue?.forceFlush(explicitTimeout: timeout)
  }

  /// Stops the periodic workers from exporting anything further.
  ///
  /// Their `DispatchWorkItem` keeps being rescheduled — that cannot be cancelled from outside
  /// upstream — but from here on each tick finds the gate closed, reads nothing and sends nothing,
  /// settling at `maxExportDelay`.
  func stopExporting() {
    gate.close()
  }
}
