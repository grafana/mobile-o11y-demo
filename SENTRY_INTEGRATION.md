# Sentry/Grafault Integration Guide

This guide explains how to use the Sentry-compatible error tracking in QuickPizza with Grafault.

## Overview

QuickPizza integrates with Grafault (a Sentry-compatible error tracking backend) by sending Sentry-compatible events directly via HTTP. **No Sentry SDK is used on the backend** - all errors are sent as raw HTTP requests to the Grafault envelope API.

### Architecture

- **Backend (Go)**: Sends errors directly to Grafault via HTTP using Sentry-compatible envelope format
- **Frontend (Svelte)**: Sends errors directly to Grafault via HTTP using Sentry-compatible envelope format
- **Mobile (Flutter)**: Sends errors directly to Grafault via HTTP using Sentry-compatible envelope format

All platforms construct Sentry-compatible event payloads manually and send them to the `/api/{stack_id}/envelope/` endpoint.

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

## How Errors Are Sent

### Sentry Envelope Format

All platforms send errors using the Sentry envelope format:

```
{"event_id":"...","sent_at":"...","dsn":"...","sdk":{"name":"...","version":"..."}}
{"type":"event","content_type":"application/json"}
{"event_id":"...","timestamp":"...","platform":"...","exception":{...},"contexts":{...}}
```

### HTTP Request

Errors are sent as POST requests to:
```
{protocol}://{host}/api/{stack_id}/envelope/?sentry_key={project_token}
```

With headers:
```
Content-Type: application/x-sentry-envelope
X-Sentry-Auth: Sentry sentry_version=7, sentry_client=..., sentry_key={project_token}
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

All errors are sent **directly to Grafault via HTTP** (no SDK):

- **Backend errors**: Go code constructs Sentry-compatible envelope and sends via `net/http`
- **Frontend errors**: JavaScript/Svelte code constructs envelope and sends via `fetch()`
- **Mobile errors**: Dart/Flutter code constructs envelope and sends via `http` package

All errors include hardcoded source context:
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

**All error types include hardcoded source context** - no source maps needed!

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

## Implementation Details

### Backend (Go) - `pkg/http/http.go`

The `sendErrorToGrafault()` function:
1. Parses the DSN to extract host, stack ID, and project token
2. Builds a Sentry-compatible envelope with exception, stack trace, and source context
3. Sends via HTTP POST to the Grafault envelope endpoint

### Frontend (Svelte) - `pkg/web/src/routes/+page.svelte`

The `sendErrorDirectlyToGrafault()` function:
1. Parses the DSN from the config endpoint
2. Constructs a Sentry-compatible event with JavaScript exception details
3. Sends via `fetch()` to the Grafault envelope endpoint

### Mobile (Flutter) - `Mobiles/flutter/lib/services/sentry_with_context.dart`

The `SentryWithContext` class:
1. Parses the DSN from app configuration
2. Constructs Sentry-compatible events with Dart exception details
3. Sends via HTTP POST to the Grafault envelope endpoint

## Viewing Errors in Grafault

1. Trigger an error using the Test Error button or API
2. Open Grafault at `http://localhost:3000/a/grafana-grafault-app/errors`
3. Click on an error to see:
   - Stack trace with file paths
   - Source code context
   - Request context and tags
   - Service information

## Troubleshooting

### Errors Not Appearing in Grafault

1. Verify `SENTRY_DSN` is set correctly
2. Check that Grafault is running and accessible
3. For backend errors: Ensure `QUICKPIZZA_ENABLE_SENTRY_TEST_ENDPOINT=true`
4. Check network requests in browser dev tools (for frontend) or app logs (for mobile)

### Stack Traces Missing Source Context

All error types include hardcoded source context pointing to real files in the repository:
- **Backend errors**: `pkg/http/http.go`
- **Frontend errors**: `pkg/web/src/routes/+page.svelte`
- **Mobile errors**: `Mobiles/flutter/lib/screens/home_screen.dart`, `Mobiles/flutter/lib/services/sentry_with_context.dart`

## Why Not Use Sentry SDK?

This integration sends errors directly to Grafault without using the Sentry SDK for several reasons:

1. **Simplicity**: No SDK dependencies to manage
2. **Control**: Full control over the event payload and source context
3. **Hardcoded context**: Source context is embedded directly in the error, no source maps needed
4. **Lightweight**: No SDK initialization or configuration overhead
5. **Grafault-specific**: Tailored for Grafault's Sentry-compatible API

## Additional Resources

- [Sentry Envelope Format](https://develop.sentry.dev/sdk/envelopes/)
- [Sentry Event Payloads](https://develop.sentry.dev/sdk/event-payloads/)
- [Grafault Documentation](../hackathon-15-grafault-2_0/README.md)
