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
    if (!domain || typeof record.version !== 'number' || !Number.isInteger(record.version) || record.version <= 0) return null;
    return { domains: [domain], reason: '' };
  }
  // Older Go servers encode an absent version snapshot as null.
  if (record.versions !== null && !Array.isArray(record.versions)) return null;
  const versions = record.versions ?? [];
  const parsedDomains = [...new Set(versions.flatMap((version) => {
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

// The pure complete-buffer parser remains the canonical event-field projection.
// This incremental reader bounds each normalized frame before parsing it.
export class CustomerSSEParser {
  private static readonly maximumFrameLength = 64 * 1024;
  private frame: string[] = [];
  private suppressLF = false;
  private exceededFrameLimit = false;

  get hasExceededFrameLimit(): boolean { return this.exceededFrameLimit; }

  append(chunk: string): CustomerSSEEvent[] {
    const events: CustomerSSEEvent[] = [];
    if (this.exceededFrameLimit) return events;
    for (let index = 0; index < chunk.length; index++) {
      const character = chunk[index]!;
      if (this.suppressLF) {
        this.suppressLF = false;
        if (character === '\n') continue;
      }
      const normalized = character === '\r' ? '\n' : character;
      this.suppressLF = character === '\r';
      if (this.frame.length === CustomerSSEParser.maximumFrameLength) {
        this.frame = [];
        this.exceededFrameLimit = true;
        break;
      }
      this.frame.push(normalized);
      if (normalized !== '\n' || this.frame.at(-2) !== '\n') continue;
      events.push(...parseCustomerSSE(this.frame.join('')).events);
      this.frame = [];
    }
    return events;
  }
}

export function customerRealtimeReconnectDelay(attempt: number): number {
  return Math.min(30_000, 1_000 * (2 ** Math.min(Math.max(0, attempt), 5)));
}

function validDomain(value: unknown): CustomerRealtimeDomain | null {
  return typeof value === 'string' && domains.has(value) ? value as CustomerRealtimeDomain : null;
}
