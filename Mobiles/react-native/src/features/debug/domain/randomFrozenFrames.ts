/**
 * Demo-only: aggressively blocks the JS thread to induce obvious UI freezes
 * and Faro slow/frozen frame measurements. Each scheduled burst stays under
 * MAX_BLOCK_MS total to avoid ANR.
 */

import { useEffect } from 'react';

import { useDebugSettingsStore } from './debugSettingsStore';

const MIN_INTERVAL_MS = 300;
const MAX_INTERVAL_MS = 900;
const MIN_BLOCK_MS = 700;
const MAX_BLOCK_MS = 2800;

function randomBetween(min: number, max: number): number {
  return Math.floor(min + Math.random() * (max - min + 1));
}

function blockJsThread(durationMs: number): void {
  const end = Date.now() + durationMs;
  // Extra arithmetic so Hermes can't optimize the loop away.
  let sink = 0;
  while (Date.now() < end) {
    sink = (sink + 1) * 31;
  }
  if (sink === Number.MIN_SAFE_INTEGER) {
    console.debug('randomFrozenFrames sink', sink);
  }
}

/** Split totalBudgetMs into 1–3 back-to-back stalls (sum never exceeds budget). */
function blockJsThreadBurst(totalBudgetMs: number): void {
  const bursts = randomBetween(1, 3);
  const baseDuration = Math.floor(totalBudgetMs / bursts);
  const remainder = totalBudgetMs % bursts;

  for (let i = 0; i < bursts; i++) {
    blockJsThread(baseDuration + (i < remainder ? 1 : 0));
  }
}

/**
 * When `clientRandomFrozenFrames` is enabled, schedules frequent main-thread
 * stalls. Renders nothing.
 */
export function RandomFrozenFramesEffect(): null {
  const enabled = useDebugSettingsStore(
    (state) => state.settings.clientRandomFrozenFrames,
  );

  useEffect(() => {
    if (!enabled) {
      return undefined;
    }

    let cancelled = false;
    let timeoutId: ReturnType<typeof setTimeout> | undefined;

    const scheduleNext = () => {
      if (cancelled) {
        return;
      }
      const delay = randomBetween(MIN_INTERVAL_MS, MAX_INTERVAL_MS);
      timeoutId = setTimeout(() => {
        if (cancelled) {
          return;
        }
        blockJsThreadBurst(randomBetween(MIN_BLOCK_MS, MAX_BLOCK_MS));
        scheduleNext();
      }, delay);
    };

    // Immediate hit so the toggle feels on right away.
    blockJsThreadBurst(randomBetween(MIN_BLOCK_MS, MAX_BLOCK_MS));
    scheduleNext();

    return () => {
      cancelled = true;
      if (timeoutId !== undefined) {
        clearTimeout(timeoutId);
      }
    };
  }, [enabled]);

  return null;
}
