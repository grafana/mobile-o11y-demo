# Sentry/Grafault Integration Guide

This guide explains how to use the Sentry-compatible error tracking in QuickPizza with Grafault.

## Overview

QuickPizza integrates with Grafault (a Sentry-compatible error tracking backend) through:
- **Backend errors**: Via a test endpoint that sends errors directly to Grafault
- **Frontend errors (Svelte)**: Via the Sentry JavaScript SDK
- **Mobile errors (Flutter)**: Via the Sentry Flutter SDK

## Configuration

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `SENTRY_DSN` | Grafault/Sentry DSN URL | `http://token@localhost:8080/5739` |
| `SENTRY_ENVIRONMENT` | Environment name | `development` |
| `SENTRY_RELEASE` | Release version | `1.0.0` |
| `QUICKPIZZA_ENABLE_SENTRY_TEST_ENDPOINT` | Enable test endpoint | `true` |

### Docker Compose Configuration

In your `.env` file:
```bash
SENTRY_DSN=http://your-token@localhost:8080/your-stack-id
SENTRY_ENVIRONMENT=development
SENTRY_RELEASE=1.0.0
QUICKPIZZA_ENABLE_SENTRY_TEST_ENDPOINT=true
```

## Test Error Button

Both the web app and mobile app have a unified **"Test Error"** button that allows you to trigger different types of errors:

### Available Error Types

| Error Type | Source | Description |
|------------|--------|-------------|
| `Backend: Panic` | Go backend | Simulates a panic error |
| `Backend: Error` | Go backend | Simulates a runtime error |
| `Backend: Context` | Go backend | Error with rich context |
| `Frontend: TypeError` | Svelte/JS | Real JavaScript TypeError |
| `Frontend: ReferenceError` | Svelte/JS | Real JavaScript ReferenceError |
| `Frontend: RangeError` | Svelte/JS | Real JavaScript RangeError |
| `Mobile: TypeError` | Flutter/Dart | Real Dart TypeError |
| `Mobile: StateError` | Flutter/Dart | Real Dart StateError |
| `Mobile: RangeError` | Flutter/Dart | Real Dart RangeError |

### How It Works

- **Backend errors**: Sent directly to Grafault via HTTP with hardcoded Go source context
- **Frontend errors**: Sent directly to Grafault via HTTP with hardcoded Svelte/JS source context
- **Mobile errors**: Sent directly to Grafault via HTTP with hardcoded Flutter/Dart source context

All errors include:
- Real file paths from the repository
- Actual line numbers
- Function names
- Pre/post context lines (code snippets around the error)

### Clicking Stack Traces in Grafault

When you view an error in Grafault:
1. Click on the error to see the stack trace
2. Each frame shows:
   - **File path**: Real path in the repository (e.g., `pkg/web/src/routes/+page.svelte`)
   - **Line number**: Exact line where the error occurred
   - **Function name**: The function containing the error
   - **Source context**: Pre/post context lines around the error
3. Click on a file path to navigate to that line in your code

**All error types now include hardcoded source context** - no source maps needed!

## Backend Test Endpoint

### Enable the Endpoint

```bash
QUICKPIZZA_ENABLE_SENTRY_TEST_ENDPOINT=true
```

### Direct API Usage

```bash
# Panic error
curl http://localhost:3333/api/test-sentry-error?type=panic

# Runtime error
curl http://localhost:3333/api/test-sentry-error?type=error

# Error with context
curl http://localhost:3333/api/test-sentry-error?type=context
```

## Viewing Errors in Grafault

1. Trigger an error using the Test Error button or API
2. Open Grafault at `http://localhost:3000/a/grafana-grafault-app/errors`
3. Click on an error to see:
   - Stack trace with file paths
   - Source code context (for backend errors)
   - Request context and tags
   - Service information

## Troubleshooting

### Errors Not Appearing in Grafault

1. Verify `SENTRY_DSN` is set correctly
2. Check that Grafault is running and accessible
3. For backend errors: Ensure `QUICKPIZZA_ENABLE_SENTRY_TEST_ENDPOINT=true`
4. For frontend/mobile errors: Check browser/app console for Sentry initialization

### Stack Traces Missing Source Context

All error types now include hardcoded source context pointing to real files in the repository:
- **Backend errors**: `pkg/http/http.go`
- **Frontend errors**: `pkg/web/src/routes/+page.svelte`
- **Mobile errors**: `Mobiles/flutter/lib/screens/home_screen.dart`, `Mobiles/flutter/lib/services/api_service.dart`

## Additional Resources

- [Sentry JavaScript SDK](https://docs.sentry.io/platforms/javascript/)
- [Sentry Flutter SDK](https://docs.sentry.io/platforms/flutter/)
- [Grafault Documentation](../hackathon-15-grafault-2_0/README.md)
