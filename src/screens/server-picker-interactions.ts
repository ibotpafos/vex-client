import type { VpnLocation } from '@/api/vexApi';
import { chooseBestVpnLocation } from '@/vpn/serverSelection';

export type ServerPickerSource = 'all_locations' | 'carousel';

export function serverPickerActionForSource(_source: ServerPickerSource): 'open_picker' {
  return 'open_picker';
}

export function serverPickerRowPresentation(
  location: VpnLocation,
  context: {
    busy: boolean;
    selected: boolean;
    selectedLatencyText?: string;
  },
) {
  const latency = context.selected && context.selectedLatencyText
    ? context.selectedLatencyText
    : typeof location.latencyMs === 'number' && Number.isFinite(location.latencyMs)
      ? `${Math.max(0, Math.round(location.latencyMs))} мс`
      : '-- мс';
  const title = ({ DE: 'Германия', FI: 'Финляндия', NL: 'Нидерланды' } as Record<string, string>)[
    location.countryCode.toUpperCase()
  ] ?? location.city;
  const disabled = context.busy || location.healthyNodes <= 0;

  return {
    accessibilityLabel: [title, latency, context.selected ? 'выбрано' : null]
      .filter(Boolean)
      .join(', '),
    disabled,
    latency,
    selected: context.selected,
  } as const;
}

export type VpnCountryLocationGroup = {
  bestLocation?: VpnLocation;
  countryCode: string;
  flagEmoji?: string;
  locations: VpnLocation[];
  title: string;
};

export function groupVpnLocationsByCountry(locations: VpnLocation[]): VpnCountryLocationGroup[] {
  const groups = new Map<string, VpnLocation[]>();
  for (const location of locations) {
    const countryCode = location.countryCode.trim().toUpperCase() || 'OTHER';
    const current = groups.get(countryCode) ?? [];
    current.push(location);
    groups.set(countryCode, current);
  }

  return [...groups.entries()].map(([countryCode, countryLocations]) => {
    const bestLocation = chooseBestVpnLocation(countryLocations);
    const orderedLocations = [...countryLocations].sort((left, right) => {
      if (left.id === bestLocation?.id) return -1;
      if (right.id === bestLocation?.id) return 1;
      const leftLatency = typeof left.latencyMs === 'number' ? left.latencyMs : Number.POSITIVE_INFINITY;
      const rightLatency = typeof right.latencyMs === 'number' ? right.latencyMs : Number.POSITIVE_INFINITY;
      return leftLatency - rightLatency;
    });
    const representative = bestLocation ?? orderedLocations[0];
    return {
      bestLocation,
      countryCode,
      flagEmoji: representative?.flagEmoji,
      locations: orderedLocations,
      title: countryTitle(countryCode, representative?.city),
    };
  });
}

export function serverPickerLocationTitle(location: VpnLocation, ordinal?: number): string {
  const rawCity = location.city.trim();
  if (/\b(?:vex|awg|features?)\b/i.test(rawCity)) {
    return typeof ordinal === 'number' ? `Сервер ${ordinal}` : 'Сервер';
  }
  return ({
    amsterdam: 'Амстердам',
    finland: 'Хельсинки',
    frankfurt: 'Франкфурт',
    germany: 'Франкфурт',
    helsinki: 'Хельсинки',
    netherlands: 'Амстердам',
  } as Record<string, string>)[rawCity.toLowerCase()] ?? (rawCity || location.id.toUpperCase());
}

export function serverCountLabel(count: number): string {
  const normalized = Math.max(0, Math.round(count));
  const mod100 = normalized % 100;
  const mod10 = normalized % 10;
  const noun = mod100 >= 11 && mod100 <= 14
    ? 'серверов'
    : mod10 === 1
      ? 'сервер'
      : mod10 >= 2 && mod10 <= 4
        ? 'сервера'
        : 'серверов';
  return `${normalized} ${noun}`;
}

export function serverPickerCountryGapDp(): number {
  return 10;
}

function countryTitle(countryCode: string, fallback?: string): string {
  return ({ DE: 'Германия', FI: 'Финляндия', NL: 'Нидерланды' } as Record<string, string>)[countryCode]
    ?? fallback
    ?? countryCode;
}
