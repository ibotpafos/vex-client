import type { VpnLocation } from '../api/vexApi';

export type ServerSelectionMode = 'auto' | 'manual';

export function normalizeServerSelectionMode(value?: string | null): ServerSelectionMode {
  return value === 'manual' ? 'manual' : 'auto';
}

export function chooseBestVpnLocation(locations: VpnLocation[]): VpnLocation | undefined {
  return locations
    .map((location, index) => ({ location, index }))
    .filter(({ location }) => isSelectableLocation(location))
    .sort((left, right) => compareLocationCandidates(left, right))[0]?.location;
}

export function autoSwitchTargetLocationId(currentLocationId: string, locations: VpnLocation[]): string | null {
  const bestLocationId = chooseBestVpnLocation(locations)?.id;
  if (!bestLocationId || normalizeLocationId(bestLocationId) === normalizeLocationId(currentLocationId)) {
    return null;
  }
  return bestLocationId;
}

function compareLocationCandidates(
  left: { location: VpnLocation; index: number },
  right: { location: VpnLocation; index: number },
): number {
  const leftStatusScore = locationStatusScore(left.location);
  const rightStatusScore = locationStatusScore(right.location);
  if (leftStatusScore !== rightStatusScore) {
    return rightStatusScore - leftStatusScore;
  }

  const leftLatency = normalizedLatency(left.location);
  const rightLatency = normalizedLatency(right.location);
  if (leftLatency !== rightLatency) {
    return leftLatency - rightLatency;
  }

  return left.index - right.index;
}

function isSelectableLocation(location: VpnLocation): boolean {
  return location.availability !== 'retired' && location.healthyNodes > 0;
}

function locationStatusScore(location: VpnLocation): number {
  return location.status === 'healthy' ? 2 : 1;
}

function normalizedLatency(location: VpnLocation): number {
  return typeof location.latencyMs === 'number' && Number.isFinite(location.latencyMs)
    ? Math.max(0, location.latencyMs)
    : Number.POSITIVE_INFINITY;
}

function normalizeLocationId(locationId: string): string {
  return locationId.trim().toLowerCase();
}
