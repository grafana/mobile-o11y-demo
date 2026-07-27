import 'package:faro/faro.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo_rum/sdk/demo_rum.dart';
import '../faro/faro.dart';

final faroO11yErrorsProvider = Provider<O11yErrors>((ref) {
  return FaroO11yErrors(faro: ref.watch(faroProvider));
});

final demoRumO11yErrorsProvider = Provider<O11yErrors>((ref) {
  return DemoRumO11yErrors();
});

/// Fans manual error reports out to every configured RUM SDK (Faro +
/// DemoRum) so both receive the same handled exceptions.
final o11yErrorsProvider = Provider<O11yErrors>((ref) {
  return CompositeO11yErrors(
    delegates: [
      ref.watch(faroO11yErrorsProvider),
      ref.watch(demoRumO11yErrorsProvider),
    ],
  );
});

abstract class O11yErrors {
  void reportError({
    required String type,
    required String error,
    StackTrace? stacktrace,
    Map<String, String>? context,
  });
}

/// Wraps a synthesized manual error so an SDK has a throwable to capture.
/// The caller's [type] is surfaced as a tag (`o11y.error_type`) since the
/// exception type is fixed to this class.
class O11yReportedException implements Exception {
  O11yReportedException({required this.type, required this.value});

  final String type;
  final String value;

  @override
  String toString() => '$type: $value';
}

class CompositeO11yErrors implements O11yErrors {
  CompositeO11yErrors({required List<O11yErrors> delegates})
    : _delegates = delegates;

  final List<O11yErrors> _delegates;

  @override
  void reportError({
    required String type,
    required String error,
    StackTrace? stacktrace,
    Map<String, String>? context,
  }) {
    for (final delegate in _delegates) {
      delegate.reportError(
        type: type,
        error: error,
        stacktrace: stacktrace,
        context: context,
      );
    }
  }
}

class FaroO11yErrors implements O11yErrors {
  FaroO11yErrors({required Faro faro}) : _faro = faro;

  final Faro _faro;

  @override
  void reportError({
    required String type,
    required String error,
    StackTrace? stacktrace,
    Map<String, String>? context,
  }) {
    _faro.pushError(
      type: type,
      value: error,
      stacktrace: stacktrace,
      context: context,
    );
  }
}

class DemoRumO11yErrors implements O11yErrors {
  @override
  void reportError({
    required String type,
    required String error,
    StackTrace? stacktrace,
    Map<String, String>? context,
  }) {
    DemoRum.captureException(
      O11yReportedException(type: type, value: error),
      stackTrace: stacktrace,
      withScope: (scope) {
        scope.setTag('o11y.error_type', type);
        if (context != null && context.isNotEmpty) {
          scope.setContexts('o11y', context);
        }
      },
    );
  }
}
