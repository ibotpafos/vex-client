import * as SecureStore from '@/native/secureStore';
import { vpnResiliencePolicy } from '@/api/vexApi';
import { DynamicRouteEngine, parseDynamicRoutePolicy, type DynamicRouteCandidate, type DynamicRouteSnapshot } from './dynamicRouteCore';
import type { VpnProfile } from './profile';

const storageKey = 'vex.vpn.dynamic_routes.v1';

class DynamicRouteRuntime {
  private owner = '';
  private accessToken = '';
  private generation = 0;
  private sessionIsCurrent: (() => boolean) | undefined;
  private engine = new DynamicRouteEngine();
  private hydration: Promise<void> = Promise.resolve();
  private policyFetch: Promise<void> | null = null;
  private writeQueue: Promise<void> = Promise.resolve();
  private lastFetchAt = 0;

  async prepare(userId: string, accessToken: string, sessionIsCurrent?: () => boolean): Promise<void> {
    if (!userId || !accessToken || sessionIsCurrent?.() === false) return;
    if (this.owner !== userId || this.accessToken !== accessToken || this.sessionIsCurrent?.() === false) {
      this.owner = userId;
      this.accessToken = accessToken;
      this.sessionIsCurrent = sessionIsCurrent;
      const generation = ++this.generation;
      this.engine = new DynamicRouteEngine();
      this.policyFetch = null;
      this.lastFetchAt = 0;
      // Foreground preparation and Connect must share this read. Otherwise a
      // late cache read can replace a newer policy or its route health state.
      this.hydration = SecureStore.getItemAsync(storageKey).catch(() => null).then((raw) => {
        if (generation !== this.generation || sessionIsCurrent?.() === false) return;
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
      });
    }
    const generation = this.generation;
    const current = () => generation === this.generation && sessionIsCurrent?.() !== false;
    await this.hydration;
    if (!current() || this.engine.hasPolicy() || this.policyFetch || Date.now() - this.lastFetchAt < 30_000) return;
    this.lastFetchAt = Date.now();
    // The signed profile remains usable when this optional request is slow or
    // unavailable. Only local hydration belongs on the connection path.
    const fetch = this.refreshPolicy(accessToken, current);
    this.policyFetch = fetch;
    void fetch.finally(() => { if (this.policyFetch === fetch) this.policyFetch = null; });
  }

  private async refreshPolicy(accessToken: string, current: () => boolean): Promise<void> {
    try {
      const policyRaw = await vpnResiliencePolicy(accessToken);
      if (!current()) return;
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
    const generation = this.generation;
    const sessionIsCurrent = this.sessionIsCurrent;
    const current = () => generation === this.generation && sessionIsCurrent?.() !== false;
    const snapshot = this.engine.snapshot();
    delete snapshot.policy;
    if (!owner || !current()) return;
    this.writeQueue = this.writeQueue.then(async () => {
      if (!current()) return;
      const existing = await SecureStore.getItemAsync(storageKey).catch(() => null);
      if (!current()) return;
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
