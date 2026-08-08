import { ClientRoutingPolicyCache, type RoutingPolicyCacheKey } from './clientRoutingPolicyCache';
import { profileSigningKeys, type ProfileSigningKey } from './profileSigningKeys';
import { verifyP256WithWebCrypto, type P256SignatureVerifier } from './p256Signature';

const schema = 'vex-routing-policy/v1';
const algorithm = 'ECDSA_P256_SHA256_DER';
const maxBytes = 1 << 20;
const maxCidrs = 4096;
const maxDomains = 1024;
const maxTtlMs = 24 * 60 * 60 * 1000;

export type SignedRoutingPolicy = Readonly<{ schema?: string; version?: string; region?: string; platform?: string; issued_at?: string; expires_at?: string; bypass_ranges?: string[]; bypass_domains?: string[]; protected_ranges?: string[]; authorization: Readonly<{ algorithm: string; key_id: string; payload_base64: string; signature_base64: string }> }>;
export type NormalizedRoutingPolicy = Readonly<{ version: string; region: string; bypassRanges: readonly string[]; bypassDomains: readonly string[]; protectedRanges: readonly string[] }>;
export type RoutingPolicyValidationResult = Readonly<{ ok: true; policy: NormalizedRoutingPolicy }> | Readonly<{ ok: false; reason: string }>;

export async function validateRoutingPolicy(value: SignedRoutingPolicy, now: Date, keys: Readonly<Record<string, ProfileSigningKey>> = profileSigningKeys, verifySignature: P256SignatureVerifier = verifyP256WithWebCrypto): Promise<RoutingPolicyValidationResult> {
  const auth = value?.authorization;
  if (!auth || auth.algorithm !== algorithm) return invalid('invalid_algorithm');
  const key = keys[auth.key_id];
  if (!key) return invalid('unknown_key');
  const payload = decodeBase64Url(auth.payload_base64);
  const signature = decodeBase64Url(auth.signature_base64);
  if (!payload || !signature) return invalid('invalid_base64');
  if (payload.byteLength > maxBytes) return invalid('payload_too_large');
  const parsed = parsePayload(payload);
  if (!parsed) return invalid('invalid_payload');
  const normalized = normalizePayload(parsed, now);
  if (!normalized.ok) return normalized;
  return await verifySignature(auth.payload_base64, auth.signature_base64, key.subjectPublicKeyInfoBase64).catch(() => false)
    ? normalized
    : invalid('invalid_signature');
}

export async function cacheValidatedRoutingPolicy(cache: ClientRoutingPolicyCache, cacheKey: RoutingPolicyCacheKey, response: SignedRoutingPolicy, now: Date, keys: Readonly<Record<string, ProfileSigningKey>> = profileSigningKeys, verifySignature: P256SignatureVerifier = verifyP256WithWebCrypto): Promise<RoutingPolicyValidationResult> {
  const validated = await validateRoutingPolicy(response, now, keys, verifySignature);
  if (!validated.ok) return validated;
  const payload = parsePayload(decodeBase64Url(response.authorization.payload_base64));
  if (!payload || typeof payload.expires_at !== 'string') return invalid('invalid_payload');
  await cache.save(cacheKey, {
    ...validated.policy,
    expiresAt: payload.expires_at,
    payloadBase64: response.authorization.payload_base64,
    signatureBase64: response.authorization.signature_base64,
    keyId: response.authorization.key_id,
  });
  return validated;
}

function normalizePayload(payload: Record<string, unknown>, now: Date): RoutingPolicyValidationResult {
  if (payload.schema !== schema) return invalid('incompatible_schema');
  if (typeof payload.version !== 'string' || !payload.version.trim()) return invalid('invalid_version');
  if (!isRegion(payload.region) || typeof payload.platform !== 'string' || !payload.platform.trim()) return invalid('invalid_identity');
  const issuedAt = timestamp(payload.issued_at);
  const expiresAt = timestamp(payload.expires_at);
  if (!issuedAt || !expiresAt) return invalid('invalid_time');
  if (issuedAt.getTime() > now.getTime()) return invalid('issued_in_future');
  if (expiresAt.getTime() <= now.getTime()) return invalid('expired');
  if (expiresAt.getTime() - issuedAt.getTime() > maxTtlMs) return invalid('ttl_too_long');
  const bypassRanges = ranges(payload.bypass_ranges);
  if (!bypassRanges.ok) return bypassRanges;
  const protectedRanges = ranges(payload.protected_ranges);
  if (!protectedRanges.ok) return protectedRanges;
  if (bypassRanges.values.length + protectedRanges.values.length > maxCidrs) return invalid('too_many_ranges');
  const bypassDomains = domains(payload.bypass_domains);
  if (!bypassDomains.ok) return bypassDomains;
  return { ok: true, policy: Object.freeze({ version: payload.version.trim(), region: payload.region.toLowerCase(), bypassRanges: Object.freeze(bypassRanges.values), bypassDomains: Object.freeze(bypassDomains.values), protectedRanges: Object.freeze(protectedRanges.values) }) };
}

function ranges(value: unknown): Readonly<{ ok: true; values: string[] }> | Readonly<{ ok: false; reason: string }> {
  if (!Array.isArray(value)) return invalid('invalid_range');
  if (value.length > maxCidrs) return invalid('too_many_ranges');
  const seen = new Set<string>(); const values: string[] = [];
  for (const item of value) {
    const range = typeof item === 'string' ? ipv4Cidr(item) : null;
    if (!range) return invalid('invalid_range');
    if (seen.has(range)) return invalid('duplicate_range');
    seen.add(range); values.push(range);
  }
  return { ok: true, values: values.sort() };
}

function domains(value: unknown): Readonly<{ ok: true; values: string[] }> | Readonly<{ ok: false; reason: string }> {
  if (!Array.isArray(value)) return invalid('invalid_domain');
  if (value.length > maxDomains) return invalid('too_many_domains');
  const seen = new Set<string>(); const values: string[] = [];
  for (const item of value) {
    const domain = typeof item === 'string' ? item.trim().toLowerCase() : '';
    if (!domain || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(domain)) return invalid('invalid_domain');
    if (seen.has(domain)) return invalid('duplicate_domain');
    seen.add(domain); values.push(domain);
  }
  return { ok: true, values: values.sort() };
}

function ipv4Cidr(value: string): string | null {
  const match = /^([0-9]{1,3}(?:\.[0-9]{1,3}){3})\/(\d{1,2})$/.exec(value.trim());
  if (!match) return null;
  const prefix = Number(match[2]); const octets = match[1].split('.').map(Number);
  if (prefix > 32 || octets.some((item) => item > 255)) return null;
  const address = (((octets[0] << 24) >>> 0) + (octets[1] << 16) + (octets[2] << 8) + octets[3]) >>> 0;
  const mask = prefix === 0 ? 0 : ((0xffffffff << (32 - prefix)) >>> 0);
  const network = address & mask;
  return `${(network >>> 24) & 255}.${(network >>> 16) & 255}.${(network >>> 8) & 255}.${network & 255}/${prefix}`;
}

function decodeBase64Url(value: string): Uint8Array | null {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+={0,2}$/.test(value)) return null;
  try { const base64 = value.replace(/-/g, '+').replace(/_/g, '/'); const binary = atob(base64 + '='.repeat((4 - base64.length % 4) % 4)); return Uint8Array.from(binary, (c) => c.charCodeAt(0)); } catch { return null; }
}
function parsePayload(value: Uint8Array | null): Record<string, unknown> | null { if (!value) return null; try { const parsed = JSON.parse(new TextDecoder().decode(value)); return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null; } catch { return null; } }
function timestamp(value: unknown): Date | null { const date = typeof value === 'string' ? new Date(value) : new Date('invalid'); return Number.isFinite(date.getTime()) ? date : null; }
function isRegion(value: unknown): value is string { return typeof value === 'string' && /^[a-z]{2}$/.test(value.toLowerCase()); }
function invalid(reason: string): Readonly<{ ok: false; reason: string }> { return { ok: false, reason }; }
