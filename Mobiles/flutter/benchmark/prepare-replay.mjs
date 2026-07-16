#!/usr/bin/env node

import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

import {
  addCounts,
  countPayloadItems,
  findSensitiveValues,
  prepareReplayPayloads,
  sanitizePayload,
  sha256,
} from './lib/telemetry.mjs';

const { values } = parseArgs({
  options: {
    capture: { type: 'string', short: 'c' },
    run: { type: 'string', short: 'r' },
    start: { type: 'string' },
  },
});

if (!values.capture || !values.run) {
  throw new Error('--capture and --run are required');
}

const captureDir = resolve(values.capture);
const rawDir = join(captureDir, 'raw');
const sanitizedDir = join(captureDir, 'sanitized-source');
const replayDir = join(captureDir, 'replay', values.run);
const filenames = (await readdir(rawDir)).filter((name) => name.endsWith('.json')).sort();
if (filenames.length === 0) {
  throw new Error(`No captured payloads found in ${rawDir}`);
}

await mkdir(sanitizedDir, { recursive: true });
await mkdir(replayDir, { recursive: true });

const rawBuffers = await Promise.all(filenames.map((name) => readFile(join(rawDir, name))));
const rawPayloads = rawBuffers.map((body, index) => {
  try {
    return JSON.parse(body.toString('utf8'));
  } catch (error) {
    throw new Error(`${filenames[index]} is not valid JSON: ${error.message}`);
  }
});
const sanitizedPayloads = rawPayloads.map(sanitizePayload);
const sensitiveFindings = sanitizedPayloads.flatMap((payload, index) =>
  findSensitiveValues(payload).map((path) => `${filenames[index]}:${path}`),
);
if (sensitiveFindings.length > 0) {
  throw new Error(`Sensitive values remain after sanitization:\n${sensitiveFindings.join('\n')}`);
}

const prepared = prepareReplayPayloads(sanitizedPayloads, {
  runId: values.run,
  startTime: values.start,
});

let sourceCounts = {};
let replayCounts = {};
const files = [];
for (let index = 0; index < filenames.length; index += 1) {
  const filename = filenames[index];
  const raw = rawBuffers[index];
  const sanitized = `${JSON.stringify(sanitizedPayloads[index], null, 2)}\n`;
  const replay = `${JSON.stringify(prepared.payloads[index], null, 2)}\n`;
  await writeFile(join(sanitizedDir, filename), sanitized);
  await writeFile(join(replayDir, filename), replay);

  const currentSourceCounts = countPayloadItems(sanitizedPayloads[index]);
  const currentReplayCounts = countPayloadItems(prepared.payloads[index]);
  sourceCounts = addCounts(sourceCounts, currentSourceCounts);
  replayCounts = addCounts(replayCounts, currentReplayCounts);
  files.push({
    filename,
    rawSha256: sha256(raw),
    sanitizedSha256: sha256(sanitized),
    replaySha256: sha256(replay),
    sourceCounts: currentSourceCounts,
    replayCounts: currentReplayCounts,
  });
}

if (JSON.stringify(sourceCounts) !== JSON.stringify(replayCounts)) {
  throw new Error('Source and replay item counts differ');
}

const firstMeta = sanitizedPayloads.find((payload) => payload.meta)?.meta ?? {};
const manifest = {
  format: 1,
  createdAt: new Date().toISOString(),
  benchmarkRunId: values.run,
  app: firstMeta.app ?? null,
  sdk: firstMeta.sdk ?? null,
  requestCount: filenames.length,
  sourceCounts,
  replayCounts,
  timestampOffsetMs: prepared.offsetMs,
  remappedIds: prepared.remappedIds,
  sensitiveFindings: [],
  rawCapturePreserved: true,
  files,
};
await writeFile(join(replayDir, 'replay-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

process.stdout.write(`Prepared ${filenames.length} payloads in ${replayDir}\n`);
process.stdout.write(`Counts: ${JSON.stringify(sourceCounts)}\n`);
process.stdout.write(`App: ${firstMeta.app?.version ?? 'unknown'}\n`);
process.stdout.write(`SDK: ${firstMeta.sdk?.version ?? 'unknown'}\n`);
process.stdout.write(`Manifest: ${basename(replayDir)}/replay-manifest.json\n`);
