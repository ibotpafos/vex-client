import type { LocationDTO } from '../api/dto';
import type { VpnLocation } from '../api/types';

export class VpnLocationCatalogError extends Error {
  constructor(message: string) {
    super(`Invalid VPN location catalog: ${message}`);
    this.name = 'VpnLocationCatalogError';
  }
}

export function normalizeLocationCatalog(items: LocationDTO[]): VpnLocation[] {
  if (!Array.isArray(items)) {
    throw new VpnLocationCatalogError('response must be an array');
  }

  const seenIds = new Set<string>();
  const normalized = items.map((item, index) => normalizeLocation(item, index, seenIds));
  return normalized
    .filter((location) => location.availability.toLowerCase() !== 'retired')
    .sort(compareLocations);
}

function normalizeLocation(item: LocationDTO, index: number, seenIds: Set<string>): VpnLocation {
  const id = requiredString(item?.id, index, 'id');
  const comparisonId = id.trim().toLowerCase();
  if (seenIds.has(comparisonId)) {
    throw new VpnLocationCatalogError(`duplicate location id: ${id}`);
  }
  seenIds.add(comparisonId);

  const countryCode = requiredString(item.country_code, index, 'country_code').trim();
  const city = requiredString(item.city, index, 'city').trim();
  const availability = requiredString(item.availability, index, 'availability').trim().toLowerCase();
  if (typeof item.healthy_nodes !== 'number' || !Number.isFinite(item.healthy_nodes) || item.healthy_nodes < 0) {
    throw new VpnLocationCatalogError(`entry ${index} has invalid healthy_nodes`);
  }
  if (item.priority !== undefined && (typeof item.priority !== 'number' || !Number.isFinite(item.priority))) {
    throw new VpnLocationCatalogError(`entry ${index} has invalid priority`);
  }

  return {
    id,
    countryCode,
    city,
    displayName: optionalString(item.display_name)?.trim() || city,
    flagEmoji: optionalString(item.flag_emoji)?.trim() || undefined,
    availability,
    priority: item.priority ?? 100,
    status: optionalString(item.status)?.trim() || 'unknown',
    healthyNodes: item.healthy_nodes,
    capabilities: normalizeCapabilities(item.capabilities, index),
    endpoint: optionalString(item.endpoint)?.trim() || undefined,
    latencyMs: optionalFiniteNumber(item.latency_ms, index, 'latency_ms'),
  };
}

function requiredString(value: unknown, index: number, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new VpnLocationCatalogError(`entry ${index} has invalid ${field}`);
  }
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function optionalFiniteNumber(value: unknown, index: number, field: string): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new VpnLocationCatalogError(`entry ${index} has invalid ${field}`);
  }
  return value;
}

function normalizeCapabilities(value: unknown, index: number): string[] {
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value) || value.some((capability) => typeof capability !== 'string')) {
    throw new VpnLocationCatalogError(`entry ${index} has invalid capabilities`);
  }
  return [...new Set(value.map((capability) => capability.trim().toLowerCase()).filter(Boolean))].sort();
}

function compareLocations(left: VpnLocation, right: VpnLocation): number {
  if (left.priority !== right.priority) {
    return left.priority - right.priority;
  }
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}
