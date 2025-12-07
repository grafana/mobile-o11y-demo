import 'package:faro/faro.dart';
import 'package:flutter_mobile_o11y_demo/core/application_layer/o11y/faro/faro.dart';

class O11yMetrics {
  O11yMetrics() : _faro = faro;

  final Faro _faro;

  void addMeasurement(String name, Map<String, dynamic> values) {
    // Separate numeric values from string metadata
    // The backend expects only numeric (float64) values in measurements.values
    final numericValues = <String, dynamic>{};

    for (final entry in values.entries) {
      final value = entry.value;
      // Only include numeric types (int, double, num)
      if (value is num) {
        numericValues[entry.key] = value;
      }
      // Skip string values as they cause "expected float64, got string" errors
    }

    if (numericValues.isNotEmpty) {
      _faro.pushMeasurement(numericValues, name);
    }
  }
}

final o11yMetrics = O11yMetrics();
