import Foundation
import GrafanaOpenTelemetryIOS
import OpenTelemetryApi
import OpenTelemetrySdk
import OSLog
import SwiftiePod

let otelServiceProvider = Provider { pod in
    let config = pod.resolve(otelConfigProvider)
    OTelService.instance.initialize(config: config)
    return OTelService.instance
}

/// Starts OpenTelemetry through Grafana OpenTelemetry iOS and hands the upstream
/// API to the rest of the app.
///
/// All SDK assembly — providers, OTLP exporters, sessions, `URLSession` tracing and
/// MetricKit diagnostics — lives in the `GrafanaOpenTelemetryIOS` package. What stays
/// here is app-specific: reading QuickPizza's runtime config, the debug-only console
/// span exporter, and the app's instrumentation scope.
///
/// Application instrumentation (`Tracer.swift`, `Logger.swift`, `AppEvents.swift`) keeps
/// using standard OpenTelemetry APIs and does not know this package exists.
final class OTelService {
    fileprivate static let instance = OTelService()

    private static let log = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.grafana.QuickPizzaIos",
        category: "otel"
    )

    private var isInitialized = false
    private var otelConfig: OTelConfig?
    private var runtime: GrafanaOtelRuntime?

    /// Whether OpenTelemetry is installed and exporting.
    ///
    /// A valid OTLP endpoint is required, so there is no "installed but not exporting" state:
    /// this is simply whether the package handed back a runtime.
    var isExportingOtlp: Bool { runtime != nil }

    /// Why startup did not produce a runtime, if it did not. Reported in the app's startup log so a
    /// silent absence of telemetry has a stated cause rather than needing to be guessed at.
    private(set) var otlpRejectionReason: String?

    private init() {}

    func initialize(config: OTelConfig) {
        guard !isInitialized else { return }
        isInitialized = true
        self.otelConfig = config

        // The package requires a valid OTLP endpoint: it exists to export, so there is no
        // install-without-exporting mode. Without one, the app runs on upstream's no-op providers —
        // instrumentation still compiles and executes, it just produces nothing.
        guard let endpointString = config.endpointUrl else {
            otlpRejectionReason = "no OTLP endpoint configured"
            Self.log.info("OTel not initialized: no OTLP endpoint configured")
            return
        }
        guard let endpoint = URL(string: endpointString) else {
            otlpRejectionReason = "OTLP endpoint is not a valid URL"
            Self.log.error("OTel not initialized: OTLP endpoint is not a valid URL")
            return
        }

        do {
            runtime = try GrafanaOtel.initialize(
                configuration: try makeConfiguration(config: config, endpoint: endpoint),
                experimental: makeExperimentalOptions()
            )
            Self.log.info("OTel initialized, exporting to the configured OTLP endpoint")
        } catch {
            let reason = String(describing: error)
            otlpRejectionReason = reason
            Self.log.error("OTel not initialized: \(reason, privacy: .public)")
        }
    }

    private func makeConfiguration(
        config: OTelConfig,
        endpoint: URL
    ) throws -> GrafanaOtelConfiguration {
        var headers: [String: String] = [:]
        if let authHeader = config.authHeader {
            headers["Authorization"] = authHeader
        }

        // The package removes the bundle-derived `service.name` so ingest can apply the registered
        // app identity, and it offers no setting to put one back — `resourceAttributes` is the
        // route. This demo supplies one deliberately, because it also runs against the legacy OTLP
        // gateway, where `service.name` and `service.namespace` are the only identity labels.
        var resourceAttributes: [String: String] = [
            "service.name": config.serviceName,
            "service.namespace": "quickpizza",
        ]
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            resourceAttributes["service.build"] = build
        }

        return try GrafanaOtelConfiguration(
            otlpEndpoint: endpoint,
            // QuickPizza's backend is the only host this app owns, so it is the only one that
            // receives trace context. Everything else gets no traceparent.
            firstPartyHosts: firstPartyHosts(backendBaseUrl: config.backendBaseUrl),
            serviceVersion: config.appVersion,
            deploymentEnvironment: config.deploymentEnvironment,
            resourceAttributes: resourceAttributes,
            headers: headers
        )
    }

    private func makeExperimentalOptions() -> GrafanaOtelExperimentalOptions {
        var spanProcessors: [SpanProcessor] = []
        #if DEBUG
        spanProcessors.append(SimpleSpanProcessor(spanExporter: OSLogSpanExporter()))
        #endif

        return GrafanaOtelExperimentalOptions(
            additionalSpanProcessors: spanProcessors,
            // The first-party host list is applied when a request is created, which is the only
            // point upstream exposes. `URLSession` then carries a request's headers across a 3xx,
            // so without this an API call redirected off the backend host would take `traceparent`
            // wherever it was sent. This app uses `URLSession.shared` with no delegate, which is
            // exactly the case the flag covers.
            automaticRedirectProtection: true,
            // Replaces the SDK's own os_log handler, so export failures (404, 401, timeouts) land in
            // the app's log category instead of being scattered across the system log.
            diagnosticsHandler: { message in
                Self.log.warning("OTel SDK: \(message, privacy: .public)")
            }
        )
    }

    /// Derives the first-party host from the backend the app is already calling, so the two cannot
    /// drift apart as the backend changes between local, tunnelled and hosted setups.
    private func firstPartyHosts(backendBaseUrl: String) -> [String] {
        guard let host = URL(string: backendBaseUrl)?.host, !host.isEmpty else {
            // Propagating to nothing is safer than propagating to everything, but it does mean
            // mobile-to-backend traces will not connect, so say so rather than failing quietly.
            Self.log.warning(
                "No host in the backend base URL; no request will carry trace context"
            )
            return []
        }
        return [host]
    }

    // MARK: - Accessors

    func getTracer() -> Tracer {
        return OpenTelemetry.instance.tracerProvider.get(
            instrumentationName: otelConfig?.instrumentationScopeName ?? OTelConfig.defaultScopeName,
            instrumentationVersion: otelConfig?.instrumentationScopeVersion ?? OTelConfig.defaultScopeVersion
        )
    }

    func getLogger() -> OpenTelemetryApi.Logger {
        return OpenTelemetry.instance.loggerProvider.loggerBuilder(
            instrumentationScopeName: otelConfig?.instrumentationScopeName ?? OTelConfig.defaultScopeName
        ).build()
    }

    /// Hands everything currently queued to the exporters. Blocks, so keep it off the main thread.
    func forceFlush(timeout: TimeInterval? = nil) {
        runtime?.forceFlush(timeout: timeout)
    }
}
