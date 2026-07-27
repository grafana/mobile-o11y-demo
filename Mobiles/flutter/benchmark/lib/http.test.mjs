import assert from 'node:assert/strict';
import test from 'node:test';

import { isCollectorRequest } from './http.mjs';

test('accepts Faro collector POST requests', () => {
  assert.equal(isCollectorRequest('POST', '/collect'), true);
  assert.equal(isCollectorRequest('POST', '/collect/local-benchmark-key'), true);
  assert.equal(isCollectorRequest('POST', '/collect/local-benchmark-key?source=test'), true);
});

test('rejects unrelated paths and methods', () => {
  assert.equal(isCollectorRequest('GET', '/collect/local-benchmark-key'), false);
  assert.equal(isCollectorRequest('POST', '/health'), false);
  assert.equal(isCollectorRequest('POST', '/collector'), false);
});
