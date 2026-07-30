/**
 * Demo-only: blocks the native UI thread to induce real Faro slow/frozen frame
 * measurements (Choreographer / CADisplayLink). Runs in episodes: short bursts
 * of stalls, then ~30 seconds quiet, repeat.
 */

import { NativeModules, Platform } from 'react-native';
import { useEffect } from 'react';

import { useDebugSettingsStore } from './debugSettingsStore';

const MIN_STALL_GAP_MS = 300;
const MAX_STALL_GAP_MS = 900;
/** Must exceed Faro frozenFrameThresholdMs (700) so each stall counts as app_frozen_frame. */
const MIN_BLOCK_MS = 750;
const MAX_BLOCK_MS = 2800;
const MIN_ACTIVE_EPISODE_MS = 10_000;
const MAX_ACTIVE_EPISODE_MS = 15_000;
const QUIET_PERIOD_MS = 30_000;

type QuickPizzaDebugNative = {
  blockMainThread: (durationMs: number) => Promise<void>;
};

const QuickPizzaDebug = NativeModules.QuickPizzaDebug as
  | QuickPizzaDebugNative
  | undefined;

function randomBetween(min: number, max: number): number {
  return Math.floor(min + Math.random() * (max - min + 1));
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

/** Stall the UI thread via native main-looper block (Android/iOS). */
async function blockUiThread(durationMs: number): Promise<void> {
  if (!QuickPizzaDebug?.blockMainThread) {
    console.warn(
      `[randomFrozenFrames] QuickPizzaDebug.blockMainThread unavailable on ${Platform.OS}`,
    );
    return;
  }
  await QuickPizzaDebug.blockMainThread(durationMs);
}

/** One UI-thread stall per burst — splitting would drop below the 700ms frozen threshold. */
async function blockUiThreadBurst(): Promise<void> {
  await blockUiThread(randomBetween(MIN_BLOCK_MS, MAX_BLOCK_MS));
}

/**
 * When `clientRandomFrozenFrames` is enabled, alternates active stall episodes
 * (~10–15s) with quiet periods (~30s). Renders nothing.
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

    const runActiveEpisode = async (): Promise<void> => {
      console.log(
        `[randomFrozenFrames] ACTIVE episode start (${new Date().toISOString()})`,
      );
      const episodeEnd =
        Date.now() + randomBetween(MIN_ACTIVE_EPISODE_MS, MAX_ACTIVE_EPISODE_MS);

      while (!cancelled && Date.now() < episodeEnd) {
        await blockUiThreadBurst();
        if (cancelled || Date.now() >= episodeEnd) {
          return;
        }
        await delay(randomBetween(MIN_STALL_GAP_MS, MAX_STALL_GAP_MS));
      }
    };

    const runCycle = async (): Promise<void> => {
      while (!cancelled) {
        await runActiveEpisode();
        if (cancelled) {
          return;
        }
        console.log(
          `[randomFrozenFrames] QUIET period start — ${QUIET_PERIOD_MS / 1000}s (${new Date().toISOString()})`,
        );
        await delay(QUIET_PERIOD_MS);
      }
    };

    void runCycle();

    return () => {
      cancelled = true;
    };
  }, [enabled]);

  return null;
}
