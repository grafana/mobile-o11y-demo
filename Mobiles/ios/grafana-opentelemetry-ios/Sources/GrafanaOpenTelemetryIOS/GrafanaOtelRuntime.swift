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
  /// The on-disk queues, held because flushing and stopping them is not reachable through the
  /// providers. See ``GrafanaOtelDiskBuffer``.
  private let diskBuffer: GrafanaOtelDiskBuffer

  /// Install on a `URLSession`, or pass per task, to stop trace context following a redirect off
  /// the configured first-party hosts.
  ///
  /// Needed only where the package cannot supply that delegate itself — a session of your own that
  /// already has a delegate, or iOS 13 and 14. For delegate-less sessions, prefer
  /// ``GrafanaOtelExperimentalOptions/automaticRedirectProtection``, which needs nothing installed.
  ///
  /// See ``GrafanaOtelRedirectGuard`` for placement, and for why it also ends up owning span
  /// completion for the requests that use it.
  public let redirectGuard: GrafanaOtelRedirectGuard

  init(
    tracerProvider: TracerProviderSdk,
    loggerProvider: LoggerProviderSdk,
    flushableLogRecordProcessors: [LogRecordProcessor],
    retainedInstrumentations: [AnyObject],
    diskBuffer: GrafanaOtelDiskBuffer,
    redirectGuard: GrafanaOtelRedirectGuard
  ) {
    self.tracerProvider = tracerProvider
    self.loggerProvider = loggerProvider
    self.flushableLogRecordProcessors = flushableLogRecordProcessors
    self.retainedInstrumentations = retainedInstrumentations
    self.diskBuffer = diskBuffer
    self.redirectGuard = redirectGuard
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
  ///
  /// With disk buffering the disk queue is drained too, in a second step after the providers. The
  /// batch processors' own `forceFlush` only reaches `export`, which under persistence writes to
  /// disk and returns, so flushing the providers alone would leave the batch queued for the
  /// periodic worker. See ``GrafanaOtelDiskBuffer``.
  public func forceFlush(timeout: TimeInterval? = nil) {
    tracerProvider.forceFlush(timeout: timeout)
    for processor in flushableLogRecordProcessors {
      _ = processor.forceFlush(explicitTimeout: timeout)
    }
    // Second, and in this order: the steps above are what put the records on disk.
    diskBuffer.flush(timeout: timeout)
  }

  /// Stops trace and log export. The process must restart before initializing telemetry again.
  ///
  /// Blocks the calling thread on the same terms as ``forceFlush(timeout:)``. `timeout` reaches the
  /// log processors only: `TracerProviderSdk.shutdown()` takes no timeout upstream, so the trace
  /// side always uses its own 30-second export timeout.
  ///
  /// Whatever is already queued on disk is still delivered — shutting a provider down drains its
  /// queue through the persistence exporter — but nothing is exported after that, including a
  /// batch whose earlier send failed. The disk workers are gated off first, before the providers
  /// are asked to shut down, because upstream keeps rescheduling them and provides no way to
  /// cancel them from here; they stay parked and idle for the rest of the process.
  public func shutdown(timeout: TimeInterval? = nil) {
    diskBuffer.stopExporting()
    tracerProvider.shutdown()
    for processor in flushableLogRecordProcessors {
      _ = processor.shutdown(explicitTimeout: timeout)
    }
  }
}
