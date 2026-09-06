import type { VpnLocation } from '../api/types';
import { VpnLocationCatalogError } from './locationCatalog';

export type LocationCatalogRefreshReason =
  | 'startup'
  | 'foreground'
  | 'picker_open'
  | 'session_refresh'
  | 'interval'
  | 'retry';

export type LocationCatalogRefreshResult = {
  locations: VpnLocation[];
  source: 'network';
  reason: LocationCatalogRefreshReason;
};

export type LocationCatalogDiagnostics = {
  reason: LocationCatalogRefreshReason;
  outcome: 'success' | 'error';
  durationMs: number;
  source: 'network' | 'stale_cache';
  entryCount: number;
  errorCategory?: 'contract' | 'network';
};

type LocationCatalogRefresherOptions = {
  fetchCatalog: () => Promise<VpnLocation[]>;
  commitCatalog: (locations: VpnLocation[]) => Promise<void> | void;
  currentCatalog?: () => VpnLocation[] | null | undefined;
  now?: () => number;
  onDiagnostics?: (event: LocationCatalogDiagnostics) => void;
};

export function createLocationCatalogRefresher(options: LocationCatalogRefresherOptions) {
  let inFlight: Promise<LocationCatalogRefreshResult> | null = null;
  const now = options.now ?? Date.now;

  return {
    refresh(reason: LocationCatalogRefreshReason): Promise<LocationCatalogRefreshResult> {
      if (inFlight) {
        return inFlight;
      }
      const startedAt = now();
      const operation = (async () => {
        try {
          const locations = await options.fetchCatalog();
          await options.commitCatalog(locations);
          options.onDiagnostics?.({
            reason,
            outcome: 'success',
            durationMs: Math.max(0, now() - startedAt),
            source: 'network',
            entryCount: locations.length,
          });
          return { locations, source: 'network' as const, reason };
        } catch (error) {
          const prior = options.currentCatalog?.() ?? [];
          options.onDiagnostics?.({
            reason,
            outcome: 'error',
            durationMs: Math.max(0, now() - startedAt),
            source: prior.length > 0 ? 'stale_cache' : 'network',
            entryCount: prior.length,
            errorCategory: error instanceof VpnLocationCatalogError ? 'contract' : 'network',
          });
          throw error;
        }
      })();
      inFlight = operation.finally(() => {
        inFlight = null;
      });
      return inFlight;
    },
  };
}
