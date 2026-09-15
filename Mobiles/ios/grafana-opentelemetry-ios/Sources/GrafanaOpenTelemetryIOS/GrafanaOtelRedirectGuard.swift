import Foundation
import OpenTelemetryApi

/// Keeps W3C trace context from following a redirect off the first-party hosts.
///
/// The upstream instrumentation injects trace headers once, into the original request, and
/// `URLSession` copies a request's custom headers onto the request it builds for a 3xx.
/// `URLSessionInstrumentation` swizzles no redirect method and
/// `URLSessionInstrumentationConfiguration` has no redirect callback, so `shouldInjectTracingHeaders`
/// is never consulted for the new host: without this guard, a first-party request that redirects to
/// a third party carries `traceparent` there.
///
/// `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
/// is the only place the system offers the destination before that request is sent, so filtering a
/// redirect means having a delegate there.
///
/// Reach for this one when the package cannot supply that delegate itself: a session of your own
/// that already has a delegate, or iOS 13 and 14. Otherwise prefer
/// ``GrafanaOtelExperimentalOptions/automaticRedirectProtection``, which covers delegate-less
/// sessions with nothing installed by you — see ``GrafanaOtelAutomaticRedirectProtection`` for how
/// and for what it cannot reach.
///
/// As a session delegate, which is the placement that works on every supported version:
///
/// ```swift
/// URLSession(configuration: .default, delegate: runtime.redirectGuard, delegateQueue: nil)
/// ```
///
/// Or per task, on iOS 15 and later, where `URLSessionTask.delegate` exists:
///
/// ```swift
/// let (data, response) = try await URLSession.shared.data(
///   for: request,
///   delegate: GrafanaOtel.runtime?.redirectGuard
/// )
/// ```
///
/// A redirect that stays on the first-party list keeps its context, so a trace through a
/// first-party redirect stays connected.
///
/// ## Why this implements `didCompleteWithError`
///
/// Giving a task or session a delegate makes the upstream instrumentation skip its own
/// `AsyncTaskDelegate`, which is what ends the span for `async`/`await` requests.
/// `urlSession(_:task:didCompleteWithError:)` is one of the selectors `URLSessionInstrumentation`
/// scans delegate classes for, and finding it is what makes it swizzle this class and end the span
/// there instead. The implementation is empty on purpose: its presence is the whole point, which is
/// the same role upstream's own `FakeDelegate` plays for tasks that have no delegate. Removing it
/// would silently drop the HTTP spans for every request that uses this guard.
public final class GrafanaOtelRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let firstPartyHosts: Set<String>
  /// Resolved once at initialization, from the propagators registered by then, so that a redirect
  /// arriving on a background thread does not read global propagator state.
  private let propagationFields: Set<String>

  init(firstPartyHosts: Set<String>, propagationFields: Set<String>) {
    self.firstPartyHosts = firstPartyHosts
    self.propagationFields = propagationFields
    super.init()
  }

  /// The request `URLSession` should actually send, with trace context removed when the redirect
  /// leaves the first-party hosts.
  ///
  /// Public so the policy can be applied from a delegate the application already has, without
  /// installing this one.
  public func sanitizedRedirect(_ request: URLRequest) -> URLRequest {
    GrafanaOtelSetup.sanitizedRedirect(
      request,
      firstPartyHosts: firstPartyHosts,
      propagationFields: propagationFields
    )
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(sanitizedRedirect(request))
  }

  /// Deliberately empty — see the note on the type. This method existing is what keeps the HTTP
  /// spans of requests using this guard from being dropped.
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {}
}
