import Foundation
import MetricKit
import MetricKitInstrumentation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import ResourceExtension
import Sessions
import URLSessionInstrumentation

// MARK: - 1. Your values

enum OTelConfig {
    /// Frontend Observability → your app → Settings → Mobile SDK Config → iOS:
    /// copy the URL from `static let endpoint` in step 2 (it ends in `/otlp/<app-key>`).
    ///
    /// The app key in the path identifies the app *and* authorises the request,
    /// so no API token or `Authorization` header is needed.
    ///
    /// Do NOT use the Grafana Cloud OTLP gateway (`otlp-gateway-*.grafana.net`):
    /// data sent there lands in Loki/Tempo but never shows up in Frontend Observability.
    static let otlpEndpoint = "https://faro-collector-<region>.grafana.net/otlp/<app-key>"

    /// Separates production, staging, and so on inside one Frontend Observability app.
    static let environment = "development"

    /// The release shown in Frontend Observability. Defaults to the marketing version (1.0.0).
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}

// MARK: - 2. Setup

/// Wires OpenTelemetry Swift for Grafana Frontend Observability.
///
/// The OpenTelemetry Swift SDK has no "agent": it ships providers, exporters and
/// instrumentations, and you assemble them. **The order below matters**; each step says why.
enum OTel {
    // MetricKit and the URLSession swizzling must stay alive for the whole process.
    private static var metricKit: MetricKitInstrumentation?
    private static var urlSession: URLSessionInstrumentation?

    /// Call once, on the main thread, from your `App.init()`, before anything else creates
    /// spans or logs. `DefaultResources()` reads `UIDevice` and would block on the main queue
    /// if called from a background thread.
    static func start() {
        guard !OTelConfig.otlpEndpoint.contains("<"),
              let endpoint = URL(string: OTelConfig.otlpEndpoint), endpoint.host != nil
        else {
            print("[OTel] Not started: set OTelConfig.otlpEndpoint to your /otlp/<app-key> URL")
            return
        }

        // Shows export errors (404, timeouts, rejected batches) in the Xcode console.
        // The SDK is otherwise completely silent when something goes wrong.
        #if DEBUG
        OpenTelemetry.registerFeedbackHandler { message in
            print("[OTel] \(message)")
        }
        #endif

        // A. Sessions — registered first, because the processors below read it.
        //    The SDK defaults (30 min, no max, resume old session) do NOT match Grafana's rules:
        //    - 15 min of inactivity ends a session
        //    - a session lasts at most 4 hours
        //    - every cold start begins a new session (the old one is linked as `session.previous_id`)
        SessionManagerProvider.register(sessionManager: SessionManager(
            configuration: SessionConfig(
                sessionTimeout: 15 * 60,
                maxLifetime: 4 * 60 * 60,
                restorePersistedSession: false
            )
        ))

        // B. Resource — attributes attached to every span and log.
        //    `DefaultResources()` adds device, OS and app attributes. We then remove two.
        //    Neither is required for data to arrive; both keep what you see in Grafana clean:
        //    - `service.name`: it is the bundle name. Without this line, logs, events and errors
        //      show the bundle name while spans show the registered name. Removed, Grafana uses
        //      the app name you registered in Frontend Observability everywhere.
        //    - `device.id`: `identifierForVendor`, a stable per-device ID. Frontend Observability
        //      does not use it, but without this line it is stored on every span. It is personal data.
        var resource = DefaultResources().get()
        resource.attributes.removeValue(forKey: "service.name")
        resource.attributes.removeValue(forKey: "device.id")
        resource.merge(other: Resource(attributes: [
            "service.version": .string(OTelConfig.appVersion),
            "deployment.environment.name": .string(OTelConfig.environment),
        ]))

        // C. Traces. `SessionSpanProcessor` adds `session.id` to every span.
        //    REQUIRED: the endpoint rejects the *whole batch* if any record lacks `session.id`.
        //    The `/v1/traces` and `/v1/logs` suffixes are REQUIRED too: OTel Swift exporters post
        //    to the exact URL they are given and never add the signal path (other OTel SDKs do).
        let tracerProvider = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: SessionSpanProcessor())
            .add(spanProcessor: BatchSpanProcessor(
                spanExporter: OtlpHttpTraceExporter(
                    endpoint: endpoint.appending(path: "v1/traces")
                )
            ))
            .build()
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

        // D. Logs. `SessionLogRecordProcessor` adds `session.id` to every log. Same rule as spans.
        let logProcessor = SessionLogRecordProcessor(
            nextProcessor: BatchLogRecordProcessor(
                logRecordExporter: OtlpHttpLogExporter(
                    endpoint: endpoint.appending(path: "v1/logs")
                )
            )
        )
        OpenTelemetry.registerLoggerProvider(loggerProvider: LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build())

        // No meter provider on purpose: the endpoint accepts metrics and silently drops them.

        // E. `session.start` / `session.end` events. Must come AFTER the logger provider,
        //    otherwise they go to the no-op logger and Grafana never sees a session start.
        SessionEventInstrumentation.install()

        // F. Crashes and hangs from MetricKit. iOS delivers them on a later launch
        //    (not on the Simulator), as log records through the pipeline above.
        let metricKit = MetricKitInstrumentation()
        MXMetricManager.shared.add(metricKit)

        // G. Automatic HTTP spans for every `URLSession` request. Created last, because it
        //    captures the global tracer when constructed.
        let urlSession = URLSessionInstrumentation(configuration: URLSessionInstrumentationConfiguration(
            // Do not trace our own telemetry uploads (that would create more uploads, forever).
            shouldInstrument: { request in
                request.url?.host != endpoint.host
            },
            // The SDK records the raw URL. Strip query, fragment and credentials so tokens
            // or personal data in a query string never leave the device.
            createdRequest: { request, span in
                guard let url = request.url,
                      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else { return }
                parts.query = nil
                parts.fragment = nil
                parts.user = nil
                parts.password = nil
                if let clean = parts.string {
                    span.setAttribute(key: "url.full", value: clean)
                }
            },
            // Current attribute names (`http.request.method`, `url.full`, ...).
            // The SDK still defaults to the deprecated ones.
            semanticConvention: .stable
        ))

        Self.metricKit = metricKit
        Self.urlSession = urlSession
    }

    // MARK: - 3. Use it

    /// A log line. Shows up as a log in Frontend Observability.
    static func log(_ message: String, severity: Severity = .info, attributes: [String: AttributeValue] = [:]) {
        logger.logRecordBuilder()
            .setSeverity(severity)
            .setBody(.string(message))
            .setAttributes(attributes)
            .emit()
    }

    /// A log record with an event name. Shows up as an event in Frontend Observability.
    static func event(_ name: String, attributes: [String: AttributeValue] = [:]) {
        logger.logRecordBuilder()
            .setEventName(name)
            .setAttributes(attributes)
            .emit()
    }

    /// An error you caught yourself. Crashes are reported automatically (MetricKit).
    /// The `exception.*` attributes are what make it an error in Frontend Observability.
    static func logException(_ error: Error, attributes: [String: AttributeValue] = [:]) {
        logger.logRecordBuilder()
            .setEventName("exception")
            .setSeverity(.error)
            .setAttributes(attributes.merging([
                "exception.type": .string(String(describing: type(of: error))),
                "exception.message": .string(error.localizedDescription),
                // Drop this helper's own frame, so the trace starts at the caller.
                "exception.stacktrace": .string(Thread.callStackSymbols.dropFirst().joined(separator: "\n")),
            ]) { _, new in new })
            .emit()
    }

    /// Starts a span and makes it active, so `URLSession` requests made before `end()`
    /// become its children. Always call `end()` on the result.
    static func startSpan(_ name: String) -> Span {
        tracer.spanBuilder(spanName: name).setActive(true).startSpan()
    }

    /// Tracer for manual spans. Same API as any OpenTelemetry Swift app.
    static var tracer: Tracer {
        OpenTelemetry.instance.tracerProvider.get(instrumentationName: "otel-swift-sample")
    }

    /// Qualified as `OpenTelemetryApi.Logger`: `MetricKit` imports `os`, which also has a `Logger`.
    static var logger: OpenTelemetryApi.Logger {
        OpenTelemetry.instance.loggerProvider
            .loggerBuilder(instrumentationScopeName: "otel-swift-sample")
            .build()
    }

    /// The current session ID, handy for finding this session in Frontend Observability.
    /// `peekSession()` reads it without counting as activity.
    static var sessionId: String? {
        SessionManagerProvider.getInstance().peekSession()?.id
    }
}
