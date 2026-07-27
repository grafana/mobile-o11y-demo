import 'dart:developer' as developer;

import 'package:faro/faro.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo_rum/sdk/demo_rum.dart';
import '../faro/faro.dart';

final consoleO11yLoggerProvider = Provider((ref) {
  return ConsoleO11yLogger();
});

final faroO11yLoggerProvider = Provider((ref) {
  return FaroO11yLogger(faro: ref.watch(faroProvider));
});

final demoRumO11yLoggerProvider = Provider((ref) {
  return DemoRumO11yLogger();
});

final o11yLoggerProvider = Provider<O11yLogger>((ref) {
  return CompositeO11yLogger(
    delegates: [
      ref.watch(consoleO11yLoggerProvider),
      ref.watch(faroO11yLoggerProvider),
      ref.watch(demoRumO11yLoggerProvider),
    ],
  );
});

abstract class O11yLogger {
  void debug(String message, {Map<String, String>? context});
  void warning(String message, {Map<String, String>? context});
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  });
}

class CompositeO11yLogger implements O11yLogger {
  CompositeO11yLogger({required List<O11yLogger> delegates})
    : _delegates = delegates;

  final List<O11yLogger> _delegates;

  @override
  void debug(String message, {Map<String, String>? context}) {
    for (final delegate in _delegates) {
      delegate.debug(message, context: context);
    }
  }

  @override
  void warning(String message, {Map<String, String>? context}) {
    for (final delegate in _delegates) {
      delegate.warning(message, context: context);
    }
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  }) {
    for (final delegate in _delegates) {
      delegate.error(
        message,
        error: error,
        stackTrace: stackTrace,
        context: context,
      );
    }
  }
}

class ConsoleO11yLogger implements O11yLogger {
  static const _logNameDebug = 'PizzaDemo:D';
  static const _logNameWarning = 'PizzaDemo:W';
  static const _logNameError = 'PizzaDemo:E';

  String _formatContext(Map<String, String>? context) {
    if (context == null || context.isEmpty) return '';
    return ' | $context';
  }

  @override
  void debug(String message, {Map<String, String>? context}) {
    developer.log(
      '$message${_formatContext(context)}',
      name: _logNameDebug,
      level: 500,
    );
  }

  @override
  void warning(String message, {Map<String, String>? context}) {
    developer.log(
      '$message${_formatContext(context)}',
      name: _logNameWarning,
      level: 900,
    );
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  }) {
    developer.log(
      '$message${_formatContext(context)}',
      name: _logNameError,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class FaroO11yLogger implements O11yLogger {
  FaroO11yLogger({required Faro faro}) : _faro = faro;

  final Faro _faro;

  @override
  void debug(String message, {Map<String, String>? context}) {
    _faro.pushLog(message, level: LogLevel.debug, context: context);
  }

  @override
  void warning(String message, {Map<String, String>? context}) {
    _faro.pushLog(message, level: LogLevel.warn, context: context);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  }) {
    var allContext = <String, dynamic>{};
    if (context != null) {
      allContext = {...context};
    }
    if (error != null) {
      allContext = {...allContext, 'error': error.toString()};
    }
    if (stackTrace != null) {
      allContext = {...allContext, 'stackTrace': stackTrace.toString()};
    }
    _faro.pushLog(message, level: LogLevel.error, context: allContext);
  }
}

/// Routes O11y logs into the DemoRum SDK's structured Logs. Context entries
/// become attributes.
class DemoRumO11yLogger implements O11yLogger {
  static Map<String, Object> _attributes(
    Map<String, String>? context, [
    Map<String, String>? extra,
  ]) {
    final attributes = <String, Object>{};
    context?.forEach((k, v) => attributes[k] = v);
    extra?.forEach((k, v) => attributes[k] = v);
    return attributes;
  }

  @override
  void debug(String message, {Map<String, String>? context}) {
    DemoRum.logger.debug(message, attributes: _attributes(context));
  }

  @override
  void warning(String message, {Map<String, String>? context}) {
    DemoRum.logger.warn(message, attributes: _attributes(context));
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  }) {
    final extra = <String, String>{};
    if (error != null) extra['error'] = error.toString();
    if (stackTrace != null) extra['stackTrace'] = stackTrace.toString();
    DemoRum.logger.error(message, attributes: _attributes(context, extra));
  }
}
