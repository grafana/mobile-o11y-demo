import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';

const run = path.resolve(process.argv[2]);
const appID = process.argv[3];
assert.match(appID, /^\d+$/);
const source = JSON.parse(readFileSync(path.join(run, 'result.json')));
assert.equal(source.status, 'passed');
const attrs = list => Object.fromEntries((list || []).map(a => [a.key, Object.values(a.value)[0]]));
const expectedLogs = [], expectedSpans = [];
for (const line of readFileSync(path.join(run, 'telemetry.jsonl'), 'utf8').trim().split('\n')) {
  const envelope = JSON.parse(line);
  for (const resource of envelope.resourceLogs || []) {
    for (const scope of resource.scopeLogs || []) expectedLogs.push(...scope.logRecords);
  }
  for (const resource of envelope.resourceSpans || []) {
    for (const scope of resource.scopeSpans || []) expectedSpans.push(...scope.spans);
  }
}
assert(expectedLogs.length > 0 && expectedSpans.length > 0);
if (source.simulator) {
  assert.equal(source.processes, 8);
  assert.equal(expectedLogs.length, 25, 'Expected logs plus session start/end events');
  assert.equal(expectedSpans.length, 25, 'Expected manual, retained and automatic spans');
  assert.equal(expectedLogs.filter(x => x.eventName === 'session.start').length, 7);
  assert.equal(expectedLogs.filter(x => x.eventName === 'session.end').length, 4);
}
const expectedFetches = expectedSpans.filter(x => attrs(x.attributes)['url.full']);
const sessions = new Set(expectedLogs.map(x => attrs(x.attributes)['session.id']));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function get(url) {
  const response = await fetch(url, {headers: {Accept: 'application/json'}, signal: AbortSignal.timeout(10000)});
  assert(response.ok, `${response.status}: ${url}`);
  return response.json();
}
const url = new URL('http://127.0.0.1:13100/loki/api/v1/query_range');
url.searchParams.set('query', `{app_id="${appID}"} | logfmt`);
url.searchParams.set('limit', '5000');
url.searchParams.set('direction', 'forward');
const first = expectedLogs.reduce((a, x) => BigInt(x.timeUnixNano) < a ? BigInt(x.timeUnixNano) : a,
  BigInt(expectedLogs[0].timeUnixNano));
url.searchParams.set('start', String(first - 5_000_000_000n));
let loki, logs;
for (let i = 0; i < 40; i++) {
  url.searchParams.set('end', String(BigInt(Date.now()) * 1_000_000n));
  loki = await get(url);
  logs = loki.data.result.flatMap(({stream, values}) => values.map(([time, body]) => ({fields: stream, time, body})))
    .filter(x => sessions.has(x.fields.session_id));
  if (logs.length >= expectedLogs.length + expectedFetches.length) break;
  await sleep(1000);
}
writeFileSync(path.join(run, 'loki.json'), JSON.stringify(loki, null, 2));
const spans = [], traces = {};
const hex = (value, length) => new RegExp(`^[a-f0-9]{${length}}$`).test(value) ? value : Buffer.from(value, 'base64').toString('hex');
for (const id of new Set(expectedSpans.map(x => x.traceId))) {
  const trace = await get(`http://127.0.0.1:13200/api/traces/${id}`);
  traces[id] = trace;
  for (const batch of trace.batches || trace.resourceSpans || []) {
    for (const scope of batch.scopeSpans || []) {
      for (const span of scope.spans || []) spans.push({...span, traceId: hex(span.traceId, 32), spanId: hex(span.spanId, 16)});
    }
  }
}
writeFileSync(path.join(run, 'tempo.json'), JSON.stringify(traces, null, 2));
function verify(logs, spans) {
  assert.equal(logs.length, expectedLogs.length + expectedFetches.length, 'No missing or duplicate backend logs/events');
  assert.equal(spans.length, expectedSpans.length, 'No missing or duplicate backend spans');
  const fetches = logs.filter(x => x.fields.event_name === 'faro.tracing.fetch');
  assert.equal(fetches.length, expectedFetches.length, 'One derived fetch event per accepted HTTP span');
  for (const expected of expectedFetches) {
    const a = attrs(expected.attributes);
    const matches = fetches.filter(x => x.fields.traceID === expected.traceId && x.fields.spanID === expected.spanId);
    assert.equal(matches.length, 1, 'Derived fetch preserves trace context');
    const f = matches[0].fields;
    assert.equal(f.session_id, a['session.id']);
    assert.equal(f.event_data_http_url, a['url.full']);
    assert.equal(f.event_data_http_method, a['http.request.method']);
    assert.equal(f.event_data_http_status_code, String(a['http.response.status_code']));
    assert.equal(f.event_data_duration_ns, String(BigInt(expected.endTimeUnixNano) - BigInt(expected.startTimeUnixNano)));
    assert.equal(Date.parse(f.timestamp), Number(BigInt(expected.startTimeUnixNano) / 1_000_000n));
    assert.equal(f.is_mobile, 'true');
  }
  for (const expected of expectedLogs) {
    const attributes = attrs(expected.attributes);
    const event = expected.eventName === 'session.start' ? 'session_start' : expected.eventName;
    const matches = logs.filter(({fields}) => fields.session_id === attributes['session.id'] &&
      (event ? fields.event_name === event : fields.message === expected.body.stringValue) &&
      Date.parse(fields.timestamp) === Number(BigInt(expected.timeUnixNano) / 1_000_000n));
    assert.equal(matches.length, 1, `Stored log/event ${event || expected.body?.stringValue}`);
    const field = event ? 'event_data_session_previous_id' : 'context_session_previous_id';
    assert.equal(matches[0].fields[field], attributes['session.previous_id']);
    assert.equal(matches[0].fields.is_mobile, 'true');
  }
  for (const expected of expectedSpans) {
    const matches = spans.filter(x => x.traceId === expected.traceId && x.spanId === expected.spanId);
    assert.equal(matches.length, 1, `Stored span ${expected.name}`);
    const actual = matches[0];
    assert.equal(actual.name, expected.name);
    assert.equal(actual.startTimeUnixNano, expected.startTimeUnixNano);
    assert.equal(actual.endTimeUnixNano, expected.endTimeUnixNano);
    for (const key of ['session.id', 'session.previous_id']) assert.equal(attrs(actual.attributes)[key], attrs(expected.attributes)[key]);
  }
}
verify(logs, spans);
const mutations = [
  ['missing log', (l) => l.pop()],
  ['duplicate log', (l) => l.push(l[0])],
  ['wrong session', (l) => {l[0].fields.session_id = 'wrong';}],
  ['missing span', (_, s) => s.pop()],
  ['wrong derived fetch session', (l) => {l.find(x => x.fields.event_name === 'faro.tracing.fetch').fields.session_id = 'wrong';}],
  ['wrong derived fetch trace', (l) => {l.find(x => x.fields.event_name === 'faro.tracing.fetch').fields.traceID = 'wrong';}],
  ['wrong span attribution', (_, s) => {s[0].attributes.find(a => a.key === 'session.id').value.stringValue = 'wrong';}],
  ['lost previous link', (l) => {
    const row = l.find(x => x.fields.context_session_previous_id);
    assert(row); delete row.fields.context_session_previous_id;
  }],
];
for (const [name, mutate] of mutations) {
  const l = structuredClone(logs), s = structuredClone(spans);
  mutate(l, s);
  assert.throws(() => verify(l, s), undefined, `Verifier missed ${name}`);
}
const result = {status: 'passed', sdk: source.sdk, run: source.run, logs: logs.length, spans: spans.length,
  sessions: sessions.size, mutationsCaught: mutations.map(x => x[0]),
  route: 'Grafana package -> Alloy -> local Faro (session accounting enabled) -> Loki/Tempo'};
writeFileSync(path.join(run, 'backend-verification.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
