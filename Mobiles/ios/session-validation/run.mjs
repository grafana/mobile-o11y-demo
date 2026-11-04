import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { createInterface } from 'node:readline';
import { mkdirSync, readFileSync, writeFileSync, appendFileSync, existsSync, renameSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const run = randomUUID();
const output = path.join(root, `run-${run}`);
mkdirSync(output);
const capture = path.join(output, 'telemetry.jsonl');
const binary = process.argv[2];
assert(binary && existsSync(binary), 'Pass the built Session99Probe executable');
const simulator = process.env.SESSION99_SIMULATOR;
const bundle = 'net.local.varanha.session99';
const faro = process.env.SESSION99_FARO_ENDPOINT;
if (faro) assert.equal(new URL(faro).hostname, '127.0.0.1', 'Only a local test collector is allowed');
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
if (simulator) simctl('install', simulator, binary);
const children = new Set();
const servers = [];
let offline = false;
let failedUploads = 0;
const requests = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function listen(handler) {
  const server = createServer(handler);
  servers.push(server);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server.address().port;
}

async function until(fn, label, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await fn()) return;
    await sleep(100);
  }
  throw new Error(`Timed out: ${label}`);
}

function start(executable, args, name) {
  const child = spawn(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(child);
  child.on('error', error => appendFileSync(path.join(output, `${name}.log`), String(error)));
  child.stderr.on('data', bytes => appendFileSync(path.join(output, `${name}.log`), bytes));
  child.stdout.on('data', bytes => appendFileSync(path.join(output, `${name}.log`), bytes));
  child.closed = once(child, 'close');
  return child;
}

const attributes = values => Object.fromEntries((values || []).map(a => [a.key, a.value.stringValue ?? a.value.intValue]));
function records() {
  if (!existsSync(capture)) return [];
  const text = readFileSync(capture, 'utf8');
  return text.slice(0, text.lastIndexOf('\n') + 1).split('\n').filter(Boolean).flatMap(line => {
    const data = JSON.parse(line);
    return [['resourceSpans', 'scopeSpans', 'spans', 'trace'], ['resourceLogs', 'scopeLogs', 'logRecords', 'log']]
      .flatMap(([r, s, items, kind]) => (data[r] || []).flatMap(resource => (resource[s] || []).flatMap(scope =>
        (scope[items] || []).map(item => ({kind, scope: scope.scope?.name, name: item.name ?? item.body?.stringValue,
          event: item.eventName, attrs: attributes(item.attributes), trace: item.traceId, span: item.spanId})))));
  });
}

function matching(name, kind) { return records().filter(row => row.name === name && row.kind === kind); }
function expect(name, kind, session, count = 1) {
  const matches = matching(name, kind);
  assert.equal(matches.length, count, `${kind} ${name}`);
  for (const row of matches) assert.equal(row.attrs['session.id'], session, `${name} original session`);
}

try {
  // Reserve a free local port, then hand it to Alloy. A bind collision fails the readiness check.
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const alloyPort = reservation.address().port;
  const adminReservation = createServer();
  adminReservation.listen(0, '127.0.0.1');
  await once(adminReservation, 'listening');
  const adminPort = adminReservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  await new Promise(resolve => adminReservation.close(resolve));
  const config = path.join(output, 'collector.alloy');
  writeFileSync(config, `otelcol.receiver.otlp "probe" {
    http { endpoint = "127.0.0.1:${alloyPort}" }
    output { logs = [otelcol.exporter.file.probe.input${faro ? ', otelcol.exporter.otlphttp.faro.input' : ''}]
             traces = [otelcol.exporter.file.probe.input${faro ? ', otelcol.exporter.otlphttp.faro.input' : ''}] }
  }
  otelcol.exporter.file "probe" {
    path = ${JSON.stringify(capture)}
    format = "json"
    flush_interval = "100ms"
  }
  ${faro ? `otelcol.exporter.otlphttp "faro" {
    client { endpoint = ${JSON.stringify(faro)} }
    sending_queue { enabled = false }
    retry_on_failure { enabled = false }
  }` : ''}`);
  const alloy = start('/opt/homebrew/bin/alloy', ['run', '--stability.level=experimental',
    `--server.http.listen-addr=127.0.0.1:${adminPort}`, `--storage.path=${output}/alloy`, config], 'alloy');
  await until(async () => {
    assert.equal(alloy.exitCode, null, 'Alloy exited');
    try { await fetch(`http://127.0.0.1:${alloyPort}/v1/traces`); return true; } catch { return false; }
  }, 'Alloy startup');
  const collector = await listen(async (req, res) => {
    try {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      if (offline) { failedUploads++; res.writeHead(503).end(); return; }
      const headers = { 'content-type': req.headers['content-type'] };
      if (req.headers['content-encoding']) headers['content-encoding'] = req.headers['content-encoding'];
      const response = await fetch(`http://127.0.0.1:${alloyPort}${req.url}`, {
        method: 'POST', headers, body: Buffer.concat(chunks)
      });
      res.writeHead(response.status).end(Buffer.from(await response.arrayBuffer()));
    } catch (error) { res.writeHead(500).end(String(error)); }
  });
  const backend = await listen((req, res) => {
    requests.push({path: req.url, traceparent: req.headers.traceparent});
    res.writeHead(200, {'content-type': 'text/plain'}).end('ok');
  });
  let index = 0;
  async function launch({sampled, clean = false, restore = false, buffered = false, timeout = 900, lifetime = 14400}) {
    const args = ['--clean', String(clean), '--sampled', String(sampled),
      '--buffered', String(buffered), '--restore', String(restore), '--collector', `http://127.0.0.1:${collector}`,
      '--backend', `http://127.0.0.1:${backend}`, '--run', run, '--timeout', String(timeout), '--lifetime', String(lifetime)];
    let commands;
    if (simulator) {
      const container = simctl('get_app_container', simulator, bundle, 'data');
      commands = path.join(container, 'Documents', `commands-${run}-${++index}`);
      mkdirSync(commands, {recursive: true});
      args.push('--commands', commands, '--storage', path.join(container, 'Documents', `queue-${run}`));
    } else args.push('--storage', `${output}/queue`);
    const child = simulator
      ? start('xcrun', ['simctl', 'launch', '--console', simulator, bundle, ...args], `probe-${index}`)
      : start(binary, args, `probe-${++index}`);
    const lines = [];
    createInterface({input: child.stdout}).on('line', line => {
      if (line.startsWith('RESULT ')) lines.push(JSON.parse(line.slice(7)));
    });
    let sequence = 0;
    let pid;
    async function command(value) {
      if (!commands) {
        child.stdin.write(JSON.stringify(value) + '\n');
        return;
      }
      const number = sequence++;
      const file = path.join(commands, `${number}.json`);
      writeFileSync(file + '.tmp', JSON.stringify(value));
      renameSync(file + '.tmp', file);
      const resultFile = path.join(commands, `${number}.result`);
      await until(() => {
        if (existsSync(resultFile)) return true;
        assert.equal(child.exitCode, null, 'iOS probe exited before response');
        return false;
      }, value.op, 30000);
      return JSON.parse(readFileSync(resultFile));
    }
    return {
      async send(op, extra = {}) {
        let row = await command({op, ...extra});
        if (!commands) {
          await until(() => { assert.equal(child.exitCode, null, 'Probe exited before response'); return lines.length; }, op);
          row = lines.shift();
        }
        assert.equal(row.run, run, 'Response belongs to this run');
        assert.equal(row.op, op, 'Response belongs to this command');
        if (pid) assert.equal(row.pid, pid, 'Response belongs to this process');
        pid = row.pid;
        appendFileSync(path.join(output, 'journal.jsonl'), JSON.stringify({op, ...extra, result: row}) + '\n');
        return row;
      },
      async stop(clean = false) {
        await command({op: 'shutdown', clean});
        const [code] = await child.closed;
        children.delete(child);
        assert.equal(code, 0, 'Probe shutdown');
      },
      async kill() {
        assert(Number.isInteger(pid) && pid > 1, 'Only terminate the verified probe PID');
        execFileSync('/bin/kill', ['-KILL', String(pid)]);
        await child.closed;
        children.delete(child);
        appendFileSync(path.join(output, 'journal.jsonl'), JSON.stringify({op: 'SIGKILL', pid}) + '\n');
      }
    };
  }

  const first = await launch({sampled: true, clean: true});
  const original = await first.send('emit', {name: 'accepted'});
  await first.send('hold', {name: 'held'});
  const off = await first.send('reset', {sampled: false});
  assert.equal(off.previous, original.id);
  assert.equal(off.calls, 2);
  await first.send('emit', {name: 'rejected'});
  await first.send('endHeld');
  await first.send('delayed', {name: 'delayed-on', snapshot: original});
  await first.send('flush');
  await first.stop();

  const second = await launch({sampled: true});
  const cold = await second.send('emit', {name: 'cold-start'});
  assert.notEqual(cold.id, off.id);
  assert.equal(cold.previous, off.id);
  assert.equal(cold.calls, 1);
  assert.notEqual(cold.pid, original.pid);
  await second.send('delayed', {name: 'delayed-off', snapshot: off});
  await second.send('delayed', {name: 'restart-delayed-on', snapshot: original});
  await second.send('flush');
  await second.stop();

  const third = await launch({sampled: false, restore: true});
  const restored = await third.send('emit', {name: 'restored'});
  assert.equal(restored.id, cold.id);
  assert.equal(restored.decision, 'sampled');
  assert.equal(restored.calls, 0);
  await third.send('flush');
  await third.stop(true);

  offline = true;
  const queued = await launch({sampled: true, clean: true, buffered: true});
  const persisted = await queued.send('emit', {name: 'buffered'});
  await queued.send('flush');
  assert(failedUploads > 0, 'The offline path must actually attempt export');
  assert.equal(matching('buffered', 'log').length, 0);
  await queued.send('reset', {sampled: false});
  await queued.send('emit', {name: 'buffered-rejected'});
  await queued.send('flush');
  await queued.kill();

  offline = false;
  const replay = await launch({sampled: false, buffered: true});
  const replaySession = await replay.send('snapshot');
  assert.equal(replaySession.decision, 'notSampled');
  assert.notEqual(replaySession.id, persisted.id);
  await replay.send('flush');
  await until(() => matching('buffered', 'log').length === 1, 'buffered replay');
  await replay.stop();
  const again = await launch({sampled: false, buffered: true});
  await again.send('flush');
  await again.stop(true);
  if (simulator) {
    const lifecycle = await launch({sampled: true, clean: true, timeout: 4, lifetime: 30});
    const active = await lifecycle.send('emit', {name: 'lifecycle-active'});
    simctl('launch', simulator, 'com.apple.mobilesafari');
    await sleep(500);
    simctl('launch', simulator, bundle);
    const short = await lifecycle.send('snapshot');
    assert.equal(short.id, active.id, 'Short app switch preserves the session');
    simctl('launch', simulator, 'com.apple.mobilesafari');
    await sleep(5500);
    simctl('launch', simulator, bundle);
    const expired = await lifecycle.send('emit', {name: 'lifecycle-expired'});
    assert.notEqual(expired.id, active.id, 'Expiry checked on foreground');
    assert.equal(expired.previous, active.id);
    await lifecycle.send('flush');
    await lifecycle.stop(true);

    const lifetime = await launch({sampled: true, clean: true, timeout: 3, lifetime: 7});
    const initial = await lifetime.send('emit', {name: 'lifetime-start'});
    let last = initial;
    for (let i = 0; i < 5; i++) {
      await sleep(1800);
      last = await lifetime.send('emit', {name: `lifetime-${i}`});
    }
    assert.notEqual(last.id, initial.id, 'Maximum lifetime expires despite activity');
    assert.equal(last.previous, initial.id);
    await lifetime.send('flush');
    await lifetime.stop(true);
  }
  await sleep(500);

  for (const kind of ['trace', 'log']) {
    expect('accepted', kind, original.id);
    expect('cold-start', kind, cold.id);
    expect('restored', kind, restored.id);
    expect('buffered', kind, persisted.id);
    expect('rejected', kind, off.id, 0);
    expect('buffered-rejected', kind, off.id, 0);
  }
  expect('held', 'trace', original.id);
  expect('delayed-on', 'log', original.id);
  expect('restart-delayed-on', 'log', original.id);
  expect('delayed-off', 'log', off.id, 0);
  for (const request of requests) {
    assert.match(request.traceparent, /^00-[a-f0-9]{32}-[a-f0-9]{16}-0[01]$/);
    const sampled = !request.path.includes('rejected');
    assert.equal(request.traceparent.slice(-2), sampled ? '01' : '00');
    const spans = records().filter(row => row.attrs['url.full'] === `http://127.0.0.1:${backend}${request.path}`);
    assert.equal(spans.length, sampled ? 1 : 0, `automatic span ${request.path}`);
    if (sampled) {
      const [, trace, span] = request.traceparent.split('-');
      assert.equal(spans[0].trace, trace);
      assert.equal(spans[0].span, span);
    }
  }
  assert.equal(requests.length, simulator ? 14 : 6);
  const result = {run, binary, sdk: 'ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a',
    binarySHA256: createHash('sha256').update(readFileSync(simulator ? path.join(binary, 'Session99Probe') : binary)).digest('hex'),
    bufferedTermination: 'SIGKILL after explicit flush while collector returns 503',
    processes: index, simulator: simulator || null, faro, failedUploads, requests, records: records(), status: 'passed'};
  writeFileSync(path.join(output, 'result.json'), JSON.stringify(result, null, 2));
  console.log(`PASS: ${index} launches, reset/restart/saved decisions, automatic HTTP and offline replay. ${output}`);
} finally {
  if (simulator) { try { simctl('terminate', simulator, bundle); } catch {} }
  for (const child of children) {
    if (child.exitCode === null) child.kill('SIGTERM');
    await child.closed;
  }
  for (const server of servers) {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}
