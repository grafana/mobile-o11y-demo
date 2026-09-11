import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import PersistenceExporter
import ResourceExtension
import Sessions
import URLSessionInstrumentation

#if canImport(MetricKit) && !os(tvOS) && !os(macOS)
  import MetricKit
  import MetricKitInstrumentation
#endif

/// Selected upstream configuration that stays experimental until this package is published.
///
/// Everything here is applied *after* the Grafana defaults, and the four settings the distribution
/// must own are re-asserted afterwards, so a callback can narrow them but never widen them: the
/// collector origin stays excluded from automatic HTTP tracing, trace context still goes only to
/// the configured first-party hosts, the HTTP semantic convention stays stable, and the recorded
/// request URL stays sanitised. Additional processors are additive rather than replacing the
/// Grafana ones.
public struct GrafanaOtelExperimentalOptions {
  /// Extra span processors, appended after the Grafana session and export processors.
  public var additionalSpanProcessors: [SpanProcessor]
  /// Extra log record processors. These sit behind the Grafana session processor, so they receive
  /// records that already carry `session.id`.
  public var additionalLogRecordProcessors: [LogRecordProcessor]
  /// Adjust the upstream `URLSession` instrumentation before it is installed.
  public var customizeURLSession: ((inout URLSessionInstrumentationConfiguration) -> Void)?
  /// Receives upstream SDK warnings and export errors.
  ///
  /// This *replaces* upstream's default handler, which writes the same messages to `os_log`. Log
  /// them yourself if you still want them in the system log.
  public var diagnosticsHandler: (@Sendable (String) -> Void)?

  public init(
    additionalSpanProcessors: [SpanProcessor] = [],
    additionalLogRecordProcessors: [LogRecordProcessor] = [],
    customizeURLSession: ((inout URLSessionInstrumentationConfiguration) -> Void)? = nil,
    diagnosticsHandler: (@Sendable (String) -> Void)? = nil
  ) {
    self.additionalSpanProcessors = additionalSpanProcessors
    self.additionalLogRecordProcessors = additionalLogRecordProcessors
    self.customizeURLSession = customizeURLSession
    self.diagnosticsHandler = diagnosticsHandler
  }
}

/// Applies Grafana's iOS defaults while preserving the upstream OpenTelemetry API and SDK.
///
/// The upstream Swift SDK ships providers, exporters and instrumentations but no assembled RUM
/// agent, so this type owns the assembly and its ordering. Application code never talks to it
/// beyond startup: instrumentation goes through the standard OpenTelemetry API.
public enum GrafanaOtel {
  private static let initialization = SingleInitialization<GrafanaOtelRuntime>()

  /// Initializes the upstream Swift SDK with Grafana defaults and returns the runtime handle.
  ///
  /// **Call this on the main thread**, once, early in app startup, before any code creates spans or
  /// log records. Upstream's default resource providers block on the main queue to read device and
  /// OS attributes, so initializing from a background thread while the main thread waits on this
  /// package deadlocks. The resource is therefore built before any lock is taken, but the
  /// main-thread requirement is upstream's and cannot be removed from here.
  ///
  /// The first call owns process-wide initialization. Later callers receive that same runtime
  /// instead of registering duplicate providers, exporters and swizzled instrumentations, and a
  /// concurrent caller blocks until the first call finishes. If a call fails, this package does not
  /// retry in the same process, because upstream setup may already have registered global state;
  /// restart the process after correcting the configuration.
  ///
  /// Everything that can fail runs before any global provider is registered, so a thrown error
  /// leaves the process with upstream's no-op providers rather than a half-installed SDK.
  @discardableResult
  public static func initialize(
    configuration: GrafanaOtelConfiguration
  ) throws -> GrafanaOtelRuntime {
    try initialize(configuration: configuration, experimental: GrafanaOtelExperimentalOptions())
  }

  /// Initializes with access to selected upstream configuration.
  ///
  /// - SeeAlso: ``GrafanaOtelExperimentalOptions`` for what the options may and may not override.
  @discardableResult
  public static func initialize(
    configuration: GrafanaOtelConfiguration,
    experimental: GrafanaOtelExperimentalOptions
  ) throws -> GrafanaOtelRuntime {
    // Return before rebuilding the upstream default resource. Its device and OS providers
    // synchronously hop to the main queue when called off-main, so doing that work for an already
    // initialized runtime can deadlock when the main thread is waiting on the repeat caller.
    if let runtime = initialization.getOrNull() {
      return runtime
    }

    // Warn rather than trap: calling off the main thread only deadlocks when the main thread is
    // itself waiting on this work, so a hard precondition would crash apps that are merely
    // unconventional. Use upstream's default os_log handler when the caller did not supply one, so
    // the stable overload does not silently discard the warning.
    if !Thread.isMainThread {
      let message =
        "GrafanaOtel.initialize was called off the main thread. Upstream's device and OS resource "
          + "providers block on the main queue, so this deadlocks if the main thread is waiting on "
          + "this work. Call initialize from your App's init() on the main thread."
      (experimental.diagnosticsHandler
        ?? OpenTelemetryApi.OpenTelemetry.instance.feedbackHandler)?(message)
    }

    // Built before the lock is taken: upstream's device and OS resource providers hop to the main
    // queue with `DispatchQueue.main.sync`, and doing that while holding the initialization lock
    // would let a main-thread status read deadlock against a background initializer.
    let baseResource = DefaultResources().get()

    return try initialization.getOrInitialize {
      try install(
        configuration: configuration,
        experimental: experimental,
        baseResource: baseResource
      )
    }
  }

  /// The process-wide runtime after a successful ``initialize(configuration:)``, otherwise `nil`.
  public static var runtime: GrafanaOtelRuntime? { initialization.getOrNull() }

  // MARK: - Installation

  /// The install order is load-bearing and is the main thing this package owns.
  ///
  /// 1. A diagnostics handler first, so problems in the remaining steps are observable.
  /// 2. The session manager, because the session span and log processors resolve
  ///    `SessionManagerProvider.getInstance()` in their initializers — and that call *lazily
  ///    creates* a default 30-minute manager if nothing has registered one, which a later
  ///    `register` does not repair.
  /// 3. Everything that can fail: storage directories, exporters and both pipelines. None of the
  ///    remaining steps throw, so a failure here never leaves a globally registered provider
  ///    behind.
  /// 4. The providers, registered globally.
  /// 5. `SessionEventInstrumentation.install()` after the logger provider, so queued
  ///    `session.start` records do not reach the no-op default logger.
  /// 6. The instrumentations last: `URLSessionInstrumentationConfiguration.init` and
  ///    `MetricKitConfiguration.init` resolve a concrete `Tracer`/`Logger` from the globals at
  ///    construction time, so anything built earlier is permanently wired to a no-op provider.
  private static func install(
    configuration: GrafanaOtelConfiguration,
    experimental: GrafanaOtelExperimentalOptions,
    baseResource: Resource
  ) throws -> GrafanaOtelRuntime {
    if let diagnosticsHandler = experimental.diagnosticsHandler {
      OpenTelemetryApi.OpenTelemetry.registerFeedbackHandler(diagnosticsHandler)
    }

    let plan = GrafanaOtelSetup.makePlan(
      configuration: configuration,
      baseResource: baseResource,
      environmentHeaders: GrafanaOtelSetup.environmentHeaders()
    )
    let headers = plan.exportHeaders.map { ($0.name, $0.value) }

    SessionManagerProvider.register(
      sessionManager: SessionManager(configuration: plan.sessionConfig)
    )

    // Prepare both storage directories up front so a disk-buffering failure cannot happen between
    // the two pipelines and leave one of them registered.
    let storage = try prepareStorage(for: configuration.diskBuffering)

    let tracerProvider = try makeTracerProvider(
      plan: plan,
      headers: headers,
      tracesStorageURL: storage?.traces,
      experimental: experimental
    )
    let logPipeline = try makeLogPipeline(
      plan: plan,
      headers: headers,
      logsStorageURL: storage?.logs,
      experimental: experimental
    )
    let loggerProvider = LoggerProviderBuilder()
      .with(resource: plan.resource)
      .with(processors: logPipeline.providerProcessors)
      .build()

    // From here on nothing throws.
    OpenTelemetryApi.OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    OpenTelemetryApi.OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

    var retained: [AnyObject] = []

    if configuration.instrumentation.sessionEvents {
      SessionEventInstrumentation.install()
    }
    if configuration.instrumentation.urlSession {
      let instrumentationConfiguration = makeURLSessionConfiguration(
        configuration: configuration,
        plan: plan,
        experimental: experimental
      )
      retained.append(URLSessionInstrumentation(configuration: instrumentationConfiguration))
    }
    #if canImport(MetricKit) && !os(tvOS) && !os(macOS)
      if configuration.instrumentation.metricKitDiagnostics {
        // `MXMetricManager` holds subscribers weakly, so the runtime keeps this alive.
        let metricKit = MetricKitInstrumentation()
        MXMetricManager.shared.add(metricKit)
        retained.append(metricKit)
      }
    #endif

    return GrafanaOtelRuntime(
      tracerProvider: tracerProvider,
      loggerProvider: loggerProvider,
      flushableLogRecordProcessors: logPipeline.flushable,
      retainedInstrumentations: retained
    )
  }

  private struct Storage {
    let traces: URL
    let logs: URL
  }

  private static func prepareStorage(
    for diskBuffering: GrafanaOtelDiskBuffering
  ) throws -> Storage? {
    guard case let .enabled(storageURL) = diskBuffering else { return nil }
    let storage = Storage(
      traces: try prepareStorageDirectory(storageURL, signal: "traces"),
      logs: try prepareStorageDirectory(storageURL, signal: "logs")
    )
    // Only for the directory this package owns. A caller-supplied directory is left exactly as
    // configured: silently changing the backup policy of someone else's directory would be a
    // surprising side effect.
    if diskBuffering == .enabledInDefaultDirectory {
      excludeFromBackups(storageURL)
    }
    return storage
  }

  /// Keeps queued payloads out of device backups.
  ///
  /// The queue holds full trace and log payloads — URLs, error messages, user attributes — so
  /// without this they would outlive the local retention window inside a backup. Failure is
  /// non-fatal: losing the exclusion is a privacy regression worth reporting, not a reason to run
  /// without telemetry.
  private static func excludeFromBackups(_ directory: URL) {
    var directory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try directory.setResourceValues(values)
    } catch {
      OpenTelemetryApi.OpenTelemetry.instance.feedbackHandler?(
        "Could not exclude the Grafana OpenTelemetry disk buffer from device backups: \(error)"
      )
    }
  }

  private static func makeTracerProvider(
    plan: GrafanaOtelPlan,
    headers: [(String, String)],
    tracesStorageURL: URL?,
    experimental: GrafanaOtelExperimentalOptions
  ) throws -> TracerProviderSdk {
    var processors: [SpanProcessor] = [SessionSpanProcessor()]

    // With persistence the disk queue owns the retry, so the HTTP exporter must not also keep an
    // in-memory copy of a failed batch. Without persistence that copy is the only retry there is.
    var exporter: SpanExporter = OtlpHttpTraceExporter(
      endpoint: plan.tracesEndpoint,
      envVarHeaders: headers,
      requeueOnFailure: tracesStorageURL == nil
    )
    if let tracesStorageURL {
      exporter = try wrapDiskBufferingError {
        try PersistenceSpanExporterDecorator(
          spanExporter: exporter,
          storageURL: tracesStorageURL
        )
      }
    }
    processors.append(
      BatchSpanProcessor(
        spanExporter: exporter,
        maxExportBatchSize: GrafanaOtelSetup.maxExportBatchSize(bufferingToDisk: tracesStorageURL != nil)
      )
    )
    processors.append(contentsOf: experimental.additionalSpanProcessors)

    return TracerProviderBuilder()
      .with(resource: plan.resource)
      .add(spanProcessors: processors)
      .build()
  }

  /// The log record processors, split by role.
  ///
  /// `providerProcessors` is what the `LoggerProvider` receives. `flushable` is what a caller must
  /// hold to flush or shut log export down, because `SessionLogRecordProcessor.forceFlush` and
  /// `.shutdown` return `.success` without forwarding to their `nextProcessor`: flushing through the
  /// session decorator would silently do nothing.
  struct LogPipeline {
    let providerProcessors: [LogRecordProcessor]
    let flushable: [LogRecordProcessor]
  }

  private static func makeLogPipeline(
    plan: GrafanaOtelPlan,
    headers: [(String, String)],
    logsStorageURL: URL?,
    experimental: GrafanaOtelExperimentalOptions
  ) throws -> LogPipeline {
    var downstream: [LogRecordProcessor] = []

    // `requeueOnFailure` deliberately stays at its default of `true`, even with persistence.
    // `OtlpHttpLogExporter.export` reports success as soon as it hands the request to
    // `URLSession`, before the response arrives, so the disk queue deletes the batch and a later
    // network failure has nothing left to retry. The in-memory copy is weaker than disk, but it
    // is better than none until upstream makes log export await its response.
    var exporter: LogRecordExporter = OtlpHttpLogExporter(
      endpoint: plan.logsEndpoint,
      envVarHeaders: headers
    )
    if let logsStorageURL {
      exporter = try wrapDiskBufferingError {
        try PersistenceLogExporterDecorator(
          logRecordExporter: exporter,
          storageURL: logsStorageURL
        )
      }
    }
    downstream.append(
      BatchLogRecordProcessor(
        logRecordExporter: exporter,
        maxExportBatchSize: GrafanaOtelSetup.maxExportBatchSize(bufferingToDisk: logsStorageURL != nil)
      )
    )
    downstream.append(contentsOf: experimental.additionalLogRecordProcessors)

    // One session processor in front of everything, so every downstream processor receives records
    // that already carry `session.id` and `session.previous_id`.
    let multi = MultiLogRecordProcessor(logRecordProcessors: downstream)
    return LogPipeline(
      providerProcessors: [SessionLogRecordProcessor(nextProcessor: multi)],
      flushable: [multi]
    )
  }

  /// Builds the `URLSession` instrumentation configuration.
  ///
  /// Separate from installation so the Grafana-owned parts — collector-origin exclusion, the
  /// first-party host list, the semantic convention, the sanitised request URL, and client span
  /// kind — can be asserted in tests without swizzling `URLSession`, which cannot be undone.
  static func makeURLSessionConfiguration(
    configuration: GrafanaOtelConfiguration,
    plan: GrafanaOtelPlan,
    experimental: GrafanaOtelExperimentalOptions
  ) -> URLSessionInstrumentationConfiguration {
    var instrumentationConfiguration = URLSessionInstrumentationConfiguration(
      spanCustomization: { _, spanBuilder in
        spanBuilder.setSpanKind(spanKind: .client)
      },
      // Fixed by the distribution, not configurable: ingest reads the stable names first and
      // falls back to the legacy ones, so there is no reason for a new app to emit deprecated
      // `http.method` / `http.url` / `http.status_code`.
      semanticConvention: .stable
    )
    experimental.customizeURLSession?(&instrumentationConfiguration)

    // Re-assert the Grafana-owned parts after the caller's customization. Tracing the telemetry
    // export itself would generate more export, so the collector origin is never instrumented.
    let excludedOrigin = GrafanaOtelSetup.excludedOrigin(for: configuration)
    let callerShouldInstrument = instrumentationConfiguration.shouldInstrument
    instrumentationConfiguration.shouldInstrument = { request in
      if let excludedOrigin, excludedOrigin.matches(request.url) {
        return false
      }
      return callerShouldInstrument?(request) ?? true
    }

    // Upstream injects trace context into every instrumented request. Narrow that to the configured
    // first-party hosts, still respecting a caller-supplied predicate on hosts that are allowed.
    let firstPartyHosts = plan.firstPartyHosts
    let callerShouldInject = instrumentationConfiguration.shouldInjectTracingHeaders
    instrumentationConfiguration.shouldInjectTracingHeaders = { request in
      guard GrafanaOtelSetup.shouldPropagateTraceContext(
        to: request.url?.host,
        firstPartyHosts: firstPartyHosts
      ) else {
        return false
      }
      return callerShouldInject?(request) ?? true
    }

    // Re-asserted after the caller's customization: the convention is the distribution's choice.
    instrumentationConfiguration.semanticConvention = .stable

    // Overwrite the recorded URL last, so a caller's own `createdRequest` cannot put the raw
    // `absoluteString` back. Upstream records it verbatim, which would export query values and any
    // credentials embedded in the URL.
    let urlKey = GrafanaOtelSetup.urlAttributeKey
    let callerCreatedRequest = instrumentationConfiguration.createdRequest
    instrumentationConfiguration.createdRequest = { request, span in
      callerCreatedRequest?(request, span)
      guard let sanitized = GrafanaOtelSetup.sanitizedURLString(for: request.url) else { return }
      span.setAttribute(key: urlKey, value: sanitized)
    }

    return instrumentationConfiguration
  }

  private static func prepareStorageDirectory(_ base: URL, signal: String) throws -> URL {
    let directory = base.appendingPathComponent(signal, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    } catch {
      throw GrafanaOtelInitializationError.diskBufferingUnavailable(
        underlying: String(describing: error)
      )
    }
    return directory
  }

  private static func wrapDiskBufferingError<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      throw GrafanaOtelInitializationError.diskBufferingUnavailable(
        underlying: String(describing: error)
      )
    }
  }
}
