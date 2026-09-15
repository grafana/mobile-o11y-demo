import Foundation
import ObjectiveC

/// Applies the redirect policy without the application installing anything.
///
/// The upstream instrumentation assigns a task delegate of its own — `AsyncTaskDelegate`, or
/// `FakeDelegate` on the non-async path — to every task that has neither a task delegate nor a
/// session delegate. Those classes implement completion callbacks but no redirect callback, so this
/// adds one to them. Tasks that reach them are exactly the ones the application has expressed no
/// delegate opinion about, which is what makes writing to them defensible.
///
/// Deliberately *not* the alternative: swizzling `URLSessionTask.resume` a second time and
/// assigning a delegate there reaches more tasks, but it stacks onto the most intricate method
/// upstream swizzles and writes `task.delegate` on tasks the application created.
///
/// ## What this cannot reach
///
/// - Tasks or sessions with a delegate of the application's own — upstream installs nothing there,
///   so there is no class of ours in the chain. Those need ``GrafanaOtelRuntime/redirectGuard``.
/// - iOS 13 and 14, where upstream assigns no delegate at all.
/// - A future upstream release that renames or removes these classes. The lookup then finds
///   nothing and reports it through the diagnostics handler rather than failing silently.
enum GrafanaOtelAutomaticRedirectProtection {
  /// Upstream's internal delegate classes, by their Objective-C runtime names.
  ///
  /// Internal implementation details of `opentelemetry-swift`, which is why a miss is reported
  /// rather than treated as an error: the package still works, it just protects nothing here.
  static let upstreamDelegateClassNames = [
    "URLSessionInstrumentation.AsyncTaskDelegate",
    "URLSessionInstrumentation.FakeDelegate",
  ]

  /// Hand-written fallback for the redirect selector's type encoding.
  ///
  /// The runtime reports `v56@0:8@16@24@32@40@?48` for it. Only the types matter, not the frame
  /// offsets: void return, self, selector, then session, task, response, request, and a block.
  static let fallbackTypeEncoding = "v@:@@@@@?"

  /// The result of one installation attempt, for diagnostics and tests.
  struct Outcome: Equatable {
    /// Classes that now carry the redirect method because this call added it.
    var patched: [String] = []
    /// Classes that already implemented it — upstream's own, or a previous call's.
    var alreadyImplemented: [String] = []
    /// Names that the runtime does not know, i.e. upstream renamed or removed them.
    var notFound: [String] = []
    /// The hosts the installed callback treats as first party.
    var firstPartyHosts: Set<String> = []
  }

  /// The most recent installation, or `nil` if it never ran in this process.
  ///
  /// Recorded because the mutation that matters most — the branch reading the opt-in flag turned
  /// into a no-op — is otherwise undetectable: the classes may already carry the method from an
  /// earlier call, so their state proves nothing about whether *this* startup installed anything.
  /// Also the honest answer to "did the flag do something" when diagnosing a leak.
  static var lastOutcome: Outcome? { outcomeLock.withLock { recordedOutcome } }

  private static let outcomeLock = NSLock()
  nonisolated(unsafe) private static var recordedOutcome: Outcome?

  private static func record(_ outcome: Outcome) {
    outcomeLock.withLock { recordedOutcome = outcome }
  }

  /// Adds the redirect callback to upstream's delegate classes.
  ///
  /// Process-wide and not reversible, like every other runtime mutation in this area. Adding is
  /// skipped where an implementation already exists, so an upstream release that starts handling
  /// redirects itself keeps ownership of the behaviour.
  @discardableResult
  static func install(
    firstPartyHosts: Set<String>,
    propagationFields: Set<String>,
    classNames: [String] = upstreamDelegateClassNames
  ) -> Outcome {
    let selector = #selector(
      URLSessionTaskDelegate.urlSession(
        _:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    )
    let types = typeEncoding(for: selector)

    let block: @convention(block) (
      Any, URLSession, URLSessionTask, HTTPURLResponse, URLRequest, @escaping (URLRequest?) -> Void
    ) -> Void = { _, _, _, _, request, completionHandler in
      completionHandler(
        GrafanaOtelSetup.sanitizedRedirect(
          request,
          firstPartyHosts: firstPartyHosts,
          propagationFields: propagationFields
        )
      )
    }
    let implementation = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))

    var outcome = Outcome(firstPartyHosts: firstPartyHosts)
    defer { record(outcome) }
    for name in classNames {
      guard let cls: AnyClass = NSClassFromString(name) else {
        outcome.notFound.append(name)
        continue
      }
      // `class_addMethod` would refuse this anyway; checking first keeps the outcome honest about
      // *why* nothing was added.
      guard class_getInstanceMethod(cls, selector) == nil else {
        outcome.alreadyImplemented.append(name)
        continue
      }
      if class_addMethod(cls, selector, implementation, types) {
        outcome.patched.append(name)
      } else {
        outcome.alreadyImplemented.append(name)
      }
    }
    return outcome
  }

  /// The selector's type encoding, read from the protocol that declares it.
  ///
  /// Preferred over a literal so the encoding cannot drift from the declaration. The redirect
  /// callback is an *optional* protocol requirement, hence `isRequiredMethod: false`.
  static func typeEncoding(for selector: Selector) -> String {
    guard let proto = NSProtocolFromString("NSURLSessionTaskDelegate") else {
      return fallbackTypeEncoding
    }
    let description = protocol_getMethodDescription(
      proto, selector, /* isRequiredMethod: */ false, /* isInstanceMethod: */ true
    )
    guard let types = description.types else { return fallbackTypeEncoding }
    return String(cString: types)
  }

  /// A one-line summary for the diagnostics handler.
  static func diagnosticMessage(for outcome: Outcome) -> String? {
    if !outcome.notFound.isEmpty {
      return "Grafana OpenTelemetry could not install automatic redirect protection: "
        + "\(outcome.notFound.joined(separator: ", ")) not found in the Objective-C runtime. "
        + "The upstream instrumentation has probably renamed them. Requests using a URLSession "
        + "delegate of your own were never covered by this; install "
        + "GrafanaOtelRuntime.redirectGuard to filter redirects yourself."
    }
    if outcome.patched.isEmpty, !outcome.alreadyImplemented.isEmpty {
      return "Grafana OpenTelemetry left redirect handling to the upstream instrumentation: "
        + "\(outcome.alreadyImplemented.joined(separator: ", ")) already implement it."
    }
    return nil
  }
}
