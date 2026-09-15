import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import ResourceExtension
import Sessions
import URLSessionInstrumentation

/// The resolved values the Grafana distribution derives from a ``GrafanaOtelConfiguration``.
///
/// Startup is split into "decide" and "install" so the mapping from configuration to SDK inputs can
/// be asserted in unit tests without registering process-wide providers or swizzling `URLSession`.
struct GrafanaOtelPlan {
  let resource: Resource
  let tracesEndpoint: URL
  let logsEndpoint: URL
  /// Passed to the exporters as `envVarHeaders`. See ``GrafanaOtelSetup/mergeHeaders``.
  let exportHeaders: [(name: String, value: String)]
  let sessionConfig: SessionConfig
  /// Lowercased for case-insensitive exact matching.
  let firstPartyHosts: Set<String>
}

enum GrafanaOtelSetup {
  static let tracesPath = "v1/traces"
  static let logsPath = "v1/logs"
  /// Every OTLP signal path, including the one this package does not export, so a caller who pastes
  /// a full metrics URL is rejected with the same message.
  static let signalPaths = [tracesPath, logsPath, "v1/metrics"]

  /// Removed from the resource rather than set, so ingest applies the registered app identity.
  static let serviceNameKey = "service.name"
  /// Applied after the caller's `resourceAttributes`, so the package's value wins on a collision.
  static let serviceVersionKey = "service.version"
  /// The current semantic-convention key. Without it, production and staging telemetry share one
  /// app with no way to separate them.
  static let deploymentEnvironmentKey = "deployment.environment.name"

  /// Records per export batch.
  ///
  /// Upstream's default is 512, which is fine straight to the network. Persistence JSON-encodes a
  /// whole batch and then applies a 256 KiB `maxObjectSize`, and an oversized write fails
  /// *silently* — `maxExportBatchSize` counts records, not bytes, so one large stack trace or a
  /// normal multi-record batch can cross it. Buffering therefore runs smaller batches.
  static func maxExportBatchSize(bufferingToDisk: Bool) -> Int {
    bufferingToDisk ? 128 : 512
  }

  static func makePlan(
    configuration: GrafanaOtelConfiguration,
    baseResource: Resource,
    environmentHeaders: [(String, String)]?
  ) -> GrafanaOtelPlan {
    GrafanaOtelPlan(
      resource: makeResource(configuration: configuration, baseResource: baseResource),
      tracesEndpoint: signalEndpoint(configuration.otlpEndpoint, path: tracesPath),
      logsEndpoint: signalEndpoint(configuration.otlpEndpoint, path: logsPath),
      exportHeaders: mergeHeaders(
        environment: environmentHeaders,
        configured: configuration.headers
      ),
      sessionConfig: SessionConfig(
        sessionTimeout: configuration.sessionInactivityTimeout,
        maxLifetime: configuration.sessionMaxLifetime,
        restorePersistedSession: configuration.restorePersistedSession
      ),
      firstPartyHosts: Set(configuration.firstPartyHosts.map { $0.lowercased() })
    )
  }

  /// Upstream's default resource underneath, then the caller's attributes, then the two the package
  /// owns — `service.version` and `deployment.environment.name`.
  ///
  /// `Resource.merging(other:)` lets the argument win on collisions, which is what puts the
  /// package's two attributes above the caller's map. Service identity is the exception: the
  /// bundle-derived `service.name` is removed afterwards unless the caller asked for one.
  static func makeResource(
    configuration: GrafanaOtelConfiguration,
    baseResource: Resource
  ) -> Resource {
    var attributes: [String: AttributeValue] = [:]
    for (key, value) in configuration.resourceAttributes {
      attributes[key] = .string(value)
    }
    if let version = configuration.serviceVersion {
      attributes[serviceVersionKey] = .string(version)
    }
    if let environment = configuration.deploymentEnvironment {
      attributes[deploymentEnvironmentKey] = .string(environment)
    }
    var resource = baseResource.merging(other: Resource(attributes: attributes))
    if configuration.resourceAttributes[serviceNameKey] == nil {
      // Upstream's `ApplicationResourceProvider` always derives `service.name` from the bundle
      // name. Removing it is what lets ingest backfill the registered app identity, which it does
      // only when the attribute is absent or an `unknown_service*` placeholder. A caller who put
      // `service.name` in `resourceAttributes` meant it, so that one survives.
      resource.attributes.removeValue(forKey: serviceNameKey)
    }
    return resource
  }

  /// Strips the parts of a request URL that must not reach a telemetry backend.
  ///
  /// The upstream instrumentation records the URL from `absoluteString`, so a query string, a
  /// fragment, or credentials embedded in the URL would be exported verbatim. Returns `nil` when
  /// there is nothing usable to record.
  static func sanitizedURLString(for url: URL?) -> String? {
    guard let url,
          var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    parts.query = nil
    parts.fragment = nil
    parts.user = nil
    parts.password = nil
    return parts.string
  }

  /// The span attribute that carries the full request URL.
  ///
  /// One key, because the package fixes the HTTP semantic convention at `.stable`. The deprecated
  /// convention records `http.url` instead, so this would have to become a list again if that ever
  /// became configurable.
  static let urlAttributeKey = "url.full"

  /// Appends an OTLP signal path to the configured base endpoint.
  ///
  /// The upstream exporters do not append signal paths themselves; their defaults already point at
  /// `/v1/traces` and `/v1/logs`. `appendingPathComponent` also normalises a trailing slash on the
  /// configured endpoint, which naive string concatenation does not.
  static func signalEndpoint(_ base: URL, path: String) -> URL {
    base.appendingPathComponent(path)
  }

  /// Produces the single header list handed to the exporters.
  ///
  /// The upstream exporter treats `envVarHeaders` and `OtlpConfiguration.headers` as mutually
  /// exclusive: whenever `envVarHeaders` is non-nil, `config.headers` is never read. This package
  /// therefore merges both sources into `envVarHeaders` so configured headers cannot be silently
  /// dropped by an `OTEL_EXPORTER_OTLP_HEADERS` value in the environment.
  ///
  /// Names are compared case-insensitively and configured headers win. The result is deduplicated
  /// because the exporter uses `URLRequest.addValue(_:forHTTPHeaderField:)`, which comma-appends
  /// repeated names rather than replacing them.
  static func mergeHeaders(
    environment: [(String, String)]?,
    configured: [String: String]
  ) -> [(name: String, value: String)] {
    let configuredNames = Set(configured.keys.map { $0.lowercased() })
    var emitted = Set<String>()
    var merged: [(name: String, value: String)] = []

    for (name, value) in environment ?? [] {
      let key = name.lowercased()
      guard !configuredNames.contains(key), emitted.insert(key).inserted else { continue }
      merged.append((name: name, value: value))
    }
    // Sorted so that when a caller supplies two spellings of one header name, the surviving one is
    // deterministic rather than dictionary-order dependent.
    for name in configured.keys.sorted() {
      guard let value = configured[name], emitted.insert(name.lowercased()).inserted else { continue }
      merged.append((name: name, value: value))
    }
    return merged
  }

  /// Reads `OTEL_EXPORTER_OTLP_HEADERS`, which upstream would otherwise read itself.
  ///
  /// Upstream's `EnvVarHeaders` lives in `OpenTelemetryProtocolExporterCommon`, which
  /// `opentelemetry-swift` exposes as a target but not as an SPM product, so it cannot be imported
  /// here. Because this package always supplies `envVarHeaders` (see ``mergeHeaders``), the
  /// upstream default would otherwise never run and the environment variable would stop working.
  ///
  /// Comma-separated `name=value` pairs; an empty result is reported as `nil`.
  ///
  /// This deliberately diverges from upstream in one way: upstream requires an entry to split into
  /// *exactly* two `=`-separated components, which silently drops every base64 value carrying `=`
  /// padding — that is, every `Authorization: Basic …` credential. Splitting on the first `=` only
  /// accepts those.
  static func environmentHeaders(
    from raw: String? = ProcessInfo.processInfo.environment["OTEL_EXPORTER_OTLP_HEADERS"]
  ) -> [(String, String)]? {
    guard let raw else { return nil }

    var parsed: [(String, String)] = []
    for entry in raw.split(separator: ",") {
      guard let separator = entry.firstIndex(of: "=") else { continue }
      let name = entry[entry.startIndex..<separator].trimmingCharacters(in: .whitespaces)
      let value = entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard name.isValidHeaderName, value.isValidHeaderValue else { continue }
      parsed.append((name, value))
    }
    return parsed.isEmpty ? nil : parsed
  }

  /// Whether an instrumented request's host may receive W3C trace-context headers.
  ///
  /// An exact, case-insensitive host match against the configured first-party hosts. Deliberately
  /// not a suffix match: `example.com` does not authorise `api.example.com`, so a host is only ever
  /// trusted because someone listed it.
  static func shouldPropagateTraceContext(to host: String?, firstPartyHosts: Set<String>) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else { return false }
    return firstPartyHosts.contains(host)
  }

  /// The header names a redirect off the first-party list has to be stripped of.
  ///
  /// Read from the installed propagators, so replacing them keeps the guard correct, unioned with
  /// the W3C names because those are what this package's defaults inject and the union costs
  /// nothing. `fields` is advisory rather than exhaustive: `ZipkinBaggagePropagator` declares an
  /// empty set while writing one header per baggage entry under a `baggage-` prefix, so a
  /// propagator that writes names it does not declare stays outside what this can remove.
  static func tracePropagationFields(
    propagators: ContextPropagators = OpenTelemetryApi.OpenTelemetry.instance.propagators
  ) -> Set<String> {
    var fields: Set<String> = ["traceparent", "tracestate", "baggage"]
    fields.formUnion(propagators.textMapPropagator.fields)
    fields.formUnion(propagators.textMapBaggagePropagator.fields)
    return fields
  }

  /// Removes trace-context headers from a redirect that leaves the first-party hosts.
  ///
  /// `URLSession` carries the original request's custom headers onto the request it builds for a
  /// 3xx, and upstream injected those headers before the destination was known. Same host policy
  /// as ``shouldPropagateTraceContext(to:firstPartyHosts:)``, so a redirect that stays on the list
  /// keeps its context and the trace stays connected.
  static func sanitizedRedirect(
    _ request: URLRequest,
    firstPartyHosts: Set<String>,
    propagationFields: Set<String>
  ) -> URLRequest {
    guard !shouldPropagateTraceContext(
      to: request.url?.host,
      firstPartyHosts: firstPartyHosts
    ) else {
      return request
    }
    var sanitized = request
    for field in propagationFields {
      sanitized.setValue(nil, forHTTPHeaderField: field)
    }
    return sanitized
  }

  /// The origin the package must never trace, because tracing telemetry export creates more export.
  ///
  /// Host alone is not enough. During local development the collector and the application backend
  /// are routinely the same host on different ports (`localhost:8001` and `localhost:3333`), and a
  /// host-only match silently suppresses every backend span — the connected trace the demo exists
  /// to show. Matching the effective port as well keeps the exclusion to the collector itself.
  static func excludedOrigin(for configuration: GrafanaOtelConfiguration) -> Origin? {
    Origin(url: configuration.otlpEndpoint)
  }

  /// A scheme-normalised host and port pair.
  struct Origin: Equatable {
    let host: String
    let port: Int

    init?(url: URL) {
      guard let host = url.host, !host.isEmpty else { return nil }
      self.host = host.lowercased()
      self.port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    func matches(_ url: URL?) -> Bool {
      guard let url, let other = Origin(url: url) else { return false }
      return self == other
    }
  }
}
