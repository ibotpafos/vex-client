import type { EffectiveRoutingPolicy } from './clientRoutingPolicy';
import type { VpnRoutingMode } from './routingPolicy';

const FULL_TUNNEL_IPV4 = '0.0.0.0/0';
const FULL_TUNNEL_IPV6 = '::/0';
const FULL_TUNNEL_INTERVAL: IpInterval = { start: 0, end: 0xffff_ffff };
const MAX_LOCAL_ALLOWED_IPS = 1_500;

export const FULL_TUNNEL_ALLOWED_IPS = Object.freeze([FULL_TUNNEL_IPV4, FULL_TUNNEL_IPV6]);

type IpInterval = Readonly<{
  start: number;
  end: number;
}>;

export function buildLocalTunnelConfig(
  config: string,
  policy: EffectiveRoutingPolicy,
  mode: VpnRoutingMode,
): string {
  const peerSection = findSinglePeerSection(config);
  const allowedIps = nextAllowedIps(policy, mode);
  const lines = config.split(/\r?\n/);
  const nextPeerLines = replacePeerAllowedIps(lines, peerSection.startLine, peerSection.endLine, allowedIps);
  return nextPeerLines.join('\n');
}

export function excludeCidrs(
  baseCidrs: readonly string[],
  excludedCidrs: readonly string[],
): readonly string[] {
  const baseIntervals = normalizeIntervals(baseCidrs);
  const excludedIntervals = normalizeIntervals(excludedCidrs);
  return subtractIntervals(baseIntervals, excludedIntervals).flatMap(intervalToCidrs);
}

function nextAllowedIps(
  policy: EffectiveRoutingPolicy,
  mode: VpnRoutingMode,
): readonly string[] {
  if (mode !== 'all_except_ru' || policy.source === 'full_tunnel' || policy.bypassRanges.length === 0) {
    return FULL_TUNNEL_ALLOWED_IPS;
  }

  try {
    const bypassIntervals = normalizeIntervals(policy.bypassRanges);
    const protectedIntervals = normalizeIntervals(policy.protectedRanges);
    const effectiveBypass = subtractIntervals(bypassIntervals, protectedIntervals);
    const allowedIpv4Cidrs = subtractIntervals([FULL_TUNNEL_INTERVAL], effectiveBypass).flatMap(intervalToCidrs);
    if (allowedIpv4Cidrs.length + 1 > MAX_LOCAL_ALLOWED_IPS) {
      return FULL_TUNNEL_ALLOWED_IPS;
    }
    return Object.freeze([...allowedIpv4Cidrs, FULL_TUNNEL_IPV6]);
  } catch {
    return FULL_TUNNEL_ALLOWED_IPS;
  }
}

function findSinglePeerSection(config: string): { startLine: number; endLine: number } {
  const lines = config.split(/\r?\n/);
  const peerIndexes = lines
    .map((line, index) => line.trim().toLowerCase() === '[peer]' ? index : -1)
    .filter((index) => index >= 0);
  if (peerIndexes.length !== 1) {
    throw new Error('Managed tunnel config must contain a single [Peer] section.');
  }
  const startLine = peerIndexes[0];
  const endLine = lines.findIndex((line, index) => index > startLine && isSectionHeader(line));
  return {
    startLine,
    endLine: endLine >= 0 ? endLine : lines.length,
  };
}

function replacePeerAllowedIps(
  lines: readonly string[],
  peerStartLine: number,
  peerEndLine: number,
  allowedIps: readonly string[],
): string[] {
  const nextLines = [...lines];
  const allowedIpLine = `AllowedIPs = ${allowedIps.join(', ')}`;
  const allowedIndexes = [];
  for (let index = peerStartLine + 1; index < peerEndLine; index += 1) {
    const key = nextLines[index].split('=')[0]?.trim().toLowerCase();
    if (key === 'allowedips') {
      allowedIndexes.push(index);
    }
  }
  if (allowedIndexes.length === 0) {
    nextLines.splice(peerEndLine, 0, allowedIpLine);
    return nextLines;
  }
  nextLines.splice(allowedIndexes[0], allowedIndexes.length, allowedIpLine);
  return nextLines;
}

function isSectionHeader(line: string): boolean {
  const trimmed = line.trim();
  return trimmed.startsWith('[') && trimmed.endsWith(']');
}

function normalizeIntervals(cidrs: readonly string[]): IpInterval[] {
  const intervals = cidrs.map(parseIpv4Cidr);
  const seen = new Set<string>();
  for (const interval of intervals) {
    const key = `${interval.start}-${interval.end}`;
    if (seen.has(key)) {
      throw new Error('duplicate_range');
    }
    seen.add(key);
  }
  return mergeIntervals(intervals);
}

function parseIpv4Cidr(cidr: string): IpInterval {
  const value = cidr.trim();
  const [addressPart, prefixPart = '32'] = value.split('/');
  const prefix = Number(prefixPart);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) {
    throw new Error('invalid_range');
  }
  const octets = addressPart.split('.').map((part) => Number(part));
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    throw new Error('invalid_range');
  }
  const address = ((octets[0] * 256 ** 3) + (octets[1] * 256 ** 2) + (octets[2] * 256) + octets[3]) >>> 0;
  const blockSize = 2 ** (32 - prefix);
  const start = Math.floor(address / blockSize) * blockSize;
  return {
    start,
    end: start + blockSize - 1,
  };
}

function mergeIntervals(intervals: readonly IpInterval[]): IpInterval[] {
  if (intervals.length === 0) {
    return [];
  }
  const sorted = [...intervals].sort((left, right) => left.start - right.start);
  const merged: IpInterval[] = [sorted[0]];
  for (const interval of sorted.slice(1)) {
    const current = merged[merged.length - 1];
    if (interval.start <= current.end + 1) {
      merged[merged.length - 1] = { start: current.start, end: Math.max(current.end, interval.end) };
      continue;
    }
    merged.push(interval);
  }
  return merged;
}

function subtractIntervals(
  baseIntervals: readonly IpInterval[],
  excludedIntervals: readonly IpInterval[],
): IpInterval[] {
  if (excludedIntervals.length === 0) {
    return [...baseIntervals];
  }
  const result: IpInterval[] = [];
  const sortedExclusions = mergeIntervals(excludedIntervals);
  for (const base of mergeIntervals(baseIntervals)) {
    let cursor = base.start;
    for (const exclusion of sortedExclusions) {
      if (exclusion.end < cursor) {
        continue;
      }
      if (exclusion.start > base.end) {
        break;
      }
      if (exclusion.start > cursor) {
        result.push({ start: cursor, end: Math.min(base.end, exclusion.start - 1) });
      }
      cursor = Math.max(cursor, exclusion.end + 1);
      if (cursor > base.end) {
        break;
      }
    }
    if (cursor <= base.end) {
      result.push({ start: cursor, end: base.end });
    }
  }
  return result;
}

function intervalToCidrs(interval: IpInterval): string[] {
  const cidrs: string[] = [];
  let cursor = interval.start;
  while (cursor <= interval.end) {
    let prefix = 32;
    while (prefix > 0) {
      const candidatePrefix = prefix - 1;
      const blockSize = 2 ** (32 - candidatePrefix);
      if (cursor % blockSize !== 0 || cursor + blockSize - 1 > interval.end) {
        break;
      }
      prefix = candidatePrefix;
    }
    cidrs.push(`${numberToIpv4(cursor)}/${prefix}`);
    cursor += 2 ** (32 - prefix);
  }
  return cidrs;
}

function numberToIpv4(value: number): string {
  const octet1 = Math.floor(value / 256 ** 3) % 256;
  const octet2 = Math.floor(value / 256 ** 2) % 256;
  const octet3 = Math.floor(value / 256) % 256;
  const octet4 = value % 256;
  return `${octet1}.${octet2}.${octet3}.${octet4}`;
}
