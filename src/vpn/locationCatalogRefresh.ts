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

export function isVisibleLocationCatalogRefresh(
  reason: LocationCatalogRefreshReason,
  hasCatalog: boolean,
): boolean {
  return !hasCatalog || reason === 'picker_open' || reason === 'retry';
}

type LocationCatalogRefresherOptions = {
  fetchCatalog: () => Promise<VpnLocation[]>;
  commitCatalog: (locations: VpnLocation[]) => Promise<void> | void;
  currentCatalog?: () => VpnLocation[] | null | undefined;
  now?: () => number;
  onDiagnostics?: (event: LocationCatalogDiagnostics) => void;
};

export function createLocationCatalogRefresher(options: LocationCatalogRefresherOptions) {
  let inFlight: Promise<LocationCatalogRefreshResult> | null = null;
  let lastCatalog: VpnLocation[] | null = null;
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
          const current = options.currentCatalog?.() ?? lastCatalog;
          const stableLocations = current && areLocationCatalogsEqual(current, locations)
            ? current
            : locations;
          if (stableLocations === locations) {
            await options.commitCatalog(locations);
          }
          lastCatalog = stableLocations;
          options.onDiagnostics?.({
            reason,
            outcome: 'success',
            durationMs: Math.max(0, now() - startedAt),
            source: 'network',
            entryCount: stableLocations.length,
          });
          return { locations: stableLocations, source: 'network' as const, reason };
        } catch (error) {
          const prior = options.currentCatalog?.() ?? lastCatalog ?? [];
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

function areLocationCatalogsEqual(left: VpnLocation[], right: VpnLocation[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  return left.every((location, index) => {
    const candidate = right[index];
    return Boolean(candidate)
      && location.id === candidate.id
      && location.countryCode === candidate.countryCode
      && location.city === candidate.city
      && location.displayName === candidate.displayName
      && location.flagEmoji === candidate.flagEmoji
      && location.availability === candidate.availability
      && location.priority === candidate.priority
      && location.status === candidate.status
      && location.healthyNodes === candidate.healthyNodes
      && location.endpoint === candidate.endpoint
      && location.capabilities.length === candidate.capabilities.length
      && location.capabilities.every((capability, capabilityIndex) => capability === candidate.capabilities[capabilityIndex]);
  });
}
