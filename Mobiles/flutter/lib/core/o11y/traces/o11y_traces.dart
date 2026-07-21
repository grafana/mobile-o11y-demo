import 'dart:async';

import 'package:faro/faro.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo_rum/sdk/demo_rum.dart';
import '../faro/faro.dart';

final faroO11yTracesProvider = Provider<O11yTraces>((ref) {
  return FaroO11yTraces(faro: ref.watch(faroProvider));
});

final demoRumO11yTracesProvider = Provider<O11yTraces>((ref) {
  return DemoRumO11yTraces();
});

/// Fans span creation out to every configured RUM SDK (Faro + DemoRum) so a
/// single instrumented operation is recorded as a span in both: Faro spans →
/// Grafana Cloud tracing, DemoRum spans → wherever a real second SDK would
/// send them (here: nowhere — it's a no-op stand-in).
///
/// The two SDKs remain separate trace systems (independent trace/span IDs) —
/// we mirror the same logical span into each, we don't share a trace context
/// between them.
final o11yTracesProvider = Provider<O11yTraces>((ref) {
  return CompositeO11yTraces(
    delegates: [
      ref.watch(faroO11yTracesProvider),
      ref.watch(demoRumO11yTracesProvider),
    ],
  );
});

/// App-owned span handle. Returned by [O11yTraces] so call sites never depend
/// on a Faro (`Span`) or DemoRum (`DemoRumSpan`) type directly — the composite
/// fans each call out to whichever underlying spans exist.
abstract class O11ySpan {
  /// Sets a single attribute on the span.
  void setAttribute(String key, Object value);

  /// Marks the span as failed and records what went wrong. Both SDKs set the
  /// span status to error and remember the failure so a later [end] call with
  /// the default `ok: true` won't silently downgrade it back to OK. Faro also
  /// records the exception natively; DemoRum surfaces `exception.*` attributes
  /// (type, message, and stacktrace when provided). Does not end the span.
  void recordException(Object exception, {StackTrace? stackTrace});

  /// Finishes the span. [ok] maps to the span status; [message] is an optional
  /// status description (used by Faro).
  void end({bool ok = true, String? message});
}

/// Manual + auto span creation, abstracted over the underlying RUM SDK(s).
///
/// For Faro, parenting is automatic: any span started inside a [startSpan]
/// callback auto-parents to it (via Faro's zone context). Pass [parentSpan] —
/// an [O11ySpan] previously returned by *this same tracer* — to parent
/// explicitly instead, which is what you need when stitching spans across
/// async/zone boundaries.
abstract class O11yTraces {
  /// Runs [body] inside a span named [name] and ends it automatically. If
  /// [body] throws, the exception is recorded, the span is marked failed, and
  /// the error rethrows.
  ///
  /// For Faro the span establishes zone context, so work performed inside
  /// [body] (nested spans, auto-instrumented HTTP) auto-parents to it.
  FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(O11ySpan span) body, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  });

  /// Starts a span whose lifecycle the caller owns — you MUST call
  /// [O11ySpan.end] yourself (typically in a `finally`).
  O11ySpan startSpanManual(
    String name, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  });
}

class CompositeO11yTraces implements O11yTraces {
  CompositeO11yTraces({required List<O11yTraces> delegates})
    : _delegates = delegates;

  final List<O11yTraces> _delegates;

  /// Nests each delegate's native [startSpan] so every SDK establishes its own
  /// context around [body]:
  /// `delegate[0].startSpan(() => delegate[1].startSpan(() => ... => body))`.
  ///
  /// Faro (delegate 0, outermost) then auto-parents its nested/HTTP spans under
  /// the span it created. Each delegate's `startSpan` also owns its span's
  /// lifecycle + error status, so a thrown error propagates up through every
  /// layer and marks each SDK's span failed.
  @override
  FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(O11ySpan span) body, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return _startNested(0, name, body, attributes, parentSpan, const []);
  }

  FutureOr<T> _startNested<T>(
    int index,
    String name,
    FutureOr<T> Function(O11ySpan span) body,
    Map<String, Object> attributes,
    O11ySpan? parentSpan,
    List<O11ySpan> openSpans,
  ) {
    if (index == _delegates.length) {
      return body(CompositeO11ySpan(openSpans));
    }
    return _delegates[index].startSpan(
      name,
      (span) => _startNested(index + 1, name, body, attributes, parentSpan, [
        ...openSpans,
        span,
      ]),
      attributes: attributes,
      parentSpan: _parentForDelegate(parentSpan, index),
    );
  }

  @override
  O11ySpan startSpanManual(
    String name, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return CompositeO11ySpan([
      for (var i = 0; i < _delegates.length; i++)
        _delegates[i].startSpanManual(
          name,
          attributes: attributes,
          parentSpan: _parentForDelegate(parentSpan, i),
        ),
    ]);
  }

  /// Picks the delegate-specific parent out of a composite parent span. A
  /// [CompositeO11ySpan]'s inner spans are index-aligned with [_delegates]
  /// (both built in the same order), so delegate `i` gets sub-span `i`.
  ///
  /// Only spans created by *this same composite* compose correctly; any other
  /// [O11ySpan] yields no explicit parent, so the delegate falls back to its
  /// ambient zone parent.
  O11ySpan? _parentForDelegate(O11ySpan? parentSpan, int index) {
    return parentSpan is CompositeO11ySpan ? parentSpan.spanAt(index) : null;
  }
}

class CompositeO11ySpan implements O11ySpan {
  CompositeO11ySpan(this._spans);

  final List<O11ySpan> _spans;

  /// The underlying span for delegate [index], or null if out of range. Used by
  /// [CompositeO11yTraces] to hand each delegate its own parent span.
  O11ySpan? spanAt(int index) =>
      index >= 0 && index < _spans.length ? _spans[index] : null;

  @override
  void setAttribute(String key, Object value) {
    for (final span in _spans) {
      span.setAttribute(key, value);
    }
  }

  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {
    for (final span in _spans) {
      span.recordException(exception, stackTrace: stackTrace);
    }
  }

  @override
  void end({bool ok = true, String? message}) {
    for (final span in _spans) {
      span.end(ok: ok, message: message);
    }
  }
}

class FaroO11yTraces implements O11yTraces {
  FaroO11yTraces({required Faro faro}) : _faro = faro;

  final Faro _faro;

  /// Uses Faro's native [Faro.startSpan] so the body runs inside Faro's zone
  /// context: the span is registered as active, so nested spans and Faro's HTTP
  /// auto-instrumentation auto-parent to it, and it's auto-ended (status/
  /// exception handled by Faro).
  @override
  FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(O11ySpan span) body, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return _faro.startSpan(
      name,
      (faroSpan) => body(FaroO11ySpan(faroSpan)),
      attributes: attributes,
      parentSpan: _faroParent(parentSpan),
    );
  }

  @override
  O11ySpan startSpanManual(
    String name, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return FaroO11ySpan(
      _faro.startSpanManual(
        name,
        attributes: attributes,
        parentSpan: _faroParent(parentSpan),
      ),
    );
  }

  /// Faro resolves `parentSpan ?? getActiveSpan()`, so returning null for a
  /// missing/foreign parent correctly falls back to the ambient zone span.
  Span? _faroParent(O11ySpan? parentSpan) =>
      parentSpan is FaroO11ySpan ? parentSpan.span : null;
}

class FaroO11ySpan implements O11ySpan {
  FaroO11ySpan(this._span);

  final Span _span;

  /// Set once [recordException] runs so [end] preserves the failure even when
  /// called with the default `ok: true`.
  bool _failed = false;

  /// The wrapped Faro span, so [FaroO11yTraces] can use it as an explicit
  /// parent for a child span.
  Span get span => _span;

  @override
  void setAttribute(String key, Object value) =>
      _span.setAttribute(key, value);

  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {
    _failed = true;
    _span.recordException(exception, stackTrace: stackTrace);
    // Faro auto-sets error status only in its startSpan(callback) flow when the
    // body throws (via SpanExceptionOptions). Faro's Span.recordException() —
    // the method we call on _span above — only records the exception event and
    // leaves status untouched, so set it explicitly to cover manual spans and
    // record-without-throw cases.
    _span.setStatus(SpanStatusCode.error, message: exception.toString());
  }

  @override
  void end({bool ok = true, String? message}) {
    final isError = _failed || !ok;
    _span.setStatus(
      isError ? SpanStatusCode.error : SpanStatusCode.ok,
      message: message,
    );
    _span.end();
  }
}

class DemoRumO11yTraces implements O11yTraces {
  @override
  FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(O11ySpan span) body, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return DemoRum.startSpan<T>(
      name,
      (span) => body(DemoRumO11ySpan(span)),
      attributes: attributes,
      parentSpan: _demoRumParent(parentSpan),
    );
  }

  @override
  O11ySpan startSpanManual(
    String name, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    return DemoRumO11ySpan(
      DemoRum.startInactiveSpan(
        name,
        attributes: attributes,
        parentSpan: _demoRumParent(parentSpan),
      ),
    );
  }

  DemoRumSpan? _demoRumParent(O11ySpan? parentSpan) =>
      parentSpan is DemoRumO11ySpan ? parentSpan.span : null;
}

class DemoRumO11ySpan implements O11ySpan {
  DemoRumO11ySpan(this._span);

  final DemoRumSpan _span;

  /// Set once [recordException] runs so [end] preserves the failure even when
  /// called with the default `ok: true`.
  bool _failed = false;

  /// The wrapped DemoRum span, so [DemoRumO11yTraces] can use it as an explicit
  /// parent for a child span.
  DemoRumSpan get span => _span;

  @override
  void setAttribute(String key, Object value) =>
      _span.setAttribute(key, value);

  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {
    _failed = true;
    _span.status = DemoRumSpanStatus.error;
    _span.setAttribute('exception.type', exception.runtimeType.toString());
    _span.setAttribute('exception.message', exception.toString());
    if (stackTrace != null) {
      _span.setAttribute('exception.stacktrace', stackTrace.toString());
    }
  }

  @override
  void end({bool ok = true, String? message}) {
    _span.status = (_failed || !ok)
        ? DemoRumSpanStatus.error
        : DemoRumSpanStatus.ok;
    _span.end();
  }
}
