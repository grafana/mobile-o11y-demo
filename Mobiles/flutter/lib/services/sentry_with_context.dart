import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config_service.dart';

/// Error type definition with source (backend/mobile) and type
class ErrorType {
  final String value;
  final String label;
  final String source;

  const ErrorType({
    required this.value,
    required this.label,
    required this.source,
  });
}

/// Available error types for UI selection - backend and mobile errors
List<ErrorType> getAvailableErrorTypes() {
  return const [
    ErrorType(
      value: 'backend:panic',
      label: 'Backend: Panic',
      source: 'backend',
    ),
    ErrorType(
      value: 'backend:error',
      label: 'Backend: Error',
      source: 'backend',
    ),
    ErrorType(
      value: 'backend:context',
      label: 'Backend: Context',
      source: 'backend',
    ),
    ErrorType(
      value: 'mobile:TypeError',
      label: 'Mobile: TypeError',
      source: 'mobile',
    ),
    ErrorType(
      value: 'mobile:StateError',
      label: 'Mobile: StateError',
      source: 'mobile',
    ),
    ErrorType(
      value: 'mobile:RangeError',
      label: 'Mobile: RangeError',
      source: 'mobile',
    ),
  ];
}

/// Send a test error - routes to backend API or mobile direct to Grafault
Future<void> sendTestError(String errorTypeValue) async {
  final parts = errorTypeValue.split(':');
  if (parts.length != 2) {
    throw ArgumentError('Invalid error type format: $errorTypeValue');
  }

  final source = parts[0];
  final errorType = parts[1];

  if (source == 'backend') {
    await _sendBackendError(errorType);
  } else {
    await _sendMobileError(errorType);
  }
}

/// Send a test error to backend API
Future<void> _sendBackendError(String errorType) async {
  final baseUrl = ConfigService.baseUrl;
  final url = Uri.parse('$baseUrl/api/test-sentry-error?type=$errorType');

  final response = await http.get(url);

  // 500 is expected - error was captured
  if (response.statusCode != 200 && response.statusCode != 500) {
    throw Exception(
      'Failed to send error: ${response.statusCode} ${response.reasonPhrase}',
    );
  }
}

/// Mobile error templates with hardcoded source locations
/// These point to real file paths in the repository
class _MobileErrorTemplate {
  final String type;
  final String message;
  final List<Map<String, dynamic>> frames;

  const _MobileErrorTemplate({
    required this.type,
    required this.message,
    required this.frames,
  });
}

final Map<String, _MobileErrorTemplate> _mobileErrorTemplates = {
  'TypeError': _MobileErrorTemplate(
    type: 'NoSuchMethodError',
    message:
        "The method 'getUserProfile' was called on null - QuickPizza mobile error",
    frames: [
      {
        'filename': 'Mobiles/flutter/lib/screens/home_screen.dart',
        'function': '_HomeScreenState._loadUserProfile',
        'lineno': 156,
        'colno': 12,
        'in_app': true,
        'context_line': "    final profile = user.getUserProfile();",
        'pre_context': [
          "  Future<void> _loadUserProfile() async {",
          "    final user = await _apiService.getCurrentUser();",
          "    // Bug: user can be null if not logged in",
        ],
        'post_context': [
          "    setState(() => _userProfile = profile);",
          "  }",
          "",
        ],
      },
      {
        'filename': 'Mobiles/flutter/lib/screens/home_screen.dart',
        'function': '_HomeScreenState.initState',
        'lineno': 42,
        'colno': 5,
        'in_app': true,
        'context_line': "    _loadUserProfile();",
        'pre_context': [
          "  @override",
          "  void initState() {",
          "    super.initState();",
        ],
        'post_context': ["    _loadInitialData();", "  }", ""],
      },
    ],
  ),
  'StateError': _MobileErrorTemplate(
    type: 'StateError',
    message: "Bad state: No element - QuickPizza mobile error",
    frames: [
      {
        'filename': 'Mobiles/flutter/lib/services/api_service.dart',
        'function': 'ApiService.getFirstPizza',
        'lineno': 89,
        'colno': 12,
        'in_app': true,
        'context_line':
            "    return pizzaList.first; // Throws if list is empty",
        'pre_context': [
          "  Future<Pizza> getFirstPizza() async {",
          "    final pizzaList = await getPizzas();",
          "    // Bug: doesn't check if list is empty",
        ],
        'post_context': [
          "  }",
          "",
          "  Future<List<Pizza>> getPizzas() async {",
        ],
      },
      {
        'filename': 'Mobiles/flutter/lib/screens/home_screen.dart',
        'function': '_HomeScreenState._getPizza',
        'lineno': 67,
        'colno': 8,
        'in_app': true,
        'context_line':
            "        final pizza = await widget.apiService.getFirstPizza();",
        'pre_context': [
          "  Future<void> _getPizza() async {",
          "    setState(() => _isLoading = true);",
          "    try {",
        ],
        'post_context': [
          "        setState(() => _pizza = pizza);",
          "    } catch (e) {",
          "        setState(() => _errorMessage = e.toString());",
        ],
      },
    ],
  ),
  'RangeError': _MobileErrorTemplate(
    type: 'RangeError',
    message:
        "RangeError (index): Invalid value: Not in range 0..2, inclusive: 5 - QuickPizza mobile error",
    frames: [
      {
        'filename': 'Mobiles/flutter/lib/models/pizza.dart',
        'function': 'Pizza.getIngredient',
        'lineno': 34,
        'colno': 12,
        'in_app': true,
        'context_line': "    return ingredients[index]; // No bounds check",
        'pre_context': [
          "  /// Get ingredient at index",
          "  String getIngredient(int index) {",
          "    // Bug: doesn't validate index bounds",
        ],
        'post_context': [
          "  }",
          "",
          "  int get ingredientCount => ingredients.length;",
        ],
      },
      {
        'filename': 'Mobiles/flutter/lib/screens/home_screen.dart',
        'function': '_HomeScreenState._displayIngredients',
        'lineno': 234,
        'colno': 8,
        'in_app': true,
        'context_line': "        final ingredient = pizza.getIngredient(i);",
        'pre_context': [
          "  void _displayIngredients() {",
          "    // Bug: hardcoded loop count doesn't match actual ingredients",
          "    for (int i = 0; i < 5; i++) {",
        ],
        'post_context': [
          "        print('Ingredient \$i: \$ingredient');",
          "    }",
          "  }",
        ],
      },
    ],
  ),
};

/// Send mobile error directly to Grafault with hardcoded source info
Future<void> _sendMobileError(String errorType) async {
  final sentryDsn = ConfigService.sentryDsn;
  if (sentryDsn.isEmpty) {
    throw Exception('Sentry DSN not configured');
  }

  final template = _mobileErrorTemplates[errorType];
  if (template == null) {
    throw Exception('Unknown error type: $errorType');
  }

  // Parse DSN: http://token@host/stackId
  final dsnUri = Uri.parse(sentryDsn);
  final projectToken = dsnUri.userInfo;
  final host = dsnUri.host;
  final port = dsnUri.port;
  final stackId = dsnUri.path.replaceFirst('/', '');

  if (projectToken.isEmpty || stackId.isEmpty) {
    throw Exception('Invalid Sentry DSN format');
  }

  // Generate event ID (32 hex chars)
  final eventId = DateTime.now().millisecondsSinceEpoch
      .toRadixString(16)
      .padLeft(32, '0')
      .substring(0, 32);
  final timestamp = DateTime.now();

  // Build envelope header
  final header = {
    'event_id': eventId,
    'sent_at': timestamp.toIso8601String(),
    'sdk': {'name': 'sentry.dart.flutter', 'version': '8.12.0'},
    'trace': {'environment': 'development'},
  };

  // Build event data with hardcoded stack trace
  final eventData = {
    'event_id': eventId,
    'platform': 'dart',
    'timestamp': timestamp.millisecondsSinceEpoch / 1000,
    'environment': 'development',
    'release': '1.0.0',
    'exception': [
      {
        'type': template.type,
        'value': template.message,
        'stacktrace': {'frames': template.frames},
        'mechanism': {'type': 'generic', 'handled': true},
      },
    ],
    'sdk': {
      'name': 'sentry.dart.flutter',
      'version': '8.12.0',
      'integrations': ['FlutterError', 'LoadContextsIntegration'],
    },
    'tags': {
      'service.name': 'quickpizza-mobile',
      'error.source': 'mobile-test-button',
      'error.type': errorType,
    },
    'extra': {'userTriggered': true, 'timestamp': timestamp.toIso8601String()},
    'contexts': {
      'app': {'app_name': 'QuickPizza', 'app_version': '1.0.0'},
      'device': {'family': 'mobile'},
    },
  };

  // Build envelope (newline-delimited JSON)
  final envelope = [
    jsonEncode(header),
    jsonEncode({'type': 'event'}),
    jsonEncode(eventData),
  ].join('\n');

  // Send to Grafault
  final hostWithPort = port != 80 && port != 443 ? '$host:$port' : host;
  final endpoint =
      '${dsnUri.scheme}://$hostWithPort/api/$stackId/envelope/?sentry_key=$projectToken';

  final response = await http.post(
    Uri.parse(endpoint),
    headers: {
      'Content-Type': 'application/x-sentry-envelope',
      'X-Sentry-Auth':
          'Sentry sentry_version=7, sentry_client=sentry.dart.flutter/8.12.0, sentry_key=$projectToken',
    },
    body: envelope,
  );

  if (response.statusCode != 200) {
    throw Exception(
      'Failed to send error: ${response.statusCode} ${response.body}',
    );
  }
}
