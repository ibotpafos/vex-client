export function createExpiringSettingsRemoteConfigLoader<TInput, TValue>(
  loader: (input: TInput) => Promise<TValue>,
  ttlMs: number,
  now: () => number = Date.now,
): (input: TInput) => Promise<TValue> {
  let cached: { key: string; loadedAt: number; promise: Promise<TValue> } | null = null;

  return (input) => {
    const key = JSON.stringify(input);
    const currentTime = now();
    if (cached && cached.key === key && currentTime - cached.loadedAt <= ttlMs) {
      return cached.promise;
    }

    const promise = loader(input);
    cached = { key, loadedAt: currentTime, promise };
    void promise.catch(() => {
      if (cached?.promise === promise) {
        cached = null;
      }
    });
    return promise;
  };
}
