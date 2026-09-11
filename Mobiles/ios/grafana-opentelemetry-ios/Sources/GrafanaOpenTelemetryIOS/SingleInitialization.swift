import Foundation

/// Holds a value that may only be produced once per process.
///
/// The first caller runs the initializer. Later callers get that same value instead of installing
/// a second set of exporters, processors and swizzled instrumentations. A failed attempt is
/// remembered: upstream setup may already have registered global state, so the process must
/// restart before a retry can be trusted.
///
/// `Value: AnyObject` is stored and handed to callers as-is, so this type inherits whatever thread
/// safety the value itself has. It guarantees only that the value is produced once and published
/// safely, not that using it is safe from any thread.
final class SingleInitialization<Value: AnyObject>: @unchecked Sendable {
  /// Serialises initialization. Recursive so a same-thread re-entrant call can observe
  /// `isInitializing` and throw instead of deadlocking on the lock it already owns.
  private let initLock = NSRecursiveLock()
  /// Guards the published value. Deliberately a *second* lock, and never held across the
  /// initializer, so that reading state can never join a cycle with work the initializer is doing.
  private let stateLock = NSLock()
  private var value: Value?
  private var failure: Error?
  private var isInitializing = false

  func getOrNull() -> Value? {
    stateLock.withLock { value }
  }

  func getOrInitialize(_ initializer: () throws -> Value) throws -> Value {
    try initLock.withLock {
      if let existing = stateLock.withLock({ value }) { return existing }
      if let failure = stateLock.withLock({ failure }) {
        throw GrafanaOtelInitializationError.previousAttemptFailed(
          underlying: String(describing: failure)
        )
      }
      guard !isInitializing else {
        throw GrafanaOtelInitializationError.reentrantInitialization
      }

      isInitializing = true
      defer { isInitializing = false }
      do {
        let produced = try initializer()
        stateLock.withLock { value = produced }
        return produced
      } catch {
        stateLock.withLock { failure = error }
        throw error
      }
    }
  }
}

/// Why ``GrafanaOtel/initialize(configuration:)`` could not produce a runtime.
public enum GrafanaOtelInitializationError: Error, CustomStringConvertible {
  /// An earlier call in this process failed. Upstream global state may be half-installed.
  case previousAttemptFailed(underlying: String)
  /// `initialize` was called from inside its own initializer.
  case reentrantInitialization
  /// Disk buffering was requested but its storage directory could not be prepared.
  case diskBufferingUnavailable(underlying: String)

  public var description: String {
    switch self {
    case let .previousAttemptFailed(underlying):
      return "Grafana OpenTelemetry initialization previously failed (\(underlying)); "
        + "restart the process before retrying"
    case .reentrantInitialization:
      return "Grafana OpenTelemetry initialization is already in progress on this thread"
    case let .diskBufferingUnavailable(underlying):
      return "Grafana OpenTelemetry disk buffering could not be prepared: \(underlying)"
    }
  }
}
