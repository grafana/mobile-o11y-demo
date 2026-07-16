import assert from 'node:assert/strict';
import test from 'node:test';

import {
  countPayloadItems,
  findSensitiveValues,
  prepareReplayPayloads,
  sanitizePayload,
} from './telemetry.mjs';

function fixture() {
  return {
    meta: {
      app: { version: '1.1.1', installationId: 'install-original' },
      sdk: { version: '0.17.0-beta.1' },
      session: {
        id: 'session-original',
        attributes: { device_id: 'device-original', device_model: 'iPhone' },
      },
      user: { id: 'user-original', username: 'default', email: 'person@example.com' },
    },
    events: [
      {
        name: 'session_start',
        timestamp: '2026-07-14T12:00:00.000Z',
        trace: { traceId: '0123456789abcdef0123456789abcdef', spanId: '0123456789abcdef' },
      },
      {
        name: 'faro.user.action',
        timestamp: '2026-07-14T12:00:05.000Z',
        action: { id: 'action-original', name: 'request pizza' },
      },
    ],
    measurements: [],
    logs: [],
    exceptions: [],
    traces: {
      resourceSpans: [
        {
          resource: {
            attributes: [
              { key: 'device_id', value: { stringValue: 'device-original' } },
            ],
          },
          scopeSpans: [
            {
              spans: [
                {
                  traceId: '0123456789abcdef0123456789abcdef',
                  spanId: '0123456789abcdef',
                  attributes: [
                    { key: 'session.id', value: { stringValue: 'session-original' } },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  };
}

test('sanitizes identifying user and installation fields', () => {
  const sanitized = sanitizePayload(fixture());
  assert.equal(sanitized.meta.user.id, 'benchmark-source-user');
  assert.equal(sanitized.meta.user.email, 'benchmark@example.invalid');
  assert.equal(sanitized.meta.app.installationId, 'benchmark-source-installation');
  assert.equal(sanitized.meta.session.attributes.device_id, 'benchmark-source-device');
  assert.equal(
    sanitized.traces.resourceSpans[0].resource.attributes[0].value.stringValue,
    'benchmark-source-device',
  );
  assert.deepEqual(findSensitiveValues(sanitized), []);
});

test('preserves item counts and relative time while remapping correlated IDs', () => {
  const source = sanitizePayload(fixture());
  const sourceCounts = countPayloadItems(source);
  const prepared = prepareReplayPayloads([source], {
    runId: 'run-20260714-1',
    startTime: '2026-07-14T13:00:00.000Z',
  });
  const replay = prepared.payloads[0];

  assert.deepEqual(countPayloadItems(replay), sourceCounts);
  assert.equal(replay.events[0].timestamp, '2026-07-14T13:00:00.000Z');
  assert.equal(replay.events[1].timestamp, '2026-07-14T13:00:05.000Z');
  assert.notEqual(replay.meta.session.id, source.meta.session.id);
  assert.notEqual(
    replay.meta.session.attributes.device_id,
    source.meta.session.attributes.device_id,
  );
  assert.notEqual(replay.events[0].trace.traceId, source.events[0].trace.traceId);
  assert.equal(replay.events[0].trace.traceId.length, 32);
  assert.equal(replay.meta.session.attributes.benchmark_run_id, 'run-20260714-1');
  assert.equal(replay.meta.app.version, source.meta.app.version);
  assert.equal(replay.meta.sdk.version, source.meta.sdk.version);
  assert.equal(
    replay.traces.resourceSpans[0].scopeSpans[0].spans[0].attributes[0].value.stringValue,
    replay.meta.session.id,
  );
  assert.equal(
    replay.traces.resourceSpans[0].resource.attributes[0].value.stringValue,
    replay.meta.session.attributes.device_id,
  );
});

test('uses one mapping for repeated correlated IDs', () => {
  const source = sanitizePayload(fixture());
  source.events[1].attributes = { session_id: source.meta.session.id };
  const { payloads } = prepareReplayPayloads([source], { runId: 'run-consistent' });
  assert.equal(payloads[0].meta.session.id, payloads[0].events[1].attributes.session_id);
});
