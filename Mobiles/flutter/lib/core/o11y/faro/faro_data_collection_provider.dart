import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'faro.dart';

/// Exposes Faro's global data-collection switch (`Faro().enableDataCollection`)
/// as reactive state for the debug UI.
///
/// Unlike the URL / sample-rate overrides, this takes effect **immediately**:
/// the Faro transport checks the flag on every send. Faro also persists the
/// value across app restarts on its own (via its `DataCollectionPolicy`), so
/// there is no separate SharedPreferences plumbing here — this notifier is just
/// a thin, reactive mirror of the SDK's own state.
final faroDataCollectionProvider =
    NotifierProvider<FaroDataCollectionNotifier, bool>(
      FaroDataCollectionNotifier.new,
    );

class FaroDataCollectionNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(faroProvider).enableDataCollection;

  /// Enable or disable Faro telemetry collection live. Persisted by Faro.
  void setEnabled(bool value) {
    ref.read(faroProvider).enableDataCollection = value;
    state = value;
  }
}
