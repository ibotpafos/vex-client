import { connectionAttemptsForProfile, profileEndpoint, profileWithEndpoint } from './connectionFallback';
import type { VpnProfile } from './profile';

export type DynamicRouteCandidate = {
  id: string;
  pathId?: string;
  pathKind: 'direct' | 'relay';
  entryNodeId?: string;
  failureDomain?: string;
  priority: number;
  deviceId: string;
  protocol: string;
  locationId: string;
  nodeId: string;
  endpoint: string;
  healthScore: number;
  expiresAt: string;
};

export type DynamicRoutePolicy = {
  policyVersion: string;
  expiresAt: string;
  probe: {
    maxCandidates: number;
    failureThreshold: number;
    quarantineMs: number;
    failbackHoldMs: number;
  };
  candidates: DynamicRouteCandidate[];
};

type RouteState = {
  failures: number;
  quarantineUntil: number;
  lastSuccessAt: number;
};

export type DynamicRouteSnapshot = {
  policy?: DynamicRoutePolicy;
  routes: Record<string, RouteState>;
  preferredByDevice: Record<string, string>;
};

export type DynamicRouteAttempt = { profile: VpnProfile; candidate?: DynamicRouteCandidate };

export function parseDynamicRoutePolicy(value: unknown, nowMs = Date.now()): DynamicRoutePolicy | null {
  if (!record(value) || typeof value.policy_version !== 'string' || !unexpired(value.expires_at, nowMs)
      || !record(value.probe) || !Array.isArray(value.candidates)) {
    return null;
  }
  const probe = value.probe;
  const candidates: DynamicRouteCandidate[] = [];
  for (const item of value.candidates) {
    if (!record(item) || typeof item.id !== 'string' || !item.id ||
        (item.path_kind !== 'direct' && item.path_kind !== 'relay') ||
        typeof item.device_id !== 'string' || !item.device_id ||
        typeof item.protocol !== 'string' || typeof item.location_id !== 'string' ||
        typeof item.node_id !== 'string' || typeof item.endpoint !== 'string' ||
        typeof item.expires_at !== 'string' || !validEndpoint(item.endpoint)) {
      continue;
    }
    candidates.push({
      id: item.id,
      pathId: typeof item.path_id === 'string' ? item.path_id : undefined,
      pathKind: item.path_kind,
      entryNodeId: typeof item.entry_node_id === 'string' ? item.entry_node_id : undefined,
      failureDomain: typeof item.failure_domain === 'string' ? item.failure_domain : undefined,
      priority: boundedNumber(item.priority, 0, 1000, 0),
      deviceId: item.device_id,
      protocol: item.protocol,
      locationId: item.location_id,
      nodeId: item.node_id,
      endpoint: item.endpoint,
      healthScore: boundedNumber(item.health_score, 0, 100, 0),
      expiresAt: item.expires_at,
    });
  }
  return {
    policyVersion: value.policy_version,
    expiresAt: value.expires_at,
    probe: {
      maxCandidates: boundedNumber(probe.max_candidates, 1, 12, 3),
      failureThreshold: boundedNumber(probe.failure_threshold, 1, 10, 2),
      quarantineMs: boundedNumber(probe.quarantine_ms, 0, 300_000, 30_000),
      failbackHoldMs: boundedNumber(probe.failback_hold_ms, 0, 3_600_000, 120_000),
    },
    candidates,
  };
}

export class DynamicRouteEngine {
  private policy: DynamicRoutePolicy | null = null;
  private routes: Record<string, RouteState> = {};
  private preferredByDevice: Record<string, string> = {};
  private active: DynamicRouteCandidate | null = null;

  setPolicy(policy: DynamicRoutePolicy, nowMs = Date.now()): void {
    if (unexpired(policy.expiresAt, nowMs)) this.policy = policy;
  }

  hasPolicy(nowMs = Date.now()): boolean {
    return !!this.policy && unexpired(this.policy.expiresAt, nowMs);
  }

  restore(snapshot: DynamicRouteSnapshot, nowMs = Date.now()): void {
    this.policy = snapshot.policy && unexpired(snapshot.policy.expiresAt, nowMs) ? snapshot.policy : null;
    this.routes = {};
    if (record(snapshot.routes)) {
      for (const [id, value] of Object.entries(snapshot.routes).slice(0, 64)) {
        if (record(value) && finiteNonnegative(value.failures) && finiteNonnegative(value.quarantineUntil) && finiteNonnegative(value.lastSuccessAt)) {
          this.routes[id] = {
            failures: value.failures,
            quarantineUntil: value.quarantineUntil,
            lastSuccessAt: value.lastSuccessAt,
          };
        }
      }
    }
    this.preferredByDevice = {};
    if (record(snapshot.preferredByDevice)) {
      for (const [deviceId, path] of Object.entries(snapshot.preferredByDevice).slice(0, 64)) {
        if (typeof path === 'string') this.preferredByDevice[deviceId] = path;
      }
    }
    this.active = null;
  }

  snapshot(nowMs = Date.now()): DynamicRouteSnapshot {
    const liveIds = new Set(this.policy?.candidates.map(routeKey) ?? []);
    const routes = Object.fromEntries(Object.entries(this.routes)
      .filter(([id]) => liveIds.has(id)).slice(0, 64));
    return {
      policy: this.policy && unexpired(this.policy.expiresAt, nowMs) ? this.policy : undefined,
      routes,
      preferredByDevice: this.preferredByDevice,
    };
  }

  attempts(profile: VpnProfile, nowMs = Date.now()): DynamicRouteAttempt[] {
    const eligible = this.eligibleCandidates(profile, nowMs);
    const available = eligible.filter((candidate) => (this.routes[routeKey(candidate)]?.quarantineUntil ?? 0) <= nowMs);
    const preferred = this.preferredByDevice[profile.device?.id ?? ''];
    const sticky = available.find((candidate) => pathId(candidate) === preferred &&
      nowMs - (this.routes[routeKey(candidate)]?.lastSuccessAt ?? 0) < (this.policy?.probe.failbackHoldMs ?? 0));
    available.sort((a, b) => {
      if (sticky) {
        if (a.id === sticky.id) return -1;
        if (b.id === sticky.id) return 1;
      }
      return b.priority - a.priority || b.healthScore - a.healthScore || a.id.localeCompare(b.id);
    });
    const selected: DynamicRouteCandidate[] = [];
    const domains = new Set<string>();
    const limit = this.policy?.probe.maxCandidates ?? 0;
    for (const candidate of available) {
      const domain = failureDomain(candidate);
      if (domains.has(domain)) continue;
      selected.push(candidate);
      domains.add(domain);
      if (selected.length >= limit) break;
    }
    for (const candidate of available) {
      if (selected.length >= limit) break;
      if (!selected.some((item) => item.id === candidate.id)) selected.push(candidate);
    }
    const routed = selected.map((candidate) => ({
      candidate,
      profile: profileWithEndpoint(profile, candidate.endpoint),
    })).filter((item): item is { candidate: DynamicRouteCandidate; profile: VpnProfile } => item.profile !== null);
    const seen = new Set(routed.map((item) => profileEndpoint(item.profile)?.toLowerCase()));
    const declaredEndpoints = selected.length > 0
      ? new Set(eligible.map((candidate) => candidate.endpoint.toLowerCase()))
      : new Set<string>();
    const attempts: DynamicRouteAttempt[] = routed.map(({ candidate, profile: attempt }) => ({ candidate, profile: attempt }));
    for (const legacy of connectionAttemptsForProfile(profile)) {
      const endpoint = profileEndpoint(legacy)?.toLowerCase();
      if (endpoint && (seen.has(endpoint) || declaredEndpoints.has(endpoint))) continue;
      attempts.push({ profile: legacy });
      if (endpoint) seen.add(endpoint);
    }
    return attempts;
  }

  recordFailure(candidate: DynamicRouteCandidate, nowMs = Date.now()): void {
    const key = routeKey(candidate);
    const previous = this.routes[key] ?? { failures: 0, quarantineUntil: 0, lastSuccessAt: 0 };
    const threshold = this.policy?.probe.failureThreshold ?? 2;
    const failures = Math.min(threshold, previous.failures + 1);
    this.routes[key] = {
      failures,
      quarantineUntil: failures >= threshold ? nowMs + (this.policy?.probe.quarantineMs ?? 30_000) : 0,
      lastSuccessAt: previous.lastSuccessAt,
    };
    if (failures >= threshold && this.preferredByDevice[candidate.deviceId] === pathId(candidate)) {
      delete this.preferredByDevice[candidate.deviceId];
    }
    if (this.active && routeKey(this.active) === key) this.active = null;
  }

  recordSuccess(candidate: DynamicRouteCandidate, nowMs = Date.now()): void {
    this.routes[routeKey(candidate)] = { failures: 0, quarantineUntil: 0, lastSuccessAt: nowMs };
    this.preferredByDevice[candidate.deviceId] = pathId(candidate);
    this.active = candidate;
  }

  recordActiveFailure(profile: VpnProfile, nowMs = Date.now()): DynamicRouteCandidate | null {
    const active = this.active;
    if (!active || active.deviceId !== profile.device?.id ||
        active.locationId !== profile.locationId || active.endpoint !== profileEndpoint(profile)) return null;
    this.recordFailure(active, nowMs);
    return active;
  }

  clearActive(): void { this.active = null; }

  private eligibleCandidates(profile: VpnProfile, nowMs: number): DynamicRouteCandidate[] {
    // The route policy only describes AWG3 listeners. Never apply it to an
    // older AWG profile, even when the device id and location happen to match.
    if (!this.policy || !unexpired(this.policy.expiresAt, nowMs) || !profile.device?.id ||
        !/^HeaderProtectionKey\s*=\s*\S+/m.test(profile.config)) return [];
    return this.policy.candidates.filter((candidate) =>
      candidate.deviceId === profile.device?.id &&
      candidate.locationId.toLowerCase() === profile.locationId.toLowerCase() &&
      (!profile.device?.nodeId || candidate.nodeId.toLowerCase() === profile.device.nodeId.toLowerCase()) &&
      (!profile.device?.protocol || candidate.protocol.toLowerCase() === profile.device.protocol.toLowerCase()) &&
      unexpired(candidate.expiresAt, nowMs));
  }
}

export function routeTransport(candidate: DynamicRouteCandidate): 'awg3_direct' | 'awg3_relay' {
  return candidate.pathKind === 'direct' ? 'awg3_direct' : 'awg3_relay';
}

function pathId(candidate: DynamicRouteCandidate): string { return candidate.pathId || candidate.id; }
function routeKey(candidate: DynamicRouteCandidate): string { return `${candidate.id}\u0000${candidate.endpoint}`; }
function failureDomain(candidate: DynamicRouteCandidate): string {
  return candidate.failureDomain?.toLowerCase() || candidate.entryNodeId?.toLowerCase() || candidate.endpoint.toLowerCase();
}
function record(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}
function unexpired(value: unknown, nowMs: number): value is string {
  return typeof value === 'string' && Number.isFinite(Date.parse(value)) && Date.parse(value) > nowMs;
}
function boundedNumber(value: unknown, min: number, max: number, fallback: number): number {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}
function finiteNonnegative(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}
function validEndpoint(endpoint: string): boolean {
  const match = /^(?:\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+):([0-9]{1,5})$/.exec(endpoint);
  const port = Number(match?.[1]);
  return !!match && port >= 1 && port <= 65535;
}
