import { ApiRequestError } from './error';

// Keep the literal dot access: Expo inlines this expression into the app bundle.
export const vexApiBaseUrl = trimTrailingSlash(process.env.EXPO_PUBLIC_VEX_API_BASE_URL || 'https://vexguard.app');

export function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

export function validatedApiBaseUrl(value = vexApiBaseUrl): URL {
  try {
    const url = new URL(value.trim());
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password
      || value.includes('?') || value.includes('#')) {
      throw new Error('invalid API base');
    }
    return url;
  } catch {
    // Do not include configuration text: an invalid URL can contain credentials.
    throw new ApiRequestError('Неверно настроен адрес API.', { code: 'invalid_api_base_url' });
  }
}

export function apiRequestUrl(path: string, baseUrl = vexApiBaseUrl): string {
  const base = validatedApiBaseUrl(baseUrl);
  if (!path.startsWith('/') || path.startsWith('//') || path.includes('\\') || path.includes('#')) {
    throw new ApiRequestError('Некорректный путь API.', { code: 'invalid_api_path' });
  }
  return new URL(`${trimTrailingSlash(base.toString())}${path}`).toString();
}
