/**
 * Demo-only: retain growing buffers while a Debug switch is on to stress
 * process memory hard enough to feel on a 1 GB AVD. Releases when disabled.
 */

import { useEffect } from 'react';

import { useDebugSettingsStore } from './debugSettingsStore';

const CHUNK_BYTES = 24 * 1024 * 1024; // 24 MiB ArrayBuffer per chunk
const INTERVAL_MS = 400;
/** Up to 30 chunks (~24 MiB buffer + ~1 MiB string each); turn off to free. */
const MAX_CHUNKS = 30;
const BURST_ON_ENABLE = 4;

const retainedChunks: Uint8Array[] = [];
const retainedStrings: string[] = [];

function allocateChunk(): void {
  if (retainedChunks.length >= MAX_CHUNKS) {
    return;
  }
  const chunk = new Uint8Array(CHUNK_BYTES);
  // Touch every page + write a large string so Hermes/heap also grows.
  for (let i = 0; i < chunk.length; i += 4096) {
    chunk[i] = (i + retainedChunks.length) & 0xff;
  }
  // Fill a slice densely so allocation itself is expensive / janky.
  for (let i = 0; i < Math.min(chunk.length, 2 * 1024 * 1024); i++) {
    chunk[i] = i & 0xff;
  }
  retainedChunks.push(chunk);
  retainedStrings.push('x'.repeat(1024 * 1024)); // +1 MiB string
}

function releaseChunks(): void {
  retainedChunks.length = 0;
  retainedStrings.length = 0;
}

/**
 * When `clientMemoryStress` is enabled, grows retained buffers quickly.
 * Renders nothing.
 */
export function MemoryStressEffect(): null {
  const enabled = useDebugSettingsStore(
    (state) => state.settings.clientMemoryStress,
  );

  useEffect(() => {
    if (!enabled) {
      releaseChunks();
      return undefined;
    }

    for (let i = 0; i < BURST_ON_ENABLE; i++) {
      allocateChunk();
    }

    const intervalId = setInterval(() => {
      allocateChunk();
    }, INTERVAL_MS);

    return () => {
      clearInterval(intervalId);
      releaseChunks();
    };
  }, [enabled]);

  return null;
}
