export type RoutingPolicyCacheKey = Readonly<{
  region: string;
  platform: string;
}>;

export type CachedRoutingPolicy = Readonly<{
  version: string;
  region: string;
  bypassRanges: readonly string[];
  bypassDomains: readonly string[];
  protectedRanges: readonly string[];
  expiresAt: string;
  payloadBase64: string;
  signatureBase64: string;
  keyId: string;
}>;

export type RoutingPolicyStorage = Readonly<{
  getItemAsync(key: string): Promise<string | null>;
  setItemAsync(key: string, value: string): Promise<void>;
}>;

const storageKeyPrefix = 'vex.vpn.routing_policy.v1';

export class ClientRoutingPolicyCache {
  constructor(private readonly storage: RoutingPolicyStorage) {}

  async load(key: RoutingPolicyCacheKey, now: Date): Promise<Omit<CachedRoutingPolicy, 'expiresAt' | 'payloadBase64' | 'signatureBase64' | 'keyId'> | null> {
    const raw = await this.storage.getItemAsync(storageKey(key)).catch(() => null);
    if (!raw) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as CachedRoutingPolicy;
      const expiresAt = new Date(parsed.expiresAt);
      if (!Number.isFinite(expiresAt.getTime()) || expiresAt.getTime() <= now.getTime() || parsed.region !== key.region) {
        return null;
      }
      return immutablePolicy(parsed);
    } catch {
      return null;
    }
  }

  async save(key: RoutingPolicyCacheKey, policy: CachedRoutingPolicy): Promise<void> {
    await this.storage.setItemAsync(storageKey(key), JSON.stringify({
      version: policy.version,
      region: policy.region,
      bypassRanges: [...policy.bypassRanges],
      bypassDomains: [...policy.bypassDomains],
      protectedRanges: [...policy.protectedRanges],
      expiresAt: policy.expiresAt,
      payloadBase64: policy.payloadBase64,
      signatureBase64: policy.signatureBase64,
      keyId: policy.keyId,
    }));
  }
}

function storageKey(key: RoutingPolicyCacheKey): string {
  return `${storageKeyPrefix}:${key.platform.trim().toLowerCase()}:${key.region.trim().toLowerCase()}`;
}

function immutablePolicy(policy: CachedRoutingPolicy): Omit<CachedRoutingPolicy, 'expiresAt' | 'payloadBase64' | 'signatureBase64' | 'keyId'> {
  return Object.freeze({
    version: policy.version,
    region: policy.region,
    bypassRanges: Object.freeze([...policy.bypassRanges]),
    bypassDomains: Object.freeze([...policy.bypassDomains]),
    protectedRanges: Object.freeze([...policy.protectedRanges]),
  });
}
