import { clientVersionHeaders, jsonRequest } from '@/api/client';
import * as SecureStore from '@/native/secureStore';
import { ClientRoutingPolicyCache, type RoutingPolicyCacheKey } from './clientRoutingPolicyCache';
import { cacheValidatedRoutingPolicy, type NormalizedRoutingPolicy, type SignedRoutingPolicy } from './clientRoutingPolicyCore';
import { profileSigningKeys } from './profileSigningKeys';
import { verifyP256WithWebCrypto, type P256SignatureVerifier } from './p256Signature';

export { cacheValidatedRoutingPolicy, validateRoutingPolicy, type RoutingPolicyValidationResult, type SignedRoutingPolicy } from './clientRoutingPolicyCore';

export type EffectiveRoutingPolicy = NormalizedRoutingPolicy & Readonly<{
  source: 'network' | 'cache' | 'full_tunnel';
}>;

export async function loadEffectiveRoutingPolicy(
  accessToken: string,
  input: Readonly<{ region: string; platform: string; now: Date }>,
  verifySignature: P256SignatureVerifier = verifyP256WithWebCrypto,
): Promise<EffectiveRoutingPolicy> {
  const cacheKey = normalizedCacheKey(input);
  const cache = new ClientRoutingPolicyCache(SecureStore);
  try {
    const headers = await clientVersionHeaders();
    const query = new URLSearchParams({ region: cacheKey.region, platform: cacheKey.platform, schema_version: '1' });
    const response = await jsonRequest<SignedRoutingPolicy>(`/v1/vpn/routing-policy?${query.toString()}`, { accessToken, headers, suppressErrorLog: true });
    const validated = await cacheValidatedRoutingPolicy(cache, cacheKey, response, input.now, profileSigningKeys, verifySignature);
    if (validated.ok && validated.policy.region === cacheKey.region) return Object.freeze({ ...validated.policy, source: 'network' as const });
  } catch {
    // Keep the last verified, unexpired cache after an unavailable or invalid response.
  }
  const cached = await cache.load(cacheKey, input.now);
  return cached ? Object.freeze({ ...cached, source: 'cache' as const }) : fullTunnelPolicy(cacheKey.region);
}

function normalizedCacheKey(input: Readonly<{ region: string; platform: string }>): RoutingPolicyCacheKey {
  return { region: input.region.trim().toLowerCase(), platform: input.platform.trim().toLowerCase() };
}

function fullTunnelPolicy(region: string): EffectiveRoutingPolicy {
  return Object.freeze({ version: '', region, bypassRanges: Object.freeze([]), bypassDomains: Object.freeze([]), protectedRanges: Object.freeze([]), source: 'full_tunnel' });
}
