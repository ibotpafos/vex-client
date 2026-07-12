import type { VpnLocation } from '@/api/vexApi';

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
