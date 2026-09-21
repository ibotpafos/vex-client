import type { VpnLocation } from '@/api/vexApi';
import { ApiRequestError } from '@/api/error';

export function isProfileResolutionFallbackError(error: unknown): boolean {
  // Resolving another location only helps when the requested location has no
  // profile target. Authentication, entitlement, configuration, key and
  // generic network/API failures are shared across locations; retrying every
  // location only multiplies latency and can hide the real error.
  return error instanceof ApiRequestError && error.status === 404;
}

export function profileResolutionOrder(
  initialLocationId: string,
  availableLocations: VpnLocation[],
): VpnLocation[] {
  const ordered: VpnLocation[] = [];
  const initial = availableLocations.find((location) => location.id === initialLocationId);
  for (const candidate of [initial, ...availableLocations]) {
    if (!candidate || candidate.availability === 'retired') {
      continue;
    }
    if (candidate.id !== initialLocationId && candidate.healthyNodes <= 0) {
      continue;
    }
    if (!ordered.some((location) => location.id === candidate.id)) {
      ordered.push(candidate);
    }
  }
  return ordered;
}
