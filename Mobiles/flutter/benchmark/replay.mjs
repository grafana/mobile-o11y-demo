#!/usr/bin/env node

import { readFile, readdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    input: { type: 'string', short: 'i' },
    endpoint: { type: 'string', default: 'http://127.0.0.1:12347/collect' },
  },
});

if (!values.input) {
  throw new Error('--input is required');
}

const inputDir = resolve(values.input);
const filenames = (await readdir(inputDir))
  .filter((name) => name.startsWith('request-') && name.endsWith('.json'))
  .sort();
if (filenames.length === 0) {
  throw new Error(`No replay payloads found in ${inputDir}`);
}

for (const filename of filenames) {
  const body = await readFile(join(inputDir, filename));
  const response = await fetch(values.endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  });
  if (!response.ok) {
    throw new Error(`${filename} failed with HTTP ${response.status}: ${await response.text()}`);
  }
  process.stdout.write(`Replayed ${filename}\n`);
}

process.stdout.write(`Replayed ${filenames.length} payloads to local Faro receiver\n`);
