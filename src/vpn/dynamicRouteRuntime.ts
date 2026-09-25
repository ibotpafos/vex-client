import * as SecureStore from '@/native/secureStore';
import { vpnResiliencePolicy } from '@/api/vexApi';
import { DynamicRouteEngine, parseDynamicRoutePolicy, type DynamicRouteCandidate, type DynamicRouteSnapshot } from './dynamicRouteCore';
import type { VpnProfile } from './profile';

const storageKey = 'vex.vpn.dynamic_routes.v1';

class DynamicRouteRuntime {
  private owner = '';
  private engine = new DynamicRouteEngine();
  private writeQueue: Promise<void> = Promise.resolve();
  private lastFetchAt = 0;

  async prepare(userId: string, accessToken: string): Promise<void> {
    if (this.owner !== userId) {
      this.owner = userId;
      this.engine = new DynamicRouteEngine();
      this.lastFetchAt = 0;
      const raw = await SecureStore.getItemAsync(storageKey).catch(() => null);
      if (this.owner !== userId) return;
      if (raw) {
        try {
          const saved = JSON.parse(raw) as { owner?: string; policyRaw?: unknown; snapshot?: DynamicRouteSnapshot };
          if (saved.owner === userId && saved.snapshot) {
            const policy = parseDynamicRoutePolicy(saved.policyRaw);
            this.engine.restore({ ...saved.snapshot, policy: policy ?? undefined });
          }
        } catch {
          // A damaged cache cannot prevent a normal VPN connection.
        }
      }
    }
    if (this.owner !== userId || this.engine.hasPolicy() || Date.now() - this.lastFetchAt < 30_000) return;
    this.lastFetchAt = Date.now();
    try {
      const policyRaw = await vpnResiliencePolicy(accessToken);
      if (this.owner !== userId) return;
      const policy = parseDynamicRoutePolicy(policyRaw);
      if (policy) {
        this.engine.setPolicy(policy);
        this.save(policyRaw);
      }
    } catch {
      // Older API releases and temporary API failures use the unexpired cache.
    }
  }

  attempts(profile: VpnProfile) { return this.engine.attempts(profile); }

  recordFailure(candidate: DynamicRouteCandidate): void {
    this.engine.recordFailure(candidate);
    this.save();
  }

  recordSuccess(candidate: DynamicRouteCandidate): void {
    this.engine.recordSuccess(candidate);
    this.save();
  }

  recordActiveFailure(profile: VpnProfile): DynamicRouteCandidate | null {
    const candidate = this.engine.recordActiveFailure(profile);
    if (candidate) this.save();
    return candidate;
  }

  clearActive(): void { this.engine.clearActive(); }

  private save(policyRaw?: unknown): void {
    const owner = this.owner;
    const snapshot = this.engine.snapshot();
    delete snapshot.policy;
    if (!owner) return;
    this.writeQueue = this.writeQueue.then(async () => {
      if (this.owner !== owner) return;
      const existing = await SecureStore.getItemAsync(storageKey).catch(() => null);
      if (this.owner !== owner) return;
      let cachedRaw = policyRaw;
      if (!cachedRaw && existing) {
        try {
          const saved = JSON.parse(existing) as { owner?: string; policyRaw?: unknown };
          if (saved.owner === owner) cachedRaw = saved.policyRaw;
        } catch { /* Replace a damaged cache. */ }
      }
      await SecureStore.setItemAsync(storageKey, JSON.stringify({ owner, policyRaw: cachedRaw, snapshot })).catch(() => undefined);
    }).catch(() => undefined);
  }
}

export const dynamicRouteRuntime = new DynamicRouteRuntime();
