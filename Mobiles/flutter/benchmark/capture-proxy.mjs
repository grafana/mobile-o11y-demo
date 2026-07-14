#!/usr/bin/env node

import { createServer } from 'node:http';
import { mkdir, rename, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

import { sha256 } from './lib/telemetry.mjs';

const { values } = parseArgs({
  options: {
    output: { type: 'string', short: 'o' },
    forward: { type: 'string', default: 'http://127.0.0.1:12347/collect' },
    port: { type: 'string', default: '12348' },
    scenario: { type: 'string', default: 'launch-request-rate-background-foreground' },
  },
});

if (!values.output) {
  throw new Error('--output is required');
}

const outputDir = resolve(values.output);
const rawDir = join(outputDir, 'raw');
const manifestPath = join(outputDir, 'capture-manifest.json');
const port = Number(values.port);
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error(`--port must be an integer between 1 and 65535: ${values.port}`);
}
await mkdir(rawDir, { recursive: true });

const manifest = {
  format: 1,
  capturedAt: new Date().toISOString(),
  scenario: values.scenario,
  forwardTarget: 'local-faro-receiver',
  requests: [],
};

let requestNumber = 0;
let manifestWrite = Promise.resolve();
let stopping = false;

const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    for await (const chunk of request) {
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    requestNumber += 1;
    const filename = `request-${String(requestNumber).padStart(4, '0')}.json`;
    await writeFile(join(rawDir, filename), body, { flag: 'wx' });

    const headers = new Headers();
    for (const [key, value] of Object.entries(request.headers)) {
      if (value != null && !['host', 'content-length'].includes(key.toLowerCase())) {
        headers.set(key, Array.isArray(value) ? value.join(', ') : value);
      }
    }

    const forwarded = await fetch(values.forward, {
      method: request.method,
      headers,
      body,
    });
    const forwardedBody = Buffer.from(await forwarded.arrayBuffer());

    manifest.requests.push({
      filename,
      capturedAt: new Date().toISOString(),
      bytes: body.length,
      sha256: sha256(body),
      contentType: request.headers['content-type'] ?? null,
      forwardedStatus: forwarded.status,
    });
    await queueManifestWrite();

    response.writeHead(forwarded.status, Object.fromEntries(forwarded.headers.entries()));
    response.end(forwardedBody);
    process.stdout.write(`Captured ${filename} (${body.length} bytes)\n`);
  } catch (error) {
    response.writeHead(502, { 'content-type': 'text/plain' });
    response.end('Local capture proxy failed');
    process.stderr.write(`${error.stack ?? error}\n`);
  }
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`Capture proxy listening on http://127.0.0.1:${port}\n`);
  process.stdout.write(`Raw payloads: ${rawDir}\n`);
});

async function writeManifest() {
  const temporaryPath = `${manifestPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await rename(temporaryPath, manifestPath);
}

function queueManifestWrite() {
  const nextWrite = manifestWrite.catch(() => {}).then(writeManifest);
  manifestWrite = nextWrite.catch(() => {});
  return nextWrite;
}

async function shutdown() {
  if (stopping) {
    return;
  }
  stopping = true;
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
  await queueManifestWrite();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
