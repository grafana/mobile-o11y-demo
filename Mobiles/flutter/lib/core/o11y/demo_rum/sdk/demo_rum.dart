/// DemoRum — a made-up, no-op RUM SDK used purely for demonstration.
///
/// This app's real instrumentation is **Grafana Faro**. DemoRum exists to show
/// how you would run a *second* RUM SDK side by side with Faro: the shared
/// `core/o11y/` layer fans every error / log / event / span out to both Faro
/// and DemoRum, so you can see the exact call sites a second SDK would plug
/// into.
///
/// It is intentionally a **stand-in**: every method is a no-op that (optionally)
/// echoes to the console instead of sending anything over the network. That
/// keeps the demo free of any third-party SDK or service. The public API here
/// is deliberately shaped like a typical mobile RUM SDK (init + options, a root
/// widget, a navigation observer, an HTTP client wrapper, exception capture,
/// structured logs, scope/user, and spans), so to wire up a *real* SDK you can
/// swap this file's types for the vendor's and keep the surrounding code
/// essentially unchanged.
///
/// A few things do real work so the demo is honest and the app keeps
/// functioning: [DemoRum.startSpan] runs its callback and returns the result,
/// [DemoRumHttpClient] forwards the request to its inner client (and echoes
/// it), and [DemoRum.init] installs *chained* `FlutterError.onError` /
/// `PlatformDispatcher.onError` handlers (the same cooperative pattern real
/// SDKs use) that echo and then delegate to the previously-installed handler.
/// Nothing is ever sent over the network.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Status a span can finish in. Mirrors the ok/error split every RUM SDK has.
enum DemoRumSpanStatus { ok, error }

/// Build-time configuration handed to [DemoRum.init]. A real SDK would also
/// take an ingest endpoint + API key/client token (plus knobs like a traces
/// sample rate) here; this stand-in keeps the identity fields worth showing in
/// the demo plus one knob it actually honors: [echoToConsole].
class DemoRumOptions {
  String environment = '';
  String release = '';

  /// When true, DemoRum echoes every (otherwise no-op) call to the console so
  /// you can *see* the second SDK receiving the same telemetry as Faro. A real
  /// SDK would send to its backend instead; this is the demo's stand-in for
  /// "where do signals go?".
  bool echoToConsole = true;
}

/// Entry point for the made-up RUM SDK.
class DemoRum {
  const DemoRum._();

  /// Backs [DemoRumOptions.echoToConsole]; set once from [init]. Defaults to
  /// true so calls made before/without init still surface during a demo.
  static bool _echoToConsole = true;

  static final DemoRumLogger logger = DemoRumLogger._();

  /// Initializes the SDK and then runs the app. Mirrors the
  /// `Sdk.init(configure, appRunner: ...)` shape common to Flutter RUM SDKs.
  static Future<void> init(
    void Function(DemoRumOptions options) configure, {
    required FutureOr<void> Function() appRunner,
  }) async {
    final options = DemoRumOptions();
    configure(options);
    _echoToConsole = options.echoToConsole;
    _echo('init', {
      'environment': options.environment,
      'release': options.release,
    });
    _installErrorHandlers();
    await appRunner();
  }

  /// Installs *chained* global error handlers — the real cooperative pattern a
  /// RUM SDK uses: save the handler that's already installed, run our own
  /// (here just an echo), then call the saved one so nothing downstream is
  /// swallowed. Because DemoRum inits before Faro, the resulting chain is
  /// Faro → DemoRum → Flutter default, so both SDKs observe every error. This
  /// is why init order between cooperating SDKs doesn't decide *who* captures,
  /// only who runs first.
  static void _installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      _echo('FlutterError.onError', {'exception': details.exceptionAsString()});
      previousOnError?.call(details);
    };

    final previousPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _echo('PlatformDispatcher.onError', {'exception': error.toString()});
      return previousPlatformOnError?.call(error, stack) ?? false;
    };
  }

  static bool _handlersInstalled = false;

  /// Reports a handled exception. [withScope] lets the caller attach tags /
  /// contexts / user for just this event, matching the common SDK signature.
  static void captureException(
    Object throwable, {
    StackTrace? stackTrace,
    void Function(DemoRumScope scope)? withScope,
  }) {
    final scope = DemoRumScope();
    withScope?.call(scope);
    _echo('captureException', {
      'exception': throwable.toString(),
      if (stackTrace != null) 'hasStackTrace': true,
      ...scope._snapshot(),
    });
  }

  /// Mutates the global scope (user, tags, contexts) that future signals carry.
  static void configureScope(void Function(DemoRumScope scope) configure) {
    final scope = DemoRumScope();
    configure(scope);
    _echo('configureScope', scope._snapshot());
  }

  /// Runs [body] inside a span named [name] and finishes it automatically,
  /// marking it failed if [body] throws. The body IS executed (and its result
  /// returned), so instrumenting a call site with a span never changes app
  /// behavior.
  static FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(DemoRumSpan span) body, {
    Map<String, Object> attributes = const {},
    DemoRumSpan? parentSpan,
  }) {
    final span = startInactiveSpan(
      name,
      attributes: attributes,
      parentSpan: parentSpan,
    );
    try {
      final result = body(span);
      if (result is Future<T>) {
        return result.then(
          (value) {
            span.end();
            return value;
          },
          onError: (Object error, StackTrace stackTrace) {
            span.status = DemoRumSpanStatus.error;
            span.end();
            throw error;
          },
        );
      }
      span.end();
      return result;
    } catch (_) {
      span.status = DemoRumSpanStatus.error;
      span.end();
      rethrow;
    }
  }

  /// Starts a span whose lifecycle the caller owns (must call [DemoRumSpan.end]).
  static DemoRumSpan startInactiveSpan(
    String name, {
    Map<String, Object> attributes = const {},
    DemoRumSpan? parentSpan,
  }) {
    _echo('startSpan', {'name': name, if (parentSpan != null) 'parent': parentSpan.name});
    return DemoRumSpan._(name, attributes);
  }

  static void _echo(String api, Map<String, Object?> fields) {
    if (!_echoToConsole) return;
    final details = fields.entries.map((e) => '${e.key}=${e.value}').join(', ');
    developer.log(details.isEmpty ? api : '$api($details)', name: 'DemoRum');
  }
}

/// Structured-log surface. Mirrors `sdk.logger.debug/info/warn/error(...)`.
class DemoRumLogger {
  DemoRumLogger._();

  void debug(String message, {Map<String, Object>? attributes}) =>
      DemoRum._echo('log.debug', {'message': message, ...?attributes});

  void info(String message, {Map<String, Object>? attributes}) =>
      DemoRum._echo('log.info', {'message': message, ...?attributes});

  void warn(String message, {Map<String, Object>? attributes}) =>
      DemoRum._echo('log.warn', {'message': message, ...?attributes});

  void error(String message, {Map<String, Object>? attributes}) =>
      DemoRum._echo('log.error', {'message': message, ...?attributes});
}

/// Per-event / global scope. Collects the metadata a real SDK would attach.
class DemoRumScope {
  DemoRumUser? _user;
  final Map<String, String> _tags = {};
  final Map<String, Map<String, String>> _contexts = {};

  void setUser(DemoRumUser? user) => _user = user;

  void setTag(String key, String value) => _tags[key] = value;

  void setContexts(String key, Map<String, String> context) =>
      _contexts[key] = context;

  Map<String, Object?> _snapshot() => {
    if (_user != null) 'user': _user!.id ?? _user!.email ?? _user!.username,
    if (_tags.isNotEmpty) 'tags': _tags,
    if (_contexts.isNotEmpty) 'contexts': _contexts,
  };
}

/// Identity attached to the scope.
class DemoRumUser {
  DemoRumUser({this.id, this.username, this.email, this.data});

  final String? id;
  final String? username;
  final String? email;
  final Map<String, String>? data;
}

/// A span/segment. Attributes and status are recorded (echoed); nothing is sent.
class DemoRumSpan {
  DemoRumSpan._(this.name, Map<String, Object> attributes)
    : _attributes = {...attributes};

  final String name;
  final Map<String, Object> _attributes;
  DemoRumSpanStatus status = DemoRumSpanStatus.ok;
  bool _ended = false;

  void setAttribute(String key, Object value) {
    _attributes[key] = value;
    DemoRum._echo('span.setAttribute', {'span': name, key: value});
  }

  void end() {
    if (_ended) return;
    _ended = true;
    DemoRum._echo('span.end', {'name': name, 'status': status.name});
  }
}

/// Root widget wrapper. A real SDK anchors screenshot / view-hierarchy / replay
/// capture here; the stand-in just returns its child unchanged.
class DemoRumWidget extends StatelessWidget {
  const DemoRumWidget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Navigation observer. A real SDK derives screen/transaction names from routes
/// here; the stand-in just echoes a `screen.view` for whichever route becomes
/// visible after each transition. `didRemove` and the user-gesture callbacks
/// are intentionally ignored — they rarely map to a visible screen change and
/// would only add console noise.
class DemoRumNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    // The pushed route is now on top.
    _echoScreenView(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    // `route` was popped; `previousRoute` is visible again.
    _echoScreenView(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    // `newRoute` took `oldRoute`'s place on top.
    _echoScreenView(newRoute);
  }

  void _echoScreenView(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) DemoRum._echo('screen.view', {'name': name});
  }
}

/// HTTP client wrapper. A real SDK would time the request and emit an HTTP span
/// here; the stand-in forwards to its inner client so traffic still flows (and
/// Faro's HttpOverrides underneath still does the real instrumentation).
class DemoRumHttpClient extends http.BaseClient {
  DemoRumHttpClient({required http.Client client}) : _inner = client;

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    DemoRum._echo('http', {'method': request.method, 'url': request.url.toString()});
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
