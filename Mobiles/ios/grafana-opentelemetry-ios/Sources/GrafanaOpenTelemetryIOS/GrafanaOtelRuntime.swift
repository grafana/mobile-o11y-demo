import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// The handle returned by ``GrafanaOtel/initialize(configuration:)``.
///
/// The upstream Swift SDK has no single runtime object of its own, so this type bundles what a
/// caller needs after startup: the registered upstream providers, a lifecycle path for flushing
/// before termination, and strong references to instrumentations that would otherwise be released.
///
/// It deliberately exposes upstream types only. There is no Grafana tracer, span, logger or meter
/// API: application code keeps calling ``openTelemetry`` and the standard OpenTelemetry protocols.
///
/// Treat the runtime as process-lifetime. After ``shutdown(timeout:)`` the registered providers
/// stop exporting, and the process must restart before telemetry can be initialized again.
public final class GrafanaOtelRuntime: @unchecked Sendable {
  /// The tracer provider this package registered globally.
  public let tracerProvider: TracerProviderSdk
  /// The logger provider this package registered globally.
  public let loggerProvider: LoggerProviderSdk

  /// `LoggerProviderSdk` exposes no flush or shutdown, so the log processors are retained here to
  /// make log delivery controllable before termination.
  ///
  /// These are deliberately the processors *behind* the session decorator.
  /// `SessionLogRecordProcessor.forceFlush` and `.shutdown` return `.success` without forwarding to
  /// their `nextProcessor`, so flushing through the decorator would export nothing.
  private let flushableLogRecordProcessors: [LogRecordProcessor]
  /// `MXMetricManager` holds its subscribers weakly, so the MetricKit instrumentation would be
  /// deallocated immediately without this. The `URLSession` instrumentation is retained by its own
  /// swizzle blocks and is kept here only so the two have the same lifetime as the runtime.
  private let retainedInstrumentations: [AnyObject]

  init(
    tracerProvider: TracerProviderSdk,
    loggerProvider: LoggerProviderSdk,
    flushableLogRecordProcessors: [LogRecordProcessor],
    retainedInstrumentations: [AnyObject]
  ) {
    self.tracerProvider = tracerProvider
    self.loggerProvider = loggerProvider
    self.flushableLogRecordProcessors = flushableLogRecordProcessors
    self.retainedInstrumentations = retainedInstrumentations
  }

  /// The standard OpenTelemetry API entry point. Use this for all application instrumentation.
  public var openTelemetry: OpenTelemetryApi.OpenTelemetry { OpenTelemetryApi.OpenTelemetry.instance }

  /// Hands everything currently queued to the exporters.
  ///
  /// Call this before deliberately terminating the process; batch processors otherwise drop
  /// whatever has not reached its scheduled export.
  ///
  /// **This blocks the calling thread, so do not call it from the main thread.** The trace path
  /// waits for its export operations to finish, and each OTLP batch can take up to the exporter's
  /// 10-second transport timeout, so a stalled or blackholed collector blocks for
  /// `10s × pending batches`. `timeout` can only lower that per-batch ceiling, never raise it.
  ///
  /// What this guarantees differs by signal. Spans are handed to a synchronous OTLP request, so a
  /// completed call means the request finished — successfully or not. Log export is fire-and-forget
  /// at the pinned upstream version: `OtlpHttpLogExporter.export` returns `.success` without
  /// waiting, so for logs this only guarantees the records left the batch queue, not that they
  /// were delivered.
  public func forceFlush(timeout: TimeInterval? = nil) {
    tracerProvider.forceFlush(timeout: timeout)
    for processor in flushableLogRecordProcessors {
      _ = processor.forceFlush(explicitTimeout: timeout)
    }
  }

  /// Stops trace and log export. The process must restart before initializing telemetry again.
  ///
  /// Blocks the calling thread on the same terms as ``forceFlush(timeout:)``. `timeout` reaches the
  /// log processors only: `TracerProviderSdk.shutdown()` takes no timeout upstream, so the trace
  /// side always uses its own 30-second export timeout.
  public func shutdown(timeout: TimeInterval? = nil) {
    tracerProvider.shutdown()
    for processor in flushableLogRecordProcessors {
      _ = processor.shutdown(explicitTimeout: timeout)
    }
  }
}
