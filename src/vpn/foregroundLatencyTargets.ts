import type { VpnLocation } from '@/api/vexApi';
import type { ServerSelectionMode } from './serverSelection';

type ForegroundLatencyTargetInput = {
  activeEndpoint?: string;
  locations: VpnLocation[];
  selectedLocationId: string;
  serverSelectionMode: ServerSelectionMode;
};

// The active endpoint has its own short-cadence probe for the connected
// session. Foreground location ranking is advisory, so manual selection needs
// only its selected location and automatic selection is deliberately slower.
export function foregroundLatencyTargets({
  activeEndpoint,
  locations,
  selectedLocationId,
  serverSelectionMode,
}: ForegroundLatencyTargetInput): VpnLocation[] {
  const candidates = serverSelectionMode === 'auto'
    ? locations
    : locations.filter((location) => location.id === selectedLocationId);
  const seenEndpoints = new Set<string>();
  const normalizedActiveEndpoint = normalizeEndpoint(activeEndpoint);

  return candidates.filter((location) => {
    const endpoint = normalizeEndpoint(location.endpoint);
    if (!endpoint || endpoint === normalizedActiveEndpoint || seenEndpoints.has(endpoint)) {
      return false;
    }
    seenEndpoints.add(endpoint);
    return true;
  });
}

function normalizeEndpoint(endpoint?: string): string {
  return endpoint?.trim().toLowerCase() ?? '';
}
