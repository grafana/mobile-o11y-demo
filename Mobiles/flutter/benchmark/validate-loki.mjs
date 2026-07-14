#!/usr/bin/env node

import { parseArgs } from 'node:util';

import { quoteLogQLString } from './lib/logql.mjs';

const { values } = parseArgs({
  options: {
    run: { type: 'string', short: 'r' },
    loki: { type: 'string', default: 'http://127.0.0.1:3100' },
    app: { type: 'string', default: 'quickpizza-flutter-local' },
    since: { type: 'string', default: '30m' },
  },
});

if (!values.run) {
  throw new Error('--run is required');
}

const durationMs = parseDuration(values.since);
const now = Date.now();
const end = now * 1_000_000;
const start = (now - durationMs) * 1_000_000;
const query = `{app_id=${quoteLogQLString(values.app)}, kind="event"} |~ "session_start|session_extend|session_resume" | logfmt | session_attr_benchmark_run_id=${quoteLogQLString(values.run)} | event_name=~"session_start|session_extend|session_resume"`;
const url = new URL('/loki/api/v1/query_range', values.loki);
url.searchParams.set('query', query);
url.searchParams.set('start', String(start));
url.searchParams.set('end', String(end));
url.searchParams.set('limit', '5000');
url.searchParams.set('direction', 'forward');

const response = await fetch(url);
if (!response.ok) {
  throw new Error(`Loki query failed with HTTP ${response.status}: ${await response.text()}`);
}
const body = await response.json();
const lines = body.data.result.flatMap((stream) => stream.values.map((value) => value[1]));
const sessions = new Set(
  lines
    .map((line) => /(?:^|\s)session_id=(?:"([^"]+)"|([^\s]+))/.exec(line))
    .filter(Boolean)
    .map((match) => match[1] ?? match[2]),
);

if (lines.length === 0 || sessions.size === 0) {
  throw new Error(`Sessions validation failed for benchmark run ${values.run}`);
}

process.stdout.write(`Sessions validation passed\n`);
process.stdout.write(`Lifecycle rows: ${lines.length}\n`);
process.stdout.write(`Unique sessions: ${sessions.size}\n`);
process.stdout.write(`Session IDs: ${[...sessions].join(', ')}\n`);

function parseDuration(value) {
  const match = /^(\d+)(s|m|h)$/.exec(value);
  if (!match) {
    throw new Error(`Invalid duration: ${value}`);
  }
  const multiplier = { s: 1_000, m: 60_000, h: 3_600_000 }[match[2]];
  return Number(match[1]) * multiplier;
}
