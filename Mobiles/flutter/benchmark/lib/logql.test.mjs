import assert from 'node:assert/strict';
import test from 'node:test';

import { quoteLogQLString } from './logql.mjs';

test('quotes strings for LogQL selectors and filters', () => {
  assert.equal(quoteLogQLString('run-"one"\\next\nline'), '"run-\\"one\\"\\\\next\\nline"');
});
