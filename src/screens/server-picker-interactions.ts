import type { VpnLocation } from '@/api/vexApi';

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
