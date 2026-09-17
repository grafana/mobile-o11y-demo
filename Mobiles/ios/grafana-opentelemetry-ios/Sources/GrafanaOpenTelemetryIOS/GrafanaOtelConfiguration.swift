import Foundation
import OpenTelemetryApi

/// Whether spans and pre-export log batches are persisted to disk between launches.
///
/// Enabled by default, at ``enabledInDefaultDirectory``. For spans, the disk queue owns retry, so
/// failed exports survive relaunch and can be delivered after connectivity returns. For logs,
/// persistence only protects the batch until its first export attempt: the pinned upstream HTTP log
/// exporter reports success before the response arrives, causing the disk copy to be removed, and
/// requeues a later network failure in memory only. Log records — including MetricKit diagnostics —
/// therefore do not have durable offline retry after an attempt has started.
///
/// It is not free. Records become readable to the exporter after roughly 4.75 seconds and then
/// export on an adaptive 1–20 second cycle, so every signal arrives later than it would without
/// buffering. It is also not synchronous: a sudden termination can still beat the write to disk.
/// Buffering shortens that window rather than closing it.
public enum GrafanaOtelDiskBuffering: Sendable, Equatable {
  case disabled
  /// Persist to a directory the caller owns. It is created if it does not exist.
  ///
  /// Choose the location deliberately. A caches directory can be purged by the system under storage
  /// pressure, losing queued telemetry. A directory that survives is usually included in device
  /// backups, and the queue holds full trace and log payloads — URLs, error messages, user
  /// attributes — which would then outlive the 18-hour local retention inside a backup. This
  /// package sets no backup-exclusion flag on a directory you supplied; do it yourself, or use
  /// ``enabledInDefaultDirectory``.
  case enabled(storageURL: URL)

  /// Persist to a package-owned directory that survives system cache eviction and is excluded from
  /// device backups.
  ///
  /// This is the default. The directory lives under Application Support, so the system does not
  /// reclaim it, and the package sets `isExcludedFromBackupKey` on it so queued payloads never
  /// reach a device backup.
  public static let enabledInDefaultDirectory = GrafanaOtelDiskBuffering.enabled(
    storageURL: GrafanaOtelDiskBuffering.defaultStorageURL
  )

  /// Application Support is not guaranteed to resolve, so this falls back to the temporary
  /// directory rather than making buffering unavailable. `appendingPathComponent` is used instead
  /// of the iOS 16 `appending(path:)` because this package supports iOS 13.
  static let defaultStorageURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("com.grafana.opentelemetry.ios", isDirectory: true)
  }()
}

/// Which Grafana-selected instrumentations the package installs during startup.
///
/// Every instrumentation here comes from the upstream Swift SDK. Turning one off does not change
/// how the application creates telemetry; application code keeps using standard OpenTelemetry APIs.
public struct GrafanaOtelInstrumentationOptions: Sendable, Equatable {
  /// Automatic client spans for `URLSession` requests, including W3C trace-context propagation.
  public var urlSession: Bool
  /// `session.start` and `session.end` log records from the upstream `Sessions` instrumentation.
  public var sessionEvents: Bool
  /// MetricKit crash, hang and performance diagnostics. iOS only; ignored on other platforms.
  public var metricKitDiagnostics: Bool

  public init(
    urlSession: Bool = true,
    sessionEvents: Bool = true,
    metricKitDiagnostics: Bool = true
  ) {
    self.urlSession = urlSession
    self.sessionEvents = sessionEvents
    self.metricKitDiagnostics = metricKitDiagnostics
  }

  public static let `default` = GrafanaOtelInstrumentationOptions()
}

/// Grafana-owned setup values layered on top of the upstream OpenTelemetry Swift SDK.
///
/// This configures SDK startup only. Applications continue to create telemetry through the
/// standard OpenTelemetry API reachable from ``GrafanaOtelRuntime/openTelemetry``.
public struct GrafanaOtelConfiguration: Sendable {
  /// OTLP/HTTP base endpoint. Required: this package exists to export, so there is no
  /// install-without-exporting mode. Signal paths are appended by the package.
  public let otlpEndpoint: URL
  public let serviceVersion: String?
  public let deploymentEnvironment: String?
  /// Extra resource attributes. Applied before the attributes this package owns, which win.
  ///
  /// This is also the only route to `service.name` and `service.namespace`. The package removes the
  /// bundle-derived `service.name` upstream adds, so that ingest applies the app identity you
  /// registered — pass one here only when exporting somewhere with no registered identity, such as
  /// the general Grafana Cloud OTLP gateway, and it is kept as given.
  public let resourceAttributes: [String: String]
  /// Export headers. Applied on top of `OTEL_EXPORTER_OTLP_HEADERS`, which these override.
  public let headers: [String: String]
  public let sessionInactivityTimeout: TimeInterval
  public let sessionMaxLifetime: TimeInterval
  /// Whether a persisted session is resumed on a cold start. `false` starts a new session,
  /// matching the Faro session rule the Grafana products expect.
  public let restorePersistedSession: Bool
  /// The hosts you own, which are the only ones that receive W3C trace-context headers.
  ///
  /// Required, with no default. Upstream injects `traceparent`, `tracestate` and `baggage` into
  /// *every* request it instruments, which sends trace identifiers to third-party hosts — analytics,
  /// CDNs, ad SDKs — and can break servers that reject unknown headers or sign a fixed header set.
  /// A package cannot know which hosts you own, so choosing is part of setup.
  ///
  /// Matching is an exact, case-insensitive host comparison: list every host you want, including
  /// each subdomain. `["example.com"]` does not cover `api.example.com`. An empty array propagates
  /// to nothing, which is valid and means no trace will connect to a backend.
  public let firstPartyHosts: [String]
  public let diskBuffering: GrafanaOtelDiskBuffering
  public let instrumentation: GrafanaOtelInstrumentationOptions

  /// Creates a validated configuration.
  ///
  /// - Throws: ``GrafanaOtelConfigurationError`` when a value cannot produce a working exporter,
  ///   resource or session. Validation happens here so startup failures surface at the call site
  ///   instead of silently dropping telemetry.
  public init(
    otlpEndpoint: URL,
    firstPartyHosts: [String],
    serviceVersion: String? = nil,
    deploymentEnvironment: String? = nil,
    resourceAttributes: [String: String] = [:],
    headers: [String: String] = [:],
    sessionInactivityTimeout: TimeInterval = 15 * 60,
    sessionMaxLifetime: TimeInterval = 4 * 60 * 60,
    restorePersistedSession: Bool = false,
    diskBuffering: GrafanaOtelDiskBuffering = .enabledInDefaultDirectory,
    instrumentation: GrafanaOtelInstrumentationOptions = .default
  ) throws {
    try GrafanaOtelConfiguration.validate(otlpEndpoint: otlpEndpoint)
    try GrafanaOtelConfiguration.requireNonBlankIfPresent(serviceVersion, field: "serviceVersion")
    try GrafanaOtelConfiguration.requireNonBlankIfPresent(
      deploymentEnvironment,
      field: "deploymentEnvironment"
    )
    // `Resource(attributes:)` discards *every* attribute when any key is invalid, so reject bad
    // keys here rather than losing the whole resource at export time.
    for key in resourceAttributes.keys {
      guard key.isValidResourceAttributeKey else {
        throw GrafanaOtelConfigurationError.invalidResourceAttributeKey(key)
      }
    }
    for (name, value) in headers {
      guard name.isValidHeaderName else {
        throw GrafanaOtelConfigurationError.invalidHeaderName(name)
      }
      guard value.isValidHeaderValue else {
        throw GrafanaOtelConfigurationError.invalidHeaderValue(name: name)
      }
    }
    for host in firstPartyHosts {
      try GrafanaOtelConfiguration.validate(firstPartyHost: host)
    }
    try GrafanaOtelConfiguration.requirePositive(
      sessionInactivityTimeout,
      field: "sessionInactivityTimeout"
    )
    try GrafanaOtelConfiguration.requirePositive(sessionMaxLifetime, field: "sessionMaxLifetime")
    guard sessionMaxLifetime >= sessionInactivityTimeout else {
      throw GrafanaOtelConfigurationError.sessionMaxLifetimeTooShort
    }

    self.otlpEndpoint = otlpEndpoint
    self.serviceVersion = serviceVersion
    self.deploymentEnvironment = deploymentEnvironment
    self.resourceAttributes = resourceAttributes
    self.headers = headers
    self.sessionInactivityTimeout = sessionInactivityTimeout
    self.sessionMaxLifetime = sessionMaxLifetime
    self.restorePersistedSession = restorePersistedSession
    self.firstPartyHosts = firstPartyHosts
    self.diskBuffering = diskBuffering
    self.instrumentation = instrumentation
  }

  private static func validate(otlpEndpoint: URL) throws {
    guard let components = URLComponents(url: otlpEndpoint, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty
    else {
      throw GrafanaOtelConfigurationError.invalidEndpoint(
        reason: "must be an absolute http:// or https:// URL"
      )
    }
    guard components.query == nil else {
      throw GrafanaOtelConfigurationError.invalidEndpoint(reason: "must not contain a query string")
    }
    guard components.fragment == nil else {
      throw GrafanaOtelConfigurationError.invalidEndpoint(reason: "must not contain a fragment")
    }
    let trimmedPath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    for signalPath in GrafanaOtelSetup.signalPaths where trimmedPath.hasSuffix("/" + signalPath) {
      throw GrafanaOtelConfigurationError.invalidEndpoint(
        reason: "must be the OTLP base URL, not a signal URL ending in /\(signalPath)"
      )
    }
  }

  /// A `firstPartyHosts` entry must be a bare host.
  ///
  /// A scheme, path, port or credentials in an entry would never match `URL.host` and would
  /// silently stop trace-context injection for that host, which is indistinguishable from a
  /// deliberately narrow allowlist.
  ///
  /// Known limitation: rejecting `:` also rejects an IPv6 literal such as `::1`, so an IPv6 backend
  /// cannot be listed. Hostnames and IPv4 addresses are unaffected.
  private static func validate(firstPartyHost host: String) throws {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw GrafanaOtelConfigurationError.blankValue(field: "firstPartyHosts entry")
    }
    let rejected: Set<Character> = ["/", ":", "@", "?", "#", " ", "*"]
    guard !trimmed.contains(where: rejected.contains),
          !trimmed.hasPrefix("."),
          !trimmed.hasSuffix("."),
          trimmed == host
    else {
      throw GrafanaOtelConfigurationError.invalidFirstPartyHost(host)
    }
  }

  private static func requireNonBlankIfPresent(_ value: String?, field: String) throws {
    guard let value else { return }
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GrafanaOtelConfigurationError.blankValue(field: field)
    }
  }

  private static func requirePositive(_ value: TimeInterval, field: String) throws {
    guard value.isFinite, value > 0 else {
      throw GrafanaOtelConfigurationError.notPositive(field: field)
    }
  }
}

/// Why a ``GrafanaOtelConfiguration`` was rejected.
public enum GrafanaOtelConfigurationError: Error, Equatable, CustomStringConvertible {
  case invalidEndpoint(reason: String)
  case blankValue(field: String)
  case notPositive(field: String)
  case sessionMaxLifetimeTooShort
  case invalidResourceAttributeKey(String)
  case invalidHeaderName(String)
  case invalidHeaderValue(name: String)
  case invalidFirstPartyHost(String)

  public var description: String {
    switch self {
    case let .invalidEndpoint(reason):
      return "otlpEndpoint \(reason)"
    case let .blankValue(field):
      return "\(field) must not be blank"
    case let .notPositive(field):
      return "\(field) must be a positive number of seconds"
    case .sessionMaxLifetimeTooShort:
      return "sessionMaxLifetime must be greater than or equal to sessionInactivityTimeout"
    case let .invalidResourceAttributeKey(key):
      return "resource attribute key \(key.debugDescription) must be 1-255 printable ASCII characters"
    case let .invalidHeaderName(name):
      return "header name \(name.debugDescription) must contain only visible ASCII characters"
    case let .invalidHeaderValue(name):
      return "value for header \(name.debugDescription) must contain only tabs or visible ASCII characters"
    case let .invalidFirstPartyHost(host):
      return "firstPartyHosts entry \(host.debugDescription) must be a bare host, "
        + "without a scheme, port, path or surrounding whitespace"
    }
  }
}

// These match what `URLRequest` will carry rather than the stricter HTTP token grammar, so a header
// name containing a separator such as `(` is accepted here and rejected by nothing downstream.
extension String {
  var isValidHeaderName: Bool {
    !isEmpty && unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
  }

  var isValidHeaderValue: Bool {
    unicodeScalars.allSatisfy { $0.value == 0x09 || (0x20...0x7e).contains($0.value) }
  }

  var isValidResourceAttributeKey: Bool {
    !isEmpty && count <= 255 && unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
  }
}
