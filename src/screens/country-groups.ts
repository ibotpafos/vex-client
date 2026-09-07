import type { VpnLocation } from '../api/types';

export function isLocationAvailable(location: VpnLocation): boolean {
  return Number.isFinite(location.healthyNodes) && location.healthyNodes > 0
    && ['active', 'online', 'healthy', 'degraded'].includes(location.status.trim().toLowerCase())
    && !['maintenance', 'unavailable', 'retired'].includes(location.availability.trim().toLowerCase());
}

export function availableNodeCountText(count: number): string {
  const lastTwo = count % 100;
  const last = count % 10;
  const noun = lastTwo >= 11 && lastTwo <= 14 ? 'узлов' : last === 1 ? 'узел' : last >= 2 && last <= 4 ? 'узла' : 'узлов';
  return `${count} ${noun}`;
}

export interface CountryGroup {
  id: string;
  locations: VpnLocation[];
  representative: VpnLocation;
  availableNodeCount: number;
  isSelected: boolean;
}

/** Presentation only: retain original location IDs for every connection request. */
export function countryGroups(locations: VpnLocation[], selectedID: string, selectedLocation?: VpnLocation, limit = Number.POSITIVE_INFINITY): CountryGroup[] {
  const unique = new Map(locations.map(location => [location.id, location]));
  if (selectedLocation && !unique.has(selectedLocation.id)) unique.set(selectedLocation.id, selectedLocation);
  const grouped = new Map<string, VpnLocation[]>();
  for (const location of unique.values()) {
    const code = location.countryCode.trim().toUpperCase();
    const key = /^[A-Z]{2}$/.test(code) ? `country:${code}` : `location:${location.id}`;
    grouped.set(key, [...(grouped.get(key) ?? []), location]);
  }
  const latency = (location: VpnLocation) => Number.isFinite(location.latencyMs) && location.latencyMs! >= 0 ? location.latencyMs! : Infinity;
  return [...grouped.entries()].map(([id, members]): CountryGroup => {
    const sorted = [...members].sort((a, b) => Number(isLocationAvailable(b)) - Number(isLocationAvailable(a)) || latency(a) - latency(b) || a.id.localeCompare(b.id));
    const selected = sorted.find(location => location.id === selectedID);
    const representative = selected ?? sorted[0];
    return {
      id, locations: sorted, isSelected: Boolean(selected),
      availableNodeCount: sorted.reduce((count, location) => count + (isLocationAvailable(location) ? Math.floor(location.healthyNodes) : 0), 0),
      representative: { ...representative, countryCode: representative.countryCode.trim().toUpperCase(), latencyMs: isLocationAvailable(representative) ? representative.latencyMs : undefined },
    };
  }).sort((a, b) => Number(b.isSelected) - Number(a.isSelected) || a.id.localeCompare(b.id)).slice(0, Math.max(0, limit));
}

/** Keep FlatList data and item identities stable when polling returns the same catalog. */
export function stableCountryGroups(previous: CountryGroup[], next: CountryGroup[]): CountryGroup[] {
  if (previous.length === 0) return next;

  const previousByID = new Map(previous.map(group => [group.id, group]));
  const nextByID = new Map(next.map(group => [group.id, group]));
  const ordered = previous
    .map(group => nextByID.get(group.id))
    .filter((group): group is CountryGroup => Boolean(group));
  const knownIDs = new Set(previousByID.keys());
  ordered.push(...next.filter(group => !knownIDs.has(group.id)));

  const stable = ordered.map(group => {
    const prior = previousByID.get(group.id);
    return sameCountryGroup(prior, group) ? prior! : group;
  });
  return stable.length === previous.length
    && stable.every((group, index) => group === previous[index])
    ? previous
    : stable;
}

function sameCountryGroup(left: CountryGroup | undefined, right: CountryGroup): boolean {
  if (!left || left.id !== right.id || left.isSelected !== right.isSelected || left.availableNodeCount !== right.availableNodeCount) return false;
  if (!sameLocationCard(left.representative, right.representative) || left.locations.length !== right.locations.length) return false;
  return left.locations.every((location, index) => sameLocationCard(location, right.locations[index]));
}

function sameLocationCard(left: VpnLocation, right: VpnLocation | undefined): boolean {
  const leftCapabilities = left.capabilities ?? [];
  const rightCapabilities = right?.capabilities ?? [];
  return Boolean(right)
    && left.id === right!.id
    && left.countryCode === right!.countryCode
    && left.city === right!.city
    && left.displayName === right!.displayName
    && left.flagEmoji === right!.flagEmoji
    && left.availability === right!.availability
    && left.priority === right!.priority
    && left.status === right!.status
    && left.healthyNodes === right!.healthyNodes
    && left.endpoint === right!.endpoint
    && leftCapabilities.length === rightCapabilities.length
    && leftCapabilities.every((capability, index) => capability === rightCapabilities[index]);
}
