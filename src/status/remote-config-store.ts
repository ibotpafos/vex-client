import type { AppRemoteConfig } from '../api/types';

export type RemoteConfigSnapshot = { config: AppRemoteConfig | null; unavailable: boolean };

// One read and one foreground/poll lifecycle for Home and Settings together.
export function createRemoteConfigStore(
  load: () => Promise<AppRemoteConfig>,
  lifecycle: {
    foreground: (callback: () => void) => () => void;
    schedule: (callback: () => void, delay: number) => () => void;
  },
) {
  let snapshot: RemoteConfigSnapshot = { config: null, unavailable: false };
  const listeners = new Set<() => void>();
  let pending: Promise<void> | null = null;
  let stopForeground: (() => void) | undefined;
  let stopTimer: (() => void) | undefined;

  const refresh = () => {
    if (pending) return pending;
    stopTimer?.();
    pending = Promise.resolve().then(load).then((config) => {
      // An available incident read without a banner confirms its removal.
      if (
        !config || typeof config.platform !== 'string' ||
        (config.incidentBanner != null && typeof config.incidentBanner !== 'string') ||
        (config.incidentBannerUnavailable !== undefined && typeof config.incidentBannerUnavailable !== 'boolean')
      ) {
        throw new Error('Invalid remote config');
      }
      if (config.incidentBannerUnavailable === true) {
        snapshot = {
          config: { ...config, incidentBanner: snapshot.config?.incidentBanner || config.incidentBanner },
          unavailable: true,
        };
      } else {
        snapshot = { config, unavailable: false };
      }
    }).catch(() => {
      snapshot = { ...snapshot, unavailable: true };
    }).finally(() => {
      pending = null;
      listeners.forEach((listener) => listener());
      if (listeners.size) stopTimer = lifecycle.schedule(() => { void refresh(); }, 60_000);
    });
    return pending;
  };

  return {
    getSnapshot: () => snapshot,
    refresh,
    subscribe(listener: () => void) {
      listeners.add(listener);
      if (listeners.size === 1) {
        stopForeground = lifecycle.foreground(() => { void refresh(); });
        void refresh();
      }
      return () => {
        listeners.delete(listener);
        if (!listeners.size) {
          stopTimer?.();
          stopForeground?.();
        }
      };
    },
  };
}
