export const customerRealtimeDomains = [
  'account',
  'entitlement',
  'billing',
  'devices',
  'provisioning',
  'connection',
  'family',
  'support',
  'releases',
  'status',
] as const;

export type CustomerRealtimeDomain = (typeof customerRealtimeDomains)[number];
export type CustomerRealtimeEventType = 'customer.change' | 'customer.resync' | 'customer.session.revoked' | 'customer.heartbeat';
export type CustomerSSEEvent = { type: CustomerRealtimeEventType; id: string; data: string };

const domains = new Set<string>(customerRealtimeDomains);
const eventTypes = new Set<string>(['customer.change', 'customer.resync', 'customer.session.revoked', 'customer.heartbeat']);

export function customerRealtimeMetadata(type: CustomerRealtimeEventType, data: string): { domains: CustomerRealtimeDomain[]; reason: string } | null {
  let payload: unknown;
  try {
    payload = JSON.parse(data);
  } catch {
    return null;
  }
  if (!payload || typeof payload !== 'object') return null;
  const record = payload as Record<string, unknown>;
  if (type === 'customer.heartbeat') return { domains: [], reason: '' };
  if (type === 'customer.session.revoked') {
    return { domains: [], reason: typeof record.reason === 'string' ? record.reason : 'session_invalid' };
  }
  if (type === 'customer.change') {
    const domain = validDomain(record.domain);
    if (!domain || typeof record.version !== 'number' || record.version <= 0) return null;
    return { domains: [domain], reason: '' };
  }
  if (!Array.isArray(record.versions)) return null;
  const parsedDomains = [...new Set(record.versions.flatMap((version) => {
    if (!version || typeof version !== 'object') return [];
    const domain = validDomain((version as Record<string, unknown>).domain);
    return domain ? [domain] : [];
  }))];
  return { domains: parsedDomains, reason: typeof record.reason === 'string' ? record.reason : 'resync' };
}

export function customerRealtimeInvalidationRoots(input: readonly CustomerRealtimeDomain[]): string[] {
  const roots = new Set<string>();
  for (const domain of input) {
    switch (domain) {
      case 'account':
        break;
      case 'entitlement':
      case 'billing':
        roots.add('entitlement');
        roots.add('billing-summary');
        break;
      case 'devices':
      case 'provisioning':
      case 'connection':
      case 'family':
        roots.add('vpn-devices');
        roots.add('vpn-profile');
        break;
      case 'releases':
        roots.add('android-update');
        roots.add('ios-update');
        break;
      case 'support':
      case 'status':
        break;
    }
  }
  return [...roots].sort();
}

export function parseCustomerSSE(input: string): { events: CustomerSSEEvent[]; remainder: string } {
  const normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  const boundary = normalized.lastIndexOf('\n\n');
  if (boundary < 0) return { events: [], remainder: normalized };
  const complete = normalized.slice(0, boundary);
  const remainder = normalized.slice(boundary + 2);
  const events: CustomerSSEEvent[] = [];
  for (const frame of complete.split('\n\n')) {
    let type = 'message';
    let id = '';
    const data: string[] = [];
    for (const line of frame.split('\n')) {
      if (line.startsWith('event:')) type = line.slice(6).trim();
      else if (line.startsWith('id:')) id = line.slice(3).trim();
      else if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
    }
    if (eventTypes.has(type) && data.length > 0) {
      events.push({ type: type as CustomerRealtimeEventType, id, data: data.join('\n') });
    }
  }
  return { events, remainder };
}

export function customerRealtimeReconnectDelay(attempt: number): number {
  return Math.min(30_000, 1_000 * (2 ** Math.min(Math.max(0, attempt), 5)));
}

function validDomain(value: unknown): CustomerRealtimeDomain | null {
  return typeof value === 'string' && domains.has(value) ? value as CustomerRealtimeDomain : null;
}
