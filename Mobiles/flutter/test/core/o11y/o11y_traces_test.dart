import 'dart:async';

import 'package:flutter_mobile_o11y_demo/core/o11y/traces/o11y_traces.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the parent it was handed so we can assert the composite distributes
/// each delegate its own sub-span.
class _RecordedCall {
  _RecordedCall(this.name, this.parent);
  final String name;
  final O11ySpan? parent;
}

class _FakeSpan implements O11ySpan {
  _FakeSpan(this.name);
  final String name;
  bool ended = false;

  @override
  void setAttribute(String key, Object value) {}

  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {}

  @override
  void end({bool ok = true, String? message}) => ended = true;
}

class _FakeTraces implements O11yTraces {
  final List<_RecordedCall> manualCalls = [];
  final List<_RecordedCall> spanCalls = [];

  @override
  FutureOr<T> startSpan<T>(
    String name,
    FutureOr<T> Function(O11ySpan span) body, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) async {
    spanCalls.add(_RecordedCall(name, parentSpan));
    final span = _FakeSpan(name);
    try {
      return await body(span);
    } finally {
      span.end();
    }
  }

  @override
  O11ySpan startSpanManual(
    String name, {
    Map<String, Object> attributes = const {},
    O11ySpan? parentSpan,
  }) {
    manualCalls.add(_RecordedCall(name, parentSpan));
    return _FakeSpan(name);
  }
}

void main() {
  group('CompositeO11yTraces parent distribution', () {
    late _FakeTraces faro;
    late _FakeTraces demoRum;
    late CompositeO11yTraces composite;

    setUp(() {
      faro = _FakeTraces();
      demoRum = _FakeTraces();
      composite = CompositeO11yTraces(delegates: [faro, demoRum]);
    });

    test('startSpanManual with no parent passes null to every delegate', () {
      composite.startSpanManual('root');

      expect(faro.manualCalls.single.parent, isNull);
      expect(demoRum.manualCalls.single.parent, isNull);
    });

    test('startSpanManual hands each delegate its own sub-span of the '
        'composite parent', () {
      final parent = composite.startSpanManual('parent') as CompositeO11ySpan;

      composite.startSpanManual('child', parentSpan: parent);

      // Child call is the 2nd manual call on each delegate.
      expect(faro.manualCalls[1].parent, same(parent.spanAt(0)));
      expect(demoRum.manualCalls[1].parent, same(parent.spanAt(1)));
    });

    test('startSpan hands each delegate its own sub-span of the composite '
        'parent', () async {
      final parent = composite.startSpanManual('parent') as CompositeO11ySpan;

      await composite.startSpan('child', (_) async {}, parentSpan: parent);

      expect(faro.spanCalls.single.parent, same(parent.spanAt(0)));
      expect(demoRum.spanCalls.single.parent, same(parent.spanAt(1)));
    });

    test('a foreign (non-composite) parent yields no explicit parent', () {
      composite.startSpanManual('child', parentSpan: _FakeSpan('foreign'));

      expect(faro.manualCalls.single.parent, isNull);
      expect(demoRum.manualCalls.single.parent, isNull);
    });
  });
}
