#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { closeSync, openSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const benchmarkDir = dirname(fileURLToPath(import.meta.url));
const runtimeDir = join(benchmarkDir, '.runtime');
await mkdir(runtimeDir, { recursive: true });

const children = [];
const logDescriptors = [];
let stopping = false;
children.push(await start('loki', ['-config.file=config/loki.local.yaml'], 'loki.log'));
await waitFor('http://127.0.0.1:3100/ready');
children.push(
  await start(
    'alloy',
    [
      'run',
      '--disable-reporting',
      '--server.http.listen-addr=127.0.0.1:12346',
      '--storage.path=.runtime/alloy',
      'config/alloy.local.alloy',
    ],
    'alloy.log',
  ),
);
await waitFor('http://127.0.0.1:12346/-/ready');

process.stdout.write('Local Loki and Faro receiver are ready\n');
process.stdout.write('Faro receiver: http://127.0.0.1:12347/collect\n');
process.stdout.write('Press Ctrl-C to stop\n');

process.on('SIGINT', () => shutdown());
process.on('SIGTERM', () => shutdown());

await new Promise(() => {});

async function start(command, args, logName) {
  const logDescriptor = openSync(join(runtimeDir, logName), 'w');
  logDescriptors.push(logDescriptor);
  const child = spawn(command, args, {
    cwd: benchmarkDir,
    stdio: ['ignore', logDescriptor, logDescriptor],
  });
  child.on('error', (error) => {
    process.stderr.write(
      `Failed to start ${command}: ${error.message}. Is it installed and available on PATH?\n`,
    );
    shutdown(1);
  });
  child.on('exit', (code) => {
    if (code !== 0 && code != null) {
      process.stderr.write(`${command} exited with code ${code}; see ${logName}\n`);
      shutdown(1);
    }
  });
  return child;
}

async function waitFor(url) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // Service is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function shutdown(code = 0) {
  if (stopping) {
    return;
  }
  stopping = true;
  for (const child of children) {
    child.kill('SIGTERM');
  }
  setTimeout(() => {
    for (const descriptor of logDescriptors) {
      closeSync(descriptor);
    }
    process.exit(code);
  }, 250);
}
