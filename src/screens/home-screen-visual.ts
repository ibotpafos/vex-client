import type { VpnLocation } from '@/api/vexApi';

import type { ConnectionPhase } from './home-screen-helpers';

export type HomeLocationBackdropKey = 'nl' | 'de' | 'fi' | 'fallback';

export function homeBrandPresentation() {
  return {
    accessibilityLabel: 'VEX VPN',
    usesEmblem: false,
    wordmark: 'VEX',
  } as const;
}

export type HomeConnectionPresentation = {
  action: string;
  helper: string;
  status: string;
  tone: 'idle' | 'busy' | 'connected' | 'warning';
};

const locationCopyByCountry: Record<string, { city: string; country: string }> = {
  DE: { city: 'Франкфурт', country: 'Германия' },
  FI: { city: 'Хельсинки', country: 'Финляндия' },
  NL: { city: 'Амстердам', country: 'Нидерланды' },
};

export function homeLocationBackdropKey(location?: VpnLocation): HomeLocationBackdropKey {
  const countryCode = location?.countryCode.trim().toLowerCase();
  if (countryCode === 'nl' || countryCode === 'de' || countryCode === 'fi') {
    return countryCode;
  }

  const locationID = location?.id.trim().toLowerCase();
  if (locationID === 'nl' || locationID === 'de' || locationID === 'fi') {
    return locationID;
  }
  return 'fallback';
}

export function homeLocationCopy(location: VpnLocation, latencyText: string): {
  city: string;
  countryAndLatency: string;
} {
  const localized = locationCopyByCountry[location.countryCode.trim().toUpperCase()];
  const city = localized?.city ?? (location.city.trim() || location.id.toUpperCase());
  const country = localized?.country ?? location.countryCode.trim().toUpperCase();
  return {
    city,
    countryAndLatency: `${country} · ${latencyText}`,
  };
}

export function homeConnectionPresentation(phase: ConnectionPhase): HomeConnectionPresentation {
  switch (phase) {
    case 'connected':
      return {
        action: 'Подключено',
        helper: 'Соединение защищено',
        status: 'VPN включён',
        tone: 'connected',
      };
    case 'connecting':
      return {
        action: 'Отменить',
        helper: 'Создаём защищённый канал',
        status: 'Подключаем',
        tone: 'busy',
      };
    case 'verifying':
      return {
        action: 'Проверяем',
        helper: 'Ожидаем подтверждение сервера',
        status: 'Проверяем защиту',
        tone: 'busy',
      };
    case 'switching':
      return {
        action: 'Переключение',
        helper: 'Меняем локацию',
        status: 'Меняем локацию',
        tone: 'busy',
      };
    case 'disconnecting':
      return {
        action: 'Отключение',
        helper: 'Завершаем соединение',
        status: 'Отключаем',
        tone: 'busy',
      };
    case 'blocked':
      return {
        action: 'Отключить',
        helper: 'Защита от утечки активна',
        status: 'Интернет заблокирован',
        tone: 'warning',
      };
    case 'degraded':
      return {
        action: 'Восстанавливаем',
        helper: 'Перезапускаем защищённый канал',
        status: 'Восстанавливаем защиту',
        tone: 'warning',
      };
    default:
      return {
        action: 'Подключить',
        helper: 'Одно касание',
        status: 'VPN выключен',
        tone: 'idle',
      };
  }
}
