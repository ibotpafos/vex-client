import type { AuthSession } from '@/api/vexApi';

export const sessionLoadRetryDelaysMs = [120, 360, 900];

export async function loadSessionWithRetry(
  load: () => Promise<AuthSession | null>,
  delayFn: (ms: number) => Promise<void> = delay,
  retryDelaysMs: readonly number[] = sessionLoadRetryDelaysMs,
): Promise<AuthSession | null> {
  return loadWithRetry(load, delayFn, retryDelaysMs);
}

export async function loadWithRetry<T>(
  load: () => Promise<T>,
  delayFn: (ms: number) => Promise<void> = delay,
  retryDelaysMs: readonly number[] = sessionLoadRetryDelaysMs,
): Promise<T> {
  for (let attempt = 0; attempt <= retryDelaysMs.length; attempt += 1) {
    try {
      return await load();
    } catch (error) {
      if (attempt >= retryDelaysMs.length) {
        throw error;
      }
      await delayFn(retryDelaysMs[attempt]);
    }
  }
  throw new Error('retry loop exhausted');
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
