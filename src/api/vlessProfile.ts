export type VlessProfileResponse = {
  schema_version: 1;
  protocol: 'vless';
  device_id: string;
  location_id: string;
  route_id: string;
  expires_at: string;
  config: string;
};

/** Credentials remain in memory; invalid or cross-device responses fail closed. */
export function parseVlessProfileResponse(value: unknown, deviceId: string, locationId: string, nowMs = Date.now()): VlessProfileResponse {
  if (!value || typeof value !== 'object') throw invalidProfile();
  const row = value as Partial<VlessProfileResponse>;
  if (row.schema_version !== 1 || row.protocol !== 'vless' || row.device_id !== deviceId || row.location_id !== locationId ||
      typeof row.route_id !== 'string' || !/^[A-Za-z0-9_.:-]{1,128}$/.test(row.route_id) ||
      typeof row.expires_at !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(row.expires_at) ||
      !Number.isFinite(Date.parse(row.expires_at)) || Date.parse(row.expires_at) <= nowMs ||
      typeof row.config !== 'string' || !row.config.trim() || row.config.length > 256 * 1024 || utf8Bytes(row.config) > 256 * 1024) throw invalidProfile();
  let config: unknown;
  try { config = JSON.parse(row.config); } catch { throw invalidProfile(); }
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw invalidProfile();
  const outbounds = (config as { outbounds?: unknown }).outbounds;
  if (!Array.isArray(outbounds) || outbounds.length !== 1) throw invalidProfile();
  const outbound = outbounds[0];
  const stream = outbound?.streamSettings;
  if (!outbound || typeof outbound !== 'object' || outbound.protocol !== 'vless' ||
      Object.hasOwn(outbound, 'proxySettings') || !stream || typeof stream !== 'object' ||
      stream.network !== 'xhttp' || stream.security !== 'tls' ||
      !stream.tlsSettings || typeof stream.tlsSettings !== 'object' || Array.isArray(stream.tlsSettings) ||
      (stream.tlsSettings.allowInsecure !== undefined && stream.tlsSettings.allowInsecure !== false) || (stream.sockopt && Object.hasOwn(stream.sockopt, 'dialerProxy'))) throw invalidProfile();
  return row as VlessProfileResponse;
}

function invalidProfile(): Error {
  return new Error('Сервер вернул некорректный VLESS-профиль. Повторите подключение.');
}

function utf8Bytes(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const code = character.codePointAt(0)!;
    bytes += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
  }
  return bytes;
}
