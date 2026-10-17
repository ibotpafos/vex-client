import type { VpnRoutingMode } from './routingPolicy';

export type RoutingAuthorization = {
  key_id: string;
  algorithm: string;
  payload_base64: string;
  signature_base64: string;
};

export function routingAuthorization(value: unknown): RoutingAuthorization | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const authorization = value as Partial<RoutingAuthorization>;
  if (authorization.algorithm !== 'ECDSA_P256_SHA256_DER' ||
      typeof authorization.key_id !== 'string' || authorization.key_id.length > 128 ||
      typeof authorization.payload_base64 !== 'string' || authorization.payload_base64.length > 1_398_112 ||
      typeof authorization.signature_base64 !== 'string' || authorization.signature_base64.length > 256) return undefined;
  return authorization as RoutingAuthorization;
}

// Native admission verifies the exact signed payload. JavaScript only carries
// it; outer response fields never become privileged destination exceptions.
export function nativeRoutingParameters(config: string, mode: VpnRoutingMode, authorization?: RoutingAuthorization): string {
  const values = (name: string): string[] => {
    const line = config.split(/\r?\n/).find(line => line.split('=')[0]?.trim().toLowerCase() === name.toLowerCase());
    return line?.slice(line.indexOf('=') + 1).split(',').map(value => value.trim()).filter(Boolean) ?? [];
  };
  return JSON.stringify({ addresses: values('Address'), dns: values('DNS'), mode, ...(authorization ? { authorization } : {}) });
}
