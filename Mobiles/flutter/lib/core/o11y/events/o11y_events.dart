import 'package:faro/faro.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo_rum/sdk/demo_rum.dart';
import '../faro/faro.dart';

final faroO11yEventsProvider = Provider<O11yEvents>((ref) {
  return FaroO11yEvents(faro: ref.watch(faroProvider));
});

final demoRumO11yEventsProvider = Provider<O11yEvents>((ref) {
  return DemoRumO11yEvents();
});

/// Fans custom events and user identity out to every configured RUM SDK.
final o11yEventsProvider = Provider<O11yEvents>((ref) {
  return CompositeO11yEvents(
    delegates: [
      ref.watch(faroO11yEventsProvider),
      ref.watch(demoRumO11yEventsProvider),
    ],
  );
});

abstract class O11yEvents {
  void trackEvent(String name, {Map<String, String>? context});

  void setUser({
    String? id,
    String? name,
    String? email,
    Map<String, String>? attributes,
  });
}

class CompositeO11yEvents implements O11yEvents {
  CompositeO11yEvents({required List<O11yEvents> delegates})
    : _delegates = delegates;

  final List<O11yEvents> _delegates;

  @override
  void trackEvent(String name, {Map<String, String>? context}) {
    for (final delegate in _delegates) {
      delegate.trackEvent(name, context: context);
    }
  }

  @override
  void setUser({
    String? id,
    String? name,
    String? email,
    Map<String, String>? attributes,
  }) {
    for (final delegate in _delegates) {
      delegate.setUser(
        id: id,
        name: name,
        email: email,
        attributes: attributes,
      );
    }
  }
}

class FaroO11yEvents implements O11yEvents {
  FaroO11yEvents({required Faro faro}) : _faro = faro;

  final Faro _faro;

  @override
  void trackEvent(String name, {Map<String, String>? context}) {
    _faro.pushEvent(name, attributes: context);
  }

  @override
  void setUser({
    String? id,
    String? name,
    String? email,
    Map<String, String>? attributes,
  }) {
    final user =
        id == null && name == null && email == null && attributes == null
        ? FaroUser.cleared()
          : FaroUser(
            id: id,
            username: name,
            email: email,
            attributes: attributes,
          );
    _faro.setUser(user);
  }
}

/// Many RUM SDKs have no first-class custom-event stream like Faro, so we
/// route [trackEvent] into the SDK's structured Logs. The
/// `telemetry.type=event` attribute keeps these separable from real logs
/// emitted by [DemoRumO11yLogger]. [setUser] maps to the SDK scope user.
class DemoRumO11yEvents implements O11yEvents {
  @override
  void trackEvent(String name, {Map<String, String>? context}) {
    final attributes = <String, Object>{
      'telemetry.type': 'event',
      'event.name': name,
    };
    context?.forEach((k, v) => attributes[k] = v);
    DemoRum.logger.info(name, attributes: attributes);
  }

  @override
  void setUser({
    String? id,
    String? name,
    String? email,
    Map<String, String>? attributes,
  }) {
    // Clear the scope user when no identifier is provided (matches
    // FaroUser.cleared() semantics).
    final hasIdentity = id != null || name != null || email != null;
    DemoRum.configureScope((scope) {
      scope.setUser(
        hasIdentity
            ? DemoRumUser(
                id: id,
                username: name,
                email: email,
                data: attributes,
              )
            : null,
      );
    });
  }
}
